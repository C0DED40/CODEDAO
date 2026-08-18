// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVintageVault} from "./interfaces/IVintageVault.sol";
import {IDCode} from "./interfaces/IDCode.sol";

interface ICodeBurnable is IERC20 {
    function burn(uint256 amount) external;
}

/// @title VintageVault
/// @notice Vintage accounting: returns are paid to the season whose judgment funded the deal (§10).
///
/// @dev Three separate contractions act on a vintage, and conflating any two of them produces a
///      subtly wrong payout. Kept distinct here:
///
///      1. **Penalties** shrink what a participant may claim but do *not* enlarge anyone else's
///         claim. §2.3 is explicit that redistributing a slashed share "would create an appetite
///         for seeing neighbours slashed". So distribution is computed against the vintage's full
///         pre-penalty base, each participant claims against their penalised weight, and the
///         differential is burned at the moment of crediting.
///
///      2. **Exit forfeiture** does the opposite. §10.3: "The forfeited stream is not burned and
///         not sent to the treasury: the vintage's weight base contracts, and future arrivals
///         distribute over the participants who stayed. Departing carry accrues to remaining
///         partners." So an exit removes the leaver from *both* bases, which mechanically enlarges
///         everyone else's share of everything that arrives afterwards, and leaves everything that
///         already arrived untouched.
///
///      3. **The monotone cap** in §10.3 is applied by the staking vault, not here. This contract
///         is told the new weight and never computes it, because the low-water history the cap
///         depends on lives with the principal.
///
///      The accumulator pattern is what makes all three O(1). A participant's entitlement is
///      `weight x (accReturnPerWeight - claimDebt)`, so crediting a return touches one storage slot
///      regardless of how many thousands of stakers the vintage holds, and contracting a base
///      never has to revisit anyone else's position.
contract VintageVault is IVintageVault {
    using SafeERC20 for IERC20;

    /// @dev Accumulator scale. Returns and weights are both 1e18-denominated, so 1e27 leaves nine
    ///      decimal digits of headroom on the per-weight quotient before truncation bites.
    uint256 internal constant ACC = 1e27;

    ICodeBurnable public immutable code;
    IDCode public immutable dcode;

    /// @notice Receives the residue described in `sweepResidue`, and stale vintages' arrivals.
    address public immutable treasury;

    /// @notice The home-chain repayment endpoint, the only address that may credit a vintage (§9).
    address public receiver;

    /// @notice Timelock, for residue sweeps only. It cannot touch a participant's claim.
    address public immutable timelock;

    address public configurer;

    struct Vintage {
        /// @dev Cumulative CODE credited per unit of *pre-penalty* weight, scaled by ACC.
        uint256 accReturnPerWeight;
        /// @dev Pre-penalty weight base, contracting only as participants exit.
        uint256 preSlashBase;
        /// @dev Penalised weight base, contracting on exits. Drives the burn differential.
        uint256 effectiveBase;
        bool initialised;
    }

    struct Position {
        /// @dev The participant's pre-penalty share of the vintage.
        uint256 preWeight;
        /// @dev The participant's penalised claim weight.
        uint256 effWeight;
        uint256 claimDebt;
        bool registered;
        /// @dev §10.3: "A zeroed vintage weight never revives, under any subsequent staking."
        bool dead;
    }

    mapping(uint32 vintage => Vintage) internal _vintages;
    mapping(uint32 vintage => mapping(address account => Position)) internal _positions;

    /// @notice Amounts settled at exit and not yet collected. Withdrawable at any time.
    mapping(address account => uint256) public settled;

    /// @notice Total CODE this contract owes to participants across every vintage.
    uint256 public liability;

    event VintageInitialised(uint32 indexed vintage, uint256 preSlashBase, uint256 effectiveBase);
    event Credited(uint32 indexed vintage, uint256 amount, uint256 distributed, uint256 burned);
    event StaleVintageRouted(uint32 indexed vintage, uint256 amount);
    event Claimed(address indexed account, uint256 amount);
    event WeightContracted(address indexed account, uint32 indexed vintage, uint256 newEffWeight, uint256 settledNow);
    event ResidueSwept(uint256 amount);
    event PhantomWeightBurned(address indexed account, uint32 indexed vintage, uint256 amount);

    error NotReceiver();
    error NotStakingVault();
    error NotTimelock();
    error NotConfigurer();
    error SeasonNotFrozen();
    error ZeroAddress();
    error ZeroAmount();
    error WeightCannotGrow();
    error NothingToClaim();

    constructor(ICodeBurnable code_, IDCode dcode_, address treasury_, address timelock_) {
        if (
            address(code_) == address(0) || address(dcode_) == address(0) || treasury_ == address(0)
                || timelock_ == address(0)
        ) revert ZeroAddress();
        code = code_;
        dcode = dcode_;
        treasury = treasury_;
        timelock = timelock_;
        configurer = msg.sender;
    }

    function wire(address receiver_) external {
        if (msg.sender != configurer) revert NotConfigurer();
        if (receiver_ == address(0)) revert ZeroAddress();
        receiver = receiver_;
        configurer = address(0);
    }

    // =====================================================================
    // Crediting returns (§9 step 5, §10.2)
    // =====================================================================

    /// @notice Credit a vintage with its half of a repayment's CODE purchase.
    /// @dev Pulls the CODE in the same call, so the vault's balance and its `liability` cannot
    ///      drift apart through a transfer that forgot its bookkeeping.
    ///
    ///      The burn happens here rather than at claim time. §2.3 says the differential burns "on
    ///      distribution", and doing it at the moment of crediting has two properties claim-time
    ///      burning does not: the supply reduction is immediate and public rather than waiting on
    ///      whether a slashed participant ever bothers to claim, and the vault's balance stays equal
    ///      to what it actually owes, so there is never a pot of unburned differential sitting here
    ///      looking claimable.
    function creditVintage(uint32 vintage, uint256 amount) external {
        if (msg.sender != receiver) revert NotReceiver();
        if (amount == 0) revert ZeroAmount();

        IERC20(address(code)).safeTransferFrom(msg.sender, address(this), amount);

        Vintage storage v = _initVintage(vintage);

        // §10.3: "A vintage whose weight base reaches zero routes all further arrivals to the
        // treasury." Nobody is left to pay, and burning it would quietly convert a portfolio
        // return into a supply cut that no participant chose.
        if (v.preSlashBase == 0) {
            IERC20(address(code)).safeTransfer(treasury, amount);
            emit StaleVintageRouted(vintage, amount);
            return;
        }

        v.accReturnPerWeight += (amount * ACC) / v.preSlashBase;

        // Rounded up, deliberately. Each participant's claim truncates independently, so the sum of
        // the individual floors can exceed the floor of the sum by up to a wei per participant. A
        // liability rounded down would then be a liability the vault cannot settle, and the last
        // claimant of a vintage would revert on an underflow. Rounding up costs at most one wei of
        // under-burn per credit and errs toward the participants rather than toward a burn nobody
        // can audit.
        uint256 distributed = (amount * v.effectiveBase + v.preSlashBase - 1) / v.preSlashBase;
        if (distributed > amount) distributed = amount;
        uint256 burned = amount - distributed;

        liability += distributed;
        if (burned != 0) code.burn(burned);

        emit Credited(vintage, amount, distributed, burned);
    }

    // =====================================================================
    // Claims (§10.2)
    // =====================================================================

    /// @notice Claim across any number of vintages, plus anything settled at a past exit.
    /// @dev §10.2: "Claims are open at any time after the vintage freezes, across as many vintages
    ///      as the participant holds, batched in one call."
    function claim(uint32[] calldata vintages) external returns (uint256 total) {
        for (uint256 i; i < vintages.length; ++i) {
            uint32 vintage = vintages[i];
            Vintage storage v = _initVintage(vintage);
            Position storage p = _register(msg.sender, vintage);

            uint256 pending = (p.effWeight * (v.accReturnPerWeight - p.claimDebt)) / ACC;
            p.claimDebt = v.accReturnPerWeight;
            total += pending;
        }

        uint256 owed = settled[msg.sender];
        if (owed != 0) {
            settled[msg.sender] = 0;
            total += owed;
        }

        if (total == 0) revert NothingToClaim();
        liability -= total;
        IERC20(address(code)).safeTransfer(msg.sender, total);
        emit Claimed(msg.sender, total);
    }

    /// @notice What an account could claim from one vintage right now.
    function claimable(address account, uint32 vintage) public view returns (uint256) {
        Vintage storage v = _vintages[vintage];
        if (!v.initialised) return 0;
        Position storage p = _positions[vintage][account];
        (uint256 effWeight, uint256 debt) =
            p.registered ? (p.effWeight, p.claimDebt) : (dcode.frozenWeightOf(account, vintage), uint256(0));
        return (effWeight * (v.accReturnPerWeight - debt)) / ACC;
    }

    // =====================================================================
    // Exit forfeiture (§10.3)
    // =====================================================================

    /// @notice Contract a participant's claim weight in a frozen vintage.
    /// @dev Called by the staking vault on withdrawal. The sequence matters and is the whole of
    ///      §10.3: settle everything that has already arrived at the *old* weight, because
    ///      "everything accrued to a participant's vintages up to the moment of exit... is theirs",
    ///      and only then shrink the bases so that "everything that arrives after is forfeited" and
    ///      lands on the participants who stayed.
    function syncVintageWeight(address account, uint32 vintage, uint256 newWeight) external {
        if (msg.sender != address(dcode)) revert NotStakingVault();
        Vintage storage v = _vintages[vintage];
        if (!v.initialised) {
            if (!dcode.isSeasonClosed(vintage)) return; // nothing frozen yet, nothing to contract
            v = _initVintage(vintage);
        }
        Position storage p = _register(account, vintage);
        _contract(v, p, account, vintage, newWeight, true);
    }

    /// @dev Two callers, two different meanings, and collapsing them was a real bug.
    ///
    ///      `settleAtOldWeight = true` is an **exit**. The weight being given up was genuinely held
    ///      until this instant, so everything that arrived while it was held belongs to the
    ///      participant and is settled before the base contracts (§10.3).
    ///
    ///      `settleAtOldWeight = false` is a **cap the vault is only now learning about**: the
    ///      participant's stake had already fallen below their frozen weight before this contract
    ///      ever heard of them, so the difference was never claim weight they held at any point
    ///      after the freeze, and settling it would pay them for weight that did not exist. The
    ///      share of past arrivals that had been allocated to that phantom weight is burned, which
    ///      is the same treatment §2.3 gives the penalty differential and for the same reason: it
    ///      corresponds to weight counted in the base that nobody can claim against.
    function _contract(
        Vintage storage v,
        Position storage p,
        address account,
        uint32 vintage,
        uint256 newWeight,
        bool settleAtOldWeight
    ) internal {
        if (newWeight >= p.effWeight) return; // monotone: weight never grows (§10.3)

        uint256 oldEff = p.effWeight;
        uint256 settledNow;

        if (settleAtOldWeight) {
            settledNow = (oldEff * (v.accReturnPerWeight - p.claimDebt)) / ACC;
            if (settledNow != 0) settled[account] += settledNow;
            p.claimDebt = v.accReturnPerWeight;
        } else {
            uint256 stranded = ((oldEff - newWeight) * (v.accReturnPerWeight - p.claimDebt)) / ACC;
            if (stranded != 0) {
                if (stranded > liability) stranded = liability;
                liability -= stranded;
                code.burn(stranded);
                emit PhantomWeightBurned(account, vintage, stranded);
            }
        }

        // The pre-penalty contribution leaves in the same proportion as the penalised one, so the
        // participant's multiplier is preserved across a partial exit rather than silently reset.
        uint256 newPre = oldEff == 0 ? 0 : (p.preWeight * newWeight) / oldEff;

        v.effectiveBase -= (oldEff - newWeight);
        v.preSlashBase -= (p.preWeight - newPre);

        p.effWeight = newWeight;
        p.preWeight = newPre;
        if (newWeight == 0) p.dead = true;

        emit WeightContracted(account, vintage, newWeight, settledNow);
    }

    // =====================================================================
    // Residue (the documented rounding asymmetry)
    // =====================================================================

    /// @notice CODE held here beyond what is owed to participants.
    /// @dev The staking vault's aggregate penalised weight is, by the truncation argument in the
    ///      decisions log, greater than or equal to the sum of the individual penalised weights.
    ///      This vault takes its bases from the aggregate and its positions from the individual
    ///      reads, so the amount marked distributable is very slightly larger than the sum anyone
    ///      can actually claim. The excess is dust, but it is dust that would otherwise sit here
    ///      forever pretending to be someone's, so it is measurable and sweepable to the treasury.
    function residue() public view returns (uint256) {
        uint256 balance = IERC20(address(code)).balanceOf(address(this));
        return balance > liability ? balance - liability : 0;
    }

    function sweepResidue() external returns (uint256 amount) {
        if (msg.sender != timelock) revert NotTimelock();
        amount = residue();
        if (amount == 0) revert ZeroAmount();
        IERC20(address(code)).safeTransfer(treasury, amount);
        emit ResidueSwept(amount);
    }

    // =====================================================================
    // Views
    // =====================================================================

    function getVintage(uint32 vintage) external view returns (Vintage memory) {
        return _vintages[vintage];
    }

    function getPosition(address account, uint32 vintage) external view returns (Position memory) {
        return _positions[vintage][account];
    }

    // =====================================================================
    // Internals
    // =====================================================================

    /// @dev A vintage's bases are read from the staking vault once, at the first touch after the
    ///      season froze, and never re-read. §10.1: "Vintage records never reopen: a slash carried
    ///      into the freeze is carried in the vintage forever."
    function _initVintage(uint32 vintage) internal returns (Vintage storage v) {
        v = _vintages[vintage];
        if (v.initialised) return v;
        if (!dcode.isSeasonClosed(vintage)) revert SeasonNotFrozen();
        v.preSlashBase = dcode.vintagePreSlashWeight(vintage);
        v.effectiveBase = dcode.vintageEffectiveWeight(vintage);
        v.initialised = true;
        emit VintageInitialised(vintage, v.preSlashBase, v.effectiveBase);
    }

    /// @dev Positions are registered lazily at their owner's first interaction. A participant who
    ///      has never touched this contract still holds their full frozen weight, because the
    ///      vintage's bases already counted them at the freeze; registration just writes down what
    ///      was already true. `claimDebt` starts at zero, which is correct: they were in the
    ///      vintage from the moment it froze and are owed every accrual since.
    function _register(address account, uint32 vintage) internal returns (Position storage p) {
        p = _positions[vintage][account];
        if (p.registered) return p;

        p.registered = true;
        p.preWeight = dcode.snapshotPrincipalOf(account, vintage);
        // Frozen, not live: the bases were taken from the same uncapped aggregate, so registering
        // at the capped figure would leave the two sides of the ledger describing different things.
        p.effWeight = dcode.frozenWeightOf(account, vintage);

        // Then apply whatever monotone cap has accrued since the freeze, through the same path an
        // exit takes, so a participant who withdrew before ever touching this contract is treated
        // identically to one who withdrew after.
        uint256 live = dcode.liveVintageWeightOf(account, vintage);
        if (live < p.effWeight) {
            _contract(_vintages[vintage], p, account, vintage, live, false);
        }
    }
}
