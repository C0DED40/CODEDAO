// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title PenaltyMath
/// @notice Multiplicative season-bounded penalty arithmetic for CODE DAO (whitepaper §7.1).
/// @dev Penalties compose multiplicatively: a participant wrong twice carries 0.9 * 0.9 = 81%
///      of base weight. Rather than writing a multiplier per account at every verdict (which
///      would require iterating the electorate, and is impossible for the non-vote penalty
///      because absence produces no transaction), the multiplier is derived on read from two
///      bitmaps: which proposals the account voted on, and how it voted. Counting bits gives
///      the exponents, and two fixed-point powers give the multiplier in O(1).
library PenaltyMath {
    /// @dev Fixed-point scale for all multipliers.
    uint256 internal constant WAD = 1e18;

    /// @dev §15: Many penalty, wrong vote. 10%, so 90% of weight survives.
    uint256 internal constant WRONG_VOTE_MULT = 0.90e18;

    /// @dev §15: Many penalty, non-vote. 15%, so 85% survives. Strictly harsher than a wrong
    ///      vote, which is what makes casting an honest ballot dominate abstention.
    uint256 internal constant NON_VOTE_MULT = 0.85e18;

    /// @dev §15: Guardian penalty for sponsoring a SAINE-rejected proposal. 50%.
    uint256 internal constant GUARDIAN_MULT = 0.50e18;

    /// @notice x^n in WAD fixed point by squaring, truncating at every step.
    /// @dev Truncation rounds the multiplier down, so rounding error can only ever make a
    ///      penalty marginally harsher, never lighter. It is applied identically to every
    ///      participant, so it cannot be used to gain relative advantage.
    function wpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        z = WAD;
        if (n == 0) return z;
        // x <= WAD and z <= WAD throughout, so x * z <= 1e36 and overflow is impossible.
        while (n != 0) {
            if (n & 1 == 1) z = (z * x) / WAD;
            n >>= 1;
            if (n != 0) x = (x * x) / WAD;
        }
    }

    /// @notice The composed Many multiplier for a season, in WAD.
    /// @param wrongs Count of adjudicated proposals where the account voted against the verdict.
    /// @param absences Count of adjudicated proposals where the account did not vote.
    function manyMultiplier(uint256 wrongs, uint256 absences) internal pure returns (uint256) {
        if (wrongs == 0 && absences == 0) return WAD;
        return (wpow(WRONG_VOTE_MULT, wrongs) * wpow(NON_VOTE_MULT, absences)) / WAD;
    }

    /// @notice Population count of a 256-bit word (SWAR).
    function popcount(uint256 x) internal pure returns (uint256) {
        unchecked {
            x = x - ((x >> 1) & 0x5555555555555555555555555555555555555555555555555555555555555555);
            x = (x & 0x3333333333333333333333333333333333333333333333333333333333333333)
                + ((x >> 2) & 0x3333333333333333333333333333333333333333333333333333333333333333);
            x = (x + (x >> 4)) & 0x0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f;
            x = (x * 0x0101010101010101010101010101010101010101010101010101010101010101) >> 248;
            return x;
        }
    }

    /// @notice Apply a WAD multiplier to a weight, rounding down.
    function applyMultiplier(uint256 weight, uint256 mult) internal pure returns (uint256) {
        return (weight * mult) / WAD;
    }
}
