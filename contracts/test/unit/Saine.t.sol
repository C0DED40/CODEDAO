// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Code} from "../../src/Code.sol";
import {Saine, ICodeBurn, ISeasonClock} from "../../src/Saine.sol";
import {IOracle} from "../../src/interfaces/ISaineConsumer.sol";

contract OracleStub is IOracle {
    uint256 public price = 0.02e18; // $0.02 per CODE, so a $1,000 bond is 50,000 CODE

    function setPrice(uint256 p) external {
        price = p;
    }

    function codeUsdPrice() external view returns (uint256) {
        return price;
    }

    function poke() external {}
}

contract ClockStub is ISeasonClock {
    uint32 public currentSeason = 1;

    function setSeason(uint32 s) external {
        currentSeason = s;
    }
}

contract GovernorSpy {
    uint256 public lastSubject;
    bool public lastApproved;
    bool public lastLapsed;
    uint256 public calls;

    function onSaineVerdict(uint256 subject, bool approved, bool lapsed) external {
        lastSubject = subject;
        lastApproved = approved;
        lastLapsed = lapsed;
        ++calls;
    }
}

contract EscrowSpy {
    uint256 public totalDrawnWeth;
    uint256 public releasedDeal;
    uint8 public releasedIndex;
    uint256 public releases;

    function setDrawn(uint256 v) external {
        totalDrawnWeth = v;
    }

    function releaseTranche(uint256 dealId, uint8 index) external {
        releasedDeal = dealId;
        releasedIndex = index;
        ++releases;
    }

    function openTrancheRound(Saine saine, uint256 dealId, uint8 index) external returns (uint256) {
        return saine.openTrancheRound(dealId, index, bytes32(0));
    }
}

