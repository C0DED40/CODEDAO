// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Code} from "../../src/Code.sol";
import {DCode} from "../../src/DCode.sol";
import {CodeTimelock} from "../../src/CodeTimelock.sol";
import {Treasury, ITreasuryOracle} from "../../src/Treasury.sol";
import {Targets} from "../../src/Targets.sol";
import {Oracle} from "../../src/Oracle.sol";
import {Escrow} from "../../src/Escrow.sol";
import {VintageVault, ICodeBurnable} from "../../src/VintageVault.sol";
import {Saine, ICodeBurn, ISeasonClock} from "../../src/Saine.sol";
import {Governor, ICodeBurnable2, ISaineOpen, ITreasuryCeiling} from "../../src/Governor.sol";

import {IDCode} from "../../src/interfaces/IDCode.sol";
import {IVintageVault} from "../../src/interfaces/IVintageVault.sol";
import {IOracle} from "../../src/interfaces/ISaineConsumer.sol";
import {IUniswapV2Pair, IUniswapV2Router02, IAggregatorV3} from "../../src/interfaces/IExternal.sol";
import {MockWeth, MockRouter, MockPair, MockFeed} from "../mocks/Mocks.sol";

/// @dev The whole protocol, wired as it would be on chain, exercised end to end.
///
///      The deployment itself is part of what this test proves. Several constructors take addresses
///      of contracts that do not exist yet (the token needs the treasury it pays tax to; the timelock
///      needs the governor that proposes to it), so the real deploy has to predict addresses rather
///      than wire after the fact. Doing it here the same way means a wiring mistake shows up as a
///      failing test rather than as a dead mainnet deployment.
contract LifecycleTest is Test {
    Code internal code;
    DCode internal dcode;
    CodeTimelock internal timelock;
    Treasury internal treasury;
    Targets internal targets;
    Oracle internal oracle;
    Escrow internal escrow;
    VintageVault internal vault;
    Saine internal saine;
    Governor internal governor;

    MockWeth internal weth;
    MockRouter internal router;
    MockPair internal pair;
    MockFeed internal feed;

    address internal genesis = makeAddr("genesis");
    address internal maintenance = makeAddr("maintenance");
    address internal receiver = makeAddr("receiver");
    address internal teamOperator = makeAddr("teamOperator");
    address internal relayer = makeAddr("relayer");
    address internal investee = makeAddr("investee");

    address[] internal whales;
    address[] internal many;

    uint256[10] internal pk;

    uint256 internal constant WHALE_STAKE = 1_000_000e18;
    uint256 internal constant MANY_STAKE = 10_000e18;
    uint256 internal constant MANY_COUNT = 8;
    uint256 internal constant TREASURY_CODE = 500_000_000e18;

    bytes32 internal constant COMMIT_TYPEHASH =
        keccak256("Commit(uint256 roundId,uint8 slot,bytes32 commitment,bytes32 modelHash)");
    bytes32 internal constant REVEAL_TYPEHASH =
        keccak256("Reveal(uint256 roundId,uint8 slot,bool verdict,bytes32 reasonHash,bytes32 salt)");

    function setUp() public {
        vm.warp(1_700_000_000);

        weth = new MockWeth();
        router = new MockRouter(weth);
        feed = new MockFeed();

        _deployProtocol();
        _wireProtocol();
        _primeOracle();
        _seatElectorate();
    }

    // -----------------------------------------------------------------
    // Deployment
    // -----------------------------------------------------------------

    /// @dev Predicted addresses, indexed in deployment order. Held in storage rather than as
    ///      locals because eleven of them plus the constructor arguments exceeds the stack.
    address[11] internal a;

    function _predict() internal {
        uint256 n = vm.getNonce(address(this));
        for (uint256 i; i < 11; ++i) {
            a[i] = vm.computeCreateAddress(address(this), n + i);
        }
    }

    function _deployProtocol() internal {
        _predict();
        code = new Code(genesis, a[3], maintenance);
        dcode = new DCode(IERC20(a[0]));
        timelock = new CodeTimelock(a[10]);
        treasury = new Treasury(IERC20(a[0]), IERC20(address(weth)), IUniswapV2Router02(address(router)), a[2]);
        targets = new Targets(a[2]);
        pair = new MockPair(a[0], address(weth));
        oracle = new Oracle(IUniswapV2Pair(a[5]), IAggregatorV3(address(feed)), a[0], address(weth), a[2]);
        escrow = new Escrow(a[2], treasury);
        vault = new VintageVault(ICodeBurnable(a[0]), IDCode(a[1]), a[3], a[2]);
        saine = new Saine(ICodeBurn(a[0]), a[2], ISeasonClock(a[1]));
        governor = new Governor(ICodeBurnable2(a[0]), IDCode(a[1]), timelock, escrow, targets);

        // If any prediction were wrong the system would be wired to empty addresses, so this is an
        // assertion about the deployment procedure itself rather than about the contracts.
        assertEq(address(code), a[0], "prediction must hold or nothing is wired");
        assertEq(address(dcode), a[1]);
        assertEq(address(timelock), a[2]);
        assertEq(address(treasury), a[3]);
        assertEq(address(pair), a[5]);
        assertEq(address(governor), a[10]);
    }

    function _wireProtocol() internal {
        address[] memory protocolContracts = new address[](5);
        protocolContracts[0] = address(treasury);
        protocolContracts[1] = address(escrow);
        protocolContracts[2] = address(vault);
        protocolContracts[3] = address(saine);
        protocolContracts[4] = address(governor);
        dcode.wire(address(governor), IVintageVault(address(vault)), protocolContracts);

        escrow.wire(address(saine), receiver);
        treasury.wire(address(escrow), ITreasuryOracle(address(oracle)));
        vault.wire(receiver);
        governor.wire(ISaineOpen(address(saine)), IOracle(address(oracle)), ITreasuryCeiling(address(treasury)));

        address[10] memory keys;
        bytes32[10] memory providers;
        bytes32[5] memory pool = [
            bytes32("anthropic"), bytes32("openai"), bytes32("google"), bytes32("meta"), bytes32("mistral")
        ];
        for (uint256 i; i < 10; ++i) {
            pk[i] = 0xA11CE + i;
            keys[i] = vm.addr(pk[i]);
            providers[i] = pool[i % 5];
        }
        saine.wire(address(governor), address(escrow), IOracle(address(oracle)), teamOperator, keys, providers);

        // The escrow's funding and halt entry points are known targets, so an ordinary deal needs no
        // review flag; anything else a proposal touches does.
        address[] memory t = new address[](2);
        bytes4[] memory sel = new bytes4[](2);
        t[0] = address(escrow);
        sel[0] = Escrow.registerDeal.selector;
        t[1] = address(escrow);
        sel[1] = Escrow.halt.selector;
        targets.seed(t, sel);

        address[] memory ex = new address[](8);
        ex[0] = genesis;
        ex[1] = address(dcode);
        ex[2] = address(treasury);
        ex[3] = address(escrow);
        ex[4] = address(vault);
        ex[5] = address(saine);
        ex[6] = address(governor);
        ex[7] = address(router);
        code.setExempt(ex);
        code.seal();

        vm.prank(genesis);
        code.transfer(address(treasury), TREASURY_CODE);
    }

    function _primeOracle() internal {
        // 1,000,000 CODE against 10 WETH: 1 CODE = 0.00001 WETH, so $0.03 at $3,000 ETH.
        pair.setReserves(1_000_000e18, 10e18);
        vm.warp(block.timestamp + 31 minutes);
        oracle.update();
    }

    function _seatElectorate() internal {
        for (uint256 i; i < 50; ++i) {
            address w = makeAddr(string.concat("whale", vm.toString(i)));
            whales.push(w);
            _fundAndStake(w, WHALE_STAKE + (50 - i) * 1e18);
        }
        for (uint256 i; i < MANY_COUNT; ++i) {
            address m = makeAddr(string.concat("many", vm.toString(i)));
            many.push(m);
            _fundAndStake(m, MANY_STAKE);
        }
        dcode.openFirstSeason();

        // Every Guardian needs liquid CODE for bonds, on top of stake.
        for (uint256 i; i < 5; ++i) {
            vm.prank(genesis);
            code.transfer(whales[i], 500_000e18);
            vm.prank(whales[i]);
            code.approve(address(governor), type(uint256).max);
        }

        // And the agent operator needs bonds posted, or every round lapses.
        vm.prank(genesis);
        code.transfer(teamOperator, 1_000_000e18);
        vm.startPrank(teamOperator);
        code.approve(address(saine), type(uint256).max);
        for (uint8 i; i < 10; ++i) {
            saine.postBond(i, 50_000e18);
        }
        vm.stopPrank();
    }

    function _fundAndStake(address who, uint256 amount) internal {
        vm.prank(genesis);
        code.transfer(who, amount);
        vm.startPrank(who);
        code.approve(address(dcode), amount);
        dcode.stake(amount);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Proposal helpers
    // -----------------------------------------------------------------

    function _terms(address who, uint128 alloc) internal view returns (Escrow.DealTerms memory t) {
        t.investee = who;
        t.vintage = dcode.currentSeason();
        t.allocationWeth = alloc;
        t.supplyBps = 500;
        t.vestingMonths = 24;
        t.manifestHash = keccak256("manifest-v1");
        t.milestones[0] = keccak256("audit");
        t.milestones[1] = keccak256("mainnet");
        t.windowEnds[0] = uint64(block.timestamp + 120 days);
        t.windowEnds[1] = uint64(block.timestamp + 300 days);
    }

    function _fundingInput(address proposerInvestee, uint128 alloc, bytes32 manifest)
        internal
        view
        returns (Governor.ProposalInput memory input)
    {
        Escrow.DealTerms memory t = _terms(proposerInvestee, alloc);
        input.kind = Governor.Kind.Funding;
        input.targets = new address[](1);
        input.values = new uint256[](1);
        input.calldatas = new bytes[](1);
        input.targets[0] = address(escrow);
        input.calldatas[0] = abi.encodeCall(Escrow.registerDeal, (t));
        input.manifestHash = manifest;
        input.manifestInvestee = proposerInvestee;
        input.descriptionUri = "ipfs://deal";
    }

    function _propose(address guardian, Governor.ProposalInput memory input) internal returns (uint256 id) {
        vm.prank(guardian);
        id = governor.propose(input);
    }

    function _voteYes(uint256 id, uint256 count) internal {
        for (uint256 i; i < count; ++i) {
            vm.prank(many[i]);
            governor.castVote(id, true);
        }
    }

    function _voteNo(uint256 id, uint256 count) internal {
        for (uint256 i; i < count; ++i) {
            vm.prank(many[i]);
            governor.castVote(id, false);
        }
    }

    // --- agent round helpers ---

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", saine.domainSeparator(), structHash));
    }

    function _salt(uint8 slot) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("salt", slot));
    }

    bytes32 internal constant REASON = keccak256("reason:tokenomics");

    function _sign(uint256 key, bytes32 structHash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, structHash);
        return abi.encodePacked(r, s, v);
    }

    function _commitAll(uint256 roundId, uint8 approvals) internal {
        Saine.CommitAttestation[] memory atts = new Saine.CommitAttestation[](10);
        bytes[] memory sigs = new bytes[](10);
        for (uint8 i; i < 10; ++i) {
            atts[i] = Saine.CommitAttestation(
                roundId, i, keccak256(abi.encode(i < approvals, REASON, _salt(i))), keccak256("model")
            );
            sigs[i] = _sign(
                pk[i],
                _digest(
                    keccak256(abi.encode(COMMIT_TYPEHASH, roundId, i, atts[i].commitment, atts[i].modelHash))
                )
            );
        }
        vm.prank(relayer);
        saine.submitCommits(atts, sigs);
    }

    function _revealSome(uint256 roundId, uint8 revealCount, uint8 approvals) internal {
        Saine.RevealAttestation[] memory atts = new Saine.RevealAttestation[](revealCount);
        bytes[] memory sigs = new bytes[](revealCount);
        for (uint8 i; i < revealCount; ++i) {
            atts[i] = Saine.RevealAttestation(roundId, i, i < approvals, REASON, _salt(i));
            sigs[i] = _sign(
                pk[i],
                _digest(
                    keccak256(abi.encode(REVEAL_TYPEHASH, roundId, i, i < approvals, REASON, _salt(i)))
                )
            );
        }
        vm.prank(relayer);
        saine.submitReveals(atts, sigs);
    }

    /// @dev Drive one full commit-reveal cycle and settle it.
    function _adjudicate(uint256 roundId, uint8 revealCount, uint8 approvals) internal {
        _commitAll(roundId, approvals);
        vm.warp(block.timestamp + 24 hours + 1);
        _revealSome(roundId, revealCount, approvals);
        vm.warp(block.timestamp + 24 hours + 1);
        saine.settleRound(roundId);
    }

    // =================================================================
    // The happy path, end to end
    // =================================================================

    function test_lifecycle_dealReachesTheInvesteesWallet() public {
        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        assertEq(uint8(governor.getProposal(id).state), uint8(Governor.State.Active));

        _voteYes(id, 2);
        vm.warp(block.timestamp + 5 days + 1);
        governor.closeVote(id);
        assertEq(uint8(governor.getProposal(id).state), uint8(Governor.State.Adjudicating));

        _adjudicate(governor.getProposal(id).saineRound, 10, 6);
        assertEq(uint8(governor.getProposal(id).state), uint8(Governor.State.Approved));

        governor.queue(id);
        vm.warp(block.timestamp + 24 hours + 1);
        governor.execute(id);
        assertEq(uint8(governor.getProposal(id).state), uint8(Governor.State.Executed));

        // The escrow now holds the deal, and tranche one is claimable (§6.3).
        assertEq(escrow.dealCount(), 1);
        assertEq(escrow.getDeal(1).investee, investee);
        assertEq(uint256(escrow.getTranche(1, 0).amountWeth), 8 ether, "40% of 20");

        vm.prank(investee);
        uint256 delivered = escrow.draw(1, 0);
        // Realised and nominal differ by oracle truncation, which is exactly the separation §8.2
        // asks for: the obligation is the round 8, what arrives is whatever the pool returned.
        assertApproxEqRel(delivered, 8 ether, 1e12, "capital reaches the founder as WETH");
        assertApproxEqRel(weth.balanceOf(investee), 8 ether, 1e12);
        assertEq(uint256(escrow.getDeal(1).drawnWeth), 8 ether, "and what is owed is the nominal figure");
    }

    function test_lifecycle_bondIsReturnedOnApproval() public {
        uint256 before = code.balanceOf(whales[0]);
        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        assertLt(code.balanceOf(whales[0]), before, "bond is held during the lifecycle");

        _voteYes(id, 2);
        vm.warp(block.timestamp + 5 days + 1);
        governor.closeVote(id);
        _adjudicate(governor.getProposal(id).saineRound, 10, 6);

        assertEq(code.balanceOf(whales[0]), before, "returned in full whatever the verdict");
    }

    // =================================================================
    // A Many rejection is terminal, and the advisory round still scores
    // =================================================================

    function test_defeat_isTerminalButStillScoresTheElectorate() public {
        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));

        // many[0] votes yes, many[1] votes no. The Many defeat it.
        vm.prank(many[0]);
        governor.castVote(id, true);
        vm.prank(many[1]);
        governor.castVote(id, false);
        vm.prank(many[2]);
        governor.castVote(id, false);

        vm.warp(block.timestamp + 5 days + 1);
        governor.closeVote(id);
        assertEq(uint8(governor.getProposal(id).state), uint8(Governor.State.Adjudicating), "advisory round runs");

        uint256 weightBefore = dcode.ballotWeight(many[0], 1);

        // The agents would have approved it. §5.6: the yes voters were right, the no voters wrong.
        _adjudicate(governor.getProposal(id).saineRound, 10, 6);

        assertEq(uint8(governor.getProposal(id).state), uint8(Governor.State.Defeated), "still dead");
        assertEq(escrow.dealCount(), 0, "invariant 8: no agent verdict funds what the Many refused");

        assertEq(dcode.ballotWeight(many[0], 1), weightBefore, "the yes voter was right and keeps full weight");
        assertLt(dcode.ballotWeight(many[1], 1), weightBefore, "the no voter was wrong and is penalised");
        assertLt(dcode.ballotWeight(many[3], 1), weightBefore, "and the absentee is penalised harder");
        assertLt(dcode.ballotWeight(many[3], 1), dcode.ballotWeight(many[1], 1));
    }

    function test_defeat_doesNotPenaliseTheSponsor() public {
        // §7.3: "A Guardian is never penalised for a proposal the Many defeated, nor for any
        // advisory outcome, nor for sponsoring a halt."
        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        _voteNo(id, 2);
        vm.warp(block.timestamp + 5 days + 1);
        governor.closeVote(id);
        _adjudicate(governor.getProposal(id).saineRound, 10, 2); // agents also reject

        assertFalse(dcode.guardianExcluded(whales[0], 1), "seat keeps its proposal rights");
        assertFalse(dcode.guardianSlashedIn(1, whales[0]), "and keeps its full vintage weight");
    }

    // =================================================================
    // A binding rejection penalises the sponsor (§7.3)
    // =================================================================

    function test_bindingRejection_slashesAndExcludesTheGuardian() public {
        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        _voteYes(id, 2);
        vm.warp(block.timestamp + 5 days + 1);
        governor.closeVote(id);

        // The Many approved; the board did not.
        _adjudicate(governor.getProposal(id).saineRound, 10, 5);

        assertEq(uint8(governor.getProposal(id).state), uint8(Governor.State.Rejected));
        assertTrue(dcode.guardianExcluded(whales[0], 1), "excluded from proposing for the season");
        assertEq(escrow.dealCount(), 0);

        // And the exclusion actually bites.
        Governor.ProposalInput memory next = _fundingInput(makeAddr("other"), 20 ether, keccak256("m2"));
        vm.prank(whales[0]);
        vm.expectRevert(Governor.GuardianIsExcluded.selector);
        governor.propose(next);
    }

    function test_bindingRejection_writesTheRejectionRegistry() public {
        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        _voteYes(id, 2);
        vm.warp(block.timestamp + 5 days + 1);
        governor.closeVote(id);
        _adjudicate(governor.getProposal(id).saineRound, 10, 5);

        // §6.4: the cooldown is code, and a byte-identical manifest is barred forever.
        Governor.ProposalInput memory same = _fundingInput(investee, 20 ether, keccak256("m1"));
        Governor.ProposalInput memory changed = _fundingInput(investee, 20 ether, keccak256("m2"));
        vm.prank(whales[1]);
        vm.expectRevert(Governor.ManifestBarred.selector);
        governor.propose(same);

        vm.prank(whales[1]);
        vm.expectRevert(Governor.CooldownActive.selector);
        governor.propose(changed);

        vm.warp(block.timestamp + 30 days + 1);
        uint256 id2 = _propose(whales[1], _fundingInput(investee, 20 ether, keccak256("m2")));
        assertEq(uint8(governor.getProposal(id2).state), uint8(Governor.State.Active), "the road back is a better proposal");
    }

    // =================================================================
    // Lapse (§5.4)
    // =================================================================

    function test_lapse_failsTheProposalAndSlashesNobody() public {
        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        _voteYes(id, 2);
        vm.warp(block.timestamp + 5 days + 1);
        governor.closeVote(id);

        uint256 weightBefore = dcode.ballotWeight(many[3], 1); // an absentee

        // Only seven reveal: below the liveness floor.
        _adjudicate(governor.getProposal(id).saineRound, 7, 7);

        assertEq(uint8(governor.getProposal(id).state), uint8(Governor.State.Lapsed));
        assertFalse(dcode.guardianExcluded(whales[0], 1), "the sponsor is untouched");
        assertEq(dcode.ballotWeight(many[3], 1), weightBefore, "and so is the absentee");
        assertEq(escrow.dealCount(), 0);
    }

    function test_lapse_freesTheQueue() public {
        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        _voteYes(id, 2);
        vm.warp(block.timestamp + 5 days + 1);
        governor.closeVote(id);
        _adjudicate(governor.getProposal(id).saineRound, 7, 7);

        assertEq(governor.liveOrigination(), 0);
        uint256 id2 = _propose(whales[1], _fundingInput(makeAddr("other"), 20 ether, keccak256("m2")));
        assertEq(uint8(governor.getProposal(id2).state), uint8(Governor.State.Active));
    }

    // =================================================================
    // Serialisation (invariant 6)
    // =================================================================

    function test_origination_isSerialised() public {
        _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        Governor.ProposalInput memory second = _fundingInput(makeAddr("other"), 20 ether, keccak256("m2"));
        vm.prank(whales[1]);
        vm.expectRevert(Governor.OriginationBusy.selector);
        governor.propose(second);
    }

    function test_origination_nextProposalOpensOnceTheVerdictLands() public {
        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        _voteYes(id, 2);
        vm.warp(block.timestamp + 5 days + 1);
        governor.closeVote(id);
        _adjudicate(governor.getProposal(id).saineRound, 10, 6);

        uint256 id2 = _propose(whales[1], _fundingInput(makeAddr("other"), 20 ether, keccak256("m2")));
        assertEq(uint8(governor.getProposal(id2).state), uint8(Governor.State.Active), "the slot frees at the verdict");
    }

    // =================================================================
    // The halt track (§6.5)
    // =================================================================

    function test_halt_runsInParallelWithAnOpenOrigination() public {
        // "Halts follow the normal path... but run on their own track, jump no queue and wait in
        // none." A protective mechanism must not be blocked by whatever else is being voted on.
        uint256 origination = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        assertEq(governor.liveOrigination(), origination);

        Governor.ProposalInput memory haltInput;
        haltInput.kind = Governor.Kind.Halt;
        haltInput.targets = new address[](1);
        haltInput.values = new uint256[](1);
        haltInput.calldatas = new bytes[](1);
        haltInput.targets[0] = address(escrow);
        haltInput.calldatas[0] = abi.encodeCall(Escrow.halt, (1));
        haltInput.descriptionUri = "ipfs://halt";

        uint256 haltId = _propose(whales[1], haltInput);
        assertEq(uint8(governor.getProposal(haltId).state), uint8(Governor.State.Active));
        assertFalse(governor.getProposal(haltId).hasSlot, "a halt occupies no scored slot");
        assertEq(governor.liveOrigination(), origination, "and does not disturb the queue");
    }

    function test_halt_scoresNobody() public {
        Governor.ProposalInput memory haltInput;
        haltInput.kind = Governor.Kind.Halt;
        haltInput.targets = new address[](1);
        haltInput.values = new uint256[](1);
        haltInput.calldatas = new bytes[](1);
        haltInput.targets[0] = address(escrow);
        haltInput.calldatas[0] = abi.encodeCall(Escrow.halt, (1));

        uint256 haltId = _propose(whales[0], haltInput);
        uint256 weightBefore = dcode.ballotWeight(many[3], 1);

        vm.prank(many[0]);
        governor.castVote(haltId, true);
        vm.prank(many[1]);
        governor.castVote(haltId, true);
        vm.prank(many[2]);
        governor.castVote(haltId, false);

        vm.warp(block.timestamp + 5 days + 1);
        governor.closeVote(haltId);
        _adjudicate(governor.getProposal(haltId).saineRound, 10, 6);

        assertEq(dcode.ballotWeight(many[2], 1), weightBefore, "the wrong-side halt voter is untouched");
        assertEq(dcode.ballotWeight(many[3], 1), weightBefore, "and so is the absentee");
        assertFalse(dcode.guardianExcluded(whales[0], 1), "and so is the sponsor");
    }

    // =================================================================
    // Submission rules (§6.2)
    // =================================================================

    function test_propose_isGuardianOnly() public {
        Governor.ProposalInput memory input = _fundingInput(investee, 20 ether, keccak256("m1"));
        vm.prank(many[0]);
        vm.expectRevert(Governor.NotGuardian.selector);
        governor.propose(input);
    }

    function test_propose_revertsWhenManifestAndCalldataDisagree() public {
        // Invariant 4: such a proposal "cannot exist", not "is rejected later".
        Governor.ProposalInput memory input = _fundingInput(investee, 20 ether, keccak256("m1"));
        input.manifestInvestee = makeAddr("a different wallet entirely");
        vm.prank(whales[0]);
        vm.expectRevert(Governor.ManifestMismatch.selector);
        governor.propose(input);
    }

    function test_propose_refusesToMixFundingWithParameters() public {
        // §6.2's single rule that "closes the bundling path by which governance changes ride into
        // execution on the back of attractive deals".
        Governor.ProposalInput memory input = _fundingInput(investee, 20 ether, keccak256("m1"));
        input.kind = Governor.Kind.Parameter;
        vm.prank(whales[0]);
        vm.expectRevert(Governor.ParameterCannotFund.selector);
        governor.propose(input);
    }

    function test_propose_fundingMustBeExactlyOneAction() public {
        Governor.ProposalInput memory input = _fundingInput(investee, 20 ether, keccak256("m1"));
        input.targets = new address[](2);
        input.values = new uint256[](2);
        input.calldatas = new bytes[](2);
        input.targets[0] = address(escrow);
        input.targets[1] = address(escrow);
        input.calldatas[0] = abi.encodeCall(Escrow.registerDeal, (_terms(investee, 20 ether)));
        input.calldatas[1] = abi.encodeCall(Escrow.registerDeal, (_terms(investee, 20 ether)));
        vm.prank(whales[0]);
        vm.expectRevert(Governor.FundingNeedsOneAction.selector);
        governor.propose(input);
    }

    function test_propose_unknownTargetMustBeFlagged() public {
        Governor.ProposalInput memory input;
        input.kind = Governor.Kind.Parameter;
        input.targets = new address[](1);
        input.values = new uint256[](1);
        input.calldatas = new bytes[](1);
        input.targets[0] = address(oracle);
        input.calldatas[0] = abi.encodeCall(Oracle.setWindows, (1 hours, 4 hours, 30 minutes));

        vm.prank(whales[0]);
        vm.expectRevert(Governor.UnknownTargetNotFlagged.selector);
        governor.propose(input);

        input.flagUnknownTargets = true;
        uint256 id = _propose(whales[0], input);
        assertTrue(governor.getProposal(id).targetsFlagged, "the flag travels to the agents");
    }

    function test_propose_refusesAnAllocationOverTheCeiling() public {
        uint256 ceiling = treasury.perDealCeiling();
        Governor.ProposalInput memory input = _fundingInput(investee, uint128(ceiling + 1), keccak256("m1"));
        vm.prank(whales[0]);
        vm.expectRevert(Governor.AllocationOverCeiling.selector);
        governor.propose(input);
    }

    function test_propose_capsGuardiansAtTwoPerSeason() public {
        for (uint256 i; i < 2; ++i) {
            uint256 id = _propose(whales[0], _fundingInput(makeAddr(string.concat("inv", vm.toString(i))), 20 ether, keccak256(abi.encode(i))));
            _voteYes(id, 2);
            vm.warp(block.timestamp + 5 days + 1);
            governor.closeVote(id);
            _adjudicate(governor.getProposal(id).saineRound, 10, 6);
        }
        Governor.ProposalInput memory third = _fundingInput(makeAddr("third"), 20 ether, keccak256("m3"));
        vm.prank(whales[0]);
        vm.expectRevert(Governor.GuardianCapReached.selector);
        governor.propose(third);
    }

    function test_propose_refusesWhatCannotFinishThisSeason() public {
        // §6.2: "Proposals that cannot finish this season do not open this season."
        vm.warp(dcode.seasonEnd(1) - 6 days);
        Governor.ProposalInput memory input = _fundingInput(investee, 20 ether, keccak256("m1"));
        vm.prank(whales[0]);
        vm.expectRevert(Governor.WontFinishThisSeason.selector);
        governor.propose(input);
    }

    function test_propose_bondIsPricedInUsd() public {
        // $1,000 at $0.03 per CODE.
        assertApproxEqRel(governor.bondRequirement(), 33_333e18, 1e15);
    }

    // =================================================================
    // Voting rules (§4)
    // =================================================================

    function test_vote_guardiansHoldNoBallot() public {
        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        vm.prank(whales[1]);
        vm.expectRevert(Governor.NoWeight.selector);
        governor.castVote(id, true);
    }

    function test_vote_isOncePerProposal() public {
        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        vm.prank(many[0]);
        governor.castVote(id, true);
        vm.prank(many[0]);
        vm.expectRevert(DCode.AlreadyVoted.selector);
        governor.castVote(id, true);
    }

    function test_vote_quorumIsTenPercentOfSeasonalEffectivePower() public {
        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        // Eight Many at 10,000 each: 80,000 of power, so quorum is 8,000.
        assertEq(governor.quorumFor(id), 8_000e18);
    }

    function test_vote_belowQuorumIsADefeatEvenIfUnanimous() public {
        // A tiny holder votes yes and nobody else turns up.
        address dust = makeAddr("dust");
        _fundAndStake(dust, 100e18);
        vm.warp(dcode.seasonEnd(1) + 1);
        dcode.rollover();

        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        vm.prank(dust);
        governor.castVote(id, true);
        vm.warp(block.timestamp + 5 days + 1);
        governor.closeVote(id);

        Governor.Proposal memory p = governor.getProposal(id);
        assertEq(p.yesWeight, 100e18);
        assertEq(uint8(p.state), uint8(Governor.State.Adjudicating), "an advisory round still runs");
        assertFalse(p.passedVote, "but the vote did not pass");
    }

    // =================================================================
    // Cancellation (§6.2)
    // =================================================================

    function test_cancel_burnsTheBondAndFreesTheQueue() public {
        uint256 supplyBefore = code.totalSupply();
        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        uint256 bond = governor.getProposal(id).bond;

        vm.prank(whales[0]);
        governor.cancel(id);

        assertEq(supplyBefore - code.totalSupply(), bond, "burned, not returned");
        assertEq(governor.liveOrigination(), 0);
    }

    function test_cancel_isProposerOnly() public {
        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        vm.prank(whales[1]);
        vm.expectRevert(Governor.NotProposer.selector);
        governor.cancel(id);
    }

    // =================================================================
    // Custody (§14)
    // =================================================================

    function test_custody_nothingButTheTimelockRegistersADeal() public {
        Escrow.DealTerms memory t = _terms(investee, 20 ether);
        vm.prank(address(governor));
        vm.expectRevert(Escrow.NotTimelock.selector);
        escrow.registerDeal(t);
    }

    function test_custody_onlyTheRegistryReportsAVerdict() public {
        uint256 id = _propose(whales[0], _fundingInput(investee, 20 ether, keccak256("m1")));
        _voteYes(id, 2);
        vm.warp(block.timestamp + 5 days + 1);
        governor.closeVote(id);

        vm.prank(whales[0]);
        vm.expectRevert(Governor.NotSaine.selector);
        governor.onSaineVerdict(id, true, false);
    }

    function test_custody_protocolContractsHoldNoGovernanceWeight() public {
        // Invariant 3, at the only door in.
        vm.prank(genesis);
        code.transfer(address(this), 1_000e18);
        code.approve(address(dcode), 1_000e18);
        vm.prank(address(treasury));
        vm.expectRevert(DCode.ProtocolAddress.selector);
        dcode.stake(1_000e18);
    }
}
