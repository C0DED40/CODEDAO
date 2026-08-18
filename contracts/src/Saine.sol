// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ISaineConsumer, IOracle} from "./interfaces/ISaineConsumer.sol";

interface ICodeBurn is IERC20 {
    function burn(uint256 amount) external;
}

interface IEscrowRelease {
    function releaseTranche(uint256 dealId, uint8 index) external;
}

interface IDrawTotal {
    function totalDrawnWeth() external view returns (uint256);
}

interface ISeasonClock {
    function currentSeason() external view returns (uint32);
}

/// @title SAINE
/// @notice Smart AI Negates Exploits: the ten-agent board that reads the code before money moves (§5).
///
/// @dev The contract's job is narrow and its refusals matter more than its permissions. It decides
///      nothing about any deal. It counts blind commitments, checks that the reveals match them,
///      applies §5.4's thresholds, and reports one of three outcomes to whoever opened the round.
///      Every judgement is the agents'; every consequence is the consumer's.
///
///      Four design points are worth stating because each closes something that would otherwise be
///      exploitable.
///
///      **The reason hash sits inside the commitment.** §5.4 requires it, and the reason is precise:
///      if an agent could compose its justification after seeing the tally, the published reasons
///      would be post-hoc rationalisation and the capture-detection argument in §5.5 would collapse.
///      Binding verdict and reason at the same instant is what makes the record evidence.
///
///      **Attestations are signed, not transacted.** Operators sign EIP-712 payloads and anyone
///      relays them. This is not only an operational convenience. §5.5's equivocation slashing needs
///      *two validly signed attestations* to exist as objects; with direct transactions the second
///      one is simply rejected by the contract and there is nothing to produce as evidence, so the
///      clause would be unenforceable by construction.
///
///      **Signatures are checked against the key the slot used for that round**, recorded at first
///      commit, not against whatever key the slot holds today. Operators rotate keys freely (§5.2),
///      and verifying against the current key would either void a rotating operator's live round or
///      make a long-retired key permanently slashable.
///
///      **A lapse is not a rejection.** Fewer than eight reveals fails the round and slashes nobody.
///      Anything else would let an operator set that goes dark impose penalties on the electorate,
///      which is exactly the failure §5.4 forbids.
contract Saine is EIP712 {
    using SafeERC20 for IERC20;

    // =====================================================================
    // Parameters (§15)
    // =====================================================================

    uint8 public constant SLOTS = 10;
    uint8 public constant APPROVAL_THRESHOLD = 6;
    uint8 public constant LIVENESS_FLOOR = 8;
    uint8 public constant MIN_PROVIDERS = 4;
    uint8 public constant MAX_SLOTS_PER_OPERATOR_PHASE_TWO = 2;

    uint64 public constant COMMIT_WINDOW = 24 hours;
    uint64 public constant REVEAL_WINDOW = 24 hours;

    /// @notice §15: $1,000 of CODE per slot, revalued each season boundary.
    uint256 public constant BOND_USD_TARGET = 1_000e18;

    /// @notice §15: failure to reveal a submitted commitment forfeits a quarter of the slot's bond.
    uint256 internal constant REVEAL_FORFEIT_BPS = 2_500;
    uint256 internal constant BPS = 10_000;

    /// @notice §15: phase two begins at the end of season 8, or at 2,000 WETH cumulative deployed.
    uint32 public constant PHASE_TWO_SEASON = 8;
    uint256 public constant PHASE_TWO_WETH = 2_000e18;

    // =====================================================================
    // Roles
    // =====================================================================

    ICodeBurn public immutable code;

    /// @notice Owner of the registry, in every phase and without exception (§5.8, §14).
    address public immutable timelock;

    ISeasonClock public immutable dcode;
    IOracle public oracle;

    /// @notice The governor, which opens origination and advisory rounds.
    address public governor;

    /// @notice The escrow, which opens tranche rounds and receives their releases.
    address public escrow;

    address public configurer;

    // =====================================================================
    // The board (§5.2)
    // =====================================================================

    struct Slot {
        address operator;
        /// @dev Rotating signing key. Operators rotate their own without governance (§5.2).
        address key;
        bytes32 provider;
        uint256 bondCode;
        bool suspended;
    }

    /// @dev Slots are 0..9 and always exist; an unassigned slot has a zero operator.
    Slot[10] internal _slots;

    /// @notice Count of slots held by an operator, for the phase-two cap.
    mapping(address operator => uint8) public slotsHeld;

    // =====================================================================
    // Attestation fees (§5.8, phase two)
    // =====================================================================

    /// @notice USD paid per revealed attestation, 18 decimals. Governance-set, zero until it is.
    /// @dev §5.8: "In phase two, independent operators are paid per attestation from the treasury, giving
    ///      the DAO a performance lever and operators a reason to stay live."
    ///
    ///      The economics only work in one phase without this. In phase one the team runs the board
    ///      because it is their protocol. A phase-two operator posts a $1,000 bond, pays for inference on
    ///      every round including the advisory ones nobody voted on, risks a quarter of the bond on a
    ///      missed reveal and all of it on equivocation, and without a fee receives nothing at all. The
    ///      rational response is to decline the seat, or to take it and go quiet, which walks the board
    ///      toward the eight-reveal floor that freezes every outcome.
    uint256 public attestationFeeUsd;

    /// @notice CODE held to pay attestation fees, funded from the treasury by passed proposal (§11).
    uint256 public feePool;

    /// @notice CODE held as slot bonds, summed across the board.
    /// @dev The contract holds two pools of CODE in one balance: bonds, which belong to operators and
    ///      are burnable only by §15's penalties, and the fee pool, which belongs to the DAO. Tracking
    ///      the bonded total is what makes the separation provable rather than asserted: every path that
    ///      credits the fee pool checks the balance against this figure first, so a fee can never be
    ///      paid out of somebody's bond.
    uint256 public totalBondedCode;

    /// @notice USD owed to each operator, 18 decimals.
    /// @dev Credited to the operator who held the slot when the attestation was made, not to whoever holds
    ///      it now. Slot reassignment is a governance act that can happen at any time (§5.2), and paying
    ///      the incumbent would let a reassignment take earnings that were already worked for.
    mapping(address operator => uint256) public owedUsd;

    /// @notice Total USD owed across all operators. The DAO's standing liability.
    uint256 public totalOwedUsd;

    /// @notice Rounds already accrued, so a re-settlement cannot pay twice.
    mapping(uint256 roundId => bool) public feesAccrued;

    // =====================================================================
    // Rounds (§5.4)
    // =====================================================================

    enum RoundKind {
        Origination,
        Tranche,
        Advisory
    }

    enum RoundState {
        None,
        Open,
        Approved,
        Rejected,
        Lapsed
    }

    struct Round {
        uint256 subject;
        RoundKind kind;
        RoundState state;
        uint64 commitEnd;
        uint64 revealEnd;
        uint8 commits;
        uint8 reveals;
        uint8 approvals;
        /// @dev Bit i set when slot i committed.
        uint16 committedMask;
        /// @dev Bit i set when slot i revealed.
        uint16 revealedMask;
        /// @dev Tranche rounds only: which tranche of `subject` is being verified.
        uint8 trancheIndex;
        /// @dev The attestation fee in force when this round opened, USD with 18 decimals (§5.8).
        ///      Frozen at open, not read at settlement, so an operator knows what the round pays
        ///      before spending inference on it. Governance changing the rate mid-round would
        ///      otherwise reprice work that had already been done. Zero on every round opened
        ///      before the phase two trigger, and on every round opened while the rate is unset.
        uint96 feeUsd;
    }

    uint256 public roundCount;
    mapping(uint256 roundId => Round) internal _rounds;

    /// @dev Commitment submitted by each slot in each round.
    mapping(uint256 roundId => mapping(uint8 slot => bytes32)) public commitmentOf;

    /// @dev The signing key the slot used for this round, frozen at its first commit.
    mapping(uint256 roundId => mapping(uint8 slot => address)) public roundKeyOf;

    /// @dev Revealed verdict per slot, meaningful only where `revealedMask` is set.
    mapping(uint256 roundId => mapping(uint8 slot => bool)) public verdictOf;

    /// @dev The operator holding the slot at its first commit, recorded only on rounds that pay a
    ///      fee. Attestation fees are credited here rather than to whoever holds the slot at
    ///      settlement: reassignment is a governance act available at any time (§5.2), the reveal is
    ///      signed by the key frozen at commit and so can only come from this operator, and paying
    ///      the incumbent would let a reassignment take earnings that were already worked for.
    mapping(uint256 roundId => mapping(uint8 slot => address)) public roundOperatorOf;

    // =====================================================================
    // EIP-712 (decision 1.4)
    // =====================================================================

    bytes32 private constant COMMIT_TYPEHASH =
        keccak256("Commit(uint256 roundId,uint8 slot,bytes32 commitment,bytes32 modelHash)");

    bytes32 private constant REVEAL_TYPEHASH =
        keccak256("Reveal(uint256 roundId,uint8 slot,bool verdict,bytes32 reasonHash,bytes32 salt)");

    struct CommitAttestation {
        uint256 roundId;
        uint8 slot;
        bytes32 commitment;
        /// @dev §5.4: "a hash of the model identifier, version, and system prompt in use, so silent
        ///      model substitution is detectable after the fact."
        bytes32 modelHash;
    }

    struct RevealAttestation {
        uint256 roundId;
        uint8 slot;
        bool verdict;
        bytes32 reasonHash;
        bytes32 salt;
    }

    // =====================================================================
    // Events
    // =====================================================================

    event SlotAssigned(uint8 indexed slot, address indexed operator, address key, bytes32 provider);
    event SlotVacated(uint8 indexed slot, bytes32 reason);
    event KeyRotated(uint8 indexed slot, address oldKey, address newKey);
    event BondPosted(uint8 indexed slot, uint256 amount, uint256 total);
    event BondWithdrawn(uint8 indexed slot, uint256 amount);
    event SlotSuspended(uint8 indexed slot, uint256 bondCode, uint256 required);
    event SlotReinstated(uint8 indexed slot);
    event RoundOpened(uint256 indexed roundId, RoundKind kind, uint256 subject, uint64 commitEnd, uint64 revealEnd);
    event Committed(uint256 indexed roundId, uint8 indexed slot, bytes32 commitment, bytes32 modelHash);
    event Revealed(uint256 indexed roundId, uint8 indexed slot, bool verdict, bytes32 reasonHash);
    event RoundSettled(uint256 indexed roundId, RoundState state, uint8 reveals, uint8 approvals);
    event RevealForfeit(uint256 indexed roundId, uint8 indexed slot, uint256 burned);
    event Equivocation(uint256 indexed roundId, uint8 indexed slot, uint256 burnedBond);
    event AttestationFeeSet(uint256 usdPerAttestation);
    event FeePoolFunded(address indexed from, uint256 amount, uint256 pool);
    event FeesAccrued(uint256 indexed roundId, uint8 attestations, uint256 usdPerAttestation);
    event FeesClaimed(address indexed operator, uint256 usdSettled, uint256 codePaid);

    // =====================================================================
    // Errors
    // =====================================================================

    error NotTimelock();
    error NotGovernor();
    error NotEscrow();
    error NotOperator();
    error NotConfigurer();
    error BadSlot();
    error SlotEmpty();
    error SlotIsSuspended();
    error ProviderDiversityBreached();
    error OperatorCapBreached();
    error RoundUnknown();
    error RoundNotOpen();
    error CommitWindowClosed();
    error CommitWindowOpen();
    error RevealWindowClosed();
    error RevealWindowOpen();
    error AlreadyCommitted();
    error AlreadyRevealed();
    error NoCommitment();
    error CommitmentMismatch();
    error BadSignature();
    error LengthMismatch();
    error NotEquivocation();
    error BondBelowTarget();
    error ZeroAddress();
    error ZeroAmount();
    error RoundStillOpen();
    error NothingOwed();
    error PoolEmpty();
    error FeeOutOfRange();
    error PriceUnavailable();
    error NothingToSync();

    // =====================================================================
    // Construction
    // =====================================================================

    constructor(ICodeBurn code_, address timelock_, ISeasonClock dcode_) EIP712("SAINE", "1") {
        if (address(code_) == address(0) || timelock_ == address(0)) revert ZeroAddress();
        code = code_;
        timelock = timelock_;
        dcode = dcode_;
        configurer = msg.sender;
    }

    /// @notice Wire the peers and seat the genesis board in one shot.
    /// @dev §5.8: "in phase one the team operates all ten slots... running ten distinct models
    ///      across at least four providers, so the board's model diversity is real from day one
    ///      while its operator diversity arrives with phase two." The provider constraint is checked
    ///      here exactly as it is on every later assignment; only the operator cap is deferred.
    function wire(
        address governor_,
        address escrow_,
        IOracle oracle_,
        address genesisOperator,
        address[10] calldata keys,
        bytes32[10] calldata providers
    ) external {
        if (msg.sender != configurer) revert NotConfigurer();
        if (governor_ == address(0) || escrow_ == address(0) || genesisOperator == address(0)) {
            revert ZeroAddress();
        }
        governor = governor_;
        escrow = escrow_;
        oracle = oracle_;

        for (uint8 i; i < SLOTS; ++i) {
            if (keys[i] == address(0) || providers[i] == bytes32(0)) revert ZeroAddress();
            _slots[i] = Slot(genesisOperator, keys[i], providers[i], 0, false);
            emit SlotAssigned(i, genesisOperator, keys[i], providers[i]);
        }
        slotsHeld[genesisOperator] = SLOTS;
        if (_distinctProviders() < MIN_PROVIDERS) revert ProviderDiversityBreached();

        configurer = address(0);
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert NotTimelock();
        _;
    }

    // =====================================================================
    // Registry (§5.2)
    // =====================================================================

    /// @notice Reassign a slot. Governance-gated in every phase, without exception (§5.8, §14).
    /// @dev Both constraints are checked against the board as it would be *after* the change, and
    ///      both revert rather than warn, per invariant 12. The operator cap activates only from the
    ///      phase two trigger; the provider floor holds "in every phase, from the first attestation".
    function assignSlot(uint8 slot, address operator, address key, bytes32 provider) external onlyTimelock {
        if (slot >= SLOTS) revert BadSlot();
        if (operator == address(0) || key == address(0) || provider == bytes32(0)) revert ZeroAddress();

        Slot storage s = _slots[slot];
        address previous = s.operator;

        // Bond does not travel with the seat: an incoming operator posts their own.
        if (s.bondCode != 0) {
            uint256 refund = s.bondCode;
            s.bondCode = 0;
            totalBondedCode -= refund;
            IERC20(address(code)).safeTransfer(previous, refund);
            emit BondWithdrawn(slot, refund);
        }

        if (previous != address(0)) {
            unchecked {
                --slotsHeld[previous];
            }
        }

        s.operator = operator;
        s.key = key;
        s.provider = provider;
        s.suspended = false;
        ++slotsHeld[operator];

        if (_distinctProviders() < MIN_PROVIDERS) revert ProviderDiversityBreached();
        if (phaseTwo() && slotsHeld[operator] > MAX_SLOTS_PER_OPERATOR_PHASE_TWO) {
            revert OperatorCapBreached();
        }

        emit SlotAssigned(slot, operator, key, provider);
    }

    /// @notice Rotate a slot's signing key. Operator-controlled, no governance (§5.2).
    /// @dev "Operators rotate their own signing keys freely, which handles key leaks and model
    ///      deprecations without governance." Live rounds are unaffected because each round records
    ///      the key it was committed under.
    function rotateKey(uint8 slot, address newKey) external {
        if (slot >= SLOTS) revert BadSlot();
        Slot storage s = _slots[slot];
        if (msg.sender != s.operator) revert NotOperator();
        if (newKey == address(0)) revert ZeroAddress();
        address old = s.key;
        s.key = newKey;
        emit KeyRotated(slot, old, newKey);
    }

    /// @notice Count of distinct non-zero provider tags across the board.
    function _distinctProviders() internal view returns (uint8 count) {
        for (uint8 i; i < SLOTS; ++i) {
            bytes32 p = _slots[i].provider;
            if (p == bytes32(0)) continue;
            bool seen;
            for (uint8 j; j < i; ++j) {
                if (_slots[j].provider == p) {
                    seen = true;
                    break;
                }
            }
            if (!seen) ++count;
        }
    }

    /// @notice Whether the phase two trigger has passed (§15).
    function phaseTwo() public view returns (bool) {
        if (address(dcode) != address(0) && dcode.currentSeason() > PHASE_TWO_SEASON) return true;
        if (escrow != address(0) && IDrawTotal(escrow).totalDrawnWeth() >= PHASE_TWO_WETH) return true;
        return false;
    }

    // =====================================================================
    // Bonds (§5.5)
    // =====================================================================

    /// @notice CODE required to meet a slot's USD bond target at the current oracle price.
    function bondRequirement() public view returns (uint256) {
        uint256 price = oracle.codeUsdPrice();
        if (price == 0) return type(uint256).max;
        return (BOND_USD_TARGET * 1e18) / price;
    }

    function postBond(uint8 slot, uint256 amount) external {
        if (slot >= SLOTS) revert BadSlot();
        if (amount == 0) revert ZeroAmount();
        Slot storage s = _slots[slot];
        if (s.operator == address(0)) revert SlotEmpty();

        IERC20(address(code)).safeTransferFrom(msg.sender, address(this), amount);
        s.bondCode += amount;
        totalBondedCode += amount;
        emit BondPosted(slot, amount, s.bondCode);

        if (s.suspended && s.bondCode >= bondRequirement()) {
            s.suspended = false;
            emit SlotReinstated(slot);
        }
    }

    /// @notice Revalue every bond and suspend any slot that no longer meets the target.
    /// @dev §5.5: "Bonds are revalued at each season boundary; a bond below target must be topped up
    ///      within the boundary window or the slot suspends until it is." Permissionless, because a
    ///      revaluation that depends on someone remembering to call it is not a constraint.
    ///      Suspension shrinks the live board, which can push a round below the eight-reveal floor;
    ///      that lapses the round, which is the designed failure mode and harms nobody.
    function revalueBonds() external {
        uint256 required = bondRequirement();
        for (uint8 i; i < SLOTS; ++i) {
            Slot storage s = _slots[i];
            if (s.operator == address(0)) continue;
            if (s.bondCode < required) {
                if (!s.suspended) {
                    s.suspended = true;
                    emit SlotSuspended(i, s.bondCode, required);
                }
            } else if (s.suspended) {
                s.suspended = false;
                emit SlotReinstated(i);
            }
        }
    }

    // =====================================================================
    // Opening rounds
    // =====================================================================

    function openRound(RoundKind kind, uint256 subject) external returns (uint256 roundId) {
        if (msg.sender != governor) revert NotGovernor();
        if (kind == RoundKind.Tranche) revert NotEscrow();
        roundId = _open(kind, subject, 0);
    }

    /// @notice Open a tranche verification round. Escrow-only; the escrow holds the validation.
    function openTrancheRound(uint256 dealId, uint8 index, bytes32) external returns (uint256 roundId) {
        if (msg.sender != escrow) revert NotEscrow();
        roundId = _open(RoundKind.Tranche, dealId, index);
    }

    function _open(RoundKind kind, uint256 subject, uint8 trancheIndex) internal returns (uint256 roundId) {
        roundId = ++roundCount;
        Round storage r = _rounds[roundId];
        r.subject = subject;
        r.kind = kind;
        r.state = RoundState.Open;
        r.commitEnd = uint64(block.timestamp) + COMMIT_WINDOW;
        r.revealEnd = r.commitEnd + REVEAL_WINDOW;
        r.trancheIndex = trancheIndex;
        // Bounded by `setAttestationFee` to 100e18, so the cast cannot truncate.
        if (attestationFeeUsd != 0 && phaseTwo()) r.feeUsd = uint96(attestationFeeUsd);
        emit RoundOpened(roundId, kind, subject, r.commitEnd, r.revealEnd);
    }

    // =====================================================================
    // Commit (§5.4)
    // =====================================================================

    /// @notice Relay a batch of signed commitments.
    /// @dev §12 notes adjudication is transaction-heavy; batching ten commitments into one
    ///      transaction is why the signed-and-relayed shape was chosen.
    function submitCommits(CommitAttestation[] calldata atts, bytes[] calldata sigs) external {
        if (atts.length != sigs.length) revert LengthMismatch();
        for (uint256 i; i < atts.length; ++i) {
            _commit(atts[i], sigs[i]);
        }
    }

    function _commit(CommitAttestation calldata a, bytes calldata sig) internal {
        if (a.slot >= SLOTS) revert BadSlot();
        Round storage r = _rounds[a.roundId];
        if (r.state != RoundState.Open) revert RoundNotOpen();
        if (block.timestamp > r.commitEnd) revert CommitWindowClosed();

        Slot storage s = _slots[a.slot];
        if (s.operator == address(0)) revert SlotEmpty();
        if (s.suspended) revert SlotIsSuspended();

        uint16 bit = uint16(1) << a.slot;
        if (r.committedMask & bit != 0) revert AlreadyCommitted();

        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(COMMIT_TYPEHASH, a.roundId, a.slot, a.commitment, a.modelHash)));
        if (ECDSA.recover(digest, sig) != s.key) revert BadSignature();

        r.committedMask |= bit;
        ++r.commits;
        commitmentOf[a.roundId][a.slot] = a.commitment;
        // Frozen here so a later rotation cannot invalidate this round's reveal.
        roundKeyOf[a.roundId][a.slot] = s.key;
        // Only where there is something to pay, so the phase one path costs nothing extra.
        if (r.feeUsd != 0) roundOperatorOf[a.roundId][a.slot] = s.operator;

        emit Committed(a.roundId, a.slot, a.commitment, a.modelHash);
    }

    // =====================================================================
    // Reveal (§5.4)
    // =====================================================================

    function submitReveals(RevealAttestation[] calldata atts, bytes[] calldata sigs) external {
        if (atts.length != sigs.length) revert LengthMismatch();
        for (uint256 i; i < atts.length; ++i) {
            _reveal(atts[i], sigs[i]);
        }
    }

    function _reveal(RevealAttestation calldata a, bytes calldata sig) internal {
        if (a.slot >= SLOTS) revert BadSlot();
        Round storage r = _rounds[a.roundId];
        if (r.state != RoundState.Open) revert RoundNotOpen();
        if (block.timestamp <= r.commitEnd) revert CommitWindowOpen();
        if (block.timestamp > r.revealEnd) revert RevealWindowClosed();

        uint16 bit = uint16(1) << a.slot;
        if (r.committedMask & bit == 0) revert NoCommitment();
        if (r.revealedMask & bit != 0) revert AlreadyRevealed();

        address key = roundKeyOf[a.roundId][a.slot];
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(REVEAL_TYPEHASH, a.roundId, a.slot, a.verdict, a.reasonHash, a.salt))
        );
        if (ECDSA.recover(digest, sig) != key) revert BadSignature();

        // The reason hash is inside the commitment, so a justification cannot be composed after
        // observing the tally (§5.4).
        if (keccak256(abi.encode(a.verdict, a.reasonHash, a.salt)) != commitmentOf[a.roundId][a.slot]) {
            revert CommitmentMismatch();
        }

        r.revealedMask |= bit;
        ++r.reveals;
        if (a.verdict) ++r.approvals;
        verdictOf[a.roundId][a.slot] = a.verdict;

        emit Revealed(a.roundId, a.slot, a.verdict, a.reasonHash);
    }

    // =====================================================================
    // Equivocation (§5.5)
    // =====================================================================

    /// @notice Slash and vacate a slot on proof of two conflicting signed attestations.
    /// @dev "One offence is punished automatically, because it is the one offence provable on-chain:
    ///      equivocation... No vote, no judgment, no appeal." Deliberately callable by anyone, at any
    ///      time, whether or not either attestation was ever accepted into a round: the offence is
    ///      the existence of the two signatures, not their acceptance.
    function reportEquivocation(
        RevealAttestation calldata a,
        bytes calldata sigA,
        RevealAttestation calldata b,
        bytes calldata sigB
    ) external {
        if (a.slot != b.slot || a.roundId != b.roundId) revert NotEquivocation();
        if (a.verdict == b.verdict) revert NotEquivocation();
        if (a.slot >= SLOTS) revert BadSlot();

        address key = roundKeyOf[a.roundId][a.slot];
        if (key == address(0)) key = _slots[a.slot].key;

        bytes32 digestA = _hashTypedDataV4(
            keccak256(abi.encode(REVEAL_TYPEHASH, a.roundId, a.slot, a.verdict, a.reasonHash, a.salt))
        );
        bytes32 digestB = _hashTypedDataV4(
            keccak256(abi.encode(REVEAL_TYPEHASH, b.roundId, b.slot, b.verdict, b.reasonHash, b.salt))
        );
        if (ECDSA.recover(digestA, sigA) != key) revert BadSignature();
        if (ECDSA.recover(digestB, sigB) != key) revert BadSignature();

        Slot storage s = _slots[a.slot];
        uint256 burned = s.bondCode;
        address operator = s.operator;

        s.bondCode = 0;
        totalBondedCode -= burned;
        s.operator = address(0);
        s.key = address(0);
        s.provider = bytes32(0);
        s.suspended = false;
        if (operator != address(0)) {
            unchecked {
                --slotsHeld[operator];
            }
        }

        if (burned != 0) code.burn(burned);

        // Unpaid work on the round being reported is forfeited along with the bond: a slot that signed
        // two contradictory attestations did not perform one attestation, it performed an attack. This
        // reaches only the reported round, since fees on earlier rounds may already have been claimed
        // and the burned bond is what §5.5 offers as the deterrent.
        delete roundOperatorOf[a.roundId][a.slot];

        emit Equivocation(a.roundId, a.slot, burned);
        emit SlotVacated(a.slot, "equivocation");
    }

    // =====================================================================
    // Settlement (§5.4)
    // =====================================================================

    /// @notice Tally a round, apply reveal forfeits, and report the outcome.
    /// @dev The three-way tally is §5.4 verbatim: eight or more reveals with six or more approvals
    ///      approves; eight or more reveals with fewer than six approvals rejects, because "a board
    ///      that reaches quorum and does not clear it has not approved"; fewer than eight reveals
    ///      lapses and slashes nobody.
    function settleRound(uint256 roundId) external {
        Round storage r = _rounds[roundId];
        if (r.state != RoundState.Open) revert RoundNotOpen();
        // Early settlement once every committed slot has revealed, so a full board does not wait.
        if (block.timestamp <= r.revealEnd && r.reveals != r.commits) revert RevealWindowOpen();

        if (r.reveals < LIVENESS_FLOOR) {
            r.state = RoundState.Lapsed;
        } else if (r.approvals >= APPROVAL_THRESHOLD) {
            r.state = RoundState.Approved;
        } else {
            r.state = RoundState.Rejected;
        }

        _applyRevealForfeits(roundId, r);
        _accrueAttestationFees(roundId, r);

        emit RoundSettled(roundId, r.state, r.reveals, r.approvals);

        if (r.kind == RoundKind.Tranche) {
            if (r.state == RoundState.Approved) {
                IEscrowRelease(escrow).releaseTranche(r.subject, r.trancheIndex);
            }
        } else {
            ISaineConsumer(governor)
                .onSaineVerdict(r.subject, r.state == RoundState.Approved, r.state == RoundState.Lapsed);
        }
    }

    /// @dev §15: "Reveal-failure forfeit: 25% of slot bond, burned." Charged to slots that committed
    ///      and then went silent, never to slots that never committed: the offence is abandoning an
    ///      attestation mid-round, not declining to attest.
    function _applyRevealForfeits(uint256 roundId, Round storage r) internal {
        uint16 silent = r.committedMask & ~r.revealedMask;
        if (silent == 0) return;
        for (uint8 i; i < SLOTS; ++i) {
            if (silent & (uint16(1) << i) == 0) continue;
            Slot storage s = _slots[i];
            uint256 forfeit = (s.bondCode * REVEAL_FORFEIT_BPS) / BPS;
            if (forfeit == 0) continue;
            s.bondCode -= forfeit;
            totalBondedCode -= forfeit;
            code.burn(forfeit);
            emit RevealForfeit(roundId, i, forfeit);
        }
    }

    /// @dev Credited on **reveal**, not on commit, and for every outcome including a lapse.
    ///
    ///      Not on commit, because §15 already forfeits a quarter of the bond for committing and going
    ///      silent, and paying for that commitment as well would reward the behaviour the forfeit exists to
    ///      punish. Reveal is the point at which the slot has actually done the work and published a reason
    ///      the record can be audited against.
    ///
    ///      For every outcome, because a lapse is not the revealing slots' fault. §5.4 lapses a round when
    ///      fewer than eight reveal, and paying only on approvals and rejections would leave the eight who
    ///      did their job unpaid because two others went dark. That is the opposite of "a reason to stay
    ///      live".
    ///
    ///      Accrued in USD rather than converted here, deliberately. Converting would mean reading the
    ///      oracle inside `settleRound`, and a stale average would then revert settlement: on the
    ///      origination track that also freezes the queue, because invariant 6 allows one proposal at a
    ///      time. An operator carrying price risk between accrual and claim is a far smaller problem than a
    ///      protocol that cannot settle a round because a keeper missed an oracle poke.
    function _accrueAttestationFees(uint256 roundId, Round storage r) internal {
        // The rate and the phase test were both settled when the round opened.
        uint256 rate = r.feeUsd;
        if (rate == 0) return;
        if (feesAccrued[roundId]) return;
        feesAccrued[roundId] = true;

        uint16 revealed = r.revealedMask;
        uint8 paid;
        uint256 credited;
        for (uint8 i; i < SLOTS; ++i) {
            if (revealed & (uint16(1) << i) == 0) continue;
            address operator = roundOperatorOf[roundId][i];
            // Zero only where the record was cleared by an equivocation report on this round.
            if (operator == address(0)) continue;
            owedUsd[operator] += rate;
            credited += rate;
            ++paid;
        }
        if (paid == 0) return;
        totalOwedUsd += credited;
        emit FeesAccrued(roundId, paid, rate);
    }

    /// @notice Fund the fee pool by approval. Anyone may.
    function fundFeePool(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        IERC20(address(code)).safeTransferFrom(msg.sender, address(this), amount);
        feePool += amount;
        emit FeePoolFunded(msg.sender, amount, feePool);
    }

    /// @notice Credit CODE already sent here to the fee pool. Permissionless.
    /// @dev This is the path governance actually uses. `Treasury.spend` pushes tokens to a recipient;
    ///      it cannot approve a spender, so a proposal that funded the pool through `fundFeePool` would
    ///      have to route the DAO's CODE through some intermediary account first. A proposal instead
    ///      pairs `treasury.spend(code, saine, amount)` with a call to this, and the CODE never leaves
    ///      protocol contracts.
    ///
    ///      Crediting only the surplus over the bonded total is what keeps the two pools separate: a
    ///      caller cannot conjure fee-pool balance out of operators' bonds, however it is called and in
    ///      whatever order.
    function syncFeePool() external returns (uint256 added) {
        uint256 held = IERC20(address(code)).balanceOf(address(this));
        uint256 accounted = totalBondedCode + feePool;
        if (held <= accounted) revert NothingToSync();
        added = held - accounted;
        feePool += added;
        emit FeePoolFunded(msg.sender, added, feePool);
    }

    /// @notice Set the per-attestation fee. Timelock only (§14, invariant 18).
    /// @dev The rate is the DAO's lever on the board's economics, and the ceiling exists because this
    ///      function spends treasury capital on a recurring basis: at ten slots across three tracks, a rate
    ///      set carelessly high compounds quickly. Slot reassignment remains the sharper lever on a
    ///      specific operator's performance; this one prices the work.
    function setAttestationFee(uint256 usdPerAttestation) external onlyTimelock {
        if (usdPerAttestation > 100e18) revert FeeOutOfRange();
        attestationFeeUsd = usdPerAttestation;
        emit AttestationFeeSet(usdPerAttestation);
    }

    /// @notice Pay an operator what they have accrued, converted to CODE at the oracle price.
    /// @dev Pays what the pool can cover and leaves the remainder owed rather than discarding it. An
    ///      unfunded pool is a governance failure, not an operator's, and silently zeroing what they earned
    ///      would make the fee worthless as a commitment.
    ///
    ///      Permissionless, and the recipient is the named operator rather than the caller. The operator
    ///      address is whatever governance assigned to the seat (§5.2), which may well be a multisig or a
    ///      cold key that has no business sending routine transactions; requiring it to call would make
    ///      earnings awkward to collect for exactly the operators most carefully set up. Nobody can
    ///      redirect a payment, and because the debt is denominated in USD rather than CODE, claiming it
    ///      early or late delivers the same value, so there is nothing to gain by claiming on somebody
    ///      else's behalf either.
    function claimAttestationFees(address operator) external returns (uint256 codePaid) {
        uint256 owed = owedUsd[operator];
        if (owed == 0) revert NothingOwed();
        if (feePool == 0) revert PoolEmpty();

        uint256 price = oracle.codeUsdPrice();
        if (price == 0) revert PriceUnavailable();
        uint256 wanted = (owed * 1e18) / price;

        uint256 usdSettled = owed;
        codePaid = wanted;
        if (codePaid > feePool) {
            codePaid = feePool;
            // Settle only the proportion the pool covered, so the rest stays owed at its USD value.
            usdSettled = (codePaid * price) / 1e18;
            if (usdSettled > owed) usdSettled = owed;
        }

        owedUsd[operator] = owed - usdSettled;
        totalOwedUsd -= usdSettled;
        feePool -= codePaid;

        IERC20(address(code)).safeTransfer(operator, codePaid);
        emit FeesClaimed(operator, usdSettled, codePaid);
    }

    /// @notice CODE the pool would need to clear every outstanding claim at the current price.
    /// @dev For governance: an unfunded liability that grows every round is a board that will stop
    ///      attesting, and the whole point of the fee is that it does not.
    function feeShortfallCode() external view returns (uint256) {
        if (totalOwedUsd == 0) return 0;
        uint256 price = oracle.codeUsdPrice();
        if (price == 0) revert PriceUnavailable();
        uint256 needed = (totalOwedUsd * 1e18) / price;
        return needed > feePool ? needed - feePool : 0;
    }

    // =====================================================================
    // Views
    // =====================================================================

    function getSlot(uint8 slot) external view returns (Slot memory) {
        return _slots[slot];
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return _rounds[roundId];
    }

    function distinctProviders() external view returns (uint8) {
        return _distinctProviders();
    }

    function liveSlots() external view returns (uint8 n) {
        for (uint8 i; i < SLOTS; ++i) {
            if (_slots[i].operator != address(0) && !_slots[i].suspended) ++n;
        }
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
