// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Code} from "../../src/Code.sol";
import {DCode} from "../../src/DCode.sol";
import {IVintageVault} from "../../src/interfaces/IVintageVault.sol";
import {PenaltyMath} from "../../src/libraries/PenaltyMath.sol";

/// @dev Records the weight syncs the staking vault pushes on exit, so tests can assert that a
///      withdrawal actually contracts every open vintage rather than silently skipping one.
contract VaultSpy is IVintageVault {
    mapping(address => mapping(uint32 => uint256)) public synced;
    mapping(address => mapping(uint32 => bool)) public wasSynced;
    uint256 public syncCount;

    function syncVintageWeight(address account, uint32 vintage, uint256 newWeight) external {
        synced[account][vintage] = newWeight;
        wasSynced[account][vintage] = true;
        ++syncCount;
    }

    function creditVintage(uint32, uint256) external {}
}

contract DCodeTest is Test {
    Code internal code;
    DCode internal dcode;
    VaultSpy internal vaultSpy;

    address internal treasury;
    address internal maintenance;
    address internal genesis;
    address internal governor;

    /// @dev 50 large stakers take the seats; the rest form the Many.
    address[] internal whales;
    address[] internal many;

    uint256 internal constant WHALE_STAKE = 1_000_000e18;
    uint256 internal constant MANY_STAKE = 10_000e18;
    uint256 internal constant MANY_COUNT = 8;

    function setUp() public {
        treasury = makeAddr("treasury");
        maintenance = makeAddr("maintenance");
        genesis = makeAddr("genesis");
        governor = makeAddr("governor");

        code = new Code(genesis, treasury, maintenance);
        dcode = new DCode(code);
        vaultSpy = new VaultSpy();

        address[] memory ex = new address[](2);
        ex[0] = genesis;
        ex[1] = address(dcode);
        code.setExempt(ex);
        code.seal();

        address[] memory protocol = new address[](2);
        protocol[0] = treasury;
        protocol[1] = address(vaultSpy);
        dcode.wire(governor, IVintageVault(address(vaultSpy)), protocol);

        // Seat fifty Guardians, descending so ranks are unambiguous.
        for (uint256 i; i < 50; ++i) {
            address w = makeAddr(string.concat("whale", vm.toString(i)));
            whales.push(w);
            _fund(w, WHALE_STAKE + (50 - i) * 1e18);
            _stake(w, WHALE_STAKE + (50 - i) * 1e18);
        }
        for (uint256 i; i < MANY_COUNT; ++i) {
            address m = makeAddr(string.concat("many", vm.toString(i)));
            many.push(m);
            _fund(m, MANY_STAKE);
            _stake(m, MANY_STAKE);
        }
    }

    function _fund(address who, uint256 amount) internal {
        vm.prank(genesis);
        code.transfer(who, amount);
    }

    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        code.approve(address(dcode), amount);
        dcode.stake(amount);
        vm.stopPrank();
    }

    function _openSeason1() internal {
        dcode.openFirstSeason();
        assertEq(dcode.currentSeason(), 1);
    }

    function _rollToNext() internal {
        vm.warp(dcode.seasonEnd(dcode.currentSeason()) + 1);
        dcode.rollover();
    }

    // =================================================================
    // Snapshot semantics (§3.2)
    // =================================================================

    function test_snapshot_depositMidSeasonDecidesNothingUntilBoundary() public {
        _openSeason1();
        address late = makeAddr("late");
        _fund(late, MANY_STAKE);
        _stake(late, MANY_STAKE);

        assertEq(dcode.ballotWeight(late, 1), 0, "mid-season deposit must carry no weight");
        _rollToNext();
        assertEq(dcode.ballotWeight(late, 2), MANY_STAKE, "and full weight from the next boundary");
    }

    function test_snapshot_stakeBeforeFirstSeasonCountsImmediately() public {
        _openSeason1();
        assertEq(dcode.ballotWeight(many[0], 1), MANY_STAKE);
    }

    function test_governance_doesNotOpenWithAnEmptyMany() public {
        // A launch with 50 or fewer stakers makes everyone a Guardian and quorum unreachable.
        Code c2 = new Code(genesis, treasury, maintenance);
        DCode d2 = new DCode(c2);
        address[] memory ex = new address[](2);
        ex[0] = genesis;
        ex[1] = address(d2);
        c2.setExempt(ex);
        d2.wire(governor, IVintageVault(address(vaultSpy)), new address[](0));

        vm.expectRevert(DCode.BoardNotFull.selector);
        d2.openFirstSeason();
    }

    // =================================================================
    // The Guardian / Many split (§4.1)
    // =================================================================

    function test_guardians_areTheFiftyLargestStakers() public {
        _openSeason1();
        assertEq(dcode.guardianCount(1), 50);
        for (uint256 i; i < 50; ++i) {
            assertTrue(dcode.isGuardian(whales[i], 1), "whale must hold a seat");
        }
        for (uint256 i; i < MANY_COUNT; ++i) {
            assertFalse(dcode.isGuardian(many[i], 1), "small staker must be in the Many");
        }
    }

    function test_guardians_holdNoVotingWeight() public {
        _openSeason1();
        assertEq(dcode.ballotWeight(whales[0], 1), 0, "Guardians source deals, they do not decide them");
    }

    function test_manyBase_excludesGuardianStake() public {
        _openSeason1();
        uint256 expected = MANY_STAKE * MANY_COUNT;
        assertEq(dcode.manyEffectivePower(1), expected);
    }

    function test_board_tieLeavesIncumbentSeated() public {
        // Deterministic tie-break that does not depend on address ordering.
        _openSeason1();
        address challenger = makeAddr("challenger");
        uint256 weakest = WHALE_STAKE + 1e18; // whale index 49
        _fund(challenger, weakest);
        _stake(challenger, weakest);

        address[] memory cands = new address[](1);
        cands[0] = challenger;
        dcode.pokeBoard(cands);

        _rollToNext();
        assertTrue(dcode.isGuardian(whales[49], 2), "an equal challenger does not unseat");
        assertFalse(dcode.isGuardian(challenger, 2));
    }

    function test_board_strictlyLargerChallengerTakesTheSeat() public {
        _openSeason1();
        address challenger = makeAddr("challenger");
        uint256 amount = WHALE_STAKE + 1e18 + 1;
        _fund(challenger, amount);
        _stake(challenger, amount);

        _rollToNext();
        assertTrue(dcode.isGuardian(challenger, 2), "a larger staker takes the smallest seat");
        assertFalse(dcode.isGuardian(whales[49], 2));
    }

    // =================================================================
    // Penalties (§7.1)
    // =================================================================

    /// @dev Drive one adjudicated proposal: open a slot, collect ballots, settle a verdict.
    function _adjudicate(bool approved, address[] memory yesVoters, address[] memory noVoters)
        internal
        returns (uint8 slot)
    {
        uint32 s = dcode.currentSeason();
        vm.prank(governor);
        slot = dcode.openScoredSlot(s);

        uint256 yesWeight;
        uint256 noWeight;
        for (uint256 i; i < yesVoters.length; ++i) {
            yesWeight += dcode.ballotWeight(yesVoters[i], s);
            vm.prank(governor);
            dcode.recordBallot(yesVoters[i], s, slot, true);
        }
        for (uint256 i; i < noVoters.length; ++i) {
            noWeight += dcode.ballotWeight(noVoters[i], s);
            vm.prank(governor);
            dcode.recordBallot(noVoters[i], s, slot, false);
        }
        vm.prank(governor);
        dcode.settleScoredSlot(s, slot, approved, yesWeight, noWeight);
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _none() internal pure returns (address[] memory arr) {
        arr = new address[](0);
    }

    function test_penalty_correctVoteCostsNothing() public {
        _openSeason1();
        _adjudicate(true, _one(many[0]), _none());
        assertEq(dcode.ballotWeight(many[0], 1), MANY_STAKE, "being right is free");
    }

    function test_penalty_wrongVoteCostsTenPercent() public {
        _openSeason1();
        _adjudicate(true, _none(), _one(many[0]));
        assertEq(dcode.ballotWeight(many[0], 1), (MANY_STAKE * 90) / 100);
    }

    function test_penalty_nonVoteCostsFifteenPercent() public {
        _openSeason1();
        _adjudicate(true, _one(many[0]), _none());
        assertEq(dcode.ballotWeight(many[1], 1), (MANY_STAKE * 85) / 100, "silence is priced above error");
    }

    function test_penalty_votingDominatesAbstention() public {
        // The ordering in §7.1 is load-bearing: a wrong call must cost strictly less than silence,
        // or hiding becomes the rational play and the electorate stops scoring anything.
        _openSeason1();
        _adjudicate(true, _none(), _one(many[0])); // wrong vote
        uint256 wrongWeight = dcode.ballotWeight(many[0], 1);
        uint256 silentWeight = dcode.ballotWeight(many[1], 1);
        assertGt(wrongWeight, silentWeight);
    }

    function test_penalty_compoundsMultiplicatively() public {
        _openSeason1();
        _adjudicate(true, _none(), _one(many[0]));
        _adjudicate(true, _none(), _one(many[0]));
        // 0.9 * 0.9 = 0.81, per the worked example in §7.1.
        assertEq(dcode.ballotWeight(many[0], 1), (MANY_STAKE * 81) / 100);
    }

    function test_penalty_rejectionScoresYesVotersAsWrong() public {
        _openSeason1();
        _adjudicate(false, _one(many[0]), _one(many[1]));
        assertEq(dcode.ballotWeight(many[0], 1), (MANY_STAKE * 90) / 100, "yes on a rejected deal is wrong");
        assertEq(dcode.ballotWeight(many[1], 1), MANY_STAKE, "no on a rejected deal is right");
    }

    function test_penalty_manyWrongVoteIsTenNotFifty() public {
        // Reconciles the brief with §15: the 50% belongs to the sponsoring Guardian, the Many
        // carry 10%.
        _openSeason1();
        _adjudicate(false, _one(many[0]), _none());
        assertEq(dcode.ballotWeight(many[0], 1), (MANY_STAKE * 90) / 100);
    }

    function test_penalty_unsettledSlotScoresNobody() public {
        _openSeason1();
        uint32 s = dcode.currentSeason();
        vm.prank(governor);
        dcode.openScoredSlot(s);
        // A proposal mid-adjudication is not yet a judgement and must not read as an absence.
        assertEq(dcode.ballotWeight(many[0], 1), MANY_STAKE);
    }

    function test_penalty_resetsAtRollover() public {
        _openSeason1();
        _adjudicate(true, _none(), _one(many[0]));
        assertLt(dcode.ballotWeight(many[0], 1), MANY_STAKE);
        _rollToNext();
        assertEq(dcode.ballotWeight(many[0], 2), MANY_STAKE, "penalties expire quarterly");
    }

    function test_penalty_cannotBeEvadedByRequestingExit() public {
        _openSeason1();
        _adjudicate(true, _none(), _one(many[0]));
        uint256 penalised = dcode.ballotWeight(many[0], 1);

        uint32[] memory vintages = new uint32[](0);
        vm.prank(many[0]);
        dcode.requestWithdraw(MANY_STAKE, vintages);

        assertEq(dcode.ballotWeight(many[0], 1), penalised, "requesting an exit does not shed the season");
    }

    // =================================================================
    // The aggregate must be exact, because quorum is a percentage of it (§4.2)
    // =================================================================

    function test_manyEffective_tracksSumOfIndividualWeights() public {
        _openSeason1();
        _adjudicate(true, _one(many[0]), _one(many[1]));
        _adjudicate(false, _one(many[2]), _one(many[0]));
        _adjudicate(true, _one(many[3]), _none());

        uint256 sum;
        for (uint256 i; i < MANY_COUNT; ++i) {
            sum += dcode.ballotWeight(many[i], 1);
        }
        uint256 aggregate = dcode.manyEffectivePower(1);

        // The aggregate applies one truncation to a tally; the individual reads truncate per
        // account. The residual is therefore bounded by one wei per participant, and it always
        // favours the aggregate, never a voter.
        assertApproxEqAbs(aggregate, sum, MANY_COUNT);
        assertGe(aggregate, sum);
    }

    function testFuzz_manyEffective_tracksSumUnderArbitraryVotePatterns(uint8 pattern, bool verdict) public {
        _openSeason1();

        address[] memory yes = new address[](MANY_COUNT);
        address[] memory no = new address[](MANY_COUNT);
        uint256 yn;
        uint256 nn;
        for (uint256 i; i < MANY_COUNT; ++i) {
            uint8 bits = uint8((pattern >> (i % 8)) & 1);
            // Leave a third of the electorate silent so the non-vote path is exercised too.
            if (i % 3 == 0) continue;
            if (bits == 1) {
                yes[yn++] = many[i];
            } else {
                no[nn++] = many[i];
            }
        }
        address[] memory yesTrim = new address[](yn);
        address[] memory noTrim = new address[](nn);
        for (uint256 i; i < yn; ++i) yesTrim[i] = yes[i];
        for (uint256 i; i < nn; ++i) noTrim[i] = no[i];

        _adjudicate(verdict, yesTrim, noTrim);

        uint256 sum;
        for (uint256 i; i < MANY_COUNT; ++i) {
            sum += dcode.ballotWeight(many[i], 1);
        }
        assertApproxEqAbs(dcode.manyEffectivePower(1), sum, MANY_COUNT);
    }

    // =================================================================
    // Delegation (§4.1)
    // =================================================================

    function test_delegation_takesEffectAtTheNextBoundary() public {
        _openSeason1();
        vm.prank(many[0]);
        dcode.delegate(many[1]);

        assertEq(dcode.ballotWeight(many[0], 1), MANY_STAKE, "locked for the season in progress");
        assertEq(dcode.ballotWeight(many[1], 1), MANY_STAKE);

        _rollToNext();
        assertEq(dcode.ballotWeight(many[0], 2), 0, "weight has moved");
        assertEq(dcode.ballotWeight(many[1], 2), MANY_STAKE * 2, "and arrived");
    }

    function test_delegation_delegatorInheritsTheDelegatesRecord() public {
        _openSeason1();
        vm.prank(many[0]);
        dcode.delegate(many[1]);
        _rollToNext();

        // many[1] votes wrong on behalf of both.
        _adjudicate(true, _none(), _one(many[1]));

        uint256 mult = dcode.manyMultiplierOf(many[0], 2);
        assertEq(mult, PenaltyMath.WRONG_VOTE_MULT, "the delegator carries the delegate's error");
    }

    function test_delegation_chainsAreForbidden() public {
        _openSeason1();
        vm.prank(many[0]);
        dcode.delegate(many[1]);
        _rollToNext();

        vm.prank(many[1]);
        vm.expectRevert(DCode.DelegationChainForbidden.selector);
        dcode.delegate(many[2]);
    }

    function test_delegation_cannotPointAtSomeoneWhoHasDelegatedAway() public {
        _openSeason1();
        vm.prank(many[0]);
        dcode.delegate(many[1]);

        vm.prank(many[2]);
        vm.expectRevert(DCode.DelegateHasDelegated.selector);
        dcode.delegate(many[0]);
    }

    function test_delegation_guardianOutboundWeightVotesNothing() public {
        // §4.1: "Guardians cannot delegate their weight to any address that can vote."
        _openSeason1();
        vm.prank(whales[0]);
        dcode.delegate(many[0]);
        _rollToNext();

        assertEq(
            dcode.ballotWeight(many[0], 2),
            MANY_STAKE,
            "a Guardian's stake must not appear in anyone's ballot"
        );
        assertEq(dcode.voidedGuardianInbound(2, many[0]), WHALE_STAKE + 50e18);
    }

    function test_delegation_revertsToSelfWhenTheDelegateWinsASeat() public {
        // Nobody should be disenfranchised, and charged 15% for it, because their delegate grew.
        _openSeason1();
        address grower = many[0];
        vm.prank(many[1]);
        dcode.delegate(grower);
        _rollToNext();
        assertEq(dcode.ballotWeight(grower, 2), MANY_STAKE * 2);

        // The delegate now becomes one of the fifty largest stakers.
        _fund(grower, WHALE_STAKE * 2);
        _stake(grower, WHALE_STAKE * 2);
        _rollToNext();

        assertTrue(dcode.isGuardian(grower, 3), "delegate took a seat");
        assertEq(dcode.ballotWeight(grower, 3), 0, "and so casts nothing");
        assertEq(
            dcode.resolvedDelegateeOf(many[1], 3),
            many[1],
            "the delegation resolves back to its owner"
        );
        assertEq(dcode.ballotWeight(many[1], 3), MANY_STAKE, "who can still vote and avoid the 15%");
    }

    function test_delegation_doesNotAffectGuardianRanking() public {
        // "Delegated weight counts in the delegate's ballots but never toward Guardian ranking,
        // which is computed on an address's own staked principal alone."
        _openSeason1();
        for (uint256 i; i < MANY_COUNT; ++i) {
            vm.prank(many[i]);
            dcode.delegate(many[0]);
        }
        _rollToNext();
        assertFalse(dcode.isGuardian(many[0], 2), "inbound delegation wins no seat");
    }

    // =================================================================
    // Withdrawals (§3.1)
    // =================================================================

    function test_withdraw_settlesOnlyAtTheBoundary() public {
        _openSeason1();
        uint32[] memory none = new uint32[](0);
        vm.prank(many[0]);
        dcode.requestWithdraw(MANY_STAKE, none);

        vm.prank(many[0]);
        vm.expectRevert(DCode.NotYetSettled.selector);
        dcode.collectWithdrawal();

        _rollToNext();
        uint256 before = code.balanceOf(many[0]);
        vm.prank(many[0]);
        dcode.collectWithdrawal();
        assertEq(code.balanceOf(many[0]) - before, MANY_STAKE, "principal returns untaxed");
    }

    function test_withdraw_burnsDCodeImmediately() public {
        _openSeason1();
        uint32[] memory none = new uint32[](0);
        vm.prank(many[0]);
        dcode.requestWithdraw(MANY_STAKE, none);
        assertEq(dcode.balanceOf(many[0]), 0);
    }

    function test_withdraw_requiresEveryOpenVintage() public {
        _openSeason1();
        _rollToNext(); // season 1 has frozen, so a vintage exists

        uint32[] memory empty = new uint32[](0);
        vm.prank(many[0]);
        vm.expectRevert(DCode.VintageRangeIncomplete.selector);
        dcode.requestWithdraw(MANY_STAKE, empty);

        uint32[] memory one = new uint32[](1);
        one[0] = 1;
        vm.prank(many[0]);
        dcode.requestWithdraw(MANY_STAKE, one);
        assertTrue(vaultSpy.wasSynced(many[0], 1), "the vault must learn the weight contracted");
    }

    function test_withdraw_contractsVintageWeightToZero() public {
        _openSeason1();
        _rollToNext();
        uint32[] memory one = new uint32[](1);
        one[0] = 1;
        vm.prank(many[0]);
        dcode.requestWithdraw(MANY_STAKE, one);
        assertEq(vaultSpy.synced(many[0], 1), 0, "a full exit forfeits everything not yet arrived");
    }

    function test_withdraw_monotoneCapIsPermanent() public {
        // §10.3: "A zeroed vintage weight never revives, under any subsequent staking."
        _openSeason1();
        _rollToNext();
        uint32[] memory one = new uint32[](1);
        one[0] = 1;
        vm.prank(many[0]);
        dcode.requestWithdraw(MANY_STAKE, one);

        _fund(many[0], MANY_STAKE * 5);
        _stake(many[0], MANY_STAKE * 5);
        assertEq(dcode.liveVintageWeightOf(many[0], 1), 0, "returning restores nothing");
    }

    function test_withdraw_partialExitCapsVintageAtTheLow() public {
        _openSeason1();
        _rollToNext();
        uint32[] memory one = new uint32[](1);
        one[0] = 1;
        uint256 keep = MANY_STAKE / 4;
        vm.prank(many[0]);
        dcode.requestWithdraw(MANY_STAKE - keep, one);
        assertEq(dcode.liveVintageWeightOf(many[0], 1), keep, "keep what has vested, forfeit the rest");
    }

    // =================================================================
    // dCODE is not a token you can move (§3.1)
    // =================================================================

    function test_dcode_transferReverts() public {
        _openSeason1();
        vm.prank(many[0]);
        vm.expectRevert(DCode.NonTransferable.selector);
        dcode.transfer(many[1], 1);
    }

    function test_dcode_approveReverts() public {
        vm.prank(many[0]);
        vm.expectRevert(DCode.NonTransferable.selector);
        dcode.approve(many[1], 1);
    }

    function test_dcode_balanceEqualsStakedPrincipal() public {
        _openSeason1();
        assertEq(dcode.balanceOf(many[0]), MANY_STAKE);
        assertEq(dcode.totalSupply(), WHALE_STAKE * 50 + (50 * 51 / 2) * 1e18 + MANY_STAKE * MANY_COUNT);
    }

    // =================================================================
    // Access control
    // =================================================================

    function test_onlyGovernorCanRecordBallots() public {
        _openSeason1();
        vm.expectRevert(DCode.NotGovernor.selector);
        dcode.recordBallot(many[0], 1, 0, true);
    }

    function test_onlyGovernorCanSettleVerdicts() public {
        _openSeason1();
        vm.expectRevert(DCode.NotGovernor.selector);
        dcode.settleScoredSlot(1, 0, true, 0, 0);
    }

    function test_guardiansCannotBeRecordedAsVoters() public {
        _openSeason1();
        uint32 s = dcode.currentSeason();
        vm.prank(governor);
        uint8 slot = dcode.openScoredSlot(s);
        vm.prank(governor);
        vm.expectRevert(DCode.NotInMany.selector);
        dcode.recordBallot(whales[0], s, slot, true);
    }

    function test_verdictCannotBeReplayed() public {
        _openSeason1();
        uint32 s = dcode.currentSeason();
        vm.prank(governor);
        uint8 slot = dcode.openScoredSlot(s);
        vm.prank(governor);
        dcode.settleScoredSlot(s, slot, true, 0, 0);
        vm.prank(governor);
        vm.expectRevert(DCode.SlotAlreadySettled.selector);
        dcode.settleScoredSlot(s, slot, false, 0, 0);
    }

    function test_ballotCannotBeCastTwice() public {
        _openSeason1();
        uint32 s = dcode.currentSeason();
        vm.prank(governor);
        uint8 slot = dcode.openScoredSlot(s);
        vm.prank(governor);
        dcode.recordBallot(many[0], s, slot, true);
        vm.prank(governor);
        vm.expectRevert(DCode.AlreadyVoted.selector);
        dcode.recordBallot(many[0], s, slot, false);
    }

    // =================================================================
    // Guardian penalty (§7.3)
    // =================================================================

    function test_guardianSlash_halvesVintageWeightAndBarsProposing() public {
        _openSeason1();
        vm.prank(governor);
        dcode.slashGuardian(whales[0], 1);

        assertTrue(dcode.guardianExcluded(whales[0], 1), "excluded from proposing for the season");
        assertTrue(dcode.isGuardian(whales[0], 1), "but the seat is retained");
        assertEq(dcode.ballotWeight(whales[0], 1), 0, "and no voting rights are gained");

        uint256 snapshot = dcode.snapshotPrincipalOf(whales[0], 1);
        assertEq(dcode.frozenWeightOf(whales[0], 1), snapshot / 2);
    }

    function test_guardianSlash_clearsAtRollover() public {
        _openSeason1();
        vm.prank(governor);
        dcode.slashGuardian(whales[0], 1);
        _rollToNext();
        assertFalse(dcode.guardianExcluded(whales[0], 2));
        assertEq(dcode.frozenWeightOf(whales[0], 2), dcode.snapshotPrincipalOf(whales[0], 2));
    }

    function test_guardianSlash_isPermanentInTheVintage() public {
        // §7.3: "The season resets; the season's carry does not."
        _openSeason1();
        vm.prank(governor);
        dcode.slashGuardian(whales[0], 1);
        uint256 snapshot = dcode.snapshotPrincipalOf(whales[0], 1);
        _rollToNext();
        _rollToNext();
        assertEq(dcode.frozenWeightOf(whales[0], 1), snapshot / 2, "the vintage never reopens");
    }

    function test_guardianSlash_appliesOnlyOncePerSeason() public {
        _openSeason1();
        vm.prank(governor);
        dcode.slashGuardian(whales[0], 1);
        vm.prank(governor);
        vm.expectRevert(DCode.AlreadySlashed.selector);
        dcode.slashGuardian(whales[0], 1);
    }

    // =================================================================
    // Protocol addresses hold no governance weight (§2.4, invariant 3)
    // =================================================================

    function test_protocolAddressesCannotStake() public {
        _fund(treasury, MANY_STAKE);
        vm.startPrank(treasury);
        code.approve(address(dcode), MANY_STAKE);
        vm.expectRevert(DCode.ProtocolAddress.selector);
        dcode.stake(MANY_STAKE);
        vm.stopPrank();
    }

    function test_stakingVaultCannotStakeItself() public view {
        assertTrue(dcode.barredFromStaking(address(dcode)));
    }

    // =================================================================
    // Scored slots are strictly serial (§5.6 advisory rounds)
    // =================================================================

    function test_slots_cannotOverlap() public {
        // An advisory verdict settling inside a binding proposal's voting window would leave
        // ballots cast before and after weighted on different multipliers, so the two tallies
        // would no longer sum against one denominator.
        _openSeason1();
        vm.prank(governor);
        dcode.openScoredSlot(1);
        vm.prank(governor);
        vm.expectRevert(DCode.SlotStillOpen.selector);
        dcode.openScoredSlot(1);
    }

    function test_slots_cannotSettleWhatIsNotOpen() public {
        _openSeason1();
        vm.prank(governor);
        vm.expectRevert(DCode.SlotNotOpen.selector);
        dcode.settleScoredSlot(1, 0, true, 0, 0);
    }

    function test_slots_weightIsFrozenAtSlotOpen() public {
        _openSeason1();
        // First round penalises many[0].
        _adjudicate(true, _none(), _one(many[0]));
        uint256 afterFirst = dcode.ballotWeight(many[0], 1);

        // Second round opens; the weight it will be tallied at is fixed now.
        vm.prank(governor);
        uint8 slot = dcode.openScoredSlot(1);
        assertEq(dcode.ballotWeight(many[0], 1), afterFirst, "frozen for the window");
        assertEq(dcode.multiplierAtSlot(many[0], 1, slot), PenaltyMath.WRONG_VOTE_MULT);
    }

    function test_slots_quorumDenominatorIsFixedAtOpen() public {
        _openSeason1();
        uint256 openPower = dcode.manyEffectivePower(1);
        vm.prank(governor);
        uint8 slot = dcode.openScoredSlot(1);
        assertEq(dcode.slotOpenPower(1, slot), openPower);
    }

    // =================================================================
    // Rollover
    // =================================================================

    function test_rollover_isPermissionlessButNotEarly() public {
        _openSeason1();
        vm.expectRevert(DCode.SeasonNotOver.selector);
        dcode.rollover();

        vm.warp(dcode.seasonEnd(1) + 1);
        vm.prank(makeAddr("anyone"));
        dcode.rollover();
        assertEq(dcode.currentSeason(), 2);
    }

    function test_rollover_seasonIsThirteenWeeks() public {
        _openSeason1();
        assertEq(dcode.seasonEnd(1) - dcode.seasonStart(1), 13 weeks);
    }

    function test_rollover_closesThePreviousSeason() public {
        _openSeason1();
        _rollToNext();
        assertTrue(dcode.isSeasonClosed(1));
    }
}
