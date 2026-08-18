// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router02} from "./interfaces/IExternal.sol";
import {IBridgeAdapter, Repayment} from "./interfaces/IBridge.sol";

/// @title Satellite
/// @notice Repayment intake on an investee's own chain (§9, §16.1 #9).
///
/// @dev §9's opening claim is the design constraint: repayment is "built so that neither founders nor
///      stakers carry the bridge". Both halves of that are enforced here.
///
///      **Founders don't carry it.** "The obligation is discharged at this swap: bridge risk beyond
///      this point belongs to the DAO, which chose the architecture, never to a founder who has
///      already paid." So `payInstallment` credits the investee the moment their token becomes WETH.
///      Everything after that, batching, bridge failure, delay, is the protocol's problem. There is
///      no path by which a founder who has paid ends up still owing.
///
///      **Stakers don't carry it either.** "Bridge and swap costs are paid from the maintenance
///      slice, so stakers' distributions are never haircut by infrastructure." The bridge fee and
///      the caller's bounty come from a separately funded pool, never from the batch. A batch that
///      arrives home is the full amount the swap produced.
///
///      The third thing this contract decides is the settlement path, and it is the reason the
///      investee holds no election over it (invariant 14). Each deal carries a minimum WETH per
///      installment, set from the home chain at registration. A token swap that cannot clear that
///      minimum within the slippage bound simply reverts, so the token path closes exactly when the
///      pool is too thin. The floor path opens only on a certification of *sustained* illiquidity,
///      which is why it takes repeated failures spread over time rather than one bad quote: a single
///      instant of thin liquidity is something an investee could manufacture, and a day of it is not.
contract Satellite {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    /// @notice §15: batch when accumulated value crosses twenty times the bridge cost.
    uint256 public constant BATCH_FEE_MULTIPLE = 20;

    /// @notice §15: or when the oldest pending repayment exceeds thirty days.
    uint64 public constant BATCH_MAX_AGE = 30 days;

    IERC20 public immutable weth;
    IUniswapV2Router02 public immutable router;

    /// @notice Cross-chain governance executor for this chain.
    /// @dev The home-chain timelock owns the protocol (§14), but it cannot call a function on
    ///      another chain directly. This address must therefore be an executor that acts only on
    ///      messages from that timelock. Pointing it at an ordinary key would put a satellite's
    ///      configuration outside governance, which §14 does not permit, so the deployment must not.
    address public governor;

    /// @notice The messaging adapter. Also the only address permitted to register deals remotely.
    IBridgeAdapter public bridge;

    address public configurer;

    /// @notice §PARAMETERS: 200 bps on repayment swaps, wider than treasury draws because native
    ///         liquidity in an investee's token may be thin and a revert leaves a founder unable to
    ///         discharge. Timelock-tunable.
    uint16 public swapSlippageBps = 200;

    /// @notice Failed attempts required, and the minimum gap between them, before the floor opens.
    uint8 public illiquidityStrikes = 3;
    uint64 public illiquidityGap = 12 hours;

    // =====================================================================
    // Deals
    // =====================================================================

    struct RemoteDeal {
        address token;
        /// @dev Tokens owed per monthly installment, from the escrow's vesting schedule (§8.5).
        uint256 installmentTokens;
        /// @dev Minimum WETH one installment must produce. The escrow sets this; a swap that cannot
        ///      reach it is what "cannot clear the repayment swap within its slippage bound" means.
        uint256 minWethPerInstallment;
        uint32 vintage;
        bool active;
    }

    mapping(uint256 dealId => RemoteDeal) internal _deals;

    /// @notice Illiquidity strikes accrued against a deal, and when the last one was recorded.
    mapping(uint256 dealId => uint8) public strikes;
    mapping(uint256 dealId => uint64) public lastStrikeAt;

    /// @notice Installments the floor path has been certified for and not yet consumed.
    mapping(uint256 dealId => uint16) public floorAuthorised;

    // =====================================================================
    // Batching (§9 step 3)
    // =====================================================================

    Repayment[] internal _pending;
    uint256 public pendingWeth;
    uint64 public oldestPendingAt;

    /// @notice WETH held to pay the caller of `bridgeBatch`. Funded from maintenance, never a batch.
    uint256 public bountyPool;

    /// @notice Bounty paid to whoever bridges a batch.
    uint256 public bridgeBounty = 0.002 ether;

    event DealRegistered(uint256 indexed dealId, address token, uint256 installmentTokens, uint32 vintage);
    event DealDeactivated(uint256 indexed dealId);
    event InstallmentPaid(
        uint256 indexed dealId, address indexed payer, uint16 installments, uint256 tokenIn, uint256 wethOut
    );
    event IlliquidityStrike(uint256 indexed dealId, uint8 strikes, uint256 quoted, uint256 required);
    event FloorAuthorised(uint256 indexed dealId, uint16 installments);
    event FloorSettled(uint256 indexed dealId, uint16 installments);
    event BatchBridged(uint256 entries, uint256 wethAmount, uint256 fee, address indexed caller);
    event BountyFunded(uint256 amount, uint256 pool);
    event ParametersSet(uint16 slippageBps, uint8 strikes, uint64 gap, uint256 bounty);

    error NotGovernor();
    error NotBridge();
    error NotConfigurer();
    error UnknownDeal();
    error DealInactive();
    error ZeroAmount();
    error ZeroAddress();
    error NothingPending();
    error BatchNotReady();
    error StillLiquid();
    error GapNotElapsed();
    error NoFloorAuthority();
    error FeeNotCovered();
    error OutOfRange();

    constructor(IERC20 weth_, IUniswapV2Router02 router_, address governor_) {
        if (address(weth_) == address(0) || address(router_) == address(0) || governor_ == address(0)) {
            revert ZeroAddress();
        }
        weth = weth_;
        router = router_;
        governor = governor_;
        configurer = msg.sender;
    }

    function wire(IBridgeAdapter bridge_) external {
        if (msg.sender != configurer) revert NotConfigurer();
        if (address(bridge_) == address(0)) revert ZeroAddress();
        bridge = bridge_;
        configurer = address(0);
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    // =====================================================================
    // Registration
    // =====================================================================

    /// @notice Register a deal's repayment terms on this chain.
    /// @dev Callable by the bridge, which relays the home chain's escrow, or by governance. The
    ///      minimum WETH per installment comes from the home chain deliberately: it is the figure
    ///      that decides which settlement path is open, and letting this chain compute it would move
    ///      that decision away from the escrow, which §8.5 says holds it.
    function registerDeal(
        uint256 dealId,
        address token,
        uint256 installmentTokens,
        uint256 minWethPerInstallment,
        uint32 vintage
    ) external {
        if (msg.sender != address(bridge) && msg.sender != governor) revert NotBridge();
        if (token == address(0)) revert ZeroAddress();
        if (installmentTokens == 0 || minWethPerInstallment == 0) revert ZeroAmount();

        _deals[dealId] = RemoteDeal(token, installmentTokens, minWethPerInstallment, vintage, true);
        emit DealRegistered(dealId, token, installmentTokens, vintage);
    }

    /// @notice Stop accepting repayments for a deal, for instance once it is fully discharged.
    function deactivateDeal(uint256 dealId) external {
        if (msg.sender != address(bridge) && msg.sender != governor) revert NotBridge();
        _deals[dealId].active = false;
        emit DealDeactivated(dealId);
    }

    // =====================================================================
    // Paying (§9 steps 1 and 2)
    // =====================================================================

    /// @notice Pay installments in the investee's own token.
    /// @dev "This is the entire founder experience: pay the schedule, on the chain they live on."
    ///      Anyone may pay on an investee's behalf; the obligation is the deal's, not the caller's.
    ///
    ///      The swap's minimum-out is derived from the deal's registered minimum, not from a quote
    ///      taken a moment earlier. A bound computed from the pool it is about to trade against
    ///      would be satisfied by definition and would bound nothing.
    function payInstallment(uint256 dealId, uint16 installments) external returns (uint256 wethOut) {
        RemoteDeal storage d = _requireActive(dealId);
        if (installments == 0) revert ZeroAmount();

        uint256 tokenIn = d.installmentTokens * installments;
        uint256 minOut = (d.minWethPerInstallment * installments * (BPS - swapSlippageBps)) / BPS;

        IERC20 token = IERC20(d.token);
        token.safeTransferFrom(msg.sender, address(this), tokenIn);

        address[] memory path = new address[](2);
        path[0] = d.token;
        path[1] = address(weth);

        token.forceApprove(address(router), tokenIn);
        uint256[] memory amounts =
            router.swapExactTokensForTokens(tokenIn, minOut, path, address(this), block.timestamp);
        token.forceApprove(address(router), 0);

        wethOut = amounts[amounts.length - 1];

        // Discharged here, not on arrival home (§9 step 2).
        _queue(Repayment(dealId, d.vintage, installments, wethOut, false));

        emit InstallmentPaid(dealId, msg.sender, installments, tokenIn, wethOut);
    }

    // =====================================================================
    // The floor path (§8.5, invariant 14)
    // =====================================================================

    /// @notice Record a failed swap attempt against a deal. Permissionless.
    /// @dev Deliberately a strike rather than an instant verdict. A quote showing thin liquidity is
    ///      cheap to manufacture: push the pool, certify, settle against the floor at the recorded
    ///      value, unwind. Requiring several failures spaced hours apart means certification tracks
    ///      liquidity that is actually absent rather than liquidity that was absent for one block.
    ///      The whitepaper does not specify how illiquidity is established; this is the shape that
    ///      makes it unprofitable to fake.
    function recordIlliquidity(uint256 dealId, uint16 installments) external {
        RemoteDeal storage d = _requireActive(dealId);
        if (installments == 0) revert ZeroAmount();

        uint64 last = lastStrikeAt[dealId];
        if (last != 0 && block.timestamp < last + illiquidityGap) revert GapNotElapsed();

        uint256 required = (d.minWethPerInstallment * installments * (BPS - swapSlippageBps)) / BPS;

        address[] memory path = new address[](2);
        path[0] = d.token;
        path[1] = address(weth);
        uint256 quoted = _quote(path, d.installmentTokens * installments);
        if (quoted >= required) revert StillLiquid();

        uint8 n = strikes[dealId] + 1;
        strikes[dealId] = n;
        lastStrikeAt[dealId] = uint64(block.timestamp);
        emit IlliquidityStrike(dealId, n, quoted, required);

        if (n >= illiquidityStrikes) {
            strikes[dealId] = 0;
            floorAuthorised[dealId] += installments;
            emit FloorAuthorised(dealId, installments);
        }
    }

    /// @notice Consume floor authority, recording that these installments settle in CODE at home.
    /// @dev No value moves on this chain. The investee pays CODE to the escrow on the home chain at
    ///      the recorded value, and this entry is what tells the escrow it is entitled to. Because
    ///      authority only exists after certification, an investee cannot choose the cheaper of two
    ///      paths in a given month, which is the free option §8.5 refuses them.
    function settleViaFloor(uint256 dealId, uint16 installments) external {
        _requireActive(dealId);
        if (installments == 0) revert ZeroAmount();
        if (floorAuthorised[dealId] < installments) revert NoFloorAuthority();

        floorAuthorised[dealId] -= installments;
        _queue(Repayment(dealId, _deals[dealId].vintage, installments, 0, true));
        emit FloorSettled(dealId, installments);
    }

    // =====================================================================
    // Batching and bridging (§9 step 3)
    // =====================================================================

    /// @notice Whether the batch trigger in §15 is met.
    function batchReady() public view returns (bool ready, uint256 fee) {
        if (_pending.length == 0) return (false, 0);
        fee = bridge.quoteFee(abi.encode(_pending));
        bool byValue = pendingWeth >= fee * BATCH_FEE_MULTIPLE;
        bool byAge = block.timestamp >= oldestPendingAt + BATCH_MAX_AGE;
        ready = byValue || byAge;
    }

    /// @notice Bridge the pending batch. Permissionless, and pays the caller a bounty.
    /// @dev §9: "The bridging function is permissionless and carries a small bounty, so batches move
    ///      without anyone running privileged infrastructure." Both the fee and the bounty come from
    ///      the maintenance-funded pool rather than the batch, so a staker's distribution is the
    ///      whole of what the swap produced.
    function bridgeBatch() external returns (uint256 bridged) {
        (bool ready, uint256 fee) = batchReady();
        if (_pending.length == 0) revert NothingPending();
        if (!ready) revert BatchNotReady();
        if (address(this).balance < fee) revert FeeNotCovered();

        bytes memory payload = abi.encode(_pending);
        bridged = pendingWeth;
        uint256 entries = _pending.length;

        delete _pending;
        pendingWeth = 0;
        oldestPendingAt = 0;

        if (bridged != 0) weth.forceApprove(address(bridge), bridged);
        bridge.send{value: fee}(bridged, payload);
        if (bridged != 0) weth.forceApprove(address(bridge), 0);

        uint256 bounty = bridgeBounty;
        if (bounty > bountyPool) bounty = bountyPool;
        if (bounty != 0) {
            bountyPool -= bounty;
            weth.safeTransfer(msg.sender, bounty);
        }

        emit BatchBridged(entries, bridged, fee, msg.sender);
    }

    /// @notice Top up the bounty pool. Funded from the maintenance slice (§2.2, §9).
    function fundBounty(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        weth.safeTransferFrom(msg.sender, address(this), amount);
        bountyPool += amount;
        emit BountyFunded(amount, bountyPool);
    }

    /// @notice Native gas for bridge fees, also from maintenance.
    receive() external payable {}

    // =====================================================================
    // Governance
    // =====================================================================

    function setParameters(uint16 slippageBps, uint8 strikes_, uint64 gap, uint256 bounty) external onlyGovernor {
        // A zero slippage bound makes every swap revert; above 10% the bound stops protecting the
        // DAO from a bad fill. Fewer than two strikes is a single quote, which is the thing the
        // strike mechanism exists to avoid.
        if (slippageBps == 0 || slippageBps > 1_000) revert OutOfRange();
        if (strikes_ < 2 || strikes_ > 10) revert OutOfRange();
        if (gap < 1 hours || gap > 7 days) revert OutOfRange();
        swapSlippageBps = slippageBps;
        illiquidityStrikes = strikes_;
        illiquidityGap = gap;
        bridgeBounty = bounty;
        emit ParametersSet(slippageBps, strikes_, gap, bounty);
    }

    function setGovernor(address governor_) external onlyGovernor {
        if (governor_ == address(0)) revert ZeroAddress();
        governor = governor_;
    }

    // =====================================================================
    // Views
    // =====================================================================

    function getDeal(uint256 dealId) external view returns (RemoteDeal memory) {
        return _deals[dealId];
    }

    function pendingCount() external view returns (uint256) {
        return _pending.length;
    }

    function pendingAt(uint256 i) external view returns (Repayment memory) {
        return _pending[i];
    }

    // =====================================================================
    // Internals
    // =====================================================================

    function _requireActive(uint256 dealId) internal view returns (RemoteDeal storage d) {
        d = _deals[dealId];
        if (d.token == address(0)) revert UnknownDeal();
        if (!d.active) revert DealInactive();
    }

    function _queue(Repayment memory r) internal {
        if (_pending.length == 0) oldestPendingAt = uint64(block.timestamp);
        _pending.push(r);
        pendingWeth += r.wethAmount;
    }

    /// @dev Router quote, used only to establish that a swap *would* fail. Never used to price
    ///      anything: §11 forbids reading a spot price for protocol pricing, and this reads one to
    ///      detect an absence of liquidity, which is a different question with a different failure
    ///      mode. The strike mechanism is what makes a manipulated answer useless.
    function _quote(address[] memory path, uint256 amountIn) internal view returns (uint256) {
        try this.quoteExternal(path, amountIn) returns (uint256 out) {
            return out;
        } catch {
            return 0;
        }
    }

    function quoteExternal(address[] memory path, uint256 amountIn) external view returns (uint256) {
        uint256[] memory amounts = IQuoter(address(router)).getAmountsOut(amountIn, path);
        return amounts[amounts.length - 1];
    }
}

interface IQuoter {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
}
