// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {PenaltyMath} from "./libraries/PenaltyMath.sol";
import {IVintageVault} from "./interfaces/IVintageVault.sol";

/// @title dCODE
/// @notice Staking vault, seasons, the Guardian/Many split, delegation, and penalties (§3, §4, §7).
///
/// @dev The whole contract is organised around one constraint: nothing may require iterating the
///      electorate. Three mechanisms in the whitepaper look like they demand it, and each is
///      restructured here so it does not.
///
///      1. Snapshots (§3.2). Writing every staker's weight at rollover is impossible. Instead each
///         account carries a checkpoint trace keyed by season index, written lazily whenever that
///         account's stake changes. A season's snapshot is then a read: the value at the largest
///         key at or below the previous season. Deposits during season N are pushed at key N, so
///         they are invisible to season N and live from season N+1, which is exactly the rule
///         "deposits made mid-season earn nothing and decide nothing until the next boundary".
///
///      2. Penalties (§7.1). The non-vote penalty is the hard one: absence produces no
///         transaction, so there is nothing to hook. Rather than storing multipliers, each
///         account stores two bitmaps per season over that season's adjudicated proposals, and
///         the multiplier is derived on read by counting bits. Absence is the default state of a
///         bit, so silence costs no gas to record and is still priced.
///
///      3. Aggregate voting power for quorum (§4.2). Maintained exactly, not estimated. At each
///         verdict the losing side's weight and the absent weight are both known from the tally,
///         and because a penalty scales every affected account by the same factor, the sum of the
///         scaled weights equals the scaled sum. So the aggregate can be decremented in constant
///         time with no loss of precision.
///
///      Delegation is resolved without iteration by two rules. A Guardian's outbound delegation is
///      voided in a bounded loop over the fifty frozen seats at rollover. A delegation pointing at
///      an address that becomes a Guardian resolves back to the delegator at read time, so nobody
///      is silently disenfranchised (and charged the 15%) by their delegate winning a seat.
contract DCode {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace208;

    // =====================================================================
    // Constants
    // =====================================================================

    /// @notice §15: season length is thirteen weeks, measured in timestamps.
    uint64 public constant SEASON_LENGTH = 13 weeks;

    /// @notice §15: the fifty largest stakers hold the fifty Guardian seats.
    uint256 public constant GUARDIAN_SEATS = 50;

    /// @notice Upper bound on adjudicated origination proposals per season.
    /// @dev §15 sets the origination cap at 12. The bitmaps are 128 bits wide so governance can
    ///      raise the cap substantially without a storage migration; `MAX_SCORED_SLOTS` is the
    ///      hard ceiling the bitmap can represent.
    uint8 public constant MAX_SCORED_SLOTS = 128;

    // =====================================================================
    // Immutables and roles
    // =====================================================================

    /// @notice The CODE token.
    IERC20 public immutable code;

    /// @notice The governor, the only address permitted to write ballots and verdicts.
    address public governor;

    /// @notice The vintage vault, notified when frozen claim weight contracts.
    IVintageVault public vault;

    /// @notice Deployer wiring address, zeroed once the protocol is wired.
    address public configurer;

    /// @notice Addresses barred from staking entirely.
    /// @dev §2.4 and invariant 3: "Treasury holdings cannot be staked, hold no dCODE, count toward
    ///      no Guardian ranking, and are absent from every quorum denominator. The same exclusion
    ///      applies to the escrow, the vintage vault, and every other protocol contract."
    ///      Enforced at the only door in, because an exclusion that depends on the treasury simply
    ///      never calling stake() is a convention, not an invariant: any future proposal that
    ///      routed treasury CODE through this contract would silently hand the treasury 500M of
    ///      governance weight and a permanent lock on all fifty Guardian seats.
    mapping(address account => bool) public barredFromStaking;

    // =====================================================================
    // dCODE accounting (§3.1)
    // =====================================================================

    string public constant name = "Staked CODE";
    string public constant symbol = "dCODE";
    uint8 public constant decimals = 18;

    /// @notice dCODE balance, which is exactly the account's live staked CODE principal.
    mapping(address account => uint256) public balanceOf;

    /// @notice Total dCODE in existence, equal to total staked principal.
    uint256 public totalSupply;

    // =====================================================================
    // Seasons (§3.2)
    // =====================================================================

    struct Season {
        uint64 start;
        uint64 end;
        bool closed;
        /// @dev Total staked principal at the snapshot, across Guardians and the Many alike.
        ///      This is the vintage's pre-penalty weight base (§10.2).
        uint256 totalSnapshot;
        /// @dev Snapshot stake held by the Many only, before any penalty. Quorum denominator base.
        uint256 manyBase;
        /// @dev `manyBase` less every Many penalty applied so far this season. Quorum is a
        ///      percentage of this (§4.2), and it is exact rather than approximated.
        uint256 manyEffective;
        /// @dev `totalSnapshot` less every penalty, Many and Guardian. The vault's penalised base.
        uint256 totalEffective;
        /// @dev Count of adjudicated origination proposals scored so far this season.
        uint8 scoredCount;
        /// @dev Bit i set when scored proposal i's SAINE verdict was an approval.
        uint128 approvedMask;
        /// @dev Bit i set once scored proposal i has settled, so verdicts cannot be replayed.
        uint128 settledMask;
        /// @dev True while a scored slot is open and awaiting its verdict.
        bool slotOpen;
        /// @dev The slot currently open, meaningful only while `slotOpen`.
        uint8 openSlot;
    }

    /// @dev The settled-verdict mask as it stood when each slot opened.
    /// @dev Ballots on a slot are weighted by the penalties that had *already landed* when that
    ///      slot opened, not by whatever has landed since. §7.2 makes a penalty "voting power for
    ///      the remainder of the season", and freezing the multiplier at proposal open is what
    ///      makes that well defined: every ballot on one proposal is weighted on identical terms,
    ///      whenever in the window it was cast.
    mapping(uint32 season => mapping(uint8 slot => uint128)) public slotOpenMask;

    /// @dev Aggregate Many power as it stood when each slot opened, and so that slot's quorum
    ///      denominator and the base its absent weight is derived from.
    mapping(uint32 season => mapping(uint8 slot => uint256)) public slotOpenPower;

    /// @notice Season index. Season 0 is the bootstrap period: staking is open, governance is not.
    uint32 public currentSeason;

    mapping(uint32 season => Season) internal _seasons;

    /// @notice The frozen Guardian seats for a season, in leaderboard order.
    mapping(uint32 season => address[]) internal _guardians;

    /// @notice Membership test for the frozen Guardian set.
    mapping(uint32 season => mapping(address account => bool)) public isGuardianIn;

    /// @notice A Guardian excluded from proposing for the remainder of a season (§7.3).
    mapping(uint32 season => mapping(address guardian => bool)) public guardianExcludedIn;

    /// @notice Guardians slashed 50% for a rejected proposal, for the multiplier read (§7.3).
    mapping(uint32 season => mapping(address guardian => bool)) public guardianSlashedIn;

    /// @notice Delegated stake that must be subtracted from a delegate's ballot weight because it
    ///         was delegated to them by a Guardian, whose weight votes nothing (§4.1).
    mapping(uint32 season => mapping(address delegate => uint256)) public voidedGuardianInbound;

    // =====================================================================
    // Checkpointed traces
    // =====================================================================

    /// @dev Own staked principal by season. Guardian ranking reads this and nothing else (§4.1).
    mapping(address account => Checkpoints.Trace208) internal _principal;

    /// @dev Inbound delegated principal by season, including the account's own stake when it is
    ///      self-delegated. Ballot weight reads this.
    mapping(address account => Checkpoints.Trace208) internal _delegated;

    /// @dev Delegate address by season, stored as a uint160 widened to uint208.
    mapping(address account => Checkpoints.Trace208) internal _delegatee;

    /// @dev Total staked principal by season.
    Checkpoints.Trace208 internal _totalPrincipal;

    /// @dev Lowest principal observed *within* each season, written only when principal falls.
    /// @dev The principal trace alone cannot answer the monotone question in §10.3. Pushing at a
    ///      season key overwrites any earlier push at that key, so an account that exits to zero
    ///      and re-stakes inside the same quarter leaves a trace showing only the higher, later
    ///      figure: the dip vanishes and the forfeiture it was supposed to trigger vanishes with
    ///      it. This second trace records the floor of each season instead of its last value, so
    ///      "the lowest total stake held at any point since the vintage froze" survives a
    ///      round trip. A season with no entry never fell, which is why increases write nothing.
    mapping(address account => Checkpoints.Trace208) internal _lowWater;

    /// @notice First season in which an account held any stake, so callers know the vintage range.
    mapping(address account => uint32) public firstParticipationSeason;

    // =====================================================================
    // Delegation live state (§4.1)
    // =====================================================================

    /// @notice Live delegate of an account. An account delegates to itself until it says otherwise.
    mapping(address account => address) internal _liveDelegatee;

    /// @notice Live inbound delegated principal, own stake included when self-delegated.
    mapping(address account => uint256) public liveDelegated;

    /// @notice Live inbound principal delegated by other accounts. Used to forbid delegation chains.
    mapping(address account => uint256) public liveForeignInbound;

    // =====================================================================
    // Ballots (§7.1)
    // =====================================================================

    struct Record {
        /// @dev Bit i set when the account cast a ballot on scored proposal i.
        uint128 voted;
        /// @dev Bit i set when that ballot was in favour.
        uint128 support;
    }

    mapping(uint32 season => mapping(address voter => Record)) internal _record;

    // =====================================================================
    // Withdrawals (§3.1)
    // =====================================================================

    struct Withdrawal {
        uint256 amount;
        uint32 requestedSeason;
    }

    /// @notice Pending principal awaiting the season boundary before it can be collected.
    mapping(address account => Withdrawal) public pendingWithdrawal;

    /// @notice Total principal already deducted from stake but not yet collected.
    uint256 public totalPendingWithdrawal;

    // =====================================================================
    // Guardian leaderboard
    // =====================================================================

    /// @dev Live top-50 by own principal. Frozen into `_guardians` at each rollover, at which
    ///      instant live principal and the incoming season's snapshot coincide.
    address[] internal _board;

    /// @dev One-based index into `_board`, zero meaning absent.
    mapping(address account => uint256) internal _boardIndex;

    /// @dev Zero-based index of the current smallest member of `_board`.
    uint256 internal _boardMinIndex;

    // =====================================================================
    // Events
    // =====================================================================

    event Staked(address indexed account, uint256 amount);
    event WithdrawalRequested(address indexed account, uint256 amount, uint32 settlesAfterSeason);
    event WithdrawalCollected(address indexed account, uint256 amount);
    event DelegateChanged(address indexed delegator, address indexed from, address indexed to, uint32 effectiveSeason);
    event SeasonRolled(uint32 indexed season, uint64 start, uint64 end, uint256 totalSnapshot, uint256 manyBase);
    event BallotRecorded(uint32 indexed season, uint8 indexed slot, address indexed voter, bool support, uint256 weight);
    event SlotOpened(uint32 indexed season, uint8 indexed slot);
    event SlotVoided(uint32 indexed season, uint8 indexed slot);
    event SlotSettled(uint32 indexed season, uint8 indexed slot, bool approved, uint256 penaltyApplied);
    event GuardianSlashed(uint32 indexed season, address indexed guardian);
    event BoardChanged(address indexed inserted, address indexed evicted);

    // =====================================================================
    // Errors
    // =====================================================================

    error NotGovernor();
    error NotConfigurer();
    error NonTransferable();
    error ZeroAmount();
    error SeasonNotOver();
    error BoardNotFull();
    error GovernanceNotOpen();
    error WithdrawalPending();
    error NothingPending();
    error NotYetSettled();
    error InsufficientStake();
    error DelegationChainForbidden();
    error DelegateHasDelegated();
    error SlotLimitReached();
    error SlotAlreadySettled();
    error SlotStillOpen();
    error SlotNotOpen();
    error ProtocolAddress();
    error AlreadyVoted();
    error NotInMany();
    error VintageRangeIncomplete();
    error AlreadySlashed();

    // =====================================================================
    // Construction and wiring
    // =====================================================================

    constructor(IERC20 code_) {
        code = code_;
        configurer = msg.sender;
        _seasons[0].start = uint64(block.timestamp);
        // Season 0 never ends on a timer. It ends when `openFirstSeason` is called with a full
        // board, which prevents governance opening in a degenerate state where the Many is empty.
        _seasons[0].end = type(uint64).max;
    }

    function wire(address governor_, IVintageVault vault_, address[] calldata protocolContracts)
        external
    {
        if (msg.sender != configurer) revert NotConfigurer();
        governor = governor_;
        vault = vault_;
        for (uint256 i; i < protocolContracts.length; ++i) {
            barredFromStaking[protocolContracts[i]] = true;
        }
        barredFromStaking[address(this)] = true;
        configurer = address(0);
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    // =====================================================================
    // dCODE is not a transferable token (§3.1)
    // =====================================================================

    /// @dev "dCODE is non-transferable: any transfer that is not a mint or a burn reverts. The
    ///      token itself never moves between addresses; what a participant may move is voting
    ///      weight, through delegation." There is no approve, no allowance, and no transferFrom,
    ///      because a function that exists is a function that can be reached.
    function transfer(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    function approve(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    // =====================================================================
    // Staking
    // =====================================================================

    /// @notice Stake CODE and mint dCODE one-to-one.
    /// @dev Weight from this deposit begins at the next season boundary, never in the season it
    ///      was made. The trace push at the current season key is what enforces that.
    function stake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (barredFromStaking[msg.sender]) revert ProtocolAddress();
        code.safeTransferFrom(msg.sender, address(this), amount);

        if (balanceOf[msg.sender] == 0 && firstParticipationSeason[msg.sender] == 0) {
            // Recorded as the first season whose vintage this account can appear in.
            firstParticipationSeason[msg.sender] = currentSeason + 1;
        }

        balanceOf[msg.sender] += amount;
        totalSupply += amount;

        _afterPrincipalIncrease(msg.sender, amount);
        emit Staked(msg.sender, amount);
    }

    /// @notice Request principal back. Weight leaves immediately; the CODE leaves at the boundary.
    /// @param amount Principal to withdraw.
    /// @param vintages Every season in which this account still holds vintage claim weight,
    ///        ascending and complete. Exit settles what has accrued in each before the weight
    ///        base contracts (§10.3), and the caller pays for their own exit rather than
    ///        socialising it onto the next reader.
    ///
    /// @dev The weight reduction takes effect at once even though the tokens move at the boundary.
    ///      That is deliberate. The alternative, reducing weight only on collection, would let a
    ///      participant request an exit late in a season and still carry full claim weight into
    ///      the vintage freeze, which is precisely the forfeiture the whitepaper is closing.
    ///      Voting weight for the current season is untouched, because ballots read the snapshot
    ///      at the previous key, so nobody can dodge a season's penalties by requesting an exit.
    function requestWithdraw(uint256 amount, uint32[] calldata vintages) external {
        if (amount == 0) revert ZeroAmount();
        if (amount > balanceOf[msg.sender]) revert InsufficientStake();

        Withdrawal storage w = pendingWithdrawal[msg.sender];
        if (w.amount != 0 && w.requestedSeason != currentSeason) revert WithdrawalPending();

        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        w.amount += amount;
        w.requestedSeason = currentSeason;
        totalPendingWithdrawal += amount;

        _afterPrincipalDecrease(msg.sender, amount, vintages);
        emit WithdrawalRequested(msg.sender, amount, currentSeason);
    }

    /// @notice Collect principal whose season boundary has passed.
    function collectWithdrawal() external {
        Withdrawal storage w = pendingWithdrawal[msg.sender];
        uint256 amount = w.amount;
        if (amount == 0) revert NothingPending();
        if (currentSeason <= w.requestedSeason) revert NotYetSettled();

        delete pendingWithdrawal[msg.sender];
        totalPendingWithdrawal -= amount;
        code.safeTransfer(msg.sender, amount);
        emit WithdrawalCollected(msg.sender, amount);
    }

    // =====================================================================
    // Delegation (§4.1)
    // =====================================================================

    /// @notice Point this account's voting weight at another member of the Many.
    /// @dev Effective from the next season boundary, like every other weight change. Chains are
    ///      forbidden in both directions: an account holding inbound delegation cannot delegate
    ///      onward, and an account that has delegated away cannot receive. One hop, always, so
    ///      resolving a ballot never walks a list.
    function delegate(address to) external {
        if (to == address(0)) to = msg.sender;
        address from = _liveDelegatee[msg.sender];
        if (from == address(0)) from = msg.sender;
        if (from == to) return;

        if (msg.sender != to) {
            if (liveForeignInbound[msg.sender] != 0) revert DelegationChainForbidden();
            address theirDelegate = _liveDelegatee[to];
            if (theirDelegate != address(0) && theirDelegate != to) revert DelegateHasDelegated();
        }

        uint256 amount = balanceOf[msg.sender];
        _liveDelegatee[msg.sender] = to;
        _pushDelegatee(msg.sender, to);

        if (amount != 0) {
            _moveDelegated(from, to, amount, msg.sender);
        }
        emit DelegateChanged(msg.sender, from, to, currentSeason + 1);
    }

    // =====================================================================
    // Season rollover (§3.2)
    // =====================================================================

    /// @notice Open season 1. Permissionless, but only once the board can actually seat 50.
    /// @dev Guard against a degenerate launch: with 50 or fewer stakers everyone is a Guardian,
    ///      the Many is empty, and quorum is unreachable. Governance simply does not open until
    ///      there are enough participants for the split in §4.1 to mean anything.
    function openFirstSeason() external {
        if (currentSeason != 0) revert GovernanceNotOpen();
        if (_board.length < GUARDIAN_SEATS) revert BoardNotFull();
        _roll();
    }

    /// @notice Roll to the next season once the boundary timestamp has passed.
    /// @dev "Rollover is triggered by a permissionless function callable by anyone once the
    ///      boundary timestamp passes." Every penalty multiplier accrued during the season is
    ///      cleared simply by moving the season index: multipliers are derived from per-season
    ///      bitmaps, so a new season starts clean with no state to wipe.
    function rollover() external {
        if (currentSeason == 0) revert GovernanceNotOpen();
        if (block.timestamp < _seasons[currentSeason].end) revert SeasonNotOver();
        _seasons[currentSeason].closed = true;
        _roll();
    }

    function _roll() internal {
        uint32 next = currentSeason + 1;
        currentSeason = next;

        Season storage s = _seasons[next];
        s.start = uint64(block.timestamp);
        s.end = uint64(block.timestamp) + SEASON_LENGTH;

        // The snapshot: live principal at this instant is, by definition, the new season's
        // snapshot stake. Reads use `upperLookup(next - 1)`, which is why nothing is copied.
        uint256 total = totalSupply;
        s.totalSnapshot = total;
        s.totalEffective = total;

        // Freeze the seats and, in the same bounded pass over at most fifty entries, compute the
        // Many's base weight and void every Guardian's outbound delegation.
        uint256 n = _board.length;
        if (n > GUARDIAN_SEATS) n = GUARDIAN_SEATS;
        address[] storage seats = _guardians[next];
        uint256 guardianStake;
        for (uint256 i; i < n; ++i) {
            address g = _board[i];
            seats.push(g);
            isGuardianIn[next][g] = true;
            guardianStake += balanceOf[g];

            address d = _liveDelegatee[g];
            if (d != address(0) && d != g) {
                // A Guardian may not lend voting weight to anyone who can vote (§4.1). Their
                // stake is removed from the delegate's ballot weight for this season.
                voidedGuardianInbound[next][d] += balanceOf[g];
            }
        }

        uint256 manyBase = total - guardianStake;
        s.manyBase = manyBase;
        s.manyEffective = manyBase;

        emit SeasonRolled(next, s.start, s.end, total, manyBase);
    }

    // =====================================================================
    // Governor hooks
    // =====================================================================

    /// @notice Close an open slot without scoring anyone.
    /// @dev The lapse path. §5.4: "Fewer than eight reveals: the round lapses for liveness. The
    ///      proposal fails, and nobody is slashed." Deliberately does *not* set the settled bit,
    ///      because a set bit is what makes non-voters read as absent: recording the slot as settled
    ///      would price silence on a round that never produced a judgement. The slot number is
    ///      simply retired unused, and the queue moves on.
    function voidScoredSlot(uint32 season, uint8 slot) external onlyGovernor {
        Season storage s = _seasons[season];
        if (!s.slotOpen || s.openSlot != slot) revert SlotNotOpen();
        uint128 bit = uint128(1) << slot;
        if (s.settledMask & bit != 0) revert SlotAlreadySettled();
        s.slotOpen = false;
        emit SlotVoided(season, slot);
    }

    /// @notice Reserve the next scored slot for a proposal entering adjudication.
    /// @dev Scored slots are strictly serial: one open at a time, settled before the next opens.
    ///      Invariant 6 already requires this of origination, but §5.6 lets advisory rounds run on
    ///      a background track, and an advisory verdict settling in the middle of a binding
    ///      proposal's voting window would break the aggregate arithmetic. Ballots earlier in that
    ///      window would have been weighted on a different multiplier from ballots later in it, so
    ///      the two tallies would no longer be summable against one denominator and the derived
    ///      absent weight would be wrong. Serialising *settlement* costs advisory rounds nothing
    ///      they are promised: they still never block the binding queue, their verdicts are still
    ///      produced whenever the agents get to them, and only the moment their penalties land is
    ///      ordered. Every participant's weight then changes at discrete, publicly known instants.
    function openScoredSlot(uint32 season) external onlyGovernor returns (uint8 slot) {
        Season storage s = _seasons[season];
        if (s.slotOpen) revert SlotStillOpen();
        slot = s.scoredCount;
        if (slot >= MAX_SCORED_SLOTS) revert SlotLimitReached();
        s.scoredCount = slot + 1;
        s.slotOpen = true;
        s.openSlot = slot;
        slotOpenMask[season][slot] = s.settledMask;
        slotOpenPower[season][slot] = s.manyEffective;
        emit SlotOpened(season, slot);
    }

    /// @notice Record a ballot against a scored slot.
    /// @dev Weight is not stored per ballot. The governor supplies the weight it tallied, and the
    ///      only thing kept here is the bit, because the multiplier is a function of the bits.
    function recordBallot(address voter, uint32 season, uint8 slot, bool support)
        external
        onlyGovernor
    {
        if (isGuardianIn[season][voter]) revert NotInMany();
        Record storage r = _record[season][voter];
        uint128 bit = uint128(1) << slot;
        if (r.voted & bit != 0) revert AlreadyVoted();
        r.voted |= bit;
        if (support) r.support |= bit;
        emit BallotRecorded(season, slot, voter, support, ballotWeight(voter, season));
    }

    /// @notice Settle a scored slot's verdict and decrement aggregate power by the exact penalty.
    /// @param approved The SAINE verdict. Correct ballots are yes on an approval, no on a rejection.
    /// @param yesWeight Effective weight that voted in favour.
    /// @param noWeight Effective weight that voted against.
    ///
    /// @dev The aggregate decrement is exact, not an estimate. A penalty multiplies every affected
    ///      account's weight by the same factor, and scaling distributes over a sum, so reducing
    ///      the aggregate by 10% of the losing tally and 15% of the absent remainder yields
    ///      precisely the sum of the individually reduced weights. Absent weight is derived, not
    ///      measured: because adjudication is serialised (§6.3) no penalty lands mid-vote, so the
    ///      aggregate is constant across a voting window and absence is the aggregate less the
    ///      two tallies.
    function settleScoredSlot(uint32 season, uint8 slot, bool approved, uint256 yesWeight, uint256 noWeight)
        external
        onlyGovernor
    {
        Season storage s = _seasons[season];
        uint128 bit = uint128(1) << slot;
        if (s.settledMask & bit != 0) revert SlotAlreadySettled();
        if (!s.slotOpen || s.openSlot != slot) revert SlotNotOpen();
        s.slotOpen = false;
        s.settledMask |= bit;
        if (approved) s.approvedMask |= bit;

        uint256 wrongWeight = approved ? noWeight : yesWeight;
        uint256 participated = yesWeight + noWeight;
        // Derived against the aggregate as it stood when this slot opened, which is the same base
        // every ballot in the window was weighted on.
        uint256 effective = slotOpenPower[season][slot];
        uint256 absentWeight = effective > participated ? effective - participated : 0;

        uint256 reduction =
            (wrongWeight * (PenaltyMath.WAD - PenaltyMath.WRONG_VOTE_MULT)) / PenaltyMath.WAD
            + (absentWeight * (PenaltyMath.WAD - PenaltyMath.NON_VOTE_MULT)) / PenaltyMath.WAD;

        s.manyEffective = s.manyEffective - reduction;
        s.totalEffective -= reduction;
        emit SlotSettled(season, slot, approved, reduction);
    }

    /// @notice Apply the Guardian penalty for a proposal SAINE rejected (§7.3).
    /// @dev The seat is retained and no voting rights are gained. What changes is the multiplier
    ///      on this Guardian's own weight, which is what their vintage claim is computed from, and
    ///      the exclusion flag that bars further proposals for the rest of the season.
    function slashGuardian(address guardian, uint32 season) external onlyGovernor {
        if (guardianSlashedIn[season][guardian]) revert AlreadySlashed();
        guardianSlashedIn[season][guardian] = true;
        guardianExcludedIn[season][guardian] = true;

        uint256 stake_ = snapshotPrincipalOf(guardian, season);
        uint256 reduction = (stake_ * (PenaltyMath.WAD - PenaltyMath.GUARDIAN_MULT)) / PenaltyMath.WAD;
        Season storage s = _seasons[season];
        s.totalEffective -= reduction;
        emit GuardianSlashed(season, guardian);
    }

    // =====================================================================
    // Reads: seasons
    // =====================================================================

    function seasonStart(uint32 season) external view returns (uint64) {
        return _seasons[season].start;
    }

    function seasonEnd(uint32 season) external view returns (uint64) {
        return _seasons[season].end;
    }

    function isSeasonClosed(uint32 season) external view returns (bool) {
        return _seasons[season].closed;
    }

    function seasonData(uint32 season) external view returns (Season memory) {
        return _seasons[season];
    }

    function scoredCount(uint32 season) external view returns (uint8) {
        return _seasons[season].scoredCount;
    }

    // =====================================================================
    // Reads: electorate
    // =====================================================================

    function isGuardian(address account, uint32 season) external view returns (bool) {
        return isGuardianIn[season][account];
    }

    function guardianCount(uint32 season) external view returns (uint256) {
        return _guardians[season].length;
    }

    function guardians(uint32 season) external view returns (address[] memory) {
        return _guardians[season];
    }

    function guardianExcluded(address guardian, uint32 season) external view returns (bool) {
        return guardianExcludedIn[season][guardian];
    }

    /// @notice Snapshot own principal for a season: the value at the previous season's key.
    function snapshotPrincipalOf(address account, uint32 season) public view returns (uint256) {
        if (season == 0) return 0;
        return _principal[account].upperLookup(uint48(season - 1));
    }

    function snapshotTotalPrincipal(uint32 season) public view returns (uint256) {
        if (season == 0) return 0;
        return _totalPrincipal.upperLookup(uint48(season - 1));
    }

    /// @notice The delegate in force for an account during a season, before Guardian resolution.
    function snapshotDelegateeOf(address account, uint32 season) public view returns (address) {
        if (season == 0) return account;
        uint208 raw = _delegatee[account].upperLookup(uint48(season - 1));
        return raw == 0 ? account : address(uint160(raw));
    }

    /// @notice The delegate whose ballot actually carries this account's weight.
    /// @dev A delegation pointing at an address that took a Guardian seat resolves back to the
    ///      delegator. Without this, a member of the Many whose chosen delegate happened to win a
    ///      seat would be unable to vote through them and would be charged the 15% non-vote
    ///      penalty for a situation they did not cause and could not have foreseen.
    function resolvedDelegateeOf(address account, uint32 season) public view returns (address) {
        address d = snapshotDelegateeOf(account, season);
        if (d != account && isGuardianIn[season][d]) return account;
        return d;
    }

    /// @notice Weight a voter casts with, penalties included.
    function ballotWeight(address voter, uint32 season) public view returns (uint256) {
        if (isGuardianIn[season][voter]) return 0;

        uint256 base = _delegated[voter].upperLookup(uint48(season == 0 ? 0 : season - 1));
        uint256 voided = voidedGuardianInbound[season][voter];
        base = base > voided ? base - voided : 0;

        // Weight that reverted to this account because its delegate holds a seat.
        address declared = snapshotDelegateeOf(voter, season);
        if (declared != voter && isGuardianIn[season][declared]) {
            base += snapshotPrincipalOf(voter, season);
        }

        return PenaltyMath.applyMultiplier(base, manyMultiplierOf(voter, season));
    }

    /// @notice The penalty multiplier applied to a Many member's weight, in WAD.
    /// @dev Derived from the delegate's record, not the delegator's: "a delegator carries the full
    ///      consequences of the delegate's votes and absences, exactly as if they had cast every
    ///      ballot personally".
    function manyMultiplierOf(address account, uint32 season) public view returns (uint256) {
        Season storage s = _seasons[season];
        // While a slot is open, weight is what it was when that slot opened, so every ballot in
        // the window is weighted identically.
        uint128 mask = s.slotOpen ? slotOpenMask[season][s.openSlot] : s.settledMask;
        return _multiplierAgainst(account, season, mask);
    }

    /// @notice Ballot weight computed against an explicit verdict mask.
    /// @dev Used by the halt track. §7.1 says halt proposals "score nobody", so a halt neither reads
    ///      nor mutates a scored slot; it just needs a consistent set of multipliers across its own
    ///      voting window. The governor snapshots the mask when the halt opens and passes it back
    ///      here, which gives every ballot on that halt identical terms without occupying a slot the
    ///      origination queue needs.
    function ballotWeightForMask(address voter, uint32 season, uint128 mask)
        public
        view
        returns (uint256)
    {
        if (isGuardianIn[season][voter]) return 0;

        uint256 base = _delegated[voter].upperLookup(uint48(season == 0 ? 0 : season - 1));
        uint256 voided = voidedGuardianInbound[season][voter];
        base = base > voided ? base - voided : 0;

        address declared = snapshotDelegateeOf(voter, season);
        if (declared != voter && isGuardianIn[season][declared]) {
            base += snapshotPrincipalOf(voter, season);
        }

        return PenaltyMath.applyMultiplier(base, _multiplierAgainst(voter, season, mask));
    }

    /// @notice The verdict mask as it currently stands, for the halt track's snapshot.
    function currentSettledMask(uint32 season) external view returns (uint128) {
        return _seasons[season].settledMask;
    }

    /// @notice The multiplier as it stood when a particular slot opened.
    function multiplierAtSlot(address account, uint32 season, uint8 slot) public view returns (uint256) {
        return _multiplierAgainst(account, season, slotOpenMask[season][slot]);
    }

    function _multiplierAgainst(address account, uint32 season, uint128 scored)
        internal
        view
        returns (uint256)
    {
        // Only slots that have actually settled can score anyone; a slot mid-adjudication is not
        // yet a judgement and must not read as an absence.
        if (scored == 0) return PenaltyMath.WAD;

        address judge = resolvedDelegateeOf(account, season);
        Season storage s = _seasons[season];
        Record storage r = _record[season][judge];
        uint128 voted = r.voted & scored;
        uint128 wrongBits = voted & (r.support ^ s.approvedMask);
        uint128 absentBits = scored & ~voted;

        return PenaltyMath.manyMultiplier(PenaltyMath.popcount(wrongBits), PenaltyMath.popcount(absentBits));
    }

    /// @notice Seasonal effective voting power of the Many, the quorum denominator (§4.2).
    function manyEffectivePower(uint32 season) external view returns (uint256) {
        return _seasons[season].manyEffective;
    }

    // =====================================================================
    // Reads: vintages (§10)
    // =====================================================================

    function vintagePreSlashWeight(uint32 season) external view returns (uint256) {
        return _seasons[season].totalSnapshot;
    }

    function vintageEffectiveWeight(uint32 season) external view returns (uint256) {
        return _seasons[season].totalEffective;
    }

    /// @notice An account's claim weight in a vintage at the moment the season froze.
    /// @dev Guardians carry their own penalty, the Many carry theirs. Nothing is written at the
    ///      freeze: once a season is closed its bitmaps and masks are final, so this read returns
    ///      the same value forever.
    function frozenWeightOf(address account, uint32 season) public view returns (uint256) {
        uint256 base = snapshotPrincipalOf(account, season);
        if (base == 0) return 0;
        if (isGuardianIn[season][account]) {
            return guardianSlashedIn[season][account]
                ? PenaltyMath.applyMultiplier(base, PenaltyMath.GUARDIAN_MULT)
                : base;
        }
        return PenaltyMath.applyMultiplier(base, manyMultiplierOf(account, season));
    }

    /// @notice Claim weight in a vintage now, after the monotone cap in §10.3.
    /// @dev "A participant's live weight in every open vintage equals the lesser of that vintage's
    ///      frozen weight and the lowest total stake the participant has held at any point since
    ///      the vintage froze." The low is computed from the principal trace rather than stored
    ///      per vintage, which keeps deposits cheap and puts the cost on whoever reads.
    function liveVintageWeightOf(address account, uint32 season) public view returns (uint256) {
        uint256 frozen = frozenWeightOf(account, season);
        if (frozen == 0) return 0;
        uint256 low = _minPrincipalSince(account, season);
        return low < frozen ? low : frozen;
    }

    /// @dev Minimum principal held from the close of `season` to now.
    /// @dev Two sources, because neither is sufficient alone: the principal at the close of the
    ///      season, which is where the period starts, and the per-season floors recorded since,
    ///      which capture dips that the principal trace overwrites.
    function _minPrincipalSince(address account, uint32 season) internal view returns (uint256 low) {
        low = _principal[account].upperLookup(uint48(season));
        Checkpoints.Trace208 storage t = _lowWater[account];
        uint256 len = t.length();
        for (uint256 i = len; i > 0; --i) {
            Checkpoints.Checkpoint208 memory cp = t.at(uint32(i - 1));
            if (cp._key <= season) break;
            if (cp._value < low) low = cp._value;
        }
    }

    /// @dev Record this season's floor. Called only when principal falls.
    function _recordLow(address account) internal {
        Checkpoints.Trace208 storage t = _lowWater[account];
        uint208 bal = uint208(balanceOf[account]);
        (bool exists, uint48 key, uint208 val) = t.latestCheckpoint();
        if (exists && key == uint48(currentSeason)) {
            if (bal < val) t.push(uint48(currentSeason), bal);
        } else {
            t.push(uint48(currentSeason), bal);
        }
    }

    // =====================================================================
    // Internal: principal changes
    // =====================================================================

    function _delegateeOrSelf(address account) internal view returns (address d) {
        d = _liveDelegatee[account];
        if (d == address(0)) d = account;
    }

    function _afterPrincipalIncrease(address account, uint256 amount) internal {
        address d = _delegateeOrSelf(account);
        liveDelegated[d] += amount;
        if (d != account) liveForeignInbound[d] += amount;

        _pushPrincipal(account);
        _pushTotal();
        _pushDelegated(d);

        _boardConsider(account);
    }

    /// @dev The exact decrease is passed by the caller, which already computed and applied it to
    ///      `balanceOf`. Re-deriving it here from a stored mirror of the balance was the earlier
    ///      shape of this function and it was wrong: the mirror is refreshed by `_pushPrincipal`,
    ///      so by the time the delta was needed it had already been overwritten and every
    ///      reduction folded in as zero, silently leaving delegated aggregates overstated.
    function _afterPrincipalDecrease(address account, uint256 amount, uint32[] calldata vintages) internal {
        address d = _delegateeOrSelf(account);
        liveDelegated[d] -= amount;
        if (d != account) liveForeignInbound[d] -= amount;

        _pushPrincipal(account);
        _pushTotal();
        _pushDelegated(d);
        _recordLow(account);

        // Only after the traces reflect the reduction can the new vintage weights be read, and
        // the vault settles each against the weight it already holds on its books.
        _syncVintagesOnExit(account, vintages);

        if (_boardIndex[account] != 0) _boardRefreshMin();
    }

    /// @dev Vintages exist only for seasons that have frozen, so the range runs from the account's
    ///      first participation to the season before the current one. The caller supplies the list
    ///      in full and in order; a short or misordered list reverts rather than silently skipping
    ///      a vintage whose base would then never contract.
    function _syncVintagesOnExit(address account, uint32[] calldata vintages) internal {
        uint32 first = firstParticipationSeason[account];
        uint32 cur = currentSeason;
        if (first == 0 || cur == 0 || first > cur - 1) {
            if (vintages.length != 0) revert VintageRangeIncomplete();
            return;
        }
        uint32 last = cur - 1;
        uint256 expected = uint256(last) - uint256(first) + 1;
        if (vintages.length != expected) revert VintageRangeIncomplete();

        IVintageVault v = vault;
        for (uint256 i; i < expected; ++i) {
            uint32 season = uint32(uint256(first) + i);
            if (vintages[i] != season) revert VintageRangeIncomplete();
            if (address(v) != address(0)) {
                v.syncVintageWeight(account, season, liveVintageWeightOf(account, season));
            }
        }
    }

    function _moveDelegated(address from, address to, uint256 amount, address delegator) internal {
        liveDelegated[from] -= amount;
        if (from != delegator) liveForeignInbound[from] -= amount;
        liveDelegated[to] += amount;
        if (to != delegator) liveForeignInbound[to] += amount;
        _pushDelegated(from);
        _pushDelegated(to);
    }

    // =====================================================================
    // Internal: checkpoint pushes
    // =====================================================================

    function _pushPrincipal(address account) internal {
        _principal[account].push(uint48(currentSeason), uint208(balanceOf[account]));
    }

    function _pushTotal() internal {
        _totalPrincipal.push(uint48(currentSeason), uint208(totalSupply));
    }

    function _pushDelegated(address account) internal {
        _delegated[account].push(uint48(currentSeason), uint208(liveDelegated[account]));
    }

    function _pushDelegatee(address account, address to) internal {
        _delegatee[account].push(uint48(currentSeason), uint208(uint160(to)));
    }

    // =====================================================================
    // Internal: Guardian leaderboard
    // =====================================================================

    /// @dev Offer an account a seat on the live board. Ranking is on own principal alone, so
    ///      delegation neither wins nor loses a seat (§4.1).
    function _boardConsider(address account) internal {
        uint256 idx = _boardIndex[account];
        if (idx != 0) {
            // A seated member growing can only disturb the minimum if it *was* the minimum.
            // Otherwise the smallest seat is unchanged and the O(50) scan is pure waste.
            if (idx - 1 == _boardMinIndex) _boardRefreshMin();
            return;
        }
        if (_board.length < GUARDIAN_SEATS) {
            _board.push(account);
            uint256 newIdx = _board.length - 1;
            _boardIndex[account] = newIdx + 1;
            if (newIdx == 0 || balanceOf[account] < balanceOf[_board[_boardMinIndex]]) {
                _boardMinIndex = newIdx;
            }
            emit BoardChanged(account, address(0));
            return;
        }
        address weakest = _board[_boardMinIndex];
        // Strict comparison: a tie leaves the incumbent seated, which is a deterministic
        // tie-break that does not depend on address ordering.
        if (balanceOf[account] > balanceOf[weakest]) {
            _board[_boardMinIndex] = account;
            _boardIndex[account] = _boardMinIndex + 1;
            _boardIndex[weakest] = 0;
            _boardRefreshMin();
            emit BoardChanged(account, weakest);
        }
    }

    /// @notice Permissionlessly correct the board.
    /// @dev A withdrawal can leave a seated account smaller than an unseated one, and the board
    ///      does not track the wider field, so it cannot self-heal on the way down. Anyone may
    ///      present candidates. The incentive is bilateral, which is what makes this converge:
    ///      a large staker wrongly outside the set wants proposal rights, and a staker wrongly
    ///      inside it would rather have their vote back.
    function pokeBoard(address[] calldata candidates) external {
        for (uint256 i; i < candidates.length; ++i) {
            address c = candidates[i];
            if (c == address(0) || balanceOf[c] == 0) continue;
            _boardConsider(c);
        }
    }

    function _boardRefreshMin() internal {
        uint256 len = _board.length;
        if (len == 0) {
            _boardMinIndex = 0;
            return;
        }
        uint256 minIdx;
        uint256 minVal = balanceOf[_board[0]];
        for (uint256 i = 1; i < len; ++i) {
            uint256 v = balanceOf[_board[i]];
            if (v < minVal) {
                minVal = v;
                minIdx = i;
            }
        }
        _boardMinIndex = minIdx;
    }

    function board() external view returns (address[] memory) {
        return _board;
    }
}
