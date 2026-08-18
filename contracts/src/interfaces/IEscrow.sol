// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @notice The escrow surface that SAINE, the receiver and the governor depend on.
interface IEscrow {
    function releaseTranche(uint256 dealId, uint8 index) external;
    function challengeTge(uint256 dealId) external;
    function recordInstallments(uint256 dealId, uint16 count, uint256 wethValue, bool viaFloor) external;
    function vintageOf(uint256 dealId) external view returns (uint32);
    function isDefaulted(address investee) external view returns (bool);
    function milestoneHash(uint256 dealId, uint8 index) external view returns (bytes32);
}
