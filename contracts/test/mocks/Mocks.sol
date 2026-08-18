// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IUniswapV2Pair, IUniswapV2Router02, IAggregatorV3} from "../../src/interfaces/IExternal.sol";

contract MockWeth is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Accumulates cumulative prices the way a real v2 pair does, so the oracle under test reads
///      the same shape of data it will read in production.
contract MockPair is IUniswapV2Pair {
    address public token0;
    address public token1;
    uint112 internal reserve0;
    uint112 internal reserve1;
    uint32 internal blockTimestampLast;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    constructor(address t0, address t1) {
        token0 = t0;
        token1 = t1;
        blockTimestampLast = uint32(block.timestamp);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function setReserves(uint112 r0, uint112 r1) external {
        _accumulate();
        reserve0 = r0;
        reserve1 = r1;
    }

    function _accumulate() internal {
        uint32 now32 = uint32(block.timestamp);
        uint32 elapsed = now32 - blockTimestampLast;
        if (elapsed != 0 && reserve0 != 0 && reserve1 != 0) {
            price0CumulativeLast += ((uint256(reserve1) << 112) / reserve0) * elapsed;
            price1CumulativeLast += ((uint256(reserve0) << 112) / reserve1) * elapsed;
        }
        blockTimestampLast = now32;
    }
}

contract MockFeed is IAggregatorV3 {
    uint8 public decimals = 8;
    int256 public answer = 3000e8;

    /// @dev Zero means "always fresh", which is how a live Chainlink aggregator behaves: it updates
    ///      itself. A test that wants to exercise the staleness guard pins a timestamp with `set`.
    uint256 public pinnedAt;

    function setAnswer(int256 answer_) external {
        answer = answer_;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        pinnedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 at = pinnedAt == 0 ? block.timestamp : pinnedAt;
        return (1, answer, at, at, 1);
    }
}

/// @dev Swaps at a settable output ratio so a test can simulate slippage, and honours amountOutMin
///      exactly as a real router does.
contract MockRouter is IUniswapV2Router02 {
    /// @dev Output WETH per input CODE, 18 decimals. Default 1e-5, matching the mock pool.
    uint256 public rate = 1e13;
    MockWeth public immutable weth;

    error TooLittleOut();

    constructor(MockWeth weth_) {
        weth = weth_;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rate) / 1e18;
        if (out < amountOutMin) revert TooLittleOut();
        weth.mint(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256,
        uint256,
        address[] calldata,
        address,
        uint256
    ) external pure {
        revert("unused");
    }
}

contract OraclePriceStub {
    uint256 public codeWeth = 1e13;

    function setCodeWeth(uint256 p) external {
        codeWeth = p;
    }

    function wethToCode(uint256 wethAmount) external view returns (uint256) {
        return (wethAmount * 1e18) / codeWeth;
    }

    function codeToWeth(uint256 codeAmount) external view returns (uint256) {
        return (codeAmount * codeWeth) / 1e18;
    }

    function poke() external {}
}

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A router that swaps at a settable rate out of its own funded balances, so a test can make a
///      pool thin by lowering the rate rather than by modelling reserves. Honours amountOutMin
///      exactly as a real router does, which is what the slippage bounds are tested against.
contract MockDex is IUniswapV2Router02 {
    /// @dev Output per 1e18 of input, 18 decimals.
    mapping(address => mapping(address => uint256)) public rate;

    error TooLittleOut();
    error NoLiquidity();

    function setRate(address tokenIn, address tokenOut, uint256 r) external {
        rate[tokenIn][tokenOut] = r;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        uint256 r = rate[path[0]][path[path.length - 1]];
        if (r == 0) revert NoLiquidity();
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = (amountIn * r) / 1e18;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        uint256 r = rate[tokenIn][tokenOut];
        if (r == 0) revert NoLiquidity();

        uint256 out = (amountIn * r) / 1e18;
        if (out < amountOutMin) revert TooLittleOut();

        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(to, out);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256,
        uint256,
        address[] calldata,
        address,
        uint256
    ) external pure {
        revert("unused");
    }
}
