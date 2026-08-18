// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @notice The staking vault notifies the vintage vault whenever a participant's claim weight in
///         an already-frozen vintage contracts, so the vault can settle what accrued at the old
///         weight before its base shrinks (whitepaper §10.3).
/// @dev Only the new weight is passed. The vault holds the authoritative record of the weight it
///      has on its books, so asking it to trust an `oldWeight` argument from a caller would be
///      handing it a number it can already derive.
interface IVintageVault {
    function syncVintageWeight(address account, uint32 vintage, uint256 newWeight) external;
    function creditVintage(uint32 vintage, uint256 amount) external;
}
