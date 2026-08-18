// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV2Pair, IAggregatorV3} from "./interfaces/IExternal.sol";
import {IOracle} from "./interfaces/ISaineConsumer.sol";

/// @title Oracle
/// @notice Time-weighted pricing for every protocol mechanism (§11).
///
/// @dev §11 is unambiguous: "All treasury pricing runs through time-weighted oracles on a designated
///      canonical pool, with Chainlink feeds where available. No protocol mechanism reads a spot
///      price." The lineage in §1 names reading a spot price from an AMM as one of the specific
///      things CODE DAO rebuilds, so this contract has no function that returns one, not even for
///      convenience.
///
///      The canonical pool is Uniswap v2 (decision 1.1: the 0.49% transfer tax is incompatible with
///      v3's and v4's balance-delta accounting on the sell side). A v2 oracle reads cumulative
///      prices, which is coarser than a v3 tick accumulator and therefore leans harder on the window
///      length. Two guards do the work a longer window alone cannot:
///
///      - `update()` refuses to fold in an interval shorter than `window`, so an attacker cannot
///        ratchet the average forward with a burst of tiny updates.
///      - Every read refuses a stale average. A price that has simply stopped being maintained is
///        more dangerous than no price, because it looks like a price. Draws revert instead.
///
///      The USD leg is Chainlink, checked for a positive answer and a fresh round. USD matters only
///      for the two bond figures in §15 ($1,000 operator bond, $1,000 proposal bond), which is
///      exactly the case where drift in the token's market cap must not change the economic weight
///      of the deposit.
contract Oracle is IOracle {
    /// @notice The designated canonical CODE/WETH pool (§12).
    IUniswapV2Pair public immutable pair;

    /// @notice Chainlink ETH/USD.
    IAggregatorV3 public immutable ethUsdFeed;

    address public immutable code;
    address public immutable weth;

    /// @dev True when CODE is token0 in the pair, which fixes which cumulative to read.
    bool public immutable codeIsToken0;

    address public immutable timelock;

    /// @notice §PARAMETERS: 30 minutes. Timelock-tunable.
    uint32 public window = 30 minutes;

    /// @notice How stale an average may be before reads revert.
    uint32 public maxAge = 2 hours;

    /// @notice How stale the Chainlink round may be before USD reads revert.
    uint32 public feedMaxAge = 1 hours;

    uint256 internal lastCumulative;
    uint32 internal lastTimestamp;

    /// @notice WETH per whole CODE, 18 decimals, averaged over the last completed window.
    uint256 public codeWethAverage;

    event Updated(uint256 codeWethAverage, uint32 elapsed);
    event WindowSet(uint32 window, uint32 maxAge, uint32 feedMaxAge);

    error NotTimelock();
    error WindowTooShort();
    error NoObservation();
    error StaleAverage();
    error StaleFeed();
    error BadFeedAnswer();
    error ZeroAddress();
    error OutOfRange();

    constructor(IUniswapV2Pair pair_, IAggregatorV3 ethUsdFeed_, address code_, address weth_, address timelock_) {
        if (address(pair_) == address(0) || code_ == address(0) || weth_ == address(0) || timelock_ == address(0)) {
            revert ZeroAddress();
        }
        pair = pair_;
        ethUsdFeed = ethUsdFeed_;
        code = code_;
        weth = weth_;
        timelock = timelock_;
        codeIsToken0 = pair_.token0() == code_;

        (lastCumulative, lastTimestamp) = _currentCumulative();
    }

    // =====================================================================
    // Observation
    // =====================================================================

    /// @notice Fold the elapsed interval into the average. Permissionless.
    /// @dev Refuses intervals shorter than `window`. Without that refusal an attacker could push the
    ///      pool, call `update()` immediately, and have the "average" reflect a single manipulated
    ///      instant, which would defeat the point of averaging at all.
    function update() external {
        (uint256 cumulative, uint32 timestamp) = _currentCumulative();
        uint32 elapsed = timestamp - lastTimestamp;
        if (elapsed < window) revert WindowTooShort();

        // UQ112x112 average over the interval, converted to 18 decimals through a 512-bit
        // intermediate so the shift cannot overflow.
        uint256 averageQ112 = (cumulative - lastCumulative) / elapsed;
        codeWethAverage = Math.mulDiv(averageQ112, 1e18, 2 ** 112);

        lastCumulative = cumulative;
        lastTimestamp = timestamp;
        emit Updated(codeWethAverage, elapsed);
    }

    /// @notice Fold in the elapsed interval if it is long enough, and do nothing if it is not.
    /// @dev Added after the integration test found the gap: every price-dependent entry point in the
    ///      protocol (treasury draws, both USD-denominated bonds) reverts on a stale average, so an
    ///      oracle that nobody maintains does not merely go quiet, it halts originations and
    ///      drawdowns. `update()` reverting on a short interval is correct for a keeper but useless
    ///      as a self-heal, because a caller cannot know whether enough time has passed. `poke()`
    ///      never reverts, so the paths that need a price can maintain the oracle on the way past
    ///      and the protocol carries no dependency on anyone running a bot.
    ///
    ///      A poke after a long silence produces an average over that whole silence, which is a
    ///      longer window than configured and therefore *more* manipulation-resistant, not less.
    function poke() public {
        (uint256 cumulative, uint32 timestamp) = _currentCumulative();
        if (timestamp - lastTimestamp < window) return;
        uint256 averageQ112 = (cumulative - lastCumulative) / (timestamp - lastTimestamp);
        codeWethAverage = Math.mulDiv(averageQ112, 1e18, 2 ** 112);
        emit Updated(codeWethAverage, timestamp - lastTimestamp);
        lastCumulative = cumulative;
        lastTimestamp = timestamp;
    }

    function _currentCumulative() internal view returns (uint256 cumulative, uint32 timestamp) {
        timestamp = uint32(block.timestamp);
        (uint112 r0, uint112 r1, uint32 pairTimestamp) = pair.getReserves();
        cumulative = codeIsToken0 ? pair.price0CumulativeLast() : pair.price1CumulativeLast();

        // Counterfactual: extend the pair's own accumulator to now, so a pool that has not traded
        // recently still contributes its standing price rather than a gap.
        if (pairTimestamp != timestamp && r0 != 0 && r1 != 0) {
            uint32 gap = timestamp - pairTimestamp;
            uint256 spotQ112 = codeIsToken0 ? (uint256(r1) << 112) / uint256(r0) : (uint256(r0) << 112) / uint256(r1);
            cumulative += spotQ112 * gap;
        }
    }

    // =====================================================================
    // Reads
    // =====================================================================

    /// @notice WETH per whole CODE, 18 decimals.
    function codeWethPrice() public view returns (uint256) {
        if (codeWethAverage == 0) revert NoObservation();
        if (block.timestamp - lastTimestamp > maxAge) revert StaleAverage();
        return codeWethAverage;
    }

    /// @notice USD per whole CODE, 18 decimals (§5.5, and the proposal bond in §6.2).
    function codeUsdPrice() external view returns (uint256) {
        uint256 codeWeth = codeWethPrice();
        (, int256 answer,, uint256 updatedAt,) = ethUsdFeed.latestRoundData();
        if (answer <= 0) revert BadFeedAnswer();
        if (block.timestamp - updatedAt > feedMaxAge) revert StaleFeed();

        uint8 feedDecimals = ethUsdFeed.decimals();
        uint256 ethUsd = Math.mulDiv(uint256(answer), 1e18, 10 ** feedDecimals);
        return Math.mulDiv(codeWeth, ethUsd, 1e18);
    }

    /// @notice CODE that a given WETH amount is worth at the time-weighted price.
    function wethToCode(uint256 wethAmount) external view returns (uint256) {
        return Math.mulDiv(wethAmount, 1e18, codeWethPrice());
    }

    /// @notice WETH that a given CODE amount is worth at the time-weighted price.
    function codeToWeth(uint256 codeAmount) external view returns (uint256) {
        return Math.mulDiv(codeAmount, codeWethPrice(), 1e18);
    }

    /// @notice Whether reads would currently succeed, for interfaces that would rather not revert.
    function isFresh() external view returns (bool) {
        return codeWethAverage != 0 && block.timestamp - lastTimestamp <= maxAge;
    }

    // =====================================================================
    // Governance
    // =====================================================================

    function setWindows(uint32 window_, uint32 maxAge_, uint32 feedMaxAge_) external {
        if (msg.sender != timelock) revert NotTimelock();
        // A window under ten minutes stops being a meaningful average on a 100ms-block chain, and
        // one over a day prices draws off yesterday. `maxAge` must exceed the window or every read
        // reverts immediately after a legal update.
        if (window_ < 10 minutes || window_ > 1 days) revert OutOfRange();
        if (maxAge_ <= window_ || maxAge_ > 2 days) revert OutOfRange();
        if (feedMaxAge_ < 10 minutes || feedMaxAge_ > 1 days) revert OutOfRange();
        window = window_;
        maxAge = maxAge_;
        feedMaxAge = feedMaxAge_;
        emit WindowSet(window_, maxAge_, feedMaxAge_);
    }
}
