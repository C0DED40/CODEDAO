// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRepaymentReceiver, Repayment} from "./interfaces/IBridge.sol";
import {ILayerZeroComposer, ComposeMsgCodec} from "./interfaces/ILayerZero.sol";

/// @title StargateHomeAdapter
/// @notice Receives a bridged batch on the home chain and hands it to the receiver (§9 step 4).
///
/// @dev Stargate delivers the WETH to this contract and then calls `lzCompose` with the manifest. The
///      adapter forwards both onward, so `Receiver.sol` never learns what bridge was used.
///
///      **Three checks decide whether a delivery is genuine.** Only the endpoint may call
///      `lzCompose`, or anyone with a well-formed message could announce arrivals that never happened.
///      Only the Stargate pool may be the composing sender. And the (source endpoint id, composer)
///      pair must match the registry, because without it any Stargate user on any connected chain
///      could send dust with a fabricated manifest and have it credited to a vintage.
///
///      **The landed amount comes from the message header, not the manifest.** `OFTComposeMsgCodec`
///      puts the amount that actually arrived in the prefix, written by the destination-side OFT. The
///      manifest's figures are the source chain's claim. Where the two disagree the header wins,
///      because it is the only one the home chain computed itself.
///
///      **And the two normally do disagree**, which is the substantive thing this contract handles.
///      Stargate takes a protocol fee, so less lands than the satellite sent. §9 is explicit that
///      "bridge and swap costs are paid from the maintenance slice, so stakers' distributions are
///      never haircut by infrastructure", so the shortfall is covered from a maintenance-funded
///      buffer held here and the full manifest value reaches the vintages. Only if that buffer is
///      empty does the shortfall fall on the repayment itself, and then it is scaled across the
///      entries pro-rata and announced in an event rather than absorbed quietly. A silent haircut
///      would make §9's promise false in exactly the case where nobody was watching.
contract StargateHomeAdapter is ILayerZeroComposer {
    using SafeERC20 for IERC20;

    IERC20 public immutable weth;
    IRepaymentReceiver public immutable receiver;

    /// @notice The LayerZero endpoint on this chain, the only permitted caller of `lzCompose`.
    address public immutable endpoint;

    /// @notice The Stargate pool that delivers WETH here, the only permitted composing sender.
    address public immutable stargate;

    address public immutable timelock;

    /// @notice Registered satellite adapters, keyed by source endpoint id.
    mapping(uint32 srcEid => bytes32 satelliteAdapter) public satelliteFor;

    /// @notice WETH held to cover bridge fees, funded from the maintenance slice (§2.2, §9).
    uint256 public feeBuffer;

    event SatelliteRegistered(uint32 indexed srcEid, bytes32 adapter);
    event BufferFunded(uint256 amount, uint256 buffer);
    event BufferSwept(uint256 amount);
    event ShortfallCovered(uint32 indexed srcEid, uint256 shortfall, uint256 bufferLeft);
    event ShortfallSocialised(uint32 indexed srcEid, uint256 reported, uint256 available);
    event BatchComposed(uint32 indexed srcEid, uint256 landed, uint256 forwarded, bytes32 guid);

    error NotEndpoint();
    error NotTimelock();
    error NotStargate();
    error UnknownSatellite();
    error ZeroAddress();
    error ZeroAmount();
    error NothingToSweep();

    constructor(IERC20 weth_, IRepaymentReceiver receiver_, address endpoint_, address stargate_, address timelock_) {
        if (
            address(weth_) == address(0) || address(receiver_) == address(0) || endpoint_ == address(0)
                || stargate_ == address(0) || timelock_ == address(0)
        ) revert ZeroAddress();
        weth = weth_;
        receiver = receiver_;
        endpoint = endpoint_;
        stargate = stargate_;
        timelock = timelock_;
    }

    // =====================================================================
    // Registry and buffer
    // =====================================================================

    function registerSatellite(uint32 srcEid, address adapter) external {
        if (msg.sender != timelock) revert NotTimelock();
        satelliteFor[srcEid] = ComposeMsgCodec.addressToBytes32(adapter);
        emit SatelliteRegistered(srcEid, satelliteFor[srcEid]);
    }

    /// @notice Top up the fee buffer. Anyone may, but it is maintenance's job (§9).
    function fundBuffer(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        weth.safeTransferFrom(msg.sender, address(this), amount);
        feeBuffer += amount;
        emit BufferFunded(amount, feeBuffer);
    }

    /// @notice Return unused buffer to governance.
    function sweepBuffer(uint256 amount, address to) external {
        if (msg.sender != timelock) revert NotTimelock();
        if (amount == 0 || amount > feeBuffer) revert NothingToSweep();
        feeBuffer -= amount;
        weth.safeTransfer(to, amount);
        emit BufferSwept(amount);
    }

    // =====================================================================
    // Arrival
    // =====================================================================

    function lzCompose(address from, bytes32 guid, bytes calldata message, address, bytes calldata) external payable {
        if (msg.sender != endpoint) revert NotEndpoint();
        if (from != stargate) revert NotStargate();

        uint32 srcEid = ComposeMsgCodec.srcEid(message);
        bytes32 expected = satelliteFor[srcEid];
        if (expected == bytes32(0) || ComposeMsgCodec.composeFrom(message) != expected) {
            revert UnknownSatellite();
        }

        uint256 landed = ComposeMsgCodec.amountLD(message);
        Repayment[] memory entries = abi.decode(ComposeMsgCodec.composeMsg(message), (Repayment[]));

        uint256 reported;
        for (uint256 i; i < entries.length; ++i) {
            reported += entries[i].wethAmount;
        }

        uint256 forwarded = _reconcile(srcEid, landed, reported, entries);

        if (forwarded != 0) weth.safeTransfer(address(receiver), forwarded);
        receiver.receiveBatch(srcEid, forwarded, abi.encode(entries));

        emit BatchComposed(srcEid, landed, forwarded, guid);
    }

    /// @dev Make the manifest and the money agree, preferring to spend the buffer over shrinking a
    ///      repayment. Mutates `entries` in memory when it has to scale them.
    function _reconcile(uint32 srcEid, uint256 landed, uint256 reported, Repayment[] memory entries)
        internal
        returns (uint256 forwarded)
    {
        if (landed >= reported) {
            // Surplus, which happens when a satellite over-sends. It belongs to the buffer that paid
            // for the crossing, not to whichever vintage happened to be in this batch.
            feeBuffer += landed - reported;
            return reported;
        }

        uint256 shortfall = reported - landed;
        if (feeBuffer >= shortfall) {
            feeBuffer -= shortfall;
            emit ShortfallCovered(srcEid, shortfall, feeBuffer);
            return reported;
        }

        // The buffer is dry. Spend what is left, scale the entries to what is actually available, and
        // say so loudly.
        uint256 available = landed + feeBuffer;
        feeBuffer = 0;
        emit ShortfallSocialised(srcEid, reported, available);

        uint256 assigned;
        for (uint256 i; i < entries.length; ++i) {
            uint256 scaled = (entries[i].wethAmount * available) / reported;
            entries[i].wethAmount = scaled;
            assigned += scaled;
        }
        // Truncation dust stays here rather than being credited to an arbitrary entry.
        feeBuffer += available - assigned;
        return assigned;
    }
}
