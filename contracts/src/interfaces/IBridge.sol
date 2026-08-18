// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @notice One repayment's worth of value crossing a bridge, with everything the home chain needs
///         to credit it to the right vintage (§9, §10.1).
struct Repayment {
    uint256 dealId;
    /// @dev The season that approved the deal. "Every return from that deal, whenever it arrives,
    ///      is credited to that season's pool" (§10.1). Carried in the message rather than looked
    ///      up on arrival, so a batch is self-describing and a satellite cannot misroute value to a
    ///      vintage it was not owed to.
    uint32 vintage;
    uint16 installments;
    uint256 wethAmount;
    /// @dev True when this installment settled against the floor because the token swap could not
    ///      clear its bound (§8.5). Audit information; the choice was never the investee's.
    bool viaFloor;
}

/// @notice The messaging layer, deliberately abstracted (§12 names LayerZero, but nothing here
///         depends on it).
///
/// @dev §9 needs a bridge; it does not need a *particular* bridge, and picking one is a decision
///      that should stay reversible. Everything cross-chain in this protocol goes through these two
///      functions, so replacing LayerZero with anything else is a new adapter and no change to
///      `Satellite` or `Receiver`. The satellite also has to price the bridge before it can apply
///      §15's "20x bridge cost" trigger, which is why quoting is part of the interface rather than
///      an off-chain estimate someone passes in.
interface IBridgeAdapter {
    /// @notice Native-gas cost of delivering `payload` and its WETH to the home chain.
    function quoteFee(bytes calldata payload) external view returns (uint256 nativeFee);

    /// @notice Send WETH and its manifest to the home-chain receiver.
    /// @dev The adapter pulls the WETH itself, so a satellite never approves an unbounded amount.
    function send(uint256 wethAmount, bytes calldata payload) external payable;
}

/// @notice The home-chain endpoint, called by a trusted adapter when a batch lands.
interface IRepaymentReceiver {
    function receiveBatch(uint32 srcChainId, uint256 wethAmount, bytes calldata payload) external;
}
