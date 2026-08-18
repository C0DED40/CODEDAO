// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Oracle} from "../../src/Oracle.sol";
import {MockPair, MockFeed, MockWeth} from "../mocks/Mocks.sol";
import {IUniswapV2Pair, IAggregatorV3} from "../../src/interfaces/IExternal.sol";

contract OracleTest is Test {
    Oracle internal oracle;
    MockPair internal pair;
    MockFeed internal feed;

    address internal codeToken = address(0xC0DE);
    address internal wethToken = address(0x0EEE);
    address internal timelock = makeAddr("timelock");

    function setUp() public {
        vm.warp(1_700_000_000);
        pair = new MockPair(codeToken, wethToken);
        feed = new MockFeed();
        // 1,000,000 CODE against 10 WETH: 1 CODE = 0.00001 WETH.
        pair.setReserves(1_000_000e18, 10e18);
        oracle = new Oracle(IUniswapV2Pair(address(pair)), IAggregatorV3(address(feed)), codeToken, wethToken, timelock);
    }

    function _advanceAndUpdate(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
        feed.set(3000e8, block.timestamp);
        oracle.update();
    }

    function test_read_revertsBeforeAnyObservation() public {
        vm.expectRevert(Oracle.NoObservation.selector);
        oracle.codeWethPrice();
    }

    function test_update_refusesAnIntervalShorterThanTheWindow() public {
        // Without this an attacker could push the pool, update immediately, and have the "average"
        // reflect one manipulated instant.
        vm.warp(block.timestamp + 29 minutes);
        vm.expectRevert(Oracle.WindowTooShort.selector);
        oracle.update();
    }

    function test_update_producesTheTimeWeightedPrice() public {
        _advanceAndUpdate(30 minutes);
        assertApproxEqRel(oracle.codeWethPrice(), 1e13, 1e12, "0.00001 WETH per CODE");
    }

    function test_update_averagesRatherThanTracksASpike() public {
        _advanceAndUpdate(30 minutes);
        uint256 calm = oracle.codeWethPrice();

        // A brief 10x spike over one minute of a thirty-minute window barely moves the average.
        pair.setReserves(1_000_000e18, 100e18);
        vm.warp(block.timestamp + 1 minutes);
        pair.setReserves(1_000_000e18, 10e18);
        vm.warp(block.timestamp + 29 minutes);
        feed.set(3000e8, block.timestamp);
        oracle.update();

        uint256 spiked = oracle.codeWethPrice();
        assertLt(spiked, calm * 15 / 10, "a one-minute spike must not carry the average");
        assertGt(spiked, calm, "but it is not ignored either");
    }

    function test_read_refusesAStaleAverage() public {
        // A price that has stopped being maintained is more dangerous than no price, because it
        // looks like a price. Draws must revert.
        _advanceAndUpdate(30 minutes);
        vm.warp(block.timestamp + 2 hours + 1);
        vm.expectRevert(Oracle.StaleAverage.selector);
        oracle.codeWethPrice();
        assertFalse(oracle.isFresh());
    }

    function test_usd_combinesTheTwapWithChainlink() public {
        _advanceAndUpdate(30 minutes);
        // 0.00001 WETH x $3,000 = $0.03
        assertApproxEqRel(oracle.codeUsdPrice(), 0.03e18, 1e12);
    }

    function test_usd_refusesAStaleFeed() public {
        _advanceAndUpdate(30 minutes);
        feed.set(3000e8, block.timestamp - 2 hours);
        vm.expectRevert(Oracle.StaleFeed.selector);
        oracle.codeUsdPrice();
    }

    function test_usd_refusesANonPositiveAnswer() public {
        _advanceAndUpdate(30 minutes);
        feed.set(0, block.timestamp);
        vm.expectRevert(Oracle.BadFeedAnswer.selector);
        oracle.codeUsdPrice();
    }

    function test_conversions_roundTrip() public {
        _advanceAndUpdate(30 minutes);
        uint256 codeAmount = oracle.wethToCode(1 ether);
        assertApproxEqRel(oracle.codeToWeth(codeAmount), 1 ether, 1e12);
    }

    function test_governance_windowBoundsAreEnforced() public {
        vm.startPrank(timelock);
        vm.expectRevert(Oracle.OutOfRange.selector);
        oracle.setWindows(9 minutes, 2 hours, 1 hours);
        // maxAge must exceed the window or every read reverts straight after a legal update.
        vm.expectRevert(Oracle.OutOfRange.selector);
        oracle.setWindows(1 hours, 1 hours, 1 hours);
        oracle.setWindows(1 hours, 4 hours, 30 minutes);
        vm.stopPrank();
        assertEq(oracle.window(), 1 hours);
    }

    function test_governance_isTimelockOnly() public {
        vm.expectRevert(Oracle.NotTimelock.selector);
        oracle.setWindows(1 hours, 4 hours, 30 minutes);
    }
}
