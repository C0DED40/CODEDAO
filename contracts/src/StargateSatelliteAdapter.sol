// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBridgeAdapter} from "./interfaces/IBridge.sol";
import {IStargate, SendParam, MessagingFee, MessagingReceipt, ComposeMsgCodec} from "./interfaces/ILayerZero.sol";

/// @title StargateSatelliteAdapter
/// @notice Sends a batch of WETH and its manifest from a satellite chain to the home chain (§9).
///
/// @dev `Satellite.sol` deliberately knows nothing about this contract's internals; it calls
///      `quoteFee` and `send` (see `IBridgeAdapter`) and everything Stargate-specific lives here.
///      Replacing Stargate means writing a sibling of this file and one governance call, with no
///      change to the satellite, the receiver, or any test of either.
///
///      Two properties are worth stating because they are the ones that would lose value silently.
///
///      **The minimum received is bounded.** Stargate charges a protocol fee and can deliver less
///      than was sent, so `minAmountLD` is set from a governance-tunable tolerance rather than left
///      at zero. A crossing that would arrive below the bound reverts on the source chain, where the
///      WETH is still recoverable, instead of arriving thin and being credited as a full repayment.
///
///      **The manifest rides with the value.** The `Repayment[]` payload travels as Stargate's
///      `composeMsg`, so value and manifest arrive in the same crossing and cannot be separated,
///      reordered, or replayed independently. Bridging them over two channels would create a window
///      where the home chain holds WETH it cannot attribute to a vintage.
contract StargateSatelliteAdapter is IBridgeAdapter {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    IStargate public immutable stargate;
    IERC20 public immutable weth;

    /// @notice The satellite this adapter serves. The only address permitted to send.
    address public immutable satellite;

    /// @notice LayerZero endpoint id of the home chain.
    uint32 public immutable homeEid;

    /// @notice The home-chain composer that receives the batch.
    address public immutable homeAdapter;

    /// @notice Cross-chain governance executor, as on the satellite (§14, DECISIONS §2.23).
    address public governor;

    /// @notice Tolerance on what Stargate delivers, in bps. Default 50 (0.5%).
    uint16 public deliveryToleranceBps = 50;

    /// @notice Gas the destination executor is paid to run `lzCompose`.
    uint128 public composeGasLimit = 500_000;

    event BatchSent(uint256 wethAmount, uint256 minReceived, uint256 nativeFee, bytes32 guid);
    event ParametersSet(uint16 deliveryToleranceBps, uint128 composeGasLimit);

    error NotSatellite();
    error NotGovernor();
    error ZeroAddress();
    error FeeNotCovered();
    error OutOfRange();

    constructor(
        IStargate stargate_,
        IERC20 weth_,
        address satellite_,
        uint32 homeEid_,
        address homeAdapter_,
        address governor_
    ) {
        if (
            address(stargate_) == address(0) || address(weth_) == address(0) || satellite_ == address(0)
                || homeAdapter_ == address(0) || governor_ == address(0)
        ) revert ZeroAddress();
        stargate = stargate_;
        weth = weth_;
        satellite = satellite_;
        homeEid = homeEid_;
        homeAdapter = homeAdapter_;
        governor = governor_;
    }

    /// @notice Native-gas cost of delivering `payload` and its WETH.
    /// @dev Quoted live rather than estimated, because §15's batch trigger is a multiple of this
    ///      figure and a stale one would move the trigger.
    function quoteFee(bytes calldata payload) external view returns (uint256 nativeFee) {
        // Quoted against a nominal amount: Stargate's messaging fee depends on the payload and the
        // destination, not on the size of the transfer.
        SendParam memory p = _params(1 ether, payload);
        MessagingFee memory fee = stargate.quoteSend(p, false);
        nativeFee = fee.nativeFee;
    }

    function send(uint256 wethAmount, bytes calldata payload) external payable {
        if (msg.sender != satellite) revert NotSatellite();

        SendParam memory p = _params(wethAmount, payload);
        MessagingFee memory fee = stargate.quoteSend(p, false);
        if (msg.value < fee.nativeFee) revert FeeNotCovered();

        if (wethAmount != 0) {
            weth.safeTransferFrom(satellite, address(this), wethAmount);
            weth.forceApprove(address(stargate), wethAmount);
        }

        // Refunds go to the satellite, which is where the maintenance-funded gas came from.
        (MessagingReceipt memory receipt,,) = stargate.sendToken{value: fee.nativeFee}(p, fee, satellite);

        if (wethAmount != 0) weth.forceApprove(address(stargate), 0);
        emit BatchSent(wethAmount, p.minAmountLD, fee.nativeFee, receipt.guid);
    }

    function _params(uint256 wethAmount, bytes memory payload) internal view returns (SendParam memory p) {
        p.dstEid = homeEid;
        p.to = ComposeMsgCodec.addressToBytes32(homeAdapter);
        p.amountLD = wethAmount;
        // Bounded, not zero. A thin arrival credited as a full repayment is a silent loss.
        p.minAmountLD = (wethAmount * (BPS - deliveryToleranceBps)) / BPS;
        p.extraOptions = _composeOption(composeGasLimit);
        p.composeMsg = payload;
        p.oftCmd = "";
    }

    /// @dev LayerZero executor options, type 3, one `lzCompose` instruction.
    ///      Layout: [uint16 type=3][uint8 workerId=1][uint16 optionSize][uint8 optionType=3]
    ///              [uint16 index][uint128 gas]
    function _composeOption(uint128 gas) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint16(3), // options type 3
            uint8(1), // executor worker id
            uint16(19), // option length: 1 + 2 + 16
            uint8(3), // OPTION_TYPE_LZCOMPOSE
            uint16(0), // compose index
            gas
        );
    }

    function setParameters(uint16 toleranceBps, uint128 gasLimit) external {
        if (msg.sender != governor) revert NotGovernor();
        // Zero tolerance reverts every crossing, since Stargate always takes a fee. Above 5% the
        // bound stops protecting the batch.
        if (toleranceBps == 0 || toleranceBps > 500) revert OutOfRange();
        if (gasLimit < 100_000 || gasLimit > 5_000_000) revert OutOfRange();
        deliveryToleranceBps = toleranceBps;
        composeGasLimit = gasLimit;
        emit ParametersSet(toleranceBps, gasLimit);
    }

    function setGovernor(address governor_) external {
        if (msg.sender != governor) revert NotGovernor();
        if (governor_ == address(0)) revert ZeroAddress();
        governor = governor_;
    }

    receive() external payable {}
}
