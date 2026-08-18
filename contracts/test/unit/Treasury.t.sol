// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Code} from "../../src/Code.sol";
import {Treasury, ITreasuryOracle} from "../../src/Treasury.sol";
import {MockWeth, MockRouter, OraclePriceStub} from "../mocks/Mocks.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IExternal.sol";

contract TreasuryTest is Test {
    Code internal code;
    MockWeth internal weth;
    MockRouter internal router;
    OraclePriceStub internal oracle;
    Treasury internal treasury;

    address internal genesis = makeAddr("genesis");
    address internal maintenance = makeAddr("maintenance");
    address internal timelock = makeAddr("timelock");
    address internal escrow = makeAddr("escrow");
    address internal investee = makeAddr("investee");
    address internal stranger = makeAddr("stranger");

    /// @dev 1 CODE = 0.00001 WETH, so 500M CODE is 5,000 WETH of capacity.
    uint256 internal constant GENESIS_CODE = 500_000_000e18;

    function setUp() public {
        weth = new MockWeth();
        router = new MockRouter(weth);
        oracle = new OraclePriceStub();

        // The treasury address has to exist before the token that pays it, so deploy in two steps
        // with a placeholder and then fund the real one.
        code = new Code(genesis, makeAddr("taxSink"), maintenance);
        treasury =
            new Treasury(IERC20(address(code)), IERC20(address(weth)), IUniswapV2Router02(address(router)), timelock);
        treasury.wire(escrow, ITreasuryOracle(address(oracle)));

        address[] memory ex = new address[](3);
        ex[0] = genesis;
        ex[1] = address(treasury);
        ex[2] = address(router);
        code.setExempt(ex);
        code.seal();

        vm.prank(genesis);
        code.transfer(address(treasury), GENESIS_CODE);
    }

    // =================================================================
    // Sizing (§8.1)
    // =================================================================

    function test_sizing_ceilingIsHalfAPercentOfRemainingBalance() public view {
        assertEq(treasury.availableWeth(), 5_000 ether);
        assertEq(treasury.perDealCeiling(), 25 ether, "0.5% of 5,000");
    }

    function test_sizing_floorAppliesWhenTheTreasuryIsSmall() public {
        // §15: "5 WETH; ceiling is the greater of cap and floor."
        vm.prank(timelock);
        treasury.spend(IERC20(address(code)), stranger, GENESIS_CODE - 1_000e18);
        assertEq(treasury.availableWeth(), 0.01 ether);
        assertEq(treasury.perDealCeiling(), 5 ether, "the floor keeps early cheques meaningful");
    }

    function test_sizing_committedCapitalIsNotAvailable() public {
        // A tranche schedule keeps capital committed for months. Counting it as available would let
        // a run of deals each size themselves against money the previous ones already claimed.
        vm.prank(escrow);
        treasury.commit(4_000 ether);
        assertEq(treasury.availableWeth(), 1_000 ether);
        assertEq(treasury.perDealCeiling(), 5 ether, "0.5% of 1,000 is 5, which meets the floor");
    }

    function test_sizing_emissionDecaysRatherThanExhausting() public {
        // The structural claim in §8.1: percentage sizing "decays geometrically and can never
        // exhaust the treasury".
        uint256 previous = treasury.perDealCeiling();
        for (uint256 i; i < 20; ++i) {
            uint256 draw = treasury.perDealCeiling();
            vm.prank(escrow);
            treasury.commit(draw);
            vm.prank(escrow);
            treasury.fundDraw(investee, draw);
            uint256 next = treasury.perDealCeiling();
            assertLe(next, previous, "cheque sizes never grow as the balance falls");
            previous = next;
        }
        assertGt(code.balanceOf(address(treasury)), 0, "and the treasury is never emptied");
    }

    // =================================================================
    // Allocation lifecycle
    // =================================================================

    function test_commit_isEscrowOnly() public {
        vm.prank(timelock);
        vm.expectRevert(Treasury.NotEscrow.selector);
        treasury.commit(1 ether);
    }

    function test_release_cannotExceedWhatWasCommitted() public {
        vm.prank(escrow);
        treasury.commit(10 ether);
        vm.prank(escrow);
        vm.expectRevert(Treasury.OverCommitted.selector);
        treasury.release(11 ether);
    }

    function test_release_returnsCapacity() public {
        vm.startPrank(escrow);
        treasury.commit(10 ether);
        treasury.release(10 ether);
        vm.stopPrank();
        assertEq(treasury.committedWeth(), 0);
        assertEq(treasury.availableWeth(), 5_000 ether);
    }

    // =================================================================
    // Draws (§8.2, §11)
    // =================================================================

    function test_draw_sizesTheSaleAtTheTimeWeightedPrice() public {
        vm.prank(escrow);
        treasury.commit(10 ether);
        uint256 codeBefore = code.balanceOf(address(treasury));

        vm.prank(escrow);
        uint256 delivered = treasury.fundDraw(investee, 10 ether);

        assertEq(codeBefore - code.balanceOf(address(treasury)), 1_000_000e18, "10 WETH at 0.00001");
        assertEq(delivered, 10 ether);
        assertEq(weth.balanceOf(investee), 10 ether);
        assertEq(weth.balanceOf(address(treasury)), 0, "the treasury never holds WETH between calls");
    }

    function test_draw_deliversTheRealisedOutputNotTheNominal() public {
        // §8.2 requires the two to be separable: what is received moves with the pool, what is owed
        // does not. Here the pool returns 0.5% less than nominal.
        router.setRate(0.995e13);
        vm.prank(escrow);
        treasury.commit(10 ether);
        vm.prank(escrow);
        uint256 delivered = treasury.fundDraw(investee, 10 ether);
        assertEq(delivered, 9.95 ether, "realised");
        assertEq(weth.balanceOf(investee), 9.95 ether);
    }

    function test_draw_revertsRatherThanExecutingBadly() public {
        // §11: "a swap that cannot clear its bound reverts rather than executing badly." A reverted
        // draw is a retry; a badly executed one is a permanent loss of treasury capital.
        router.setRate(0.98e13); // 2% down against a 1% bound
        vm.prank(escrow);
        treasury.commit(10 ether);
        vm.prank(escrow);
        vm.expectRevert(MockRouter.TooLittleOut.selector);
        treasury.fundDraw(investee, 10 ether);
    }

    function test_draw_isEscrowOnly() public {
        vm.prank(timelock);
        vm.expectRevert(Treasury.NotEscrow.selector);
        treasury.fundDraw(investee, 1 ether);
    }

    function test_draw_leavesNoStandingRouterApproval() public {
        vm.prank(escrow);
        treasury.commit(10 ether);
        vm.prank(escrow);
        treasury.fundDraw(investee, 10 ether);
        assertEq(code.allowance(address(treasury), address(router)), 0);
    }

    function test_draw_refusesWhatTheTreasuryCannotAfford() public {
        vm.prank(escrow);
        treasury.commit(100_000 ether);
        vm.prank(escrow);
        vm.expectRevert(Treasury.InsufficientCode.selector);
        treasury.fundDraw(investee, 100_000 ether);
    }

    // =================================================================
    // Custody (§14)
    // =================================================================

    function test_spend_isTimelockOnly() public {
        // "The treasury is nobody's... spendable only by proposal, drained by no key."
        vm.prank(escrow);
        vm.expectRevert(Treasury.NotTimelock.selector);
        treasury.spend(IERC20(address(code)), stranger, 1e18);

        vm.prank(stranger);
        vm.expectRevert(Treasury.NotTimelock.selector);
        treasury.spend(IERC20(address(code)), stranger, 1e18);
    }

    function test_wire_isSpentAfterUse() public {
        vm.expectRevert(Treasury.NotConfigurer.selector);
        treasury.wire(stranger, ITreasuryOracle(address(oracle)));
    }

    function test_slippage_boundsAreEnforced() public {
        vm.startPrank(timelock);
        vm.expectRevert(Treasury.SlippageOutOfRange.selector);
        treasury.setDrawSlippage(0); // would make every draw revert
        vm.expectRevert(Treasury.SlippageOutOfRange.selector);
        treasury.setDrawSlippage(501); // stops being a bound worth having
        treasury.setDrawSlippage(250);
        vm.stopPrank();
        assertEq(treasury.drawSlippageBps(), 250);
    }
}
