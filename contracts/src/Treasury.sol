// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ITreasury} from "./interfaces/ITreasury.sol";
import {IUniswapV2Router02} from "./interfaces/IExternal.sol";

interface ITreasuryOracle {
    function wethToCode(uint256 wethAmount) external view returns (uint256);
    function codeToWeth(uint256 codeAmount) external view returns (uint256);
    function poke() external;
}

/// @title Treasury
/// @notice The autonomous treasury: genesis capital, accrued tax, and every outbound draw (§11).
///
/// @dev "The treasury is nobody's. Excluded from governance weight, spendable only by proposal,
///      drained by no key" (§14). Three properties enforce that here rather than asserting it:
///
///      - No function transfers CODE to an arbitrary address except `spend`, which only the timelock
///        can call, and `fundDraw`, which only the escrow can call and which can only pay the
///        investee the escrow names.
///      - The treasury never holds WETH between transactions. A draw converts and forwards in one
///        call, so there is no standing balance in a second asset for anyone to target.
///      - It cannot stake. That is enforced on the staking vault's side (`barredFromStaking`),
///        because a rule the treasury merely declines to break is not a rule.
///
///      The sizing rule in §8.1 is the substantive economic choice and is worth restating: cheques
///      are a percentage of what remains, not a fixed figure. "Deals priced in external value and
///      paid in CODE make token outflow inversely proportional to price: when the token halves,
///      every deal costs twice the tokens, sell pressure doubles, and the mechanism amplifies its
///      own drawdowns." A percentage of remaining balance decays geometrically, can never exhaust
///      the treasury, and shrinks outflow in weak markets instead of widening it.
contract Treasury is ITreasury {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    /// @notice §15: the per-deal ceiling is 0.5% of the treasury's remaining balance at TWAP.
    uint256 public constant PER_DEAL_BPS = 50;

    /// @notice §15: or a 5 WETH floor, whichever is greater.
    uint256 public constant PER_DEAL_FLOOR_WETH = 5 ether;

    IERC20 public immutable code;
    IERC20 public immutable weth;
    address public immutable timelock;
    IUniswapV2Router02 public immutable router;

    ITreasuryOracle public oracle;
    address public escrow;
    address public configurer;

    /// @notice WETH-denominated allocations reserved by executed proposals and not yet drawn.
    uint256 public committedWeth;

    /// @notice §PARAMETERS: 100 bps on treasury draws. Timelock-tunable.
    uint16 public drawSlippageBps = 100;

    event Committed(uint256 wethAmount, uint256 totalCommitted);
    event Released(uint256 wethAmount, uint256 totalCommitted);
    event DrawFunded(address indexed to, uint256 nominalWeth, uint256 codeSpent, uint256 delivered);
    event Spent(address indexed token, address indexed to, uint256 amount);
    event SlippageSet(uint16 bps);

    error NotTimelock();
    error NotEscrow();
    error NotConfigurer();
    error ZeroAddress();
    error ZeroAmount();
    error OverCommitted();
    error SlippageOutOfRange();
    error InsufficientCode();

    constructor(IERC20 code_, IERC20 weth_, IUniswapV2Router02 router_, address timelock_) {
        if (
            address(code_) == address(0) || address(weth_) == address(0) || address(router_) == address(0)
                || timelock_ == address(0)
        ) revert ZeroAddress();
        code = code_;
        weth = weth_;
        router = router_;
        timelock = timelock_;
        configurer = msg.sender;
    }

    function wire(address escrow_, ITreasuryOracle oracle_) external {
        if (msg.sender != configurer) revert NotConfigurer();
        if (escrow_ == address(0) || address(oracle_) == address(0)) revert ZeroAddress();
        escrow = escrow_;
        oracle = oracle_;
        configurer = address(0);
    }

    modifier onlyEscrow() {
        if (msg.sender != escrow) revert NotEscrow();
        _;
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert NotTimelock();
        _;
    }

    // =====================================================================
    // Sizing (§8.1)
    // =====================================================================

    /// @notice WETH value of treasury CODE not already reserved by a live allocation.
    /// @dev Committed capital is subtracted before the percentage is taken. §8.1 says "0.5% of the
    ///      treasury's remaining balance", and remaining has to mean unreserved: a tranche schedule
    ///      keeps capital committed for months, so counting it as available would let a run of deals
    ///      each size themselves against money the previous ones had already claimed.
    function availableWeth() public view returns (uint256) {
        uint256 balanceWeth = oracle.codeToWeth(code.balanceOf(address(this)));
        return balanceWeth > committedWeth ? balanceWeth - committedWeth : 0;
    }

    /// @notice The largest allocation a single proposal may request.
    function perDealCeiling() public view returns (uint256) {
        uint256 cap = (availableWeth() * PER_DEAL_BPS) / BPS;
        return cap > PER_DEAL_FLOOR_WETH ? cap : PER_DEAL_FLOOR_WETH;
    }

    // =====================================================================
    // Allocation lifecycle
    // =====================================================================

    function commit(uint256 wethAmount) external onlyEscrow {
        if (wethAmount == 0) revert ZeroAmount();
        committedWeth += wethAmount;
        emit Committed(wethAmount, committedWeth);
    }

    function release(uint256 wethAmount) external onlyEscrow {
        if (wethAmount > committedWeth) revert OverCommitted();
        committedWeth -= wethAmount;
        emit Released(wethAmount, committedWeth);
    }

    /// @notice Sell CODE for WETH and forward it to the investee.
    /// @dev Exact-input, deliberately. The CODE to sell is computed at the time-weighted price, and
    ///      the investee receives whatever the pool actually returns. §8.2 requires that separation:
    ///      the obligation is "recorded in WETH at the time-weighted oracle price, never at the
    ///      realised swap output", so pool conditions at the moment of drawing move what is received
    ///      and never what is owed. The escrow records the nominal figure; this function returns the
    ///      realised one so the difference is visible in the event log rather than implied.
    ///
    ///      The minimum-out bound is §11's rule that "a swap that cannot clear its bound reverts
    ///      rather than executing badly". A reverted draw is a retry; a badly executed one is a
    ///      permanent loss of treasury capital.
    function fundDraw(address to, uint256 wethAmount) external onlyEscrow returns (uint256 delivered) {
        if (to == address(0)) revert ZeroAddress();
        if (wethAmount == 0) revert ZeroAmount();

        // Maintain the average on the way past, so a draw is never blocked by nobody having
        // updated the oracle recently.
        oracle.poke();
        uint256 codeIn = oracle.wethToCode(wethAmount);
        if (codeIn > code.balanceOf(address(this))) revert InsufficientCode();

        uint256 minOut = (wethAmount * (BPS - drawSlippageBps)) / BPS;

        committedWeth = committedWeth > wethAmount ? committedWeth - wethAmount : 0;

        address[] memory path = new address[](2);
        path[0] = address(code);
        path[1] = address(weth);

        code.forceApprove(address(router), codeIn);
        uint256[] memory amounts =
            router.swapExactTokensForTokens(codeIn, minOut, path, to, block.timestamp);
        code.forceApprove(address(router), 0);

        delivered = amounts[amounts.length - 1];
        emit DrawFunded(to, wethAmount, codeIn, delivered);
    }

    // =====================================================================
    // Governance
    // =====================================================================

    /// @notice Move any token held here. Timelock only, which is to say by passed proposal only.
    function spend(IERC20 token, address to, uint256 amount) external onlyTimelock {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit Spent(address(token), to, amount);
    }

    function setDrawSlippage(uint16 bps) external onlyTimelock {
        // Zero would make every draw revert; anything above 5% stops being a bound worth having.
        if (bps == 0 || bps > 500) revert SlippageOutOfRange();
        drawSlippageBps = bps;
        emit SlippageSet(bps);
    }
}
