// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router02} from "./interfaces/IExternal.sol";
import {IRepaymentReceiver, Repayment} from "./interfaces/IBridge.sol";
import {IVintageVault} from "./interfaces/IVintageVault.sol";
import {IEscrow} from "./interfaces/IEscrow.sol";

interface ICodeBurnable3 is IERC20 {
    function burn(uint256 amount) external;
}

interface IReceiverOracle {
    function wethToCode(uint256 wethAmount) external view returns (uint256);
    function poke() external;
}

/// @title Receiver
/// @notice The home-chain end of the repayment path (§9 steps 4 and 5, §16.1 #10).
///
/// @dev §2.3's whole claim about the token rests on this contract working: "Every repayment, from any
///      chain, in any token, ends as buy pressure on CODE and a permanent reduction in supply." Three
///      properties make that true rather than aspirational.
///
///      **Arrival and execution are separated.** A batch landing does not immediately buy CODE.
///      §9 requires "large purchases split across intervals", so arrivals queue and a permissionless
///      call drains the queue one entry at a time with a minimum gap between them. A single large
///      market buy would move the price against the DAO and hand a sandwich to whoever was watching
///      the bridge, which is a strange way to spend a portfolio return.
///
///      **Each entry keeps its own vintage.** The queue holds per-entry WETH rather than a pooled
///      total, so the CODE bought with a given repayment is credited to the season that funded that
///      deal (§10.1). Pooling and apportioning afterwards would be arithmetically equivalent only
///      when every entry clears at the same price, which is exactly what splitting across intervals
///      guarantees will not happen.
///
///      **The split is fixed in code.** 50% burned, 50% to the vintage vault (§15). Neither share is
///      a parameter, because the deflation claim in §2.3 is a property of the token rather than a
///      governance preference.
contract Receiver is IRepaymentReceiver {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    /// @notice §15: half of every repayment is burned, half goes to the funding vintage.
    uint256 public constant BURN_BPS = 5_000;

    ICodeBurnable3 public immutable code;
    IERC20 public immutable weth;
    IUniswapV2Router02 public immutable router;
    IVintageVault public immutable vault;
    IEscrow public immutable escrow;
    address public immutable timelock;

    IReceiverOracle public oracle;

    /// @notice The messaging adapters permitted to deliver batches, one per satellite chain.
    mapping(address adapter => bool) public isAdapter;

    address public configurer;

    /// @notice §PARAMETERS: 150 bps on buybacks. Timelock-tunable.
    uint16 public buybackSlippageBps = 150;

    /// @notice Minimum gap between buyback executions, which is what "split across intervals" means.
    uint64 public buybackInterval = 10 minutes;

    /// @notice Largest WETH amount converted in one execution. Anything above it is split.
    uint256 public maxPerExecution = 5 ether;

    uint64 public lastExecutionAt;

    /// @notice Arrivals awaiting conversion, oldest first.
    Repayment[] internal _queue;
    uint256 public queueHead;

    /// @notice WETH held against the queue, so a stray transfer cannot be mistaken for a repayment.
    uint256 public queuedWeth;

    event AdapterSet(address indexed adapter, bool allowed);
    event BatchReceived(uint32 indexed srcChainId, uint256 entries, uint256 wethAmount);
    event FloorRecorded(uint256 indexed dealId, uint32 indexed vintage, uint16 installments);
    event BuybackExecuted(
        uint256 indexed dealId, uint32 indexed vintage, uint256 wethIn, uint256 codeOut, uint256 burned, uint256 toVault
    );
    event QueueSplit(uint256 indexed dealId, uint256 executed, uint256 remaining);
    event ParametersSet(uint16 slippageBps, uint64 interval, uint256 maxPerExecution);

    error NotAdapter();
    error NotTimelock();
    error NotConfigurer();
    error ZeroAddress();
    error ZeroAmount();
    error QueueEmpty();
    error IntervalNotElapsed();
    error WethNotDelivered();
    error OutOfRange();

    constructor(
        ICodeBurnable3 code_,
        IERC20 weth_,
        IUniswapV2Router02 router_,
        IVintageVault vault_,
        IEscrow escrow_,
        address timelock_
    ) {
        if (
            address(code_) == address(0) || address(weth_) == address(0) || address(router_) == address(0)
                || address(vault_) == address(0) || timelock_ == address(0)
        ) revert ZeroAddress();
        code = code_;
        weth = weth_;
        router = router_;
        vault = vault_;
        escrow = escrow_;
        timelock = timelock_;
        configurer = msg.sender;
    }

    function wire(IReceiverOracle oracle_, address[] calldata adapters) external {
        if (msg.sender != configurer) revert NotConfigurer();
        if (address(oracle_) == address(0)) revert ZeroAddress();
        oracle = oracle_;
        for (uint256 i; i < adapters.length; ++i) {
            isAdapter[adapters[i]] = true;
            emit AdapterSet(adapters[i], true);
        }
        configurer = address(0);
    }

    // =====================================================================
    // Arrival (§9 step 4)
    // =====================================================================

    /// @notice Accept a bridged batch. Adapter-only.
    /// @dev The WETH must already be here. Checking the balance rather than trusting the argument
    ///      means a misreporting adapter cannot enqueue value it never delivered, which would let it
    ///      drain the queue's WETH through subsequent legitimate arrivals.
    ///
    ///      Floor entries carry no WETH by construction: they settled in CODE on this chain, so there
    ///      is nothing to convert and they are recorded against the obligation immediately.
    function receiveBatch(uint32 srcChainId, uint256 wethAmount, bytes calldata payload) external {
        if (!isAdapter[msg.sender]) revert NotAdapter();

        uint256 delivered = weth.balanceOf(address(this));
        if (delivered < queuedWeth + wethAmount) revert WethNotDelivered();

        Repayment[] memory entries = abi.decode(payload, (Repayment[]));
        uint256 accounted;

        for (uint256 i; i < entries.length; ++i) {
            Repayment memory r = entries[i];
            if (r.wethAmount == 0) {
                // A floor settlement. Nothing to buy; the obligation is discharged as reported.
                escrow.recordInstallments(r.dealId, r.installments, 0, r.viaFloor);
                emit FloorRecorded(r.dealId, r.vintage, r.installments);
                continue;
            }
            accounted += r.wethAmount;
            _queue.push(r);
        }

        queuedWeth += accounted;
        emit BatchReceived(srcChainId, entries.length, accounted);
    }

    // =====================================================================
    // Conversion and split (§9 step 5)
    // =====================================================================

    /// @notice Whether a buyback may run now.
    function buybackReady() public view returns (bool) {
        return queueHead < _queue.length && block.timestamp >= lastExecutionAt + buybackInterval;
    }

    /// @notice Convert the next queued repayment to CODE, burn half, credit half to its vintage.
    /// @dev Permissionless and unbountied. Unlike the bridge, this call costs one transaction on the
    ///      home chain and benefits every holder of the vintage it credits, so the people with a
    ///      claim on it are already motivated to make it. A bounty here would be paid out of the very
    ///      distribution it was meant to deliver.
    ///
    ///      An entry larger than `maxPerExecution` is partially executed and the remainder left at
    ///      the head of the queue, which is §9's "large purchases split across intervals" applied
    ///      within a single repayment as well as across several.
    function executeBuyback() external returns (uint256 codeOut) {
        if (queueHead >= _queue.length) revert QueueEmpty();
        if (block.timestamp < lastExecutionAt + buybackInterval) revert IntervalNotElapsed();

        lastExecutionAt = uint64(block.timestamp);

        uint256 head = queueHead;
        uint256 slice = _queue[head].wethAmount;
        bool isPartial = slice > maxPerExecution;
        if (isPartial) slice = maxPerExecution;

        codeOut = _convert(slice);
        queuedWeth -= slice;

        _advance(head, slice, isPartial);
        _split(head, codeOut, slice);
    }

    /// @dev The bounded swap. Split out because the whole of `executeBuyback` inline exceeds the
    ///      EVM's reachable stack depth.
    function _convert(uint256 slice) internal returns (uint256 codeOut) {
        oracle.poke();
        uint256 minOut = (oracle.wethToCode(slice) * (BPS - buybackSlippageBps)) / BPS;

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(code);

        weth.forceApprove(address(router), slice);
        uint256[] memory amounts = router.swapExactTokensForTokens(slice, minOut, path, address(this), block.timestamp);
        weth.forceApprove(address(router), 0);
        codeOut = amounts[amounts.length - 1];
    }

    /// @dev Report the obligation only when the last of a repayment converts, so a repayment split
    ///      across several executions is not credited to the escrow more than once.
    function _advance(uint256 head, uint256 slice, bool isPartial) internal {
        Repayment storage r = _queue[head];
        if (isPartial) {
            r.wethAmount -= slice;
            emit QueueSplit(r.dealId, slice, r.wethAmount);
            return;
        }
        escrow.recordInstallments(r.dealId, r.installments, slice, false);
        ++queueHead;
    }

    /// @dev 50 / 50, fixed in code rather than governed (§15, §2.3).
    function _split(uint256 head, uint256 codeOut, uint256 slice) internal {
        Repayment storage r = _queue[head];
        uint256 burned = (codeOut * BURN_BPS) / BPS;
        uint256 toVault = codeOut - burned;

        if (burned != 0) code.burn(burned);
        if (toVault != 0) {
            IERC20(address(code)).forceApprove(address(vault), toVault);
            vault.creditVintage(r.vintage, toVault);
            IERC20(address(code)).forceApprove(address(vault), 0);
        }
        emit BuybackExecuted(r.dealId, r.vintage, slice, codeOut, burned, toVault);
    }

    // =====================================================================
    // Governance
    // =====================================================================

    function setAdapter(address adapter, bool allowed) external {
        if (msg.sender != timelock) revert NotTimelock();
        if (adapter == address(0)) revert ZeroAddress();
        isAdapter[adapter] = allowed;
        emit AdapterSet(adapter, allowed);
    }

    function setParameters(uint16 slippageBps, uint64 interval, uint256 maxPerExecution_) external {
        if (msg.sender != timelock) revert NotTimelock();
        // Zero slippage reverts every buyback; above 5% stops bounding anything worth bounding.
        if (slippageBps == 0 || slippageBps > 500) revert OutOfRange();
        // A zero interval removes the splitting that §9 requires; a day of it strands returns.
        if (interval < 1 minutes || interval > 12 hours) revert OutOfRange();
        if (maxPerExecution_ == 0) revert ZeroAmount();
        buybackSlippageBps = slippageBps;
        buybackInterval = interval;
        maxPerExecution = maxPerExecution_;
        emit ParametersSet(slippageBps, interval, maxPerExecution_);
    }

    // =====================================================================
    // Views
    // =====================================================================

    function queueLength() external view returns (uint256) {
        return _queue.length - queueHead;
    }

    function queueAt(uint256 i) external view returns (Repayment memory) {
        return _queue[queueHead + i];
    }
}
