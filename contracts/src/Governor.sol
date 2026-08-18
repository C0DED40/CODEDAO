// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IDCode} from "./interfaces/IDCode.sol";
import {ISaineConsumer, IOracle} from "./interfaces/ISaineConsumer.sol";
import {Escrow} from "./Escrow.sol";
import {Targets} from "./Targets.sol";

interface ICodeBurnable2 is IERC20 {
    function burn(uint256 amount) external;
}

interface ISaineOpen {
    function openRound(uint8 kind, uint256 subject) external returns (uint256);
}

interface ITreasuryCeiling {
    function perDealCeiling() external view returns (uint256);
}

/// @title Governor
/// @notice Proposal lifecycle across the three tracks (§6), and the penalty writes (§7).
///
/// @dev The governor is where the whitepaper's two filters are wired to each other, and the wiring
///      is asymmetric in both directions on purpose (§5.1):
///
///      - SAINE approval funds nothing the Many did not approve. A binding round only ever opens on
///        a proposal that already passed its vote, so there is no code path from an agent verdict to
///        the timelock that does not run through a `Succeeded` state first (invariant 8).
///      - A Many rejection is terminal. A defeated proposal still gets an agent round, because §5.6
///        needs it to score the electorate in both directions, but that round is advisory: it cannot
///        change the state, cannot queue anything, and cannot penalise the sponsor (invariants 7, 9).
///
///      Three tracks, three different relationships to the scoring machinery:
///
///      **Origination** (funding and parameter proposals) is serialised. Each occupies one scored
///      slot in the staking vault from the moment its vote opens until its verdict lands, which is
///      what makes the quorum arithmetic exact and what invariant 6 requires.
///
///      **Halt** runs in parallel and scores nobody (§7.1). It reads voting weight against a mask
///      snapshotted at its own opening, so it never touches a scored slot and never queues behind
///      one. §6.5: "A protective mechanism must never be chilled by the fear of being wrong about
///      needing it."
///
///      **Advisory** is what a defeated origination proposal gets. It reuses the same slot the
///      proposal already held, so a defeat costs the queue exactly what a success costs it: one
///      commit-and-reveal cycle. See the decisions log for why this is implemented as occupying the
///      slot rather than running fully in the background.
contract Governor is ISaineConsumer {
    using SafeERC20 for IERC20;

    // =====================================================================
    // Parameters (§15)
    // =====================================================================

    /// @notice §15: the voting period is five days.
    uint64 public constant VOTING_PERIOD = 5 days;

    /// @notice §15: quorum is 10% of seasonal effective voting power.
    uint256 public constant QUORUM_BPS = 1_000;

    /// @notice §15: $1,000 of liquid CODE, additional to stake.
    uint256 public constant PROPOSAL_BOND_USD = 1_000e18;

    /// @notice §15: two proposals per Guardian per season.
    uint8 public constant GUARDIAN_PROPOSAL_CAP = 2;

    /// @notice Originations per season. §15 says 12; see the decisions log for why this is 10.
    uint8 public constant ORIGINATION_CAP = 10;

    /// @notice §15: 30-day reproposal cooldown, material change required.
    uint64 public constant REPROPOSAL_COOLDOWN = 30 days;

    /// @dev Time an adjudication needs after the vote closes: commit window plus reveal window.
    uint64 public constant ADJUDICATION_WINDOW = 48 hours;

    uint256 internal constant BPS = 10_000;

    // =====================================================================
    // Wiring
    // =====================================================================

    ICodeBurnable2 public immutable code;
    IDCode public immutable dcode;
    TimelockController public immutable timelock;
    Escrow public immutable escrow;
    Targets public immutable targets;
    ISaineOpen public saine;
    IOracle public oracle;
    ITreasuryCeiling public treasury;
    address public configurer;

    // =====================================================================
    // Proposals
    // =====================================================================

    enum Kind {
        Funding,
        Parameter,
        Halt
    }

    enum State {
        None,
        Active,
        Defeated,
        Succeeded,
        Adjudicating,
        Approved,
        Rejected,
        Lapsed,
        Queued,
        Executed,
        Cancelled
    }

    struct Proposal {
        address proposer;
        Kind kind;
        State state;
        uint32 season;
        uint64 voteStart;
        uint64 voteEnd;
        /// @dev Scored slot in the staking vault. Origination track only.
        uint8 slot;
        bool hasSlot;
        /// @dev Verdict mask snapshotted at opening. Halt track only.
        uint128 haltMask;
        /// @dev Quorum denominator for this proposal, fixed at opening.
        uint256 denominator;
        uint256 yesWeight;
        uint256 noWeight;
        uint256 bond;
        bytes32 manifestHash;
        address investee;
        uint256 saineRound;
        bool targetsFlagged;
        /// @dev True once the vote passed, which is what makes a later agent round binding.
        bool passedVote;
    }

    struct Actions {
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
    }

    struct ProposalInput {
        Kind kind;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        bytes32 manifestHash;
        address manifestInvestee;
        /// @dev Must be set when any target is outside the registry (§6.2).
        bool flagUnknownTargets;
        string descriptionUri;
    }

    uint256 public proposalCount;
    mapping(uint256 id => Proposal) internal _proposals;
    mapping(uint256 id => Actions) internal _actions;
    mapping(uint256 id => mapping(address voter => bool)) public hasVotedOnHalt;

    /// @notice Proposals opened by each Guardian this season (§15's cap of two).
    mapping(uint32 season => mapping(address guardian => uint8)) public proposalsBy;

    /// @notice Funding proposals opened this season, against the origination cap.
    mapping(uint32 season => uint8) public originationsOpened;

    /// @notice The open origination proposal, or zero. One at a time (invariant 6).
    uint256 public liveOrigination;

    // --- rejection registry (§6.4) ---

    /// @notice When an investee's deal was last rejected, defeated or lapsed.
    mapping(address investee => uint64) public rejectedAt;

    /// @notice Manifests that may never be resubmitted byte-identically.
    mapping(bytes32 manifestHash => bool) public manifestBarred;

    /// @notice Saine round id back to proposal id.
    mapping(uint256 round => uint256 proposalId) public roundToProposal;

    // =====================================================================
    // Events
    // =====================================================================

    event ProposalCreated(
        uint256 indexed id,
        address indexed proposer,
        Kind kind,
        uint32 season,
        uint64 voteStart,
        uint64 voteEnd,
        bytes32 manifestHash,
        address investee,
        bool targetsFlagged,
        string descriptionUri
    );
    event VoteCast(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event VoteClosed(uint256 indexed id, State state, uint256 yesWeight, uint256 noWeight, uint256 denominator);
    event AdjudicationOpened(uint256 indexed id, uint256 round, bool binding);
    event Verdict(uint256 indexed id, State state, bool binding);
    event GuardianPenalised(uint256 indexed id, address indexed guardian, uint32 season);
    event BondReturned(uint256 indexed id, address indexed to, uint256 amount);
    event BondBurned(uint256 indexed id, uint256 amount);
    event RejectionRecorded(address indexed investee, bytes32 manifestHash, uint64 until);
    event Queued(uint256 indexed id, bytes32 operationId);
    event Executed(uint256 indexed id);

    // =====================================================================
    // Errors
    // =====================================================================

    error NotGuardian();
    error GuardianIsExcluded();
    error GuardianCapReached();
    error OriginationCapReached();
    error OriginationBusy();
    error NotConfigurer();
    error NotSaine();
    error NotProposer();
    error UnknownProposal();
    error WrongState();
    error VotingClosed();
    error VotingOpen();
    error NoWeight();
    error AlreadyVoted();
    error EmptyProposal();
    error FundingNeedsOneAction();
    error NotAFundingAction();
    error ParameterCannotFund();
    error ManifestMismatch();
    error AllocationOverCeiling();
    error UnknownTargetNotFlagged();
    error CooldownActive();
    error ManifestBarred();
    error WontFinishThisSeason();
    error LengthMismatch();
    error NoSeason();
    error ZeroAddress();

    // =====================================================================
    // Construction
    // =====================================================================

    constructor(
        ICodeBurnable2 code_,
        IDCode dcode_,
        TimelockController timelock_,
        Escrow escrow_,
        Targets targets_
    ) {
        code = code_;
        dcode = dcode_;
        timelock = timelock_;
        escrow = escrow_;
        targets = targets_;
        configurer = msg.sender;
    }

    function wire(ISaineOpen saine_, IOracle oracle_, ITreasuryCeiling treasury_) external {
        if (msg.sender != configurer) revert NotConfigurer();
        if (address(saine_) == address(0) || address(oracle_) == address(0)) revert ZeroAddress();
        saine = saine_;
        oracle = oracle_;
        treasury = treasury_;
        configurer = address(0);
    }

    // =====================================================================
    // Submission (§6.2)
    // =====================================================================

    /// @notice Open a proposal. Every condition in §6.2 is checked here, before the proposal exists.
    /// @dev The ordering of checks is not arbitrary. The manifest-calldata equality test comes before
    ///      anything is written, because invariant 4 is that "a proposal whose manifest investee
    ///      address differs from its calldata investee address cannot exist" — not that it can exist
    ///      and be rejected later. §6.1: "The wallet a voter reads and the wallet the treasury pays
    ///      are the same wallet, guaranteed at the only moment that matters: before the proposal
    ///      exists."
    function propose(ProposalInput calldata input) external returns (uint256 id) {
        // Maintain the average before anything reads it. Every price-dependent check below would
        // otherwise revert with a staleness error that tells the proposer nothing about their
        // proposal, and would let an unmaintained oracle masquerade as a rejected submission.
        oracle.poke();

        uint32 season = dcode.currentSeason();
        if (season == 0) revert NoSeason();
        if (!dcode.isGuardian(msg.sender, season)) revert NotGuardian();
        if (dcode.guardianExcluded(msg.sender, season)) revert GuardianIsExcluded();
        if (proposalsBy[season][msg.sender] >= GUARDIAN_PROPOSAL_CAP) revert GuardianCapReached();

        uint256 n = input.targets.length;
        if (n == 0) revert EmptyProposal();
        if (input.values.length != n || input.calldatas.length != n) revert LengthMismatch();

        _validateSchedule(season, input.kind);
        address investee = _validateShape(input);

        // Ordered so that the reason a proposal is refused is the most specific one available: a
        // barred manifest reports as barred rather than as an oversized allocation.
        if (input.kind == Kind.Funding) {
            if (manifestBarred[input.manifestHash]) revert ManifestBarred();
            uint64 last = rejectedAt[investee];
            if (last != 0 && block.timestamp < last + REPROPOSAL_COOLDOWN) revert CooldownActive();
            if (originationsOpened[season] >= ORIGINATION_CAP) revert OriginationCapReached();
            if (_allocationOf(input.calldatas[0]) > treasury.perDealCeiling()) revert AllocationOverCeiling();
        }

        _validateTargets(input);

        id = ++proposalCount;
        Proposal storage p = _proposals[id];
        p.proposer = msg.sender;
        p.kind = input.kind;
        p.state = State.Active;
        p.season = season;
        p.voteStart = uint64(block.timestamp);
        p.voteEnd = uint64(block.timestamp) + VOTING_PERIOD;
        p.manifestHash = input.manifestHash;
        p.investee = investee;
        p.targetsFlagged = input.flagUnknownTargets;

        _actions[id] = Actions(input.targets, input.values, input.calldatas);
        ++proposalsBy[season][msg.sender];
        if (input.kind == Kind.Funding) ++originationsOpened[season];

        // The origination track takes a scored slot; the halt track takes a mask snapshot.
        if (input.kind == Kind.Halt) {
            p.haltMask = dcode.currentSettledMask(season);
            p.denominator = dcode.manyEffectivePower(season);
        } else {
            if (liveOrigination != 0) revert OriginationBusy();
            p.slot = dcode.openScoredSlot(season);
            p.hasSlot = true;
            p.denominator = dcode.slotOpenPower(season, p.slot);
            liveOrigination = id;
        }

        p.bond = _takeBond(msg.sender);

        emit ProposalCreated(
            id,
            msg.sender,
            input.kind,
            season,
            p.voteStart,
            p.voteEnd,
            input.manifestHash,
            investee,
            input.flagUnknownTargets,
            input.descriptionUri
        );
    }

    /// @dev The funding/parameter mixing ban (§6.2), made mechanical.
    ///
    ///      "A proposal either funds an investee or changes protocol configuration, never both. This
    ///      single rule closes the bundling path by which governance changes ride into execution on
    ///      the back of attractive deals."
    ///
    ///      Enforced by shape rather than by inspecting intent: a funding proposal is exactly one
    ///      call to `escrow.registerDeal`, and a parameter proposal may make any calls except that
    ///      one and `escrow.halt`. There is no way to express "fund this and also change that".
    function _validateShape(ProposalInput calldata input) internal view returns (address investee) {
        bytes4 registerSel = Escrow.registerDeal.selector;
        bytes4 haltSel = Escrow.halt.selector;

        if (input.kind == Kind.Funding) {
            if (input.targets.length != 1) revert FundingNeedsOneAction();
            if (input.targets[0] != address(escrow)) revert NotAFundingAction();
            if (bytes4(input.calldatas[0]) != registerSel) revert NotAFundingAction();

            Escrow.DealTerms memory terms = _decodeTerms(input.calldatas[0]);
            // Invariant 4, checked before the proposal exists.
            if (terms.investee != input.manifestInvestee) revert ManifestMismatch();
            if (input.manifestHash == bytes32(0)) revert ManifestMismatch();
            return terms.investee;
        }

        if (input.kind == Kind.Halt) {
            if (input.targets.length != 1) revert FundingNeedsOneAction();
            if (input.targets[0] != address(escrow)) revert NotAFundingAction();
            if (bytes4(input.calldatas[0]) != haltSel) revert NotAFundingAction();
            return address(0);
        }

        for (uint256 i; i < input.targets.length; ++i) {
            if (input.targets[i] == address(escrow)) {
                bytes4 sel = bytes4(input.calldatas[i]);
                if (sel == registerSel || sel == haltSel) revert ParameterCannotFund();
            }
        }
        return address(0);
    }

    function _decodeTerms(bytes calldata data) internal pure returns (Escrow.DealTerms memory terms) {
        // Strip the selector and decode the single struct argument.
        terms = abi.decode(data[4:], (Escrow.DealTerms));
    }

    /// @dev §8.1's ceiling, checked at submission so voters never see a request the treasury could
    ///      not fund even if everyone approved it.
    function _allocationOf(bytes calldata data) internal pure returns (uint256) {
        return _decodeTerms(data).allocationWeth;
    }

    /// @dev §6.2: "Every target address is either in the known-target registry or explicitly flagged
    ///      for SAINE review." The flag is the proposer's declaration, and it is recorded on the
    ///      proposal so §5.3's adjudication package can annotate the calldata as unrecognised.
    function _validateTargets(ProposalInput calldata input) internal view {
        for (uint256 i; i < input.targets.length; ++i) {
            bytes4 sel = bytes4(input.calldatas[i]);
            if (!targets.isKnown(input.targets[i], sel)) {
                if (!input.flagUnknownTargets) revert UnknownTargetNotFlagged();
            }
        }
    }

    /// @dev §6.2: "The proposal can complete its full lifecycle, voting and adjudication, before the
    ///      season boundary. Proposals that cannot finish this season do not open this season."
    ///      A proposal that straddled the boundary would have its penalties reset before they were
    ///      ever applied, and its vintage weights frozen against a verdict that had not arrived.
    function _validateSchedule(uint32 season, Kind kind) internal view {
        uint64 seasonEnd = dcode.seasonEnd(season);
        uint64 needed = uint64(block.timestamp) + VOTING_PERIOD + ADJUDICATION_WINDOW;
        if (needed > seasonEnd) revert WontFinishThisSeason();
        kind; // applies to every track: a halt that cannot adjudicate in-season is no protection
    }

    /// @dev §6.2: the bond is "posted in liquid CODE, separate from and additional to the Guardian's
    ///      stake. Staked CODE is already immobilised for the season, so a bond carved from stake
    ///      would cost nothing and deter nothing; the bond prices queue occupancy only because it is
    ///      capital the Guardian could otherwise use."
    function _takeBond(address from) internal returns (uint256 amount) {
        oracle.poke();
        uint256 price = oracle.codeUsdPrice();
        amount = Math.mulDiv(PROPOSAL_BOND_USD, 1e18, price);
        IERC20(address(code)).safeTransferFrom(from, address(this), amount);
    }

    // =====================================================================
    // Voting (§4)
    // =====================================================================

    /// @notice Cast a ballot. The Many only; Guardians hold no vote (§4.1).
    /// @dev There is no abstain option, by the argument in the decisions log: an abstention that
    ///      avoided the 15% non-vote penalty would strictly dominate voting for every participant on
    ///      every proposal, so everyone would abstain and the scoring system would stop functioning.
    function castVote(uint256 id, bool support) external {
        Proposal storage p = _proposals[id];
        if (p.state != State.Active) revert WrongState();
        if (block.timestamp > p.voteEnd) revert VotingClosed();

        uint256 weight;
        if (p.kind == Kind.Halt) {
            if (hasVotedOnHalt[id][msg.sender]) revert AlreadyVoted();
            weight = dcode.ballotWeightForMask(msg.sender, p.season, p.haltMask);
            if (weight == 0) revert NoWeight();
            hasVotedOnHalt[id][msg.sender] = true;
        } else {
            weight = dcode.ballotWeight(msg.sender, p.season);
            if (weight == 0) revert NoWeight();
            // Reverts on a second ballot, and records the vote in the season's bitmaps so the
            // non-vote penalty can be derived from absence at settlement.
            dcode.recordBallot(msg.sender, p.season, p.slot, support);
        }

        if (support) p.yesWeight += weight;
        else p.noWeight += weight;

        emit VoteCast(id, msg.sender, support, weight);
    }

    /// @notice Close the vote and, on the origination track, open the agent round. Permissionless.
    function closeVote(uint256 id) external {
        Proposal storage p = _proposals[id];
        if (p.state != State.Active) revert WrongState();
        if (block.timestamp <= p.voteEnd) revert VotingOpen();

        uint256 participation = p.yesWeight + p.noWeight;
        uint256 quorum = (p.denominator * QUORUM_BPS) / BPS;
        bool passed = participation >= quorum && p.yesWeight > p.noWeight;

        p.state = passed ? State.Succeeded : State.Defeated;
        p.passedVote = passed;
        emit VoteClosed(id, p.state, p.yesWeight, p.noWeight, p.denominator);

        if (p.kind == Kind.Halt) {
            if (passed) {
                _openRound(id, p, true);
            } else {
                // A halt scores nobody in either direction, so a defeated halt simply ends.
                _returnBond(id, p);
            }
            return;
        }

        // Origination track. Both outcomes get an agent round: a success gets a binding one, and a
        // defeat gets the advisory round §5.6 needs to score the electorate in both directions.
        _openRound(id, p, passed);
    }

    function _openRound(uint256 id, Proposal storage p, bool binding) internal {
        // The registry's kinds are Origination, Tranche, Advisory. A halt round is opened as an
        // origination-kind round: the registry only needs to distinguish tranche rounds, which it
        // gates to the escrow, and the halt's freedom from slashing is enforced here, not there.
        uint8 kind = (p.kind == Kind.Halt || binding) ? 0 : 2;

        uint256 round = saine.openRound(kind, id);
        p.saineRound = round;
        p.state = State.Adjudicating;
        roundToProposal[round] = id;
        emit AdjudicationOpened(id, round, binding);
    }

    // =====================================================================
    // Verdicts (§5.4, §7)
    // =====================================================================

    /// @notice Receive an agent verdict. Called by the registry only.
    function onSaineVerdict(uint256 subject, bool approved, bool lapsed) external {
        if (msg.sender != address(saine)) revert NotSaine();
        uint256 id = subject;
        Proposal storage p = _proposals[id];
        if (p.state != State.Adjudicating) revert WrongState();

        bool binding = p.passedVote;

        if (p.kind == Kind.Halt) {
            // §6.5: halts "carry no slashing in either direction for anyone".
            p.state = approved ? State.Approved : (lapsed ? State.Lapsed : State.Rejected);
            emit Verdict(id, p.state, true);
            _returnBond(id, p);
            return;
        }

        if (lapsed) {
            // §5.4: "the round lapses for liveness. The proposal fails, and nobody is slashed."
            dcode.voidScoredSlot(p.season, p.slot);
            p.state = State.Lapsed;
            _clearQueue(id);
            _recordRejection(p);
            emit Verdict(id, p.state, binding);
            _returnBond(id, p);
            return;
        }

        // Scores the electorate against the verdict, binding or advisory alike (§7.1).
        dcode.settleScoredSlot(p.season, p.slot, approved, p.yesWeight, p.noWeight);

        if (!binding) {
            // §5.6: "the outcome is unaffected, the proposal stays dead, and the sponsoring Guardian
            // is not penalised." The verdict is published and scored, and changes nothing else.
            p.state = State.Defeated;
            _clearQueue(id);
            _recordRejection(p);
            emit Verdict(id, State.Defeated, false);
            _returnBond(id, p);
            return;
        }

        if (approved) {
            p.state = State.Approved;
        } else {
            p.state = State.Rejected;
            // §7.3: 50% for the season plus exclusion from proposing. Binding rejections only.
            dcode.slashGuardian(p.proposer, p.season);
            emit GuardianPenalised(id, p.proposer, p.season);
            _recordRejection(p);
        }

        _clearQueue(id);
        emit Verdict(id, p.state, true);
        _returnBond(id, p);
    }

    /// @dev §6.4's clock, in code: "every rejection writes the investee address, manifest hash, and
    ///      timestamp to a rejection registry, and `propose()` reverts on any investee address with
    ///      a rejection inside the cooldown, and permanently on a byte-identical manifest."
    function _recordRejection(Proposal storage p) internal {
        if (p.kind != Kind.Funding) return;
        rejectedAt[p.investee] = uint64(block.timestamp);
        manifestBarred[p.manifestHash] = true;
        emit RejectionRecorded(p.investee, p.manifestHash, uint64(block.timestamp) + REPROPOSAL_COOLDOWN);
    }

    function _clearQueue(uint256 id) internal {
        if (liveOrigination == id) liveOrigination = 0;
    }

    // =====================================================================
    // Execution
    // =====================================================================

    /// @notice Queue an approved proposal into the timelock.
    function queue(uint256 id) external returns (bytes32 operationId) {
        Proposal storage p = _proposals[id];
        if (p.state != State.Approved) revert WrongState();
        Actions storage a = _actions[id];

        p.state = State.Queued;
        timelock.scheduleBatch(
            a.targets, a.values, a.calldatas, bytes32(0), _descriptor(id), timelock.getMinDelay()
        );
        operationId = timelock.hashOperationBatch(a.targets, a.values, a.calldatas, bytes32(0), _descriptor(id));
        emit Queued(id, operationId);
    }

    /// @notice Execute a queued proposal once its delay has elapsed. Permissionless, like the
    ///         timelock's executor role (§14).
    function execute(uint256 id) external {
        Proposal storage p = _proposals[id];
        if (p.state != State.Queued) revert WrongState();
        Actions storage a = _actions[id];
        p.state = State.Executed;
        timelock.executeBatch(a.targets, a.values, a.calldatas, bytes32(0), _descriptor(id));
        emit Executed(id);
    }

    function _descriptor(uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("CODE-DAO-PROPOSAL", id));
    }

    // =====================================================================
    // Cancellation and bonds (§6.2)
    // =====================================================================

    /// @notice Withdraw a proposal before its vote closes. The bond burns.
    /// @dev §6.2: the bond is "burned if the proposer cancels". Cancelling frees the origination
    ///      queue, which is why it is priced: the queue is the scarce resource, and abandoning a slot
    ///      the DAO reserved should not be free.
    function cancel(uint256 id) external {
        Proposal storage p = _proposals[id];
        if (p.state != State.Active) revert WrongState();
        if (msg.sender != p.proposer) revert NotProposer();

        p.state = State.Cancelled;
        if (p.hasSlot) dcode.voidScoredSlot(p.season, p.slot);
        _clearQueue(id);

        uint256 bond = p.bond;
        p.bond = 0;
        if (bond != 0) {
            code.burn(bond);
            emit BondBurned(id, bond);
        }
    }

    /// @dev §6.2: the bond is "returned in full when the proposal completes adjudication whatever the
    ///      verdict". A bond forfeited on a rejection would price sponsoring a deal that turned out
    ///      to be wrong, which the 50% weight penalty already does, and would deter exactly the
    ///      borderline proposals the board exists to judge.
    function _returnBond(uint256 id, Proposal storage p) internal {
        uint256 bond = p.bond;
        if (bond == 0) return;
        p.bond = 0;
        IERC20(address(code)).safeTransfer(p.proposer, bond);
        emit BondReturned(id, p.proposer, bond);
    }

    // =====================================================================
    // Views
    // =====================================================================

    function getProposal(uint256 id) external view returns (Proposal memory) {
        return _proposals[id];
    }

    function getActions(uint256 id) external view returns (Actions memory) {
        return _actions[id];
    }

    function quorumFor(uint256 id) external view returns (uint256) {
        return (_proposals[id].denominator * QUORUM_BPS) / BPS;
    }

    function bondRequirement() external view returns (uint256) {
        return Math.mulDiv(PROPOSAL_BOND_USD, 1e18, oracle.codeUsdPrice());
    }
}
