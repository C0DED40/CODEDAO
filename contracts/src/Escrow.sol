// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {ITreasury} from "./interfaces/ITreasury.sol";

interface ISaineRounds {
    function openTrancheRound(uint256 dealId, uint8 index, bytes32 milestone) external returns (uint256 roundId);
}

/// @title Escrow
/// @notice The obligation manager: tranches, milestones, draws, warrants and defaults (§8).
///
/// @dev This contract exists because of the whitepaper's second conviction, that "the great
///      unsolved problem of on-chain venture is not raising money but getting it back". Everything
///      here is shaped by one rule taken from §16.3's invariant 14: the investee never chooses.
///      Not which tranche unlocks, not when vesting starts, not whether an installment settles in
///      their token or against the floor. Each of those is either a consequence of time passing or
///      a decision belonging to SAINE or the timelock, and the investee's only two callable
///      functions are `draw` (take what is already unlocked) and `registerTge` (declare a token,
///      subject to challenge). An investee holding an election between two settlement paths would
///      hold a free option against the DAO and would exercise it every month; no such option is
///      reachable from any function here.
///
///      Two asymmetries in the money flow are worth stating, because they are easy to get
///      backwards. First, an allocation is a *commitment* against the treasury, not a transfer to
///      this contract: the escrow never custodies CODE or WETH, and a lapse is an accounting
///      release rather than a refund. There is no balance here to drain. Second, what an investee
///      owes is the nominal WETH figure priced at TWAP, while what they receive is the realised
///      swap output. §8.2 requires exactly this split, so that pool conditions at the moment of
///      drawing cannot move the size of the obligation in either direction.
contract Escrow {
    // =====================================================================
    // Parameters (§15)
    // =====================================================================

    /// @notice §8.3: every allocation is split 40 / 30 / 30.
    uint16 internal constant TRANCHE_0_BPS = 4_000;
    uint16 internal constant TRANCHE_1_BPS = 3_000;
    uint16 internal constant TRANCHE_2_BPS = 3_000;
    uint8 public constant TRANCHE_COUNT = 3;

    uint256 internal constant BPS = 10_000;

    /// @notice §15: six months to draw a tranche once it unlocks, then it lapses to the treasury.
    uint64 public constant CLAIM_EXPIRY = 182 days;

    /// @notice §15: a milestone window is set per manifest and may not exceed twelve months.
    uint64 public constant MAX_MILESTONE_WINDOW = 365 days;

    /// @notice §15: the long-stop is thirty-six months from first draw.
    uint64 public constant LONG_STOP = 1095 days;

    /// @notice §8.5: installments are monthly.
    uint64 public constant INSTALLMENT_PERIOD = 30 days;

    /// @notice §15: vesting is capped at twenty-four monthly installments.
    uint8 public constant MAX_VESTING_MONTHS = 24;

    /// @notice §15: the long-stop floor is 1.25x drawn value, WETH-denominated.
    uint256 public constant FLOOR_MULTIPLE_BPS = 12_500;

    /// @notice §8.6: default follows a missed installment by one further installment period.
    /// @dev Expressed as a count rather than a duration: an obligation is in default once two
    ///      installments are outstanding, which is precisely "a missed installment past its grace
    ///      period of one installment period".
    uint16 public constant DEFAULT_GRACE_INSTALLMENTS = 2;

    // =====================================================================
    // Roles
    // =====================================================================

    /// @notice The timelock. Registers allocations and halts deals; nothing else may (§14).
    address public immutable timelock;

    /// @notice The treasury, which holds the capital an allocation commits.
    ITreasury public immutable treasury;

    /// @notice The SAINE registry. Releases tranches (§8.4) and challenges TGE registrations.
    address public saine;

    /// @notice The home-chain repayment endpoint, the only source of installment credit (§9).
    address public receiver;

    /// @notice Deployer wiring address, zeroed once wired.
    address public configurer;

    // =====================================================================
    // Deals
    // =====================================================================

    enum DealState {
        None,
        Active,
        Halted
    }

    struct Tranche {
        /// @dev Nominal WETH size, fixed at registration.
        uint128 amountWeth;
        /// @dev Timestamp the tranche became claimable; zero while locked.
        uint64 unlockedAt;
        /// @dev Milestone deadline for tranches 1 and 2; zero for tranche 0.
        uint64 windowEnd;
        /// @dev Hash of the milestone specification from the manifest (§8.4).
        bytes32 milestone;
        bool drawn;
        bool cancelled;
    }

    struct Deal {
        address investee;
        /// @dev The season that approved the deal. Every return from it is credited here (§10.1).
        uint32 vintage;
        /// @dev Percentage of the investee's eventual total token supply, fixed at approval (§8.5).
        uint16 supplyBps;
        /// @dev Monthly installments, at most twenty-four.
        uint8 vestingMonths;
        /// @dev True when the investee already had a live token at approval, so vesting begins at
        ///      first draw rather than at a later registration (§8.5).
        bool liveToken;
        DealState state;
        uint64 registeredAt;
        uint64 firstDrawAt;
        /// @dev Set at first draw: thirty-six months out (§15).
        uint64 longStop;
        uint128 allocationWeth;
        /// @dev Nominal WETH drawn, priced at TWAP, never at realised swap output (§8.2).
        uint128 drawnWeth;
        bytes32 manifestHash;
    }

    /// @notice The obligation's token leg: the warrant, and the schedule it becomes (§8.5).
    struct Warrant {
        address token;
        uint256 totalSupply;
        uint64 registeredAt;
        uint64 challengeEnd;
        bool finalised;
        /// @dev `totalSupply * supplyBps / BPS`, fixed at finalisation.
        uint256 owedTokens;
        uint64 vestingStart;
    }

    /// @notice The repayment ledger and the two registries §8.6 and §13 rely on.
    struct Repayment {
        uint16 installmentsPaid;
        uint128 wethRepaid;
        bool defaulted;
        uint64 defaultedAt;
        /// @dev Non-zero once the long-stop floor has activated: a WETH obligation, payable now.
        uint128 floorWeth;
        /// @dev Installments settled against the floor because the token swap could not clear its
        ///      slippage bound. Recorded for the audit trail; the choice was never the investee's.
        uint16 floorInstallments;
    }

    uint256 public dealCount;

    /// @notice Cumulative nominal WETH drawn across every deal.
    /// @dev Read by the agent registry: §15's phase two trigger is "End of season 8, or 2,000 WETH
    ///      cumulative deployed". Deployed means drawn, not allocated, so a committed-but-unclaimed
    ///      tranche does not advance the protocol's phase.
    uint256 public totalDrawnWeth;

    mapping(uint256 dealId => Deal) internal _deals;
    mapping(uint256 dealId => Tranche[3]) internal _tranches;
    mapping(uint256 dealId => Warrant) internal _warrants;
    mapping(uint256 dealId => Repayment) internal _repayments;

    /// @notice Every deal an investee has held, which is the spine of both public registries.
    mapping(address investee => uint256[]) internal _dealsOf;

    /// @notice Count of an investee's deals currently flagged in default (§8.6).
    mapping(address investee => uint256) public defaultCount;

    // =====================================================================
    // Events
    // =====================================================================

    event DealRegistered(
        uint256 indexed dealId,
        address indexed investee,
        uint32 indexed vintage,
        uint128 allocationWeth,
        bytes32 manifestHash
    );
    event TrancheUnlocked(uint256 indexed dealId, uint8 index, uint64 claimDeadline);
    event TrancheRequested(uint256 indexed dealId, uint8 index, uint256 roundId);
    event Drawn(uint256 indexed dealId, uint8 index, uint128 nominalWeth, uint256 delivered);
    event TrancheLapsed(uint256 indexed dealId, uint8 index, uint128 returnedWeth, bytes32 reason);
    event DealHalted(uint256 indexed dealId, uint128 returnedWeth);
    event TgeRegistered(uint256 indexed dealId, address token, uint256 totalSupply, uint64 challengeEnd);
    event TgeChallenged(uint256 indexed dealId);
    event TgeFinalised(uint256 indexed dealId, address token, uint256 owedTokens, uint64 vestingStart);
    event InstallmentsRecorded(uint256 indexed dealId, uint16 count, uint256 wethValue, bool viaFloor);
    event Defaulted(uint256 indexed dealId, address indexed investee, uint16 outstanding);
    event DefaultCured(uint256 indexed dealId, address indexed investee);
    event LongStopFloorActivated(uint256 indexed dealId, uint128 floorWeth);

    // =====================================================================
    // Errors
    // =====================================================================

    error NotTimelock();
    error NotSaine();
    error NotReceiver();
    error NotInvestee();
    error NotConfigurer();
    error UnknownDeal();
    error DealNotActive();
    error BadTrancheIndex();
    error TrancheLocked();
    error TrancheAlreadyUnlocked();
    error TrancheAlreadyDrawn();
    error TrancheCancelled();
    error ClaimWindowExpired();
    error ClaimWindowOpen();
    error MilestoneWindowClosed();
    error MilestoneWindowOpen();
    error PredecessorLocked();
    error WindowTooLong();
    error WindowNotAscending();
    error NoDrawYet();
    error TokenAlreadyLive();
    error TgeAlreadyFinalised();
    error TgeNotRegistered();
    error ChallengeWindowOpen();
    error ChallengeWindowClosed();
    error LongStopNotReached();
    error FloorAlreadyActive();
    error VestingTooLong();
    error ZeroAddress();
    error ZeroAmount();
    error NotInDefault();
    error AmountTooLarge();

    // =====================================================================
    // Construction and wiring
    // =====================================================================

    constructor(address timelock_, ITreasury treasury_) {
        if (timelock_ == address(0) || address(treasury_) == address(0)) revert ZeroAddress();
        timelock = timelock_;
        treasury = treasury_;
        configurer = msg.sender;
    }

    function wire(address saine_, address receiver_) external {
        if (msg.sender != configurer) revert NotConfigurer();
        if (saine_ == address(0) || receiver_ == address(0)) revert ZeroAddress();
        saine = saine_;
        receiver = receiver_;
        configurer = address(0);
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert NotTimelock();
        _;
    }

    modifier onlySaine() {
        if (msg.sender != saine) revert NotSaine();
        _;
    }

    modifier onlyReceiver() {
        if (msg.sender != receiver) revert NotReceiver();
        _;
    }

    // =====================================================================
    // Registration (§6.3 "Executed -> allocation registered in escrow")
    // =====================================================================

    /// @notice Register an approved allocation. Callable only by the timelock (§14, invariant 18).
    /// @param milestones Hashes of the two milestone specifications from the manifest.
    /// @param windowEnds Absolute deadlines for those milestones, each at most twelve months
    ///        after the deadline before it.
    /// @dev Tranche one is claimable immediately, matching §6.3's "Executed -> allocation
    ///      registered in escrow; tranche one claimable". Tranches two and three unlock only on
    ///      SAINE's verification of their milestone.
    /// @dev Bundled because the eleven fields exceed the EVM's reachable stack depth as locals.
    struct DealTerms {
        address investee;
        uint32 vintage;
        uint128 allocationWeth;
        uint16 supplyBps;
        uint8 vestingMonths;
        bool liveToken;
        address liveTokenAddress;
        uint256 liveTokenSupply;
        bytes32 manifestHash;
        bytes32[2] milestones;
        uint64[2] windowEnds;
    }

    function registerDeal(DealTerms calldata terms) external onlyTimelock returns (uint256 dealId) {
        if (terms.investee == address(0)) revert ZeroAddress();
        if (terms.allocationWeth == 0) revert ZeroAmount();
        if (terms.vestingMonths == 0 || terms.vestingMonths > MAX_VESTING_MONTHS) revert VestingTooLong();

        uint64 nowTs = uint64(block.timestamp);
        if (terms.windowEnds[0] <= nowTs || terms.windowEnds[0] > nowTs + MAX_MILESTONE_WINDOW) {
            revert WindowTooLong();
        }
        if (terms.windowEnds[1] <= terms.windowEnds[0]) revert WindowNotAscending();
        if (terms.windowEnds[1] > terms.windowEnds[0] + MAX_MILESTONE_WINDOW) revert WindowTooLong();

        dealId = ++dealCount;
        _writeDeal(dealId, terms, nowTs);
        _writeTranches(dealId, terms, nowTs);

        if (terms.liveToken) {
            if (terms.liveTokenAddress == address(0)) revert ZeroAddress();
            Warrant storage w = _warrants[dealId];
            w.token = terms.liveTokenAddress;
            w.totalSupply = terms.liveTokenSupply;
            w.owedTokens = (terms.liveTokenSupply * terms.supplyBps) / BPS;
            w.finalised = true;
            // vestingStart is set at first draw, per §8.5.
        }

        _dealsOf[terms.investee].push(dealId);
        treasury.commit(terms.allocationWeth);

        emit DealRegistered(dealId, terms.investee, terms.vintage, terms.allocationWeth, terms.manifestHash);
        emit TrancheUnlocked(dealId, 0, nowTs + CLAIM_EXPIRY);
    }

    function _writeDeal(uint256 dealId, DealTerms calldata terms, uint64 nowTs) internal {
        Deal storage d = _deals[dealId];
        d.investee = terms.investee;
        d.vintage = terms.vintage;
        d.supplyBps = terms.supplyBps;
        d.vestingMonths = terms.vestingMonths;
        d.liveToken = terms.liveToken;
        d.state = DealState.Active;
        d.registeredAt = nowTs;
        d.allocationWeth = terms.allocationWeth;
        d.manifestHash = terms.manifestHash;
    }

    function _writeTranches(uint256 dealId, DealTerms calldata terms, uint64 nowTs) internal {
        // Rounding drops at most two wei into the final tranche, never out of the allocation.
        uint128 t0 = uint128((uint256(terms.allocationWeth) * TRANCHE_0_BPS) / BPS);
        uint128 t1 = uint128((uint256(terms.allocationWeth) * TRANCHE_1_BPS) / BPS);

        Tranche[3] storage ts = _tranches[dealId];
        ts[0].amountWeth = t0;
        ts[0].unlockedAt = nowTs;
        ts[1].amountWeth = t1;
        ts[1].milestone = terms.milestones[0];
        ts[1].windowEnd = terms.windowEnds[0];
        ts[2].amountWeth = terms.allocationWeth - t0 - t1;
        ts[2].milestone = terms.milestones[1];
        ts[2].windowEnd = terms.windowEnds[1];
    }

    // =====================================================================
    // Tranche release (§8.4)
    // =====================================================================

    /// @notice Unlock tranche two or three on SAINE's verification of its milestone.
    /// @dev "Tranche releases are verified by SAINE alone... No Many vote, no Guardian sponsor, no
    ///      slashing attached." The delegation is safe only because a milestone is mechanically
    ///      verifiable and was hashed at proposal time, so this function checks the hash exists and
    ///      the window is open, and holds no discretion the manifest did not give it.
    function releaseTranche(uint256 dealId, uint8 index) external onlySaine {
        Deal storage d = _requireActive(dealId);
        if (index == 0 || index >= TRANCHE_COUNT) revert BadTrancheIndex();

        Tranche[3] storage ts = _tranches[dealId];
        Tranche storage t = ts[index];
        if (t.cancelled) revert TrancheCancelled();
        if (t.unlockedAt != 0) revert TrancheAlreadyUnlocked();
        if (block.timestamp > t.windowEnd) revert MilestoneWindowClosed();
        // Milestones are sequential, matching the 40/30/30 ordering they gate.
        if (ts[index - 1].unlockedAt == 0) revert PredecessorLocked();

        t.unlockedAt = uint64(block.timestamp);
        d; // silence unused warning in optimised builds
        emit TrancheUnlocked(dealId, index, t.unlockedAt + CLAIM_EXPIRY);
    }

    /// @notice Ask SAINE to verify a milestone and unlock the tranche behind it.
    /// @dev Validation lives here rather than in the agent registry, because every condition is a
    ///      fact about the deal: the window is open, the predecessor cleared, the milestone hash was
    ///      fixed at proposal time. §8.4 allows unlimited retries inside the window ("a failed
    ///      request may be resubmitted at any time inside the window, once the milestone is actually
    ///      met"), so this does not consume anything and carries no penalty.
    function requestTranche(uint256 dealId, uint8 index) external returns (uint256 roundId) {
        Deal storage d = _requireActive(dealId);
        if (msg.sender != d.investee) revert NotInvestee();
        if (index == 0 || index >= TRANCHE_COUNT) revert BadTrancheIndex();

        Tranche[3] storage ts = _tranches[dealId];
        Tranche storage t = ts[index];
        if (t.cancelled) revert TrancheCancelled();
        if (t.unlockedAt != 0) revert TrancheAlreadyUnlocked();
        if (block.timestamp > t.windowEnd) revert MilestoneWindowClosed();
        if (ts[index - 1].unlockedAt == 0) revert PredecessorLocked();

        roundId = ISaineRounds(saine).openTrancheRound(dealId, index, t.milestone);
        emit TrancheRequested(dealId, index, roundId);
    }

    // =====================================================================
    // Drawdown (§8.2)
    // =====================================================================

    /// @notice Draw an unlocked tranche. The investee receives WETH; the obligation is nominal.
    /// @dev The gap between `nominalWeth` and `delivered` is the whole point of §8.2. What is owed
    ///      is priced at the time-weighted oracle, so neither pool conditions nor deliberate
    ///      manipulation at the moment of drawing can move the obligation. What is received is the
    ///      realised output of a swap that must clear its minimum-out bound or revert.
    function draw(uint256 dealId, uint8 index) external returns (uint256 delivered) {
        Deal storage d = _requireActive(dealId);
        if (msg.sender != d.investee) revert NotInvestee();
        if (index >= TRANCHE_COUNT) revert BadTrancheIndex();

        Tranche storage t = _tranches[dealId][index];
        if (t.cancelled) revert TrancheCancelled();
        if (t.unlockedAt == 0) revert TrancheLocked();
        if (t.drawn) revert TrancheAlreadyDrawn();
        if (block.timestamp > t.unlockedAt + CLAIM_EXPIRY) revert ClaimWindowExpired();

        t.drawn = true;
        d.drawnWeth += t.amountWeth;
        totalDrawnWeth += t.amountWeth;

        if (d.firstDrawAt == 0) {
            d.firstDrawAt = uint64(block.timestamp);
            d.longStop = uint64(block.timestamp) + LONG_STOP;
            // §8.5: "For teams with a live token, vesting begins at first draw."
            if (d.liveToken) _warrants[dealId].vestingStart = uint64(block.timestamp);
        }

        delivered = treasury.fundDraw(d.investee, t.amountWeth);
        emit Drawn(dealId, index, t.amountWeth, delivered);
    }

    // =====================================================================
    // Lapse and halt (§8.2, §8.4, §6.5)
    // =====================================================================

    /// @notice Return an unlocked-but-undrawn tranche to the treasury once its claim window ends.
    /// @dev §8.2: "Allocations left unclaimed past their claim window lapse back to the treasury."
    ///      Permissionless, because the capital should not wait on anyone's attention.
    function lapseUnclaimed(uint256 dealId, uint8 index) external {
        _requireActive(dealId);
        if (index >= TRANCHE_COUNT) revert BadTrancheIndex();

        Tranche storage t = _tranches[dealId][index];
        if (t.cancelled) revert TrancheCancelled();
        if (t.drawn) revert TrancheAlreadyDrawn();
        if (t.unlockedAt == 0) revert TrancheLocked();
        if (block.timestamp <= t.unlockedAt + CLAIM_EXPIRY) revert ClaimWindowOpen();

        t.cancelled = true;
        treasury.release(t.amountWeth);
        emit TrancheLapsed(dealId, index, t.amountWeth, "claim window");
    }

    /// @notice Cancel a tranche whose milestone window closed without verification, and everything
    ///         after it.
    /// @dev §8.4: "When the window expires, the remaining allocation lapses to the treasury, with
    ///      no retry loop and no penalty round. A team that recovers re-approaches through a fresh
    ///      proposal like anyone else."
    function lapseMilestone(uint256 dealId, uint8 index) external {
        _requireActive(dealId);
        if (index == 0 || index >= TRANCHE_COUNT) revert BadTrancheIndex();

        Tranche[3] storage ts = _tranches[dealId];
        Tranche storage t = ts[index];
        if (t.cancelled) revert TrancheCancelled();
        if (t.unlockedAt != 0) revert TrancheAlreadyUnlocked();
        if (block.timestamp <= t.windowEnd) revert MilestoneWindowOpen();

        uint128 returned;
        for (uint8 i = index; i < TRANCHE_COUNT; ++i) {
            Tranche storage later = ts[i];
            if (later.cancelled || later.drawn) continue;
            later.cancelled = true;
            returned += later.amountWeth;
            emit TrancheLapsed(dealId, i, later.amountWeth, "milestone window");
        }
        if (returned != 0) treasury.release(returned);
    }

    /// @notice Cancel every undrawn tranche on a passed halt proposal (§6.5).
    /// @dev "A passed halt returns all undrawn allocation to the treasury." Obligations already
    ///      created by earlier draws survive: a halt stops future funding, it does not forgive
    ///      what was taken.
    function halt(uint256 dealId) external onlyTimelock {
        Deal storage d = _requireActive(dealId);
        d.state = DealState.Halted;

        Tranche[3] storage ts = _tranches[dealId];
        uint128 returned;
        for (uint8 i; i < TRANCHE_COUNT; ++i) {
            Tranche storage t = ts[i];
            if (t.cancelled || t.drawn) continue;
            t.cancelled = true;
            returned += t.amountWeth;
        }
        if (returned != 0) treasury.release(returned);
        emit DealHalted(dealId, returned);
    }

    // =====================================================================
    // The warrant and its conversion (§8.5)
    // =====================================================================

    /// @notice Declare the token a warrant attaches to, opening a SAINE challenge window.
    /// @dev The investee is the only party who knows when they launch, so they register; the
    ///      agents hold a window to object before the declaration becomes the schedule. The risk
    ///      accepted here is stated plainly: the default outcome of agent inaction is that whatever
    ///      the investee declared stands, which is why the window is generous and why this event is
    ///      one the board should be reliably awake for.
    function registerTge(uint256 dealId, address token, uint256 totalSupply) external {
        Deal storage d = _deals[dealId];
        if (d.state == DealState.None) revert UnknownDeal();
        if (msg.sender != d.investee) revert NotInvestee();
        if (d.liveToken) revert TokenAlreadyLive();
        if (d.firstDrawAt == 0) revert NoDrawYet();
        if (token == address(0)) revert ZeroAddress();
        if (totalSupply == 0) revert ZeroAmount();

        Warrant storage w = _warrants[dealId];
        if (w.finalised) revert TgeAlreadyFinalised();

        w.token = token;
        w.totalSupply = totalSupply;
        w.registeredAt = uint64(block.timestamp);
        w.challengeEnd = uint64(block.timestamp) + tgeChallengeWindow;

        emit TgeRegistered(dealId, token, totalSupply, w.challengeEnd);
    }

    /// @notice Void a TGE registration the agents found misdescribed.
    /// @dev Voids rather than penalises: the investee re-registers with correct figures. A wrong
    ///      declaration is not by itself evidence of bad faith, and the remedy that matters for
    ///      bad faith is the default registry, not a bricked warrant.
    function challengeTge(uint256 dealId) external onlySaine {
        Warrant storage w = _warrants[dealId];
        if (w.token == address(0)) revert TgeNotRegistered();
        if (w.finalised) revert TgeAlreadyFinalised();
        if (block.timestamp > w.challengeEnd) revert ChallengeWindowClosed();

        w.token = address(0);
        w.totalSupply = 0;
        w.registeredAt = 0;
        w.challengeEnd = 0;

        emit TgeChallenged(dealId);
    }

    /// @notice Convert an unchallenged warrant into a vesting schedule.
    /// @dev Permissionless once the window closes. §8.5: the percentage "attaches to whatever token
    ///      the team eventually launches, whenever they launch it, before or after the long-stop".
    function finaliseTge(uint256 dealId) external {
        Deal storage d = _deals[dealId];
        if (d.state == DealState.None) revert UnknownDeal();
        Warrant storage w = _warrants[dealId];
        if (w.finalised) revert TgeAlreadyFinalised();
        if (w.token == address(0)) revert TgeNotRegistered();
        if (block.timestamp <= w.challengeEnd) revert ChallengeWindowOpen();

        w.owedTokens = (w.totalSupply * d.supplyBps) / BPS;
        w.vestingStart = uint64(block.timestamp);
        w.finalised = true;

        emit TgeFinalised(dealId, w.token, w.owedTokens, w.vestingStart);
    }

    /// @notice Activate the WETH floor when no token has been registered by the long-stop.
    /// @dev §8.5: "If no token has been registered by the long-stop of thirty-six months from first
    ///      draw, the floor activates: a WETH-denominated obligation, a fixed multiple of the drawn
    ///      amount, immediately payable." Note it is a multiple of *drawn*, not allocated: a team
    ///      that took one tranche owes against one tranche.
    function activateLongStopFloor(uint256 dealId) external {
        Deal storage d = _deals[dealId];
        if (d.state == DealState.None) revert UnknownDeal();
        if (d.firstDrawAt == 0) revert NoDrawYet();
        if (block.timestamp < d.longStop) revert LongStopNotReached();

        Warrant storage w = _warrants[dealId];
        if (w.finalised) revert TgeAlreadyFinalised();

        Repayment storage r = _repayments[dealId];
        if (r.floorWeth != 0) revert FloorAlreadyActive();

        uint256 floor = (uint256(d.drawnWeth) * FLOOR_MULTIPLE_BPS) / BPS;
        if (floor > type(uint128).max) revert AmountTooLarge();
        r.floorWeth = uint128(floor);
        emit LongStopFloorActivated(dealId, r.floorWeth);
    }

    // =====================================================================
    // Repayment and default (§8.6, §9)
    // =====================================================================

    /// @notice Credit installments discharged on a satellite chain.
    /// @dev Only the receiver may call, because §9 discharges the obligation at the satellite's
    ///      swap: "bridge risk beyond this point belongs to the DAO, which chose the architecture,
    ///      never to a founder who has already paid." `viaFloor` records which path the satellite's
    ///      slippage bound forced, and is audit information only. The investee cannot reach this
    ///      function, which is what makes invariant 14 structural rather than procedural.
    function recordInstallments(uint256 dealId, uint16 count, uint256 wethValue, bool viaFloor) external onlyReceiver {
        Deal storage d = _deals[dealId];
        if (d.state == DealState.None) revert UnknownDeal();
        if (count == 0) revert ZeroAmount();

        if (wethValue > type(uint128).max) revert AmountTooLarge();

        Repayment storage r = _repayments[dealId];
        r.installmentsPaid += count;
        r.wethRepaid += uint128(wethValue);
        if (viaFloor) r.floorInstallments += count;

        // A team that catches up is no longer in default; the registry records history through
        // events, but the live flag tracks the live state.
        if (r.defaulted && outstandingInstallments(dealId) < DEFAULT_GRACE_INSTALLMENTS) {
            r.defaulted = false;
            unchecked {
                --defaultCount[d.investee];
            }
            emit DefaultCured(dealId, d.investee);
        }

        emit InstallmentsRecorded(dealId, count, wethValue, viaFloor);
    }

    /// @notice Flag an obligation as defaulted. Permissionless.
    /// @dev §8.6: the remedy is "memory, public and permanent". Anyone may write that memory.
    function flagDefault(uint256 dealId) external {
        Deal storage d = _deals[dealId];
        if (d.state == DealState.None) revert UnknownDeal();
        Repayment storage r = _repayments[dealId];
        if (r.defaulted) revert NotInDefault();

        uint16 outstanding = outstandingInstallments(dealId);
        if (outstanding < DEFAULT_GRACE_INSTALLMENTS) revert NotInDefault();

        r.defaulted = true;
        r.defaultedAt = uint64(block.timestamp);
        ++defaultCount[d.investee];

        emit Defaulted(dealId, d.investee, outstanding);
    }

    // =====================================================================
    // Views: the schedule, the warrant registry, the default registry
    // =====================================================================

    /// @notice Installments due to date, capped at the vesting term.
    function installmentsDue(uint256 dealId) public view returns (uint16) {
        Warrant storage w = _warrants[dealId];
        if (!w.finalised || w.vestingStart == 0) return 0;
        if (block.timestamp <= w.vestingStart) return 0;
        uint256 elapsed = block.timestamp - w.vestingStart;
        uint256 due = elapsed / INSTALLMENT_PERIOD;
        uint8 cap = _deals[dealId].vestingMonths;
        return due > cap ? cap : uint16(due);
    }

    /// @notice Installments due but unpaid.
    function outstandingInstallments(uint256 dealId) public view returns (uint16) {
        uint16 due = installmentsDue(dealId);
        uint16 paid = _repayments[dealId].installmentsPaid;
        return due > paid ? due - paid : 0;
    }

    /// @notice Tokens owed per installment, once a warrant has become a schedule.
    function installmentTokens(uint256 dealId) external view returns (uint256) {
        Warrant storage w = _warrants[dealId];
        if (!w.finalised) return 0;
        return w.owedTokens / _deals[dealId].vestingMonths;
    }

    /// @notice §8.5's public registry of outstanding warrants, readable by "any future investor".
    /// @dev A warrant is outstanding while the deal has drawn capital and no token has yet been
    ///      finalised against it. It is perpetual: nothing here expires it, and passing the
    ///      long-stop adds the floor rather than removing the claim.
    function hasOutstandingWarrant(uint256 dealId) public view returns (bool) {
        Deal storage d = _deals[dealId];
        if (d.state == DealState.None || d.firstDrawAt == 0) return false;
        return !_warrants[dealId].finalised;
    }

    /// @notice Every deal an address has held, for both registries.
    function dealsOf(address investee) external view returns (uint256[] memory) {
        return _dealsOf[investee];
    }

    /// @notice §8.6's default registry, the query SAINE runs on every future proposal.
    function isDefaulted(address investee) external view returns (bool) {
        return defaultCount[investee] != 0;
    }

    function vintageOf(uint256 dealId) external view returns (uint32) {
        return _deals[dealId].vintage;
    }

    function milestoneHash(uint256 dealId, uint8 index) external view returns (bytes32) {
        return _tranches[dealId][index].milestone;
    }

    function getDeal(uint256 dealId) external view returns (Deal memory) {
        return _deals[dealId];
    }

    function getTranche(uint256 dealId, uint8 index) external view returns (Tranche memory) {
        return _tranches[dealId][index];
    }

    function getWarrant(uint256 dealId) external view returns (Warrant memory) {
        return _warrants[dealId];
    }

    function getRepayment(uint256 dealId) external view returns (Repayment memory) {
        return _repayments[dealId];
    }

    /// @notice Undrawn, uncancelled allocation still committed to a deal.
    function undrawnWeth(uint256 dealId) external view returns (uint128 total) {
        Tranche[3] storage ts = _tranches[dealId];
        for (uint8 i; i < TRANCHE_COUNT; ++i) {
            if (!ts[i].drawn && !ts[i].cancelled) total += ts[i].amountWeth;
        }
    }

    // =====================================================================
    // Governance parameter (§1.8 of the decisions log)
    // =====================================================================

    /// @notice How long SAINE has to challenge a TGE registration.
    uint64 public tgeChallengeWindow = 7 days;

    error WindowOutOfRange();

    /// @notice Retune the challenge window through governance (§14: timelock only).
    function setTgeChallengeWindow(uint64 window) external onlyTimelock {
        if (window < 2 days || window > 30 days) revert WindowOutOfRange();
        tgeChallengeWindow = window;
    }

    // =====================================================================
    // Internals
    // =====================================================================

    function _requireActive(uint256 dealId) internal view returns (Deal storage d) {
        d = _deals[dealId];
        if (d.state == DealState.None) revert UnknownDeal();
        if (d.state != DealState.Active) revert DealNotActive();
    }
}
