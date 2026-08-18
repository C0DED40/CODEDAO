// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @notice LayerZero V2 and Stargate V2 surfaces, transcribed from the published packages.
///
/// @dev Declared locally for the same reason as `IExternal.sol`: importing the real packages drags in
///      the whole OApp stack, its own pinned OpenZeppelin copy, and a compiler-version negotiation
///      this repository does not need. Every struct and signature below was checked field by field
///      against these exact versions:
///
///        `@layerzerolabs/lz-evm-protocol-v2`  2.0.11
///        `@layerzerolabs/lz-evm-oapp-v2`      2.3.44
///        `@stargatefinance/stg-evm-v2`        9.0.0
///
///      Backticked because a line beginning with `@` is read as a natspec tag, and three unknown tags
///      is three compiler warnings on every build.
///
///      Transcribed rather than invented, and the versions are recorded here rather than in
///      `vendor/package.json`: `lz-evm-protocol-v2` demands `@openzeppelin/contracts ^4.8.1` as a peer,
///      this project compiles against 5.1.0, and npm refuses the tree outright. Nothing in those
///      packages is compiled, so a reviewer diffing them installs them on the side:
///
///        npm install --no-save --legacy-peer-deps \
///          "@layerzerolabs/lz-evm-protocol-v2@2.0.11" \
///          "@layerzerolabs/lz-evm-oapp-v2@2.3.44" \
///          "@stargatefinance/stg-evm-v2@9.0.0"
///
///      **Re-check before mainnet**: these are ABI-level dependencies on contracts the DAO does not
///      control, and a struct field added upstream would silently change the encoding.

// --- LayerZero V2 protocol ---

struct MessagingFee {
    uint256 nativeFee;
    uint256 lzTokenFee;
}

struct MessagingReceipt {
    bytes32 guid;
    uint64 nonce;
    MessagingFee fee;
}

/// @notice Delivered to the composer on the destination chain.
struct Origin {
    uint32 srcEid;
    bytes32 sender;
    uint64 nonce;
}

// --- OFT, which Stargate implements ---

struct SendParam {
    uint32 dstEid;
    bytes32 to;
    uint256 amountLD;
    uint256 minAmountLD;
    bytes extraOptions;
    bytes composeMsg;
    bytes oftCmd;
}

struct OFTReceipt {
    uint256 amountSentLD;
    uint256 amountReceivedLD;
}

struct OFTLimit {
    uint256 minAmountLD;
    uint256 maxAmountLD;
}

struct OFTFeeDetail {
    int256 feeAmountLD;
    string description;
}

/// @notice Stargate's ticket data for bus-ride mode. Unused here; batches ride the taxi.
struct Ticket {
    uint72 ticketId;
    bytes passengerBytes;
}

/// @notice The asset bridge. LayerZero moves messages; Stargate moves value *and* a message.
/// @dev This distinction is the whole reason there are two contracts rather than one. §9 needs WETH
///      to arrive on the home chain alongside its manifest, and raw LayerZero messaging cannot move a
///      token. Stargate's `sendToken` carries both in one crossing, which is why it is the asset layer
///      here and why the composed message is where the manifest travels.
interface IStargate {
    function sendToken(SendParam calldata sendParam, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory, Ticket memory);

    function quoteSend(SendParam calldata sendParam, bool payInLzToken) external view returns (MessagingFee memory);

    function quoteOFT(SendParam calldata sendParam)
        external
        view
        returns (OFTLimit memory, OFTFeeDetail[] memory, OFTReceipt memory);

    function token() external view returns (address);

    function approvalRequired() external view returns (bool);
}

/// @notice What the destination contract must implement to receive a composed message.
interface ILayerZeroComposer {
    function lzCompose(address from, bytes32 guid, bytes calldata message, address executor, bytes calldata extraData)
        external
        payable;
}

/// @notice Field offsets in a composed message, from `OFTComposeMsgCodec`.
/// @dev The composed message Stargate delivers is not the payload that was sent: it is prefixed with
///      nonce, source endpoint id, the amount that actually landed, and the composing sender. Reading
///      the payload without stripping that prefix decodes garbage, and reading the landed amount from
///      the payload instead of the prefix would trust the source chain's claim over the destination's
///      accounting.
library ComposeMsgCodec {
    uint256 internal constant NONCE_OFFSET = 8;
    uint256 internal constant SRC_EID_OFFSET = 12;
    uint256 internal constant AMOUNT_LD_OFFSET = 44;
    uint256 internal constant COMPOSE_FROM_OFFSET = 76;

    function srcEid(bytes calldata msg_) internal pure returns (uint32) {
        return uint32(bytes4(msg_[NONCE_OFFSET:SRC_EID_OFFSET]));
    }

    /// @notice The amount that actually arrived, as reported by the destination-side OFT.
    function amountLD(bytes calldata msg_) internal pure returns (uint256) {
        return uint256(bytes32(msg_[SRC_EID_OFFSET:AMOUNT_LD_OFFSET]));
    }

    function composeFrom(bytes calldata msg_) internal pure returns (bytes32) {
        return bytes32(msg_[AMOUNT_LD_OFFSET:COMPOSE_FROM_OFFSET]);
    }

    function composeMsg(bytes calldata msg_) internal pure returns (bytes memory) {
        return msg_[COMPOSE_FROM_OFFSET:];
    }

    function addressToBytes32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function bytes32ToAddress(bytes32 b) internal pure returns (address) {
        return address(uint160(uint256(b)));
    }
}
