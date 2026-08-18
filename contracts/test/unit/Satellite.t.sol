// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Satellite} from "../../src/Satellite.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IExternal.sol";
import {IBridgeAdapter, Repayment} from "../../src/interfaces/IBridge.sol";
import {MockToken, MockDex} from "../mocks/Mocks.sol";
import {MockBridgeAdapter} from "../mocks/BridgeMocks.sol";

contract SatelliteTest is Test {
    Satellite internal satellite;
    MockToken internal weth;
    MockToken internal investeeToken;
    MockDex internal dex;
    MockBridgeAdapter internal bridge;

    address internal governor = makeAddr("crossChainGovernor");
    address internal investee = makeAddr("investee");
    address internal keeper = makeAddr("keeper");
    address internal maintenance = makeAddr("maintenance");

    uint256 internal constant DEAL = 1;
    uint32 internal constant VINTAGE = 3;

    /// @dev 1,000 tokens per installment, worth 1 WETH at the registered minimum.
    uint256 internal constant INSTALLMENT_TOKENS = 1_000e18;
    uint256 internal constant MIN_WETH = 1 ether;

    function setUp() public {
        vm.warp(1_700_000_000);
        weth = new MockToken("Wrapped Ether", "WETH");
        investeeToken = new MockToken("Investee", "INV");
        dex = new MockDex();
        satellite = new Satellite(IERC20(address(weth)), IUniswapV2Router02(address(dex)), governor);
        bridge = new MockBridgeAdapter(IERC20(address(weth)));
        satellite.wire(IBridgeAdapter(address(bridge)));

        // A healthy pool: 1,000 INV buys 1 WETH.
        dex.setRate(address(investeeToken), address(weth), 1e15);
        weth.mint(address(dex), 10_000 ether);

        investeeToken.mint(investee, 1_000_000e18);
        vm.prank(investee);
        investeeToken.approve(address(satellite), type(uint256).max);

        vm.prank(governor);
        satellite.registerDeal(DEAL, address(investeeToken), INSTALLMENT_TOKENS, MIN_WETH, VINTAGE);

        // Maintenance funds the bounty pool and the gas for bridge fees (§9).
        weth.mint(maintenance, 100 ether);
        vm.startPrank(maintenance);
        weth.approve(address(satellite), type(uint256).max);
        satellite.fundBounty(1 ether);
        vm.stopPrank();
        vm.deal(address(satellite), 1 ether);
    }

    // =================================================================
    // Registration
    // =================================================================

    function test_register_isBridgeOrGovernorOnly() public {
        vm.prank(investee);
        vm.expectRevert(Satellite.NotBridge.selector);
        satellite.registerDeal(2, address(investeeToken), 1e18, 1e18, 1);
    }

    function test_register_minimumComesFromTheHomeChain() public view {
        // §8.5 gives the escrow the settlement-path decision, so the figure that decides it is set
        // from there rather than computed here.
        assertEq(satellite.getDeal(DEAL).minWethPerInstallment, MIN_WETH);
    }

    // =================================================================
    // Paying (§9 steps 1 and 2)
    // =================================================================

    function test_pay_dischargesAtTheSwapNotOnArrival() public {
        // §9: "The obligation is discharged at this swap: bridge risk beyond this point belongs to
        // the DAO, which chose the architecture, never to a founder who has already paid."
        vm.prank(investee);
        uint256 out = satellite.payInstallment(DEAL, 1);

        assertEq(out, 1 ether);
        assertEq(satellite.pendingCount(), 1, "queued for bridging, already discharged");
        assertEq(satellite.pendingWeth(), 1 ether);

        Repayment memory r = satellite.pendingAt(0);
        assertEq(r.dealId, DEAL);
        assertEq(uint256(r.vintage), VINTAGE, "carries its own vintage");
        assertEq(uint256(r.installments), 1);
        assertFalse(r.viaFloor);
    }

    function test_pay_anyoneMayPayOnTheInvesteesBehalf() public {
        address friend = makeAddr("friend");
        investeeToken.mint(friend, INSTALLMENT_TOKENS);
        vm.startPrank(friend);
        investeeToken.approve(address(satellite), type(uint256).max);
        satellite.payInstallment(DEAL, 1);
        vm.stopPrank();
        assertEq(satellite.pendingWeth(), 1 ether);
    }

    function test_pay_multipleInstallmentsAtOnce() public {
        vm.prank(investee);
        satellite.payInstallment(DEAL, 3);
        assertEq(satellite.pendingWeth(), 3 ether);
        assertEq(uint256(satellite.pendingAt(0).installments), 3);
    }

    function test_pay_revertsWhenThePoolCannotClearTheBound() public {
        // The token path closes exactly when liquidity is too thin, which is what makes the floor
        // path a consequence rather than a choice.
        dex.setRate(address(investeeToken), address(weth), 0.5e15); // half price
        vm.prank(investee);
        vm.expectRevert(MockDex.TooLittleOut.selector);
        satellite.payInstallment(DEAL, 1);
    }

    function test_pay_toleratesSlippageWithinTheBound() public {
        // 200 bps tolerance, so 1.5% down still clears.
        dex.setRate(address(investeeToken), address(weth), 0.985e15);
        vm.prank(investee);
        uint256 out = satellite.payInstallment(DEAL, 1);
        assertEq(out, 0.985 ether);
    }

    // =================================================================
    // The floor path (§8.5, invariant 14)
    // =================================================================

    function _goIlliquid() internal {
        dex.setRate(address(investeeToken), address(weth), 0.5e15);
    }

    function test_floor_refusesCertificationWhileLiquid() public {
        vm.expectRevert(Satellite.StillLiquid.selector);
        satellite.recordIlliquidity(DEAL, 1);
    }

    function test_floor_requiresSustainedIlliquidityNotOneQuote() public {
        // A single manipulated instant must not open the cheaper path. Three strikes, twelve hours
        // apart, is a day of genuine absence.
        _goIlliquid();
        satellite.recordIlliquidity(DEAL, 1);
        assertEq(uint256(satellite.floorAuthorised(DEAL)), 0, "one strike authorises nothing");

        vm.expectRevert(Satellite.GapNotElapsed.selector);
        satellite.recordIlliquidity(DEAL, 1);

        vm.warp(block.timestamp + 12 hours);
        satellite.recordIlliquidity(DEAL, 1);
        assertEq(uint256(satellite.floorAuthorised(DEAL)), 0, "two still authorises nothing");

        vm.warp(block.timestamp + 12 hours);
        satellite.recordIlliquidity(DEAL, 1);
        assertEq(uint256(satellite.floorAuthorised(DEAL)), 1, "the third opens the floor");
    }

    function test_floor_recoveryBeforeTheThirdStrikeAuthorisesNothing() public {
        _goIlliquid();
        satellite.recordIlliquidity(DEAL, 1);
        vm.warp(block.timestamp + 12 hours);
        satellite.recordIlliquidity(DEAL, 1);

        // The pool recovers, so the third strike cannot be recorded.
        dex.setRate(address(investeeToken), address(weth), 1e15);
        vm.warp(block.timestamp + 12 hours);
        vm.expectRevert(Satellite.StillLiquid.selector);
        satellite.recordIlliquidity(DEAL, 1);
        assertEq(uint256(satellite.floorAuthorised(DEAL)), 0);
    }

    function _authoriseFloor() internal {
        _goIlliquid();
        satellite.recordIlliquidity(DEAL, 1);
        vm.warp(block.timestamp + 12 hours);
        satellite.recordIlliquidity(DEAL, 1);
        vm.warp(block.timestamp + 12 hours);
        satellite.recordIlliquidity(DEAL, 1);
    }

    function test_floor_investeeCannotSettleWithoutCertification() public {
        // Invariant 14: no election. Without a certification there is no floor to elect.
        vm.prank(investee);
        vm.expectRevert(Satellite.NoFloorAuthority.selector);
        satellite.settleViaFloor(DEAL, 1);
    }

    function test_floor_settlementConsumesAuthorityAndQueuesAZeroValueEntry() public {
        _authoriseFloor();
        vm.prank(investee);
        satellite.settleViaFloor(DEAL, 1);

        assertEq(uint256(satellite.floorAuthorised(DEAL)), 0, "authority is spent, not standing");
        Repayment memory r = satellite.pendingAt(0);
        assertTrue(r.viaFloor);
        assertEq(r.wethAmount, 0, "nothing to convert; it settles in CODE at home");
        assertEq(satellite.pendingWeth(), 0);
    }

    function test_floor_authorityDoesNotCoverMoreThanWasCertified() public {
        _authoriseFloor();
        vm.prank(investee);
        vm.expectRevert(Satellite.NoFloorAuthority.selector);
        satellite.settleViaFloor(DEAL, 2);
    }

    // =================================================================
    // Batching (§9 step 3, §15)
    // =================================================================

    function test_batch_notReadyBelowTwentyTimesTheFee() public {
        bridge.setFee(0.1 ether); // trigger at 2 WETH
        vm.prank(investee);
        satellite.payInstallment(DEAL, 1); // 1 WETH
        (bool ready,) = satellite.batchReady();
        assertFalse(ready, "no fee wasted on dust");

        vm.expectRevert(Satellite.BatchNotReady.selector);
        satellite.bridgeBatch();
    }

    function test_batch_readyOnTwentyTimesTheFee() public {
        bridge.setFee(0.1 ether);
        vm.prank(investee);
        satellite.payInstallment(DEAL, 2); // 2 WETH
        (bool ready,) = satellite.batchReady();
        assertTrue(ready);
    }

    function test_batch_readyOnAgeEvenIfSmall() public {
        // "or when the oldest pending repayment exceeds thirty days, whichever comes first, so no
        // fee is wasted on dust and no return sits stale."
        bridge.setFee(1 ether); // trigger would be 20 WETH
        vm.prank(investee);
        satellite.payInstallment(DEAL, 1);
        (bool ready,) = satellite.batchReady();
        assertFalse(ready);

        vm.warp(block.timestamp + 30 days);
        (ready,) = satellite.batchReady();
        assertTrue(ready, "no return sits stale");
    }

    function test_bridge_isPermissionlessAndBountied() public {
        bridge.setFee(0.05 ether);
        vm.prank(investee);
        satellite.payInstallment(DEAL, 2);

        uint256 before = weth.balanceOf(keeper);
        vm.prank(keeper);
        uint256 bridged = satellite.bridgeBatch();

        assertEq(bridged, 2 ether);
        assertEq(bridge.lastAmount(), 2 ether, "the full swap output crosses");
        assertEq(weth.balanceOf(keeper) - before, 0.002 ether, "and the caller is paid");
    }

    function test_bridge_bountyComesFromMaintenanceNotTheBatch() public {
        // §9: "Bridge and swap costs are paid from the maintenance slice, so stakers' distributions
        // are never haircut by infrastructure."
        bridge.setFee(0.05 ether);
        vm.prank(investee);
        satellite.payInstallment(DEAL, 2);

        uint256 poolBefore = satellite.bountyPool();
        vm.prank(keeper);
        satellite.bridgeBatch();

        assertEq(bridge.lastAmount(), 2 ether, "the batch is untouched");
        assertEq(poolBefore - satellite.bountyPool(), 0.002 ether, "the bounty is drawn from maintenance");
    }

    function test_bridge_clearsThePendingSet() public {
        bridge.setFee(0.05 ether);
        vm.prank(investee);
        satellite.payInstallment(DEAL, 2);
        vm.prank(keeper);
        satellite.bridgeBatch();

        assertEq(satellite.pendingCount(), 0);
        assertEq(satellite.pendingWeth(), 0);
        vm.expectRevert(Satellite.NothingPending.selector);
        satellite.bridgeBatch();
    }

    function test_bridge_refusesWithoutGasForTheFee() public {
        bridge.setFee(0.05 ether);
        vm.prank(investee);
        satellite.payInstallment(DEAL, 2);
        vm.deal(address(satellite), 0);
        vm.expectRevert(Satellite.FeeNotCovered.selector);
        satellite.bridgeBatch();
    }

    function test_bridge_carriesFloorEntriesToo() public {
        _authoriseFloor();
        vm.prank(investee);
        satellite.settleViaFloor(DEAL, 1);

        // Zero-value batch: age is the only trigger that can fire, which is correct.
        vm.warp(block.timestamp + 30 days);
        vm.prank(keeper);
        satellite.bridgeBatch();

        Repayment[] memory sent = abi.decode(bridge.lastPayload(), (Repayment[]));
        assertEq(sent.length, 1);
        assertTrue(sent[0].viaFloor);
    }

    // =================================================================
    // Governance
    // =================================================================

    function test_parameters_areGovernorOnlyAndBounded() public {
        vm.prank(investee);
        vm.expectRevert(Satellite.NotGovernor.selector);
        satellite.setParameters(300, 3, 12 hours, 0.001 ether);

        vm.startPrank(governor);
        vm.expectRevert(Satellite.OutOfRange.selector);
        satellite.setParameters(0, 3, 12 hours, 0); // zero bound reverts every swap
        vm.expectRevert(Satellite.OutOfRange.selector);
        satellite.setParameters(300, 1, 12 hours, 0); // one strike is a single quote
        satellite.setParameters(300, 4, 1 days, 0.005 ether);
        vm.stopPrank();

        assertEq(uint256(satellite.swapSlippageBps()), 300);
        assertEq(uint256(satellite.illiquidityStrikes()), 4);
    }
}
