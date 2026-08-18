// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @notice The treasury surface the escrow depends on (§8.2, §11).
/// @dev Allocation is a two-phase commitment. `commit` reserves WETH-denominated capacity at
///      execution so the per-deal cap in §8.1 is computed against capital that is not already
///      spoken for; `fundDraw` converts and delivers at draw time; `release` returns capacity
///      when a tranche lapses or a halt cancels it. The treasury never holds WETH between these
///      calls, so there is no idle balance for anyone to target.
interface ITreasury {
    /// @notice Reserve WETH-denominated capacity for an executed proposal.
    function commit(uint256 wethAmount) external;

    /// @notice Return unreserved capacity when an allocation lapses or is halted.
    function release(uint256 wethAmount) external;

    /// @notice Sell treasury CODE for `wethAmount` of WETH and deliver it to `to`.
    /// @dev Reverts rather than executing badly if the swap cannot clear its minimum-out bound
    ///      (§11). Returns the realised output, which may exceed the nominal amount; what the
    ///      investee owes is the nominal figure, never this one (§8.2).
    function fundDraw(address to, uint256 wethAmount) external returns (uint256 delivered);
}
