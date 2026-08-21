// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Code} from "../src/Code.sol";
import {DCode} from "../src/DCode.sol";
import {CodeTimelock} from "../src/CodeTimelock.sol";
import {Treasury, ITreasuryOracle} from "../src/Treasury.sol";
import {Targets} from "../src/Targets.sol";
import {Oracle} from "../src/Oracle.sol";
import {Escrow} from "../src/Escrow.sol";
import {VintageVault, ICodeBurnable} from "../src/VintageVault.sol";
import {Saine, ICodeBurn, ISeasonClock} from "../src/Saine.sol";
import {Governor, ICodeBurnable2, ISaineOpen, ITreasuryCeiling} from "../src/Governor.sol";
import {Receiver, ICodeBurnable3, IReceiverOracle} from "../src/Receiver.sol";

import {IDCode} from "../src/interfaces/IDCode.sol";
import {IVintageVault} from "../src/interfaces/IVintageVault.sol";
import {IEscrow} from "../src/interfaces/IEscrow.sol";
import {IOracle} from "../src/interfaces/ISaineConsumer.sol";
import {IUniswapV2Pair, IUniswapV2Router02, IAggregatorV3} from "../src/interfaces/IExternal.sol";

/// @notice Everything the deployment needs from outside the protocol.
struct DeployConfig {
    address weth;
    address router;
    /// @dev The canonical CODE/WETH pool, designated at deployment (§12).
    address pair;
    address ethUsdFeed;
    /// @dev Receives the whole supply, then splits it per §2.1. Should be the deployer.
    address genesis;
    address saleAndLiquidity;
    address team;
    address ops;
    /// @dev Team-held, powerless, funded only by the 0.09% slice (§14).
    address maintenance;
    /// @dev Phase one operator of all ten agent slots (§5.8).
    address agentOperator;
    address[10] agentKeys;
    bytes32[10] agentProviders;
}

struct Deployed {
    Code code;
    DCode dcode;
    CodeTimelock timelock;
    Treasury treasury;
    Targets targets;
    Oracle oracle;
    Escrow escrow;
    VintageVault vault;
    Saine saine;
    Governor governor;
    Receiver receiver;
}

