// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Escrow} from "../../src/Escrow.sol";
import {ITreasury} from "../../src/interfaces/ITreasury.sol";

/// @dev Stands in for the treasury so tests can separate what a draw *delivers* from what it
///      *obliges*. `deliveryBps` lets a test simulate a swap returning less than nominal, which is
///      the case §8.2 exists to handle.
contract TreasurySpy is ITreasury {
    uint256 public committed;
    uint256 public released;
    uint256 public deliveryBps = 10_000;
    address public lastPaid;
    uint256 public lastNominal;

    function setDeliveryBps(uint256 bps) external {
        deliveryBps = bps;
    }

    function commit(uint256 amount) external {
        committed += amount;
    }

    function release(uint256 amount) external {
        released += amount;
        committed -= amount;
    }

    function fundDraw(address to, uint256 wethAmount) external returns (uint256) {
        committed -= wethAmount;
        lastPaid = to;
        lastNominal = wethAmount;
        return (wethAmount * deliveryBps) / 10_000;
    }
}

contract EscrowTest is Test {
    Escrow internal escrow;
    TreasurySpy internal treasury;

    address internal timelock = makeAddr("timelock");
    address internal saine = makeAddr("saine");
    address internal receiver = makeAddr("receiver");
    address internal investee = makeAddr("investee");
    address internal stranger = makeAddr("stranger");

    uint128 internal constant ALLOC = 100 ether;
    uint32 internal constant VINTAGE = 3;

    function setUp() public {
        treasury = new TreasurySpy();
        escrow = new Escrow(timelock, ITreasury(address(treasury)));
        escrow.wire(saine, receiver);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _terms() internal view returns (Escrow.DealTerms memory t) {
        t.investee = investee;
        t.vintage = VINTAGE;
        t.allocationWeth = ALLOC;
        t.supplyBps = 500; // 5% of eventual supply
        t.vestingMonths = 24;
        t.liveToken = false;
        t.manifestHash = keccak256("manifest");
        t.milestones[0] = keccak256("audit published");
        t.milestones[1] = keccak256("mainnet migration");
        t.windowEnds[0] = uint64(block.timestamp + 200 days);
        t.windowEnds[1] = uint64(block.timestamp + 500 days);
    }

    function _register() internal returns (uint256 id) {
        vm.prank(timelock);
        id = escrow.registerDeal(_terms());
    }

    function _registerLiveToken(address token, uint256 supply) internal returns (uint256 id) {
        Escrow.DealTerms memory t = _terms();
        t.liveToken = true;
        t.liveTokenAddress = token;
        t.liveTokenSupply = supply;
        vm.prank(timelock);
        id = escrow.registerDeal(t);
    }

    function _unlockAll(uint256 id) internal {
        vm.prank(saine);
        escrow.releaseTranche(id, 1);
        vm.prank(saine);
        escrow.releaseTranche(id, 2);
    }

    // =================================================================
    // Registration (§8.3, §6.3)
    // =================================================================

    function test_register_splitsFortyThirtyThirty() public {
        uint256 id = _register();
        assertEq(uint256(escrow.getTranche(id, 0).amountWeth), 40 ether);
        assertEq(uint256(escrow.getTranche(id, 1).amountWeth), 30 ether);
        assertEq(uint256(escrow.getTranche(id, 2).amountWeth), 30 ether);
    }

    function test_register_trancheOneIsClaimableImmediately() public {
        uint256 id = _register();
        assertEq(uint256(escrow.getTranche(id, 0).unlockedAt), block.timestamp, "unlocked on execution");
        assertEq(uint256(escrow.getTranche(id, 1).unlockedAt), 0, "milestone-gated");
        assertEq(uint256(escrow.getTranche(id, 2).unlockedAt), 0, "milestone-gated");
    }

    function test_register_commitsAgainstTheTreasury() public {
        _register();
        assertEq(treasury.committed(), ALLOC, "capacity is reserved, not transferred");
    }

    function test_register_isTimelockOnly() public {
        vm.prank(stranger);
        vm.expectRevert(Escrow.NotTimelock.selector);
        escrow.registerDeal(_terms());
    }

    function test_register_rejectsMilestoneWindowOverTwelveMonths() public {
        Escrow.DealTerms memory t = _terms();
        t.windowEnds[0] = uint64(block.timestamp + 366 days);
        vm.prank(timelock);
        vm.expectRevert(Escrow.WindowTooLong.selector);
        escrow.registerDeal(t);
    }

    function test_register_rejectsNonAscendingWindows() public {
        Escrow.DealTerms memory t = _terms();
        t.windowEnds[1] = t.windowEnds[0];
        vm.prank(timelock);
        vm.expectRevert(Escrow.WindowNotAscending.selector);
        escrow.registerDeal(t);
    }

    function test_register_rejectsVestingBeyondTwentyFourMonths() public {
        Escrow.DealTerms memory t = _terms();
        t.vestingMonths = 25;
        vm.prank(timelock);
        vm.expectRevert(Escrow.VestingTooLong.selector);
        escrow.registerDeal(t);
    }

    // =================================================================
    // Drawdown (§8.2)
    // =================================================================

    function test_draw_obligationIsNominalNotRealised() public {
        // The heart of §8.2: "The obligation created by each draw is recorded in WETH at the
        // time-weighted oracle price, never at the realised swap output."
        uint256 id = _register();
        treasury.setDeliveryBps(9_700); // a 3% shortfall against nominal

        vm.prank(investee);
        uint256 delivered = escrow.draw(id, 0);

        assertEq(delivered, 38.8 ether, "investee receives the realised output");
        assertEq(uint256(escrow.getDeal(id).drawnWeth), 40 ether, "but owes the nominal figure");
    }

    function test_draw_isInvesteeOnly() public {
        uint256 id = _register();
        vm.prank(stranger);
        vm.expectRevert(Escrow.NotInvestee.selector);
        escrow.draw(id, 0);
    }

    function test_draw_rejectsLockedTranche() public {
        uint256 id = _register();
        vm.prank(investee);
        vm.expectRevert(Escrow.TrancheLocked.selector);
        escrow.draw(id, 1);
    }

    function test_draw_cannotDrawTwice() public {
        uint256 id = _register();
        vm.prank(investee);
        escrow.draw(id, 0);
        vm.prank(investee);
        vm.expectRevert(Escrow.TrancheAlreadyDrawn.selector);
        escrow.draw(id, 0);
    }

    function test_draw_setsLongStopThirtySixMonthsFromFirstDraw() public {
        uint256 id = _register();
        vm.prank(investee);
        escrow.draw(id, 0);
        assertEq(uint256(escrow.getDeal(id).longStop), block.timestamp + 1095 days);
    }

    function test_draw_liveTokenVestingBeginsAtFirstDraw() public {
        // §8.5: "For teams with a live token, vesting begins at first draw."
        address token = makeAddr("token");
        uint256 id = _registerLiveToken(token, 1_000_000e18);
        vm.warp(block.timestamp + 10 days);
        vm.prank(investee);
        escrow.draw(id, 0);
        assertEq(uint256(escrow.getWarrant(id).vestingStart), block.timestamp);
        assertEq(escrow.getWarrant(id).owedTokens, 50_000e18, "5% of supply");
    }

    // =================================================================
    // Claim expiry (§8.2, §15)
    // =================================================================

    function test_claim_expiresAfterSixMonths() public {
        uint256 id = _register();
        vm.warp(block.timestamp + 182 days + 1);
        vm.prank(investee);
        vm.expectRevert(Escrow.ClaimWindowExpired.selector);
        escrow.draw(id, 0);
    }

    function test_lapseUnclaimed_returnsAllocationToTreasury() public {
        uint256 id = _register();
        vm.warp(block.timestamp + 182 days + 1);
        escrow.lapseUnclaimed(id, 0); // permissionless
        assertEq(treasury.released(), 40 ether);
        assertTrue(escrow.getTranche(id, 0).cancelled);
    }

    function test_lapseUnclaimed_refusesWhileWindowOpen() public {
        uint256 id = _register();
        vm.expectRevert(Escrow.ClaimWindowOpen.selector);
        escrow.lapseUnclaimed(id, 0);
    }

    // =================================================================
    // Milestones (§8.4)
    // =================================================================

    function test_release_isSaineOnly() public {
        uint256 id = _register();
        vm.prank(timelock);
        vm.expectRevert(Escrow.NotSaine.selector);
        escrow.releaseTranche(id, 1);
    }

    function test_release_manyDoNotVoteOnTranches() public {
        // There is no Many-facing entry point at all; the only caller is the agent registry.
        uint256 id = _register();
        vm.prank(saine);
        escrow.releaseTranche(id, 1);
        assertEq(uint256(escrow.getTranche(id, 1).unlockedAt), block.timestamp);
    }

    function test_release_isSequential() public {
        uint256 id = _register();
        vm.prank(saine);
        vm.expectRevert(Escrow.PredecessorLocked.selector);
        escrow.releaseTranche(id, 2);
    }

    function test_release_refusesAfterWindowCloses() public {
        uint256 id = _register();
        vm.warp(block.timestamp + 201 days);
        vm.prank(saine);
        vm.expectRevert(Escrow.MilestoneWindowClosed.selector);
        escrow.releaseTranche(id, 1);
    }

    function test_lapseMilestone_cancelsThisTrancheAndEverythingAfter() public {
        // §8.4: "When the window expires, the remaining allocation lapses to the treasury, with no
        // retry loop and no penalty round."
        uint256 id = _register();
        vm.prank(investee);
        escrow.draw(id, 0);

        vm.warp(block.timestamp + 201 days);
        escrow.lapseMilestone(id, 1);

        assertTrue(escrow.getTranche(id, 1).cancelled);
        assertTrue(escrow.getTranche(id, 2).cancelled, "the tail lapses with it");
        assertEq(treasury.released(), 60 ether);
        assertEq(uint256(escrow.undrawnWeth(id)), 0);
    }

    function test_lapseMilestone_refusesWhileWindowOpen() public {
        uint256 id = _register();
        vm.expectRevert(Escrow.MilestoneWindowOpen.selector);
        escrow.lapseMilestone(id, 1);
    }

    // =================================================================
    // Halt (§6.5)
    // =================================================================

    function test_halt_returnsUndrawnAndKeepsTheObligation() public {
        // "A passed halt returns all undrawn allocation to the treasury." What was already drawn
        // stays owed: a halt stops future funding, it does not forgive what was taken.
        uint256 id = _register();
        vm.prank(investee);
        escrow.draw(id, 0);

        vm.prank(timelock);
        escrow.halt(id);

        assertEq(treasury.released(), 60 ether, "only the undrawn 30 + 30");
        assertEq(uint256(escrow.getDeal(id).drawnWeth), 40 ether, "the drawn obligation survives");
    }

    function test_halt_isTimelockOnly() public {
        uint256 id = _register();
        vm.prank(saine);
        vm.expectRevert(Escrow.NotTimelock.selector);
        escrow.halt(id);
    }

    function test_halt_blocksFurtherDraws() public {
        uint256 id = _register();
        vm.prank(timelock);
        escrow.halt(id);
        vm.prank(investee);
        vm.expectRevert(Escrow.DealNotActive.selector);
        escrow.draw(id, 0);
    }

    // =================================================================
    // The warrant and TGE (§8.5)
    // =================================================================

    function test_tge_requiresADrawFirst() public {
        uint256 id = _register();
        vm.prank(investee);
        vm.expectRevert(Escrow.NoDrawYet.selector);
        escrow.registerTge(id, makeAddr("tok"), 1e24);
    }

    function test_tge_convertsWarrantToScheduleAfterChallengeWindow() public {
        uint256 id = _register();
        vm.prank(investee);
        escrow.draw(id, 0);

        address token = makeAddr("tok");
        vm.prank(investee);
        escrow.registerTge(id, token, 1_000_000e18);

        assertTrue(escrow.hasOutstandingWarrant(id), "still a warrant during the window");

        vm.warp(block.timestamp + 7 days + 1);
        escrow.finaliseTge(id);

        Escrow.Warrant memory w = escrow.getWarrant(id);
        assertTrue(w.finalised);
        assertEq(w.owedTokens, 50_000e18, "5% of eventual supply");
        assertEq(escrow.installmentTokens(id), uint256(50_000e18) / 24);
        assertFalse(escrow.hasOutstandingWarrant(id), "warrant has become a schedule");
    }

    function test_tge_cannotFinaliseInsideTheChallengeWindow() public {
        uint256 id = _register();
        vm.prank(investee);
        escrow.draw(id, 0);
        vm.prank(investee);
        escrow.registerTge(id, makeAddr("tok"), 1e24);

        vm.expectRevert(Escrow.ChallengeWindowOpen.selector);
        escrow.finaliseTge(id);
    }

    function test_tge_challengeVoidsTheRegistration() public {
        uint256 id = _register();
        vm.prank(investee);
        escrow.draw(id, 0);
        vm.prank(investee);
        escrow.registerTge(id, makeAddr("tok"), 1e24);

        vm.prank(saine);
        escrow.challengeTge(id);

        assertEq(escrow.getWarrant(id).token, address(0), "voided, not finalised");
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(Escrow.TgeNotRegistered.selector);
        escrow.finaliseTge(id);
    }

    function test_tge_investeeMayReregisterAfterAChallenge() public {
        uint256 id = _register();
        vm.prank(investee);
        escrow.draw(id, 0);
        vm.prank(investee);
        escrow.registerTge(id, makeAddr("wrong"), 1e24);
        vm.prank(saine);
        escrow.challengeTge(id);

        address right = makeAddr("right");
        vm.prank(investee);
        escrow.registerTge(id, right, 2e24);
        vm.warp(block.timestamp + 8 days);
        escrow.finaliseTge(id);
        assertEq(escrow.getWarrant(id).token, right);
    }

    function test_tge_challengeIsSaineOnly() public {
        uint256 id = _register();
        vm.prank(investee);
        escrow.draw(id, 0);
        vm.prank(investee);
        escrow.registerTge(id, makeAddr("tok"), 1e24);

        vm.prank(investee);
        vm.expectRevert(Escrow.NotSaine.selector);
        escrow.challengeTge(id);
    }

    // =================================================================
    // Long-stop floor (§8.5, §15)
    // =================================================================

    function test_longStop_floorIsMultipleOfDrawnNotAllocated() public {
        // A team that took one tranche owes against one tranche.
        uint256 id = _register();
        vm.prank(investee);
        escrow.draw(id, 0); // 40 of 100

        vm.warp(block.timestamp + 1095 days);
        escrow.activateLongStopFloor(id);

        assertEq(uint256(escrow.getRepayment(id).floorWeth), 50 ether, "1.25 x 40, not 1.25 x 100");
    }

    function test_longStop_refusesBeforeThirtySixMonths() public {
        uint256 id = _register();
        vm.prank(investee);
        escrow.draw(id, 0);
        vm.warp(block.timestamp + 1094 days);
        vm.expectRevert(Escrow.LongStopNotReached.selector);
        escrow.activateLongStopFloor(id);
    }

    function test_longStop_doesNotApplyOnceATokenIsRegistered() public {
        // §8.5: the warrant is perpetual, and a launched token discharges it through the schedule.
        uint256 id = _register();
        vm.prank(investee);
        escrow.draw(id, 0);
        vm.prank(investee);
        escrow.registerTge(id, makeAddr("tok"), 1e24);
        vm.warp(block.timestamp + 8 days);
        escrow.finaliseTge(id);

        vm.warp(block.timestamp + 1095 days);
        vm.expectRevert(Escrow.TgeAlreadyFinalised.selector);
        escrow.activateLongStopFloor(id);
    }

    // =================================================================
    // Repayment, default registry (§8.6)
    // =================================================================

    function _liveSchedule() internal returns (uint256 id) {
        id = _registerLiveToken(makeAddr("tok"), 1_000_000e18);
        vm.prank(investee);
        escrow.draw(id, 0);
    }

    function test_installments_accrueMonthly() public {
        uint256 id = _liveSchedule();
        assertEq(uint256(escrow.installmentsDue(id)), 0);
        vm.warp(block.timestamp + 30 days);
        assertEq(uint256(escrow.installmentsDue(id)), 1);
        vm.warp(block.timestamp + 90 days);
        assertEq(uint256(escrow.installmentsDue(id)), 4);
    }

    function test_installments_capAtTheVestingTerm() public {
        uint256 id = _liveSchedule();
        vm.warp(block.timestamp + 30 days * 40);
        assertEq(uint256(escrow.installmentsDue(id)), 24, "never beyond the 24-month cap");
    }

    function test_default_flagsAtTwoOutstanding() public {
        uint256 id = _liveSchedule();

        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(Escrow.NotInDefault.selector);
        escrow.flagDefault(id); // one missed installment is inside the grace period

        vm.warp(block.timestamp + 30 days);
        escrow.flagDefault(id); // permissionless
        assertTrue(escrow.isDefaulted(investee), "SAINE reads this on every future proposal");
    }

    function test_default_clearsWhenTheTeamCatchesUp() public {
        uint256 id = _liveSchedule();
        vm.warp(block.timestamp + 60 days);
        escrow.flagDefault(id);
        assertTrue(escrow.isDefaulted(investee));

        vm.prank(receiver);
        escrow.recordInstallments(id, 2, 3 ether, false);
        assertFalse(escrow.isDefaulted(investee));
    }

    function test_repayment_creditIsReceiverOnly() public {
        uint256 id = _liveSchedule();
        vm.prank(investee);
        vm.expectRevert(Escrow.NotReceiver.selector);
        escrow.recordInstallments(id, 1, 1 ether, false);
    }

    /// @dev Invariant 14: "The repayment path choice (token or floor) is computed by the escrow;
    ///      the investee holds no election." Structural rather than procedural: the flag lives on a
    ///      receiver-gated function, so there is no path from an investee-callable function to it.
    function test_invariant14_investeeCannotElectTheFloorPath() public {
        uint256 id = _liveSchedule();
        vm.startPrank(investee);
        vm.expectRevert(Escrow.NotReceiver.selector);
        escrow.recordInstallments(id, 1, 1 ether, true);
        vm.stopPrank();

        // And the record of which path was taken is written by the satellite's bound, not a choice.
        vm.prank(receiver);
        escrow.recordInstallments(id, 1, 1 ether, true);
        assertEq(uint256(escrow.getRepayment(id).floorInstallments), 1);
    }

    // =================================================================
    // Registries (§8.5, §8.6, §13)
    // =================================================================

    function test_registry_listsEveryDealAnInvesteeHasHeld() public {
        _register();
        _register();
        assertEq(escrow.dealsOf(investee).length, 2);
    }

    function test_registry_warrantIsOutstandingOnlyAfterCapitalMoves() public {
        uint256 id = _register();
        assertFalse(escrow.hasOutstandingWarrant(id), "nothing drawn, nothing owed");
        vm.prank(investee);
        escrow.draw(id, 0);
        assertTrue(escrow.hasOutstandingWarrant(id));
    }

    // =================================================================
    // Parameters
    // =================================================================

    function test_challengeWindow_isTimelockTunableWithinBounds() public {
        vm.prank(timelock);
        escrow.setTgeChallengeWindow(14 days);
        assertEq(uint256(escrow.tgeChallengeWindow()), 14 days);

        vm.prank(timelock);
        vm.expectRevert(Escrow.WindowOutOfRange.selector);
        escrow.setTgeChallengeWindow(31 days);

        vm.prank(stranger);
        vm.expectRevert(Escrow.NotTimelock.selector);
        escrow.setTgeChallengeWindow(10 days);
    }
}