contract SaineTest is Test {
    Code internal code;
    Saine internal saine;
    OracleStub internal oracle;
    ClockStub internal clock;
    GovernorSpy internal governor;
    EscrowSpy internal escrow;

    address internal genesis = makeAddr("genesis");
    address internal treasury = makeAddr("treasury");
    address internal maintenance = makeAddr("maintenance");
    address internal timelock = makeAddr("timelock");
    address internal teamOperator = makeAddr("teamOperator");
    address internal relayer = makeAddr("relayer");

    uint256[10] internal pk;
    address[10] internal keys;
    bytes32[10] internal providers;

    bytes32 internal constant COMMIT_TYPEHASH =
        keccak256("Commit(uint256 roundId,uint8 slot,bytes32 commitment,bytes32 modelHash)");
    bytes32 internal constant REVEAL_TYPEHASH =
        keccak256("Reveal(uint256 roundId,uint8 slot,bool verdict,bytes32 reasonHash,bytes32 salt)");

    /// @dev Ten distinct models across five providers, which is the genesis board §5.8 describes.
    function setUp() public {
        code = new Code(genesis, treasury, maintenance);
        oracle = new OracleStub();
        clock = new ClockStub();
        governor = new GovernorSpy();
        escrow = new EscrowSpy();

        saine = new Saine(ICodeBurn(address(code)), timelock, ISeasonClock(address(clock)));

        bytes32[5] memory pool =
            [bytes32("anthropic"), bytes32("openai"), bytes32("google"), bytes32("meta"), bytes32("mistral")];
        for (uint256 i; i < 10; ++i) {
            pk[i] = 0xA11CE + i;
            keys[i] = vm.addr(pk[i]);
            providers[i] = pool[i % 5];
        }

        saine.wire(address(governor), address(escrow), IOracle(address(oracle)), teamOperator, keys, providers);

        address[] memory ex = new address[](2);
        ex[0] = genesis;
        ex[1] = address(saine);
        code.setExempt(ex);
        code.seal();

        // Fund and bond every slot at the target.
        vm.prank(genesis);
        code.transfer(teamOperator, 1_000_000e18);
        vm.startPrank(teamOperator);
        code.approve(address(saine), type(uint256).max);
        for (uint8 i; i < 10; ++i) {
            saine.postBond(i, 50_000e18);
        }
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Signing helpers
    // -----------------------------------------------------------------

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", saine.domainSeparator(), structHash));
    }

    function _commitment(bool verdict, bytes32 reasonHash, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(verdict, reasonHash, salt));
    }

    function _signCommit(uint256 roundId, uint8 slot, bytes32 commitment, uint256 signer)
        internal
        view
        returns (Saine.CommitAttestation memory a, bytes memory sig)
    {
        a = Saine.CommitAttestation(roundId, slot, commitment, keccak256("model-v1"));
        bytes32 d = _digest(keccak256(abi.encode(COMMIT_TYPEHASH, roundId, slot, commitment, a.modelHash)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, d);
        sig = abi.encodePacked(r, s, v);
    }

    function _signReveal(uint256 roundId, uint8 slot, bool verdict, bytes32 salt, uint256 signer)
        internal
        view
        returns (Saine.RevealAttestation memory a, bytes memory sig)
    {
        a = Saine.RevealAttestation(roundId, slot, verdict, keccak256("reason:tokenomics"), salt);
        bytes32 d = _digest(keccak256(abi.encode(REVEAL_TYPEHASH, roundId, slot, verdict, a.reasonHash, salt)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer, d);
        sig = abi.encodePacked(r, s, v);
    }

    function _salt(uint8 slot) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("salt", slot));
    }

    /// @dev Built separately from submission so a test expecting a revert can attach it to the
    ///      submit call. The signing helpers read the domain separator from the contract, which is
    ///      itself a call, and `vm.expectRevert` binds to whichever call comes next.
    function _buildCommits(uint256 roundId, uint8 n, uint8 approvals)
        internal
        view
        returns (Saine.CommitAttestation[] memory atts, bytes[] memory sigs)
    {
        atts = new Saine.CommitAttestation[](n);
        sigs = new bytes[](n);
        for (uint8 i; i < n; ++i) {
            bytes32 c = _commitment(i < approvals, keccak256("reason:tokenomics"), _salt(i));
            (atts[i], sigs[i]) = _signCommit(roundId, i, c, pk[i]);
        }
    }

    function _buildReveals(uint256 roundId, uint8 n, uint8 approvals)
        internal
        view
        returns (Saine.RevealAttestation[] memory atts, bytes[] memory sigs)
    {
        atts = new Saine.RevealAttestation[](n);
        sigs = new bytes[](n);
        for (uint8 i; i < n; ++i) {
            (atts[i], sigs[i]) = _signReveal(roundId, i, i < approvals, _salt(i), pk[i]);
        }
    }

    /// @dev Commit `n` slots, of which the first `approvals` vote yes.
    function _commitMany(uint256 roundId, uint8 n, uint8 approvals) internal {
        (Saine.CommitAttestation[] memory atts, bytes[] memory sigs) = _buildCommits(roundId, n, approvals);
        vm.prank(relayer);
        saine.submitCommits(atts, sigs);
    }

    function _revealMany(uint256 roundId, uint8 n, uint8 approvals) internal {
        (Saine.RevealAttestation[] memory atts, bytes[] memory sigs) = _buildReveals(roundId, n, approvals);
        vm.prank(relayer);
        saine.submitReveals(atts, sigs);
    }

    function _openOrigination() internal returns (uint256 id) {
        vm.prank(address(governor));
        id = saine.openRound(Saine.RoundKind.Origination, 42);
    }

    function _runRound(uint8 commits, uint8 reveals, uint8 approvals) internal returns (uint256 id) {
        id = _openOrigination();
        _commitMany(id, commits, approvals);
        vm.warp(block.timestamp + 24 hours + 1);
        _revealMany(id, reveals, approvals);
        vm.warp(block.timestamp + 24 hours + 1);
        saine.settleRound(id);
    }

    // =================================================================
    // Composition and independence (§5.2, §5.8)
    // =================================================================

    function test_genesis_boardIsTenSlotsOneOperatorFourPlusProviders() public view {
        assertEq(saine.liveSlots(), 10);
        assertEq(saine.slotsHeld(teamOperator), 10, "phase one: the team operates all ten");
        assertGe(saine.distinctProviders(), 4, "model diversity is real from day one");
    }

    function test_assign_isTimelockOnlyInEveryPhase() public {
        vm.prank(teamOperator);
        vm.expectRevert(Saine.NotTimelock.selector);
        saine.assignSlot(0, makeAddr("op"), makeAddr("k"), bytes32("anthropic"));
    }

    function test_assign_revertsIfProviderDiversityWouldDrop() public {
        // The genesis board runs five providers, two slots each. Collapsing one provider's pair
        // leaves four, which is legal. Collapsing a second leaves three, which must revert.
        // §5.2: any assignment breaching an active constraint reverts, in every phase.
        bytes32 one = bytes32("anthropic");
        vm.startPrank(timelock);
        saine.assignSlot(4, makeAddr("o4"), makeAddr("k4"), one); // mistral -> anthropic
        saine.assignSlot(9, makeAddr("o9"), makeAddr("k9"), one); // mistral gone: four left
        assertEq(saine.distinctProviders(), 4, "exactly at the floor");

        saine.assignSlot(3, makeAddr("o3"), makeAddr("k3"), one); // one of the two meta slots
        vm.expectRevert(Saine.ProviderDiversityBreached.selector);
        saine.assignSlot(8, makeAddr("o8"), makeAddr("k8"), one); // meta gone: three left
        vm.stopPrank();
    }

    function test_assign_operatorCapIsInactiveInPhaseOne() public {
        assertFalse(saine.phaseTwo());
        // The team already holds all ten, which is only legal before the trigger.
        assertEq(saine.slotsHeld(teamOperator), 10);
    }

    function test_assign_operatorCapBitesAfterThePhaseTwoTrigger() public {
        clock.setSeason(9); // §15: end of season 8
        assertTrue(saine.phaseTwo());

        address op = makeAddr("independent");
        vm.startPrank(timelock);
        saine.assignSlot(0, op, makeAddr("k0"), bytes32("anthropic"));
        saine.assignSlot(1, op, makeAddr("k1"), bytes32("openai"));
        vm.expectRevert(Saine.OperatorCapBreached.selector);
        saine.assignSlot(2, op, makeAddr("k2"), bytes32("google"));
        vm.stopPrank();
    }

    function test_phaseTwo_alsoTriggersOnCumulativeDeployment() public {
        assertFalse(saine.phaseTwo());
        escrow.setDrawn(2_000e18);
        assertTrue(saine.phaseTwo(), "2,000 WETH cumulative deployed");
    }

    function test_assign_refundsTheOutgoingOperatorsBond() public {
        uint256 before = code.balanceOf(teamOperator);
        vm.prank(timelock);
        saine.assignSlot(0, makeAddr("op"), makeAddr("k"), bytes32("anthropic"));
        assertEq(code.balanceOf(teamOperator) - before, 50_000e18, "the bond does not travel with the seat");
        assertEq(saine.getSlot(0).bondCode, 0);
    }

    function test_rotateKey_isOperatorOnlyAndNeedsNoGovernance() public {
        address newKey = makeAddr("rotated");
        vm.prank(timelock);
        vm.expectRevert(Saine.NotOperator.selector);
        saine.rotateKey(0, newKey);

        vm.prank(teamOperator);
        saine.rotateKey(0, newKey);
        assertEq(saine.getSlot(0).key, newKey);
    }

    function test_rotateKey_doesNotInvalidateALiveRound() public {
        // Each round records the key it was committed under, so a mid-round rotation is harmless.
        uint256 id = _openOrigination();
        _commitMany(id, 10, 6);

        vm.prank(teamOperator);
        saine.rotateKey(0, makeAddr("rotated-mid-round"));

        vm.warp(block.timestamp + 24 hours + 1);
        _revealMany(id, 10, 6); // signed by the original keys, still valid
        assertEq(saine.getRound(id).reveals, 10);
    }

    // =================================================================
    // Commit-reveal mechanics (§5.4)
    // =================================================================

    function test_commit_rejectsASignatureFromTheWrongKey() public {
        uint256 id = _openOrigination();
        bytes32 c = _commitment(true, keccak256("r"), _salt(0));
        (Saine.CommitAttestation memory a, bytes memory sig) = _signCommit(id, 0, c, pk[1]); // slot 0, key 1
        Saine.CommitAttestation[] memory atts = new Saine.CommitAttestation[](1);
        bytes[] memory sigs = new bytes[](1);
        atts[0] = a;
        sigs[0] = sig;
        vm.expectRevert(Saine.BadSignature.selector);
        saine.submitCommits(atts, sigs);
    }

    function test_commit_isOncePerSlotPerRound() public {
        uint256 id = _openOrigination();
        _commitMany(id, 1, 1);
        (Saine.CommitAttestation[] memory atts, bytes[] memory sigs) = _buildCommits(id, 1, 1);
        vm.expectRevert(Saine.AlreadyCommitted.selector);
        saine.submitCommits(atts, sigs);
    }

    function test_commit_closesOnSchedule() public {
        uint256 id = _openOrigination();
        (Saine.CommitAttestation[] memory atts, bytes[] memory sigs) = _buildCommits(id, 1, 1);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.expectRevert(Saine.CommitWindowClosed.selector);
        saine.submitCommits(atts, sigs);
    }

    function test_reveal_cannotPrecedeTheCommitWindowClosing() public {
        uint256 id = _openOrigination();
        _commitMany(id, 10, 6);
        (Saine.RevealAttestation[] memory atts, bytes[] memory sigs) = _buildReveals(id, 1, 1);
        vm.expectRevert(Saine.CommitWindowOpen.selector);
        saine.submitReveals(atts, sigs);
    }

    function test_reveal_mustMatchTheCommitment() public {
        uint256 id = _openOrigination();
        _commitMany(id, 10, 6);
        vm.warp(block.timestamp + 24 hours + 1);

        // Same slot, same signature validity, wrong salt.
        (Saine.RevealAttestation memory a, bytes memory sig) =
            _signReveal(id, 0, true, keccak256("different salt"), pk[0]);
        Saine.RevealAttestation[] memory atts = new Saine.RevealAttestation[](1);
        bytes[] memory sigs = new bytes[](1);
        atts[0] = a;
        sigs[0] = sig;
        vm.expectRevert(Saine.CommitmentMismatch.selector);
        saine.submitReveals(atts, sigs);
    }

    function test_reveal_verdictCannotBeFlippedAfterCommitting() public {
        // The commitment binds verdict *and* reason together, so neither can be recomposed once the
        // tally is visible. Flipping the verdict breaks the hash.
        uint256 id = _openOrigination();
        _commitMany(id, 10, 6);
        vm.warp(block.timestamp + 24 hours + 1);

        (Saine.RevealAttestation memory a, bytes memory sig) = _signReveal(id, 0, false, _salt(0), pk[0]);
        Saine.RevealAttestation[] memory atts = new Saine.RevealAttestation[](1);
        bytes[] memory sigs = new bytes[](1);
        atts[0] = a;
        sigs[0] = sig;
        vm.expectRevert(Saine.CommitmentMismatch.selector);
        saine.submitReveals(atts, sigs);
    }

    function test_reveal_requiresACommitment() public {
        uint256 id = _openOrigination();
        _commitMany(id, 5, 5);
        vm.warp(block.timestamp + 24 hours + 1);

        (Saine.RevealAttestation memory a, bytes memory sig) = _signReveal(id, 9, true, _salt(9), pk[9]);
        Saine.RevealAttestation[] memory atts = new Saine.RevealAttestation[](1);
        bytes[] memory sigs = new bytes[](1);
        atts[0] = a;
        sigs[0] = sig;
        vm.expectRevert(Saine.NoCommitment.selector);
        saine.submitReveals(atts, sigs);
    }

    // =================================================================
    // The tally (§5.4)
    // =================================================================

    function test_tally_sixOfTenApproves() public {
        uint256 id = _runRound(10, 10, 6);
        assertEq(uint8(saine.getRound(id).state), uint8(Saine.RoundState.Approved));
        assertTrue(governor.lastApproved());
    }

    function test_tally_quorumReachedButThresholdMissedIsARejection() public {
        // §5.4: "a board that reaches quorum and does not clear it has not approved."
        uint256 id = _runRound(8, 8, 5);
        assertEq(uint8(saine.getRound(id).state), uint8(Saine.RoundState.Rejected));
        assertFalse(governor.lastApproved());
        assertFalse(governor.lastLapsed());
    }

    function test_tally_eightRevealsIsTheLivenessFloor() public {
        uint256 id = _runRound(8, 8, 6);
        assertEq(uint8(saine.getRound(id).state), uint8(Saine.RoundState.Approved));
    }

    function test_tally_sevenRevealsLapses() public {
        uint256 id = _runRound(7, 7, 7);
        assertEq(uint8(saine.getRound(id).state), uint8(Saine.RoundState.Lapsed));
        assertTrue(governor.lastLapsed(), "the consumer must be able to tell a lapse from a rejection");
        assertFalse(governor.lastApproved());
    }

    function test_lapse_slashesNobody() public {
        // §5.4: "A stalled or unreachable agent set freezes outcomes; it never punishes users."
        uint256 supplyBefore = code.totalSupply();
        uint256 id = _openOrigination();
        // Nobody commits at all, so there is no abandoned attestation to forfeit either.
        vm.warp(block.timestamp + 48 hours + 2);
        saine.settleRound(id);

        assertEq(uint8(saine.getRound(id).state), uint8(Saine.RoundState.Lapsed));
        assertEq(code.totalSupply(), supplyBefore, "no bond is touched");
        for (uint8 i; i < 10; ++i) {
            assertEq(saine.getSlot(i).bondCode, 50_000e18);
        }
    }

    function test_settle_earlyOnceEveryCommittedSlotHasRevealed() public {
        uint256 id = _openOrigination();
        _commitMany(id, 10, 6);
        vm.warp(block.timestamp + 24 hours + 1);
        _revealMany(id, 10, 6);
        // Still inside the reveal window, but there is nothing left to wait for.
        saine.settleRound(id);
        assertEq(uint8(saine.getRound(id).state), uint8(Saine.RoundState.Approved));
    }

    // =================================================================
    // Reveal forfeit (§15)
    // =================================================================

    function test_forfeit_committedThenSilentLosesAQuarterOfTheBond() public {
        uint256 supplyBefore = code.totalSupply();
        // Ten commit, eight reveal: slots 8 and 9 abandoned their attestations.
        uint256 id = _runRound(10, 8, 6);
        assertEq(uint8(saine.getRound(id).state), uint8(Saine.RoundState.Approved));

        assertEq(saine.getSlot(8).bondCode, 37_500e18, "25% forfeited");
        assertEq(saine.getSlot(9).bondCode, 37_500e18);
        assertEq(saine.getSlot(0).bondCode, 50_000e18, "revealers untouched");
        assertEq(supplyBefore - code.totalSupply(), 25_000e18, "and it is burned");
    }

    function test_forfeit_neverChargesASlotThatSimplyDidNotCommit() public {
        // The offence is abandoning an attestation mid-round, not declining to attest.
        _runRound(8, 8, 6);
        assertEq(saine.getSlot(9).bondCode, 50_000e18);
    }

    // =================================================================
    // Equivocation (§5.5)
    // =================================================================

    function test_equivocation_burnsTheBondAndVacatesTheSlotAtomically() public {
        uint256 id = _openOrigination();
        _commitMany(id, 10, 6);

        uint256 supplyBefore = code.totalSupply();
        (Saine.RevealAttestation memory a, bytes memory sigA) = _signReveal(id, 0, true, _salt(0), pk[0]);
        (Saine.RevealAttestation memory b, bytes memory sigB) = _signReveal(id, 0, false, _salt(0), pk[0]);

        // Anyone may report it, and no vote, judgment or appeal intervenes.
        vm.prank(makeAddr("anybody"));
        saine.reportEquivocation(a, sigA, b, sigB);

        Saine.Slot memory s = saine.getSlot(0);
        assertEq(s.operator, address(0), "vacated");
        assertEq(s.bondCode, 0);
        assertEq(supplyBefore - code.totalSupply(), 50_000e18, "the whole bond burns");
        assertEq(saine.slotsHeld(teamOperator), 9);
    }

    function test_equivocation_rejectsMatchingVerdicts() public {
        uint256 id = _openOrigination();
        _commitMany(id, 10, 6);
        (Saine.RevealAttestation memory a, bytes memory sigA) = _signReveal(id, 0, true, _salt(0), pk[0]);
        (Saine.RevealAttestation memory b, bytes memory sigB) = _signReveal(id, 0, true, keccak256("s2"), pk[0]);
        vm.expectRevert(Saine.NotEquivocation.selector);
        saine.reportEquivocation(a, sigA, b, sigB);
    }

    function test_equivocation_rejectsSignaturesFromAnotherSlotsKey() public {
        uint256 id = _openOrigination();
        _commitMany(id, 10, 6);
        (Saine.RevealAttestation memory a, bytes memory sigA) = _signReveal(id, 0, true, _salt(0), pk[0]);
        (Saine.RevealAttestation memory b, bytes memory sigB) = _signReveal(id, 0, false, _salt(0), pk[1]);
        vm.expectRevert(Saine.BadSignature.selector);
        saine.reportEquivocation(a, sigA, b, sigB);
    }

    // =================================================================
    // Bonds (§5.5)
    // =================================================================

    function test_bond_targetIsDenominatedInUsdNotCode() public view {
        // $1,000 at $0.02 per CODE.
        assertEq(saine.bondRequirement(), 50_000e18);
    }

    function test_bond_suspendsASlotThatFallsBelowTargetAtRevaluation() public {
        oracle.setPrice(0.01e18); // CODE halves, so the requirement doubles to 100,000
        saine.revalueBonds();
        assertTrue(saine.getSlot(0).suspended);
        assertEq(saine.liveSlots(), 0);
    }

    function test_bond_suspendedSlotCannotAttest() public {
        oracle.setPrice(0.01e18);
        saine.revalueBonds();
        uint256 id = _openOrigination();
        (Saine.CommitAttestation[] memory atts, bytes[] memory sigs) = _buildCommits(id, 1, 1);
        vm.expectRevert(Saine.SlotIsSuspended.selector);
        saine.submitCommits(atts, sigs);
    }

    function test_bond_topUpReinstatesImmediately() public {
        oracle.setPrice(0.01e18);
        saine.revalueBonds();
        vm.prank(teamOperator);
        saine.postBond(0, 50_000e18);
        assertFalse(saine.getSlot(0).suspended);
    }

    function test_bond_revaluationReinstatesWhenThePriceRecovers() public {
        oracle.setPrice(0.01e18);
        saine.revalueBonds();
        assertTrue(saine.getSlot(0).suspended);
        oracle.setPrice(0.02e18);
        saine.revalueBonds();
        assertFalse(saine.getSlot(0).suspended);
    }

    // =================================================================
    // Tracks
    // =================================================================

    function test_tracks_governorCannotOpenATrancheRound() public {
        vm.prank(address(governor));
        vm.expectRevert(Saine.NotEscrow.selector);
        saine.openRound(Saine.RoundKind.Tranche, 1);
    }

    function test_tracks_trancheApprovalReleasesThroughTheEscrow() public {
        uint256 id = escrow.openTrancheRound(saine, 7, 1);
        _commitMany(id, 10, 6);
        vm.warp(block.timestamp + 24 hours + 1);
        _revealMany(id, 10, 6);
        saine.settleRound(id);

        assertEq(escrow.releases(), 1);
        assertEq(escrow.releasedDeal(), 7);
        assertEq(escrow.releasedIndex(), 1);
        assertEq(governor.calls(), 0, "a tranche check reports to nobody else");
    }

    function test_tracks_trancheRejectionReleasesNothingAndSlashesNobody() public {
        uint256 id = escrow.openTrancheRound(saine, 7, 1);
        _commitMany(id, 10, 5);
        vm.warp(block.timestamp + 24 hours + 1);
        _revealMany(id, 10, 5);
        saine.settleRound(id);
        assertEq(escrow.releases(), 0);
    }

    function test_tracks_advisoryRoundsReportToTheGovernorLikeBindingOnes() public {
        // §5.6: advisory rounds "score the electorate in both directions", so the governor must hear
        // them; what differs is what the governor does with the verdict, not whether it arrives.
        vm.prank(address(governor));
        uint256 id = saine.openRound(Saine.RoundKind.Advisory, 99);
        _commitMany(id, 10, 6);
        vm.warp(block.timestamp + 24 hours + 1);
        _revealMany(id, 10, 6);
        saine.settleRound(id);
        assertEq(governor.lastSubject(), 99);
        assertTrue(governor.lastApproved());
    }

    function test_settle_cannotRunTwice() public {
        uint256 id = _runRound(10, 10, 6);
        vm.expectRevert(Saine.RoundNotOpen.selector);
        saine.settleRound(id);
    }
}