/// @title DeployLib
/// @notice The single deployment path, used by the script and by the integration tests.
///
/// @dev Two constructor dependencies are circular and neither can be fixed by wiring afterwards,
///      because both are immutable by design: the token needs the treasury it pays tax to (§2.2) and
///      the timelock needs the governor that proposes to it (§14 leaves no deployer admin behind).
///      So the addresses are computed from the deployer's nonce sequence before anything exists, and
///      every prediction is asserted immediately after.
///
///      The order below is load-bearing. Changing it silently breaks the predictions, which is why
///      the integration tests call this function rather than reimplementing it: a reordering shows up
///      as a failing test instead of as a live system wired to empty addresses.
library DeployLib {
    /// @dev Number of contracts deployed, in order. Index positions are referenced below.
    uint256 internal constant COUNT = 11;

    function predict(address deployer) internal view returns (address[COUNT] memory a) {
        uint256 n = vmGetNonce(deployer);
        for (uint256 i; i < COUNT; ++i) {
            a[i] = computeCreateAddress(deployer, n + i);
        }
    }

    function deploy(DeployConfig memory cfg, address deployer) internal returns (Deployed memory d) {
        address[COUNT] memory a = predict(deployer);

        //  0 code      1 dcode    2 timelock  3 treasury  4 targets  5 oracle
        //  6 escrow    7 vault    8 saine     9 governor  10 receiver
        d.code = new Code(cfg.genesis, a[3], cfg.maintenance);
        d.dcode = new DCode(IERC20(a[0]));
        d.timelock = new CodeTimelock(a[9]);
        d.treasury = new Treasury(IERC20(a[0]), IERC20(cfg.weth), IUniswapV2Router02(cfg.router), a[2]);
        d.targets = new Targets(a[2]);
        d.oracle = new Oracle(IUniswapV2Pair(cfg.pair), IAggregatorV3(cfg.ethUsdFeed), a[0], cfg.weth, a[2]);
        d.escrow = new Escrow(a[2], d.treasury);
        d.vault = new VintageVault(ICodeBurnable(a[0]), IDCode(a[1]), a[3], a[2]);
        d.saine = new Saine(ICodeBurn(a[0]), a[2], ISeasonClock(a[1]));
        d.governor = new Governor(ICodeBurnable2(a[0]), IDCode(a[1]), d.timelock, d.escrow, d.targets);
        d.receiver = new Receiver(
            ICodeBurnable3(a[0]),
            IERC20(cfg.weth),
            IUniswapV2Router02(cfg.router),
            IVintageVault(a[7]),
            IEscrow(a[6]),
            a[2]
        );

        require(address(d.code) == a[0], "predict: code");
        require(address(d.dcode) == a[1], "predict: dcode");
        require(address(d.timelock) == a[2], "predict: timelock");
        require(address(d.treasury) == a[3], "predict: treasury");
        require(address(d.targets) == a[4], "predict: targets");
        require(address(d.oracle) == a[5], "predict: oracle");
        require(address(d.escrow) == a[6], "predict: escrow");
        require(address(d.vault) == a[7], "predict: vault");
        require(address(d.saine) == a[8], "predict: saine");
        require(address(d.governor) == a[9], "predict: governor");
        require(address(d.receiver) == a[10], "predict: receiver");
    }

    function wire(Deployed memory d, DeployConfig memory cfg) internal {
        // Invariant 3: no protocol contract may ever hold governance weight.
        address[] memory protocolContracts = new address[](6);
        protocolContracts[0] = address(d.treasury);
        protocolContracts[1] = address(d.escrow);
        protocolContracts[2] = address(d.vault);
        protocolContracts[3] = address(d.saine);
        protocolContracts[4] = address(d.governor);
        protocolContracts[5] = address(d.receiver);
        d.dcode.wire(address(d.governor), IVintageVault(address(d.vault)), protocolContracts);

        d.escrow.wire(address(d.saine), address(d.receiver));
        d.treasury.wire(address(d.escrow), ITreasuryOracle(address(d.oracle)));
        d.vault.wire(address(d.receiver));
        d.governor.wire(ISaineOpen(address(d.saine)), IOracle(address(d.oracle)), ITreasuryCeiling(address(d.treasury)));
        d.saine
            .wire(
                address(d.governor),
                address(d.escrow),
                IOracle(address(d.oracle)),
                cfg.agentOperator,
                cfg.agentKeys,
                cfg.agentProviders
            );
        // No bridge adapters at genesis. Governance adds them per satellite chain as deals require
        // (§12: "Satellite escrows deploy per investee chain as deals require").
        d.receiver.wire(IReceiverOracle(address(d.oracle)), new address[](0));

        // §6.2: a proposal's targets are either registered or flagged. The protocol's own funding and
        // halt entry points are registered so an ordinary deal needs no review flag.
        address[] memory t = new address[](2);
        bytes4[] memory sel = new bytes4[](2);
        t[0] = address(d.escrow);
        sel[0] = Escrow.registerDeal.selector;
        t[1] = address(d.escrow);
        sel[1] = Escrow.halt.selector;
        d.targets.seed(t, sel);

        // §2.2: protocol-internal movements are untaxed. The router is exempt so treasury draws and
        // buybacks are not tolled on the way through the pool.
        address[] memory ex = new address[](9);
        ex[0] = cfg.genesis;
        ex[1] = address(d.dcode);
        ex[2] = address(d.treasury);
        ex[3] = address(d.escrow);
        ex[4] = address(d.vault);
        ex[5] = address(d.saine);
        ex[6] = address(d.governor);
        ex[7] = address(d.receiver);
        ex[8] = cfg.router;
        d.code.setExempt(ex);
        d.code.seal();
    }

    /// @notice Distribute the supply per §2.1: 50 treasury / 40 sale and LP / 6 team / 4 ops.
    /// @dev Must be called by `cfg.genesis`, which holds the whole supply after construction.
    function distribute(Deployed memory d, DeployConfig memory cfg) internal {
        uint256 total = d.code.TOTAL_SUPPLY();
        d.code.transfer(address(d.treasury), (total * 50) / 100);
        d.code.transfer(cfg.saleAndLiquidity, (total * 40) / 100);
        d.code.transfer(cfg.team, (total * 6) / 100);
        d.code.transfer(cfg.ops, (total * 4) / 100);
        require(d.code.balanceOf(cfg.genesis) == 0, "distribute: remainder");
    }

    // --- cheatcode shims, so this library works in both a script and a test ---

    function vmGetNonce(address who) private view returns (uint256) {
        (bool ok, bytes memory out) = address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D)
            .staticcall(abi.encodeWithSignature("getNonce(address)", who));
        require(ok, "getNonce");
        return abi.decode(out, (uint256));
    }

    function computeCreateAddress(address deployer, uint256 nonce) private pure returns (address) {
        // RLP encoding of [deployer, nonce], per EIP-161. Only the ranges a real deployment reaches.
        if (nonce == 0x00) {
            return
                address(
                    uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x80)))))
                );
        }
        if (nonce <= 0x7f) {
            return
                address(
                    uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce)))))
                );
        }
        if (nonce <= type(uint8).max) {
            return address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xd7), bytes1(0x94), deployer, bytes1(0x81), uint8(nonce)))
                    )
                )
            );
        }
        if (nonce <= type(uint16).max) {
            return address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xd8), bytes1(0x94), deployer, bytes1(0x82), uint16(nonce)))
                    )
                )
            );
        }
        revert("nonce too high");
    }
}

/// @notice `forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast` (or `robinhood`)
contract Deploy is Script {
    function run() external returns (Deployed memory d) {
        DeployConfig memory cfg = _config();
        address deployer = msg.sender;

        vm.startBroadcast();
        d = DeployLib.deploy(cfg, deployer);
        DeployLib.wire(d, cfg);
        DeployLib.distribute(d, cfg);
        vm.stopBroadcast();
    }

    /// @dev Read from the environment so nothing about a live deployment is hardcoded here.
    function _config() internal view returns (DeployConfig memory cfg) {
        cfg.weth = vm.envAddress("WETH");
        cfg.router = vm.envAddress("V2_ROUTER");
        cfg.pair = vm.envAddress("CANONICAL_PAIR");
        cfg.ethUsdFeed = vm.envAddress("ETH_USD_FEED");
        cfg.genesis = msg.sender;
        cfg.saleAndLiquidity = vm.envAddress("SALE_AND_LP");
        cfg.team = vm.envAddress("TEAM");
        cfg.ops = vm.envAddress("OPS");
        cfg.maintenance = vm.envAddress("MAINTENANCE");
        cfg.agentOperator = vm.envAddress("AGENT_OPERATOR");

        address[] memory keys = vm.envAddress("AGENT_KEYS", ",");
        bytes32[] memory providers = vm.envBytes32("AGENT_PROVIDERS", ",");
        require(keys.length == 10 && providers.length == 10, "config: ten slots");
        for (uint256 i; i < 10; ++i) {
            cfg.agentKeys[i] = keys[i];
            cfg.agentProviders[i] = providers[i];
        }
    }
}
