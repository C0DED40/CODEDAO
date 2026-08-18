// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IStargate,
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt,
    OFTLimit,
    OFTFeeDetail,
    Ticket,
    ILayerZeroComposer,
    ComposeMsgCodec
} from "../../src/interfaces/ILayerZero.sol";

/// @dev A Stargate pool that takes a settable protocol fee, so a test can reproduce the case the fee
///      buffer exists for: less arrives than the manifest claims.
contract MockStargate is IStargate {
    /// @dev A real Stargate deployment is a pool per chain holding that chain's own WETH. Modelling
    ///      it with one token would let a test pass that could not work on chain, so the source and
    ///      destination assets are separate here.
    IERC20 public immutable weth;
    IERC20 public immutable homeWeth;
    uint256 public nativeFee = 0.01 ether;
    uint16 public protocolFeeBps = 10; // 0.1%

    SendParam public lastParam;
    uint256 public sends;

    error SlippageBound();

    constructor(IERC20 weth_, IERC20 homeWeth_) {
        weth = weth_;
        homeWeth = homeWeth_;
    }

    /// @dev Explicit accessors: the auto-generated getter for a struct with `bytes` members returns a
    ///      flat tuple, which is awkward to read in assertions.
    function lastComposeMsg() external view returns (bytes memory) {
        return lastParam.composeMsg;
    }

    function lastAmountLD() external view returns (uint256) {
        return lastParam.amountLD;
    }

    function lastMinAmountLD() external view returns (uint256) {
        return lastParam.minAmountLD;
    }

    function lastTo() external view returns (bytes32) {
        return lastParam.to;
    }

    function setNativeFee(uint256 f) external {
        nativeFee = f;
    }

    function setProtocolFeeBps(uint16 bps) external {
        protocolFeeBps = bps;
    }

    function received(uint256 amountLD) public view returns (uint256) {
        return amountLD - (amountLD * protocolFeeBps) / 10_000;
    }

    function quoteSend(SendParam calldata, bool) external view returns (MessagingFee memory) {
        return MessagingFee(nativeFee, 0);
    }

    function quoteOFT(SendParam calldata p)
        external
        view
        returns (OFTLimit memory, OFTFeeDetail[] memory, OFTReceipt memory)
    {
        return (OFTLimit(0, type(uint256).max), new OFTFeeDetail[](0), OFTReceipt(p.amountLD, received(p.amountLD)));
    }

    function token() external view returns (address) {
        return address(weth);
    }

    function approvalRequired() external pure returns (bool) {
        return true;
    }

    function sendToken(SendParam calldata p, MessagingFee calldata fee, address)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory, Ticket memory)
    {
        uint256 out = received(p.amountLD);
        if (out < p.minAmountLD) revert SlippageBound();
        if (p.amountLD != 0) weth.transferFrom(msg.sender, address(this), p.amountLD);

        lastParam = p;
        ++sends;

        return (
            MessagingReceipt(keccak256(abi.encode(sends)), uint64(sends), fee),
            OFTReceipt(p.amountLD, out),
            Ticket(0, "")
        );
    }

    /// @dev Complete the crossing: deliver the tokens and fire the composed callback, exactly as the
    ///      real pool and endpoint pair do.
    function deliver(address endpoint, address composer, uint32 srcEid, bytes32 composeFrom) external {
        uint256 out = received(lastParam.amountLD);
        if (out != 0) homeWeth.transfer(composer, out);

        bytes memory framed = abi.encodePacked(
            uint64(1), // nonce
            srcEid,
            out, // amountLD, as computed on the destination side
            composeFrom,
            lastParam.composeMsg
        );

        vmPrank(endpoint);
        ILayerZeroComposer(composer).lzCompose(address(this), bytes32(uint256(1)), framed, address(0), "");
    }

    /// @dev Foundry's prank cheatcode, reached without inheriting Test into a mock.
    function vmPrank(address who) internal {
        address vm = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;
        (bool ok,) = vm.call(abi.encodeWithSignature("prank(address)", who));
        require(ok, "prank failed");
    }
}
