// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @notice Read and write surface of the staking vault that the governor and vault depend on.
interface IDCode {
    // --- seasons ---
    function currentSeason() external view returns (uint32);
    function seasonEnd(uint32 season) external view returns (uint64);
    function seasonStart(uint32 season) external view returns (uint64);
    function isSeasonClosed(uint32 season) external view returns (bool);

    // --- electorate ---
    function isGuardian(address account, uint32 season) external view returns (bool);
    function guardianCount(uint32 season) external view returns (uint256);
    function ballotWeight(address voter, uint32 season) external view returns (uint256);
    function manyEffectivePower(uint32 season) external view returns (uint256);
    function guardianExcluded(address guardian, uint32 season) external view returns (bool);

    // --- governor hooks ---
    function recordBallot(address voter, uint32 season, uint8 slot, bool support) external;
    function openScoredSlot(uint32 season) external returns (uint8 slot);
    function voidScoredSlot(uint32 season, uint8 slot) external;
    function ballotWeightForMask(address voter, uint32 season, uint128 mask) external view returns (uint256);
    function currentSettledMask(uint32 season) external view returns (uint128);
    function slotOpenPower(uint32 season, uint8 slot) external view returns (uint256);
    function settleScoredSlot(uint32 season, uint8 slot, bool approved, uint256 yesWeight, uint256 noWeight) external;
    function slashGuardian(address guardian, uint32 season) external;

    // --- vintage reads ---
    function vintagePreSlashWeight(uint32 season) external view returns (uint256);
    function vintageEffectiveWeight(uint32 season) external view returns (uint256);
    function frozenWeightOf(address account, uint32 season) external view returns (uint256);
    function snapshotPrincipalOf(address account, uint32 season) external view returns (uint256);
    function liveVintageWeightOf(address account, uint32 season) external view returns (uint256);
    function firstParticipationSeason(address account) external view returns (uint32);
}
