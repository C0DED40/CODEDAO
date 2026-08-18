// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @notice How the agent registry reports a verdict back to whoever opened the round.
/// @dev Three outcomes, not two. A lapse is not a rejection: §5.4 is explicit that "a stalled or
///      unreachable agent set freezes outcomes; it never punishes users", so the consumer must be
///      able to tell the difference and decline to slash anyone on a lapse.
interface ISaineConsumer {
    function onSaineVerdict(uint256 subject, bool approved, bool lapsed) external;
}

/// @notice USD price of CODE, for revaluing operator bonds at each season boundary (§5.5).
interface IOracle {
    /// @return usdPerCode 18-decimal USD price of one whole CODE, from the CODE/WETH TWAP against
    ///         the Chainlink ETH/USD feed.
    function codeUsdPrice() external view returns (uint256 usdPerCode);

    /// @notice Maintain the average if enough time has passed; never reverts.
    function poke() external;
}
