// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployConfig, Deployed, DeployLib} from "../../script/Deploy.s.sol";
import {Escrow} from "../../src/Escrow.sol";
import {Satellite} from "../../src/Satellite.sol";
import {Saine} from "../../src/Saine.sol";
import {Governor} from "../../src/Governor.sol";
import {StargateSatelliteAdapter} from "../../src/StargateSatelliteAdapter.sol";
import {StargateHomeAdapter} from "../../src/StargateHomeAdapter.sol";
import {IBridgeAdapter, IRepaymentReceiver, Repayment} from "../../src/interfaces/IBridge.sol";
import {IStargate, ComposeMsgCodec} from "../../src/interfaces/ILayerZero.sol";
import {IUniswapV2Pair, IUniswapV2Router02, IAggregatorV3} from "../../src/interfaces/IExternal.sol";
import {MockToken, MockPair, MockFeed, MockDex} from "../mocks/Mocks.sol";
import {MockStargate} from "../mocks/StargateMocks.sol";

/// @dev The return leg, end to end, against the real contracts rather than test doubles.
///
///      §9's claim is that "every repayment, from any chain, in any token, ends as buy pressure on
///      CODE and a permanent reduction in supply". Every other test checks one link of that. This one
///      checks the whole chain: an investee pays their own token on their own chain, and the assertions
///      at the end are about CODE's total supply falling and a specific season's vintage being
///      credited, with nothing stranded anywhere in between.
///
///      It also exercises `DeployLib` rather than reimplementing the wiring, so a mistake in the
///      deployment procedure fails here.
contract CrossChainTest is Test {
    Deployed internal p;

    // Home chain externals
    MockToken internal weth;
    MockDex internal dex;
    MockPair internal pair;
    MockFeed internal feed;

    // Satellite chain
    Satellite internal satellite;
    MockToken internal investeeToken;
    MockDex internal satDex;
    MockToken internal satWeth;

    // Bridge
    MockStargate internal stargate;
    StargateSatelliteAdapter internal satAdapter;
    StargateHomeAdapter internal homeAdapter;
    address internal lzEndpoint = makeAddr("lzEndpoint");

    address internal genesis;
    address internal maintenance = makeAddr("maintenance");
    address internal agentOperator = makeAddr("agentOperator");
    address internal investee = makeAddr("investee");
    address internal keeper = makeAddr("keeper");
    address internal satGovernor = makeAddr("satGovernor");
    address internal saleAndLp = makeAddr("saleAndLp");
    address internal team = makeAddr("team");
    address internal ops = makeAddr("ops");

    uint32 internal constant HOME_EID = 30_110;
    uint32 internal constant SAT_EID = 30_111;
    uint32 internal constant VINTAGE = 1;

    uint256 internal constant CODE_PER_WETH = 100_000e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        genesis = address(this);

        weth = new MockToken("Wrapped Ether", "WETH");
        dex = new MockDex();
        feed = new MockFeed();

        // The canonical pool has to exist before the oracle reads it, and the pool needs the token's
        // address, so the pair is deployed against a predicted CODE address. Offset 1 because exactly
        // one CREATE (the pair itself) happens between this call and `Code`'s construction.
        address predictedCode = _predictNext(1);
        pair = new MockPair(predictedCode, address(weth));
        pair.setReserves(1_000_000e18, 10e18);

        DeployConfig memory cfg;
        cfg.weth = address(weth);
        cfg.router = address(dex);
        cfg.pair = address(pair);
        cfg.ethUsdFeed = address(feed);
        cfg.genesis = genesis;
        cfg.saleAndLiquidity = saleAndLp;
        cfg.team = team;
        cfg.ops = ops;
        cfg.maintenance = maintenance;
        cfg.agentOperator = agentOperator;
        bytes32[5] memory pool =
            [bytes32("anthropic"), bytes32("openai"), bytes32("google"), bytes32("meta"), bytes32("mistral")];
        for (uint256 i; i < 10; ++i) {
            cfg.agentKeys[i] = vm.addr(0xA11CE + i);
            cfg.agentProviders[i] = pool[i % 5];
        }

        p = DeployLib.deploy(cfg, genesis);
        DeployLib.wire(p, cfg);
        DeployLib.distribute(p, cfg);

        assertEq(address(p.code), predictedCode, "the pair was bound to the right token");

        // Home pool, both directions: 1 WETH buys 100,000 CODE, and 1 CODE sells for 0.00001 WETH.
        // The treasury needs the sell side for draws (§8.2); the receiver needs the buy side for
        // buybacks (§9).
        dex.setRate(address(weth), address(p.code), CODE_PER_WETH);
        dex.setRate(address(p.code), address(weth), 1e13);
        vm.prank(saleAndLp);
        p.code.transfer(address(dex), 50_000_000e18);

        vm.warp(block.timestamp + 31 minutes);
        p.oracle.update();

        _deploySatellite();
        _seatElectorate();
    }

    function _predictNext(uint256 offset) internal view returns (address) {
        return vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + offset);
    }

    function _deploySatellite() internal {
        satWeth = new MockToken("Satellite WETH", "WETH");
        investeeToken = new MockToken("Investee", "INV");
        satDex = new MockDex();
        stargate = new MockStargate(IERC20(address(satWeth)), IERC20(address(weth)));

        satellite = new Satellite(IERC20(address(satWeth)), IUniswapV2Router02(address(satDex)), satGovernor);

        homeAdapter = new StargateHomeAdapter(
            IERC20(address(weth)),
            IRepaymentReceiver(address(p.receiver)),
            lzEndpoint,
            address(stargate),
            address(p.timelock)
        );
        satAdapter = new StargateSatelliteAdapter(
            IStargate(address(stargate)),
            IERC20(address(satWeth)),
            address(satellite),
            HOME_EID,
            address(homeAdapter),
            satGovernor
        );
        satellite.wire(IBridgeAdapter(address(satAdapter)));

        // Governance registers the satellite and the adapter on the home side.
        vm.startPrank(address(p.timelock));
        homeAdapter.registerSatellite(SAT_EID, address(satAdapter));
        p.receiver.setAdapter(address(homeAdapter), true);
        vm.stopPrank();

        // Satellite pool: 1,000 INV buys 1 WETH.
        satDex.setRate(address(investeeToken), address(satWeth), 1e15);
        satWeth.mint(address(satDex), 10_000 ether);

        // Maintenance funds the crossing on both sides (§9).
        satWeth.mint(maintenance, 100 ether);
        weth.mint(maintenance, 100 ether);
        vm.startPrank(maintenance);
        satWeth.approve(address(satellite), type(uint256).max);
        satellite.fundBounty(1 ether);
        weth.approve(address(homeAdapter), type(uint256).max);
        homeAdapter.fundBuffer(1 ether);
        vm.stopPrank();
        vm.deal(address(satellite), 10 ether);
    }

    function _seatElectorate() internal {
        for (uint256 i; i < 50; ++i) {
            _stake(makeAddr(string.concat("whale", vm.toString(i))), 1_000_000e18 + (50 - i) * 1e18, saleAndLp);
        }
        for (uint256 i; i < 8; ++i) {
            _stake(makeAddr(string.concat("many", vm.toString(i))), 10_000e18, saleAndLp);
        }
        p.dcode.openFirstSeason();
    }

    /// @dev Stakes whatever actually arrived, not the nominal amount. Transfers out of the sale
    ///      allocation are taxed 0.49% like any other (§2.2 exempts only protocol-internal movement),
    ///      so a staker receives slightly less than was sent. Proportional, so the Guardian ordering
    ///      is unaffected.
    function _stake(address who, uint256 amount, address from) internal {
        vm.prank(from);
        p.code.transfer(who, amount);
        uint256 received = p.code.balanceOf(who);
        vm.startPrank(who);
        p.code.approve(address(p.dcode), received);
        p.dcode.stake(received);
        vm.stopPrank();
    }

    // =================================================================
    // Deployment
    // =================================================================

    function test_deploy_wiresEverySeamCorrectly() public view {
        assertEq(p.dcode.governor(), address(p.governor));
        assertEq(address(p.dcode.vault()), address(p.vault));
        assertEq(p.escrow.saine(), address(p.saine));
        assertEq(p.escrow.receiver(), address(p.receiver));
        assertEq(p.treasury.escrow(), address(p.escrow));
        assertEq(p.vault.receiver(), address(p.receiver));
        assertEq(address(p.governor.saine()), address(p.saine));
        assertEq(p.saine.governor(), address(p.governor));

        // Every configurer is spent, so nothing can be rewired outside governance.
        assertEq(p.code.configurer(), address(0));
        assertEq(p.dcode.configurer(), address(0));
        assertEq(p.escrow.configurer(), address(0));
        assertEq(p.treasury.configurer(), address(0));
        assertEq(p.vault.configurer(), address(0));
        assertEq(p.saine.configurer(), address(0));
        assertEq(p.governor.configurer(), address(0));
        assertEq(p.receiver.configurer(), address(0));
        assertEq(p.targets.configurer(), address(0));
    }

    function test_deploy_distributesSupplyPerSection2point1() public view {
        uint256 total = p.code.TOTAL_SUPPLY();
        // At least half. The treasury also accrues the 0.40% slice of every taxed transfer (§2.2),
        // and seating the electorate produced a few hundred of those, so an equality check here would
        // be asserting that the tax does not work.
        assertGe(p.code.balanceOf(address(p.treasury)), (total * 50) / 100);
        assertEq(p.code.balanceOf(team), (total * 6) / 100);
        assertEq(p.code.balanceOf(ops), (total * 4) / 100);
        assertEq(p.code.balanceOf(genesis), 0, "the deployer keeps nothing");
    }

    function test_deploy_treasuryHoldsNoGovernanceWeight() public {
        // §2.4 and invariant 3, at the only door in.
        vm.prank(address(p.treasury));
        vm.expectRevert(abi.encodeWithSignature("ProtocolAddress()"));
        p.dcode.stake(1e18);
    }

    // =================================================================
    // The return leg, end to end (§9)
    // =================================================================

    // -----------------------------------------------------------------
    // Driving a real deal into the escrow
    // -----------------------------------------------------------------

    bytes32 internal constant COMMIT_TYPEHASH =
        keccak256("Commit(uint256 roundId,uint8 slot,bytes32 commitment,bytes32 modelHash)");
    bytes32 internal constant REVEAL_TYPEHASH =
        keccak256("Reveal(uint256 roundId,uint8 slot,bool verdict,bytes32 reasonHash,bytes32 salt)");
    bytes32 internal constant REASON = keccak256("reason:tokenomics");

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", p.saine.domainSeparator(), structHash));
    }

    function _sign(uint256 key, bytes32 d) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s2) = vm.sign(key, d);
        return abi.encodePacked(r, s2, v);
    }

    function _salt(uint8 slot) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("salt", slot));
    }

    function _commitAll(uint256 roundId) internal {
        Saine.CommitAttestation[] memory atts = new Saine.CommitAttestation[](10);
        bytes[] memory sigs = new bytes[](10);
        for (uint8 i; i < 10; ++i) {
            atts[i] =
                Saine.CommitAttestation(roundId, i, keccak256(abi.encode(true, REASON, _salt(i))), keccak256("model"));
            sigs[i] = _sign(
                0xA11CE + i,
                _digest(keccak256(abi.encode(COMMIT_TYPEHASH, roundId, i, atts[i].commitment, atts[i].modelHash)))
            );
        }
        p.saine.submitCommits(atts, sigs);
    }

    function _revealAll(uint256 roundId) internal {
        Saine.RevealAttestation[] memory atts = new Saine.RevealAttestation[](10);
        bytes[] memory sigs = new bytes[](10);
        for (uint8 i; i < 10; ++i) {
            atts[i] = Saine.RevealAttestation(roundId, i, true, REASON, _salt(i));
            sigs[i] =
                _sign(0xA11CE + i, _digest(keccak256(abi.encode(REVEAL_TYPEHASH, roundId, i, true, REASON, _salt(i)))));
        }
        p.saine.submitReveals(atts, sigs);
    }

    function _bondAgents() internal {
        vm.prank(saleAndLp);
        p.code.transfer(agentOperator, 1_000_000e18);
        vm.startPrank(agentOperator);
        p.code.approve(address(p.saine), type(uint256).max);
        uint256 required = p.saine.bondRequirement();
        for (uint8 i; i < 10; ++i) {
            p.saine.postBond(i, required);
        }
        vm.stopPrank();
    }

    function _terms() internal view returns (Escrow.DealTerms memory t) {
        t.investee = investee;
        t.vintage = p.dcode.currentSeason();
        t.allocationWeth = 20 ether;
        t.supplyBps = 500;
        t.vestingMonths = 24;
        t.manifestHash = keccak256("manifest");
        t.milestones[0] = keccak256("audit");
        t.milestones[1] = keccak256("mainnet");
        t.windowEnds[0] = uint64(block.timestamp + 120 days);
        t.windowEnds[1] = uint64(block.timestamp + 300 days);
    }

    /// @dev Runs the whole origination path so the escrow holds deal 1 with a live obligation, which
    ///      is what makes the repayment assertions below meaningful rather than mocked.
    function _fundADeal() internal {
        _bondAgents();

        address guardian = makeAddr("whale0");
        vm.prank(saleAndLp);
        p.code.transfer(guardian, 500_000e18);
        vm.prank(guardian);
        p.code.approve(address(p.governor), type(uint256).max);

        Governor.ProposalInput memory input;
        input.kind = Governor.Kind.Funding;
        input.targets = new address[](1);
        input.values = new uint256[](1);
        input.calldatas = new bytes[](1);
        input.targets[0] = address(p.escrow);
        input.calldatas[0] = abi.encodeCall(Escrow.registerDeal, (_terms()));
        input.manifestHash = keccak256("manifest");
        input.manifestInvestee = investee;
        input.descriptionUri = "ipfs://deal";

        vm.prank(guardian);
        uint256 id = p.governor.propose(input);

        for (uint256 i; i < 3; ++i) {
            vm.prank(makeAddr(string.concat("many", vm.toString(i))));
            p.governor.castVote(id, true);
        }

        vm.warp(block.timestamp + 5 days + 1);
        p.governor.closeVote(id);

        uint256 round = p.governor.getProposal(id).saineRound;
        _commitAll(round);
        vm.warp(block.timestamp + 24 hours + 1);
        _revealAll(round);
        vm.warp(block.timestamp + 24 hours + 1);
        p.saine.settleRound(round);

        p.governor.queue(id);
        vm.warp(block.timestamp + 24 hours + 1);
        p.governor.execute(id);

        // The investee draws tranche one, which starts the obligation clock (§8.2, §8.5).
        weth.mint(address(dex), 100 ether);
        vm.prank(investee);
        p.escrow.draw(1, 0);

        // A live token, registered and finalised, gives the escrow a vesting schedule to credit.
        vm.prank(investee);
        p.escrow.registerTge(1, address(investeeToken), 1_000_000e18);
        vm.warp(block.timestamp + 8 days);
        p.escrow.finaliseTge(1);
    }

    function _registerRemoteDeal() internal {
        _fundADeal();
        // In production the escrow relays this across the bridge at TGE. Here governance does it,
        // which is the other permitted caller.
        vm.prank(satGovernor);
        satellite.registerDeal(1, address(investeeToken), 1_000e18, 1 ether, VINTAGE);
    }

    function test_returnLeg_endsAsBuyPressureAndASupplyCut() public {
        _registerRemoteDeal();

        // 1. The founder pays their own token, on their own chain.
        investeeToken.mint(investee, 10_000e18);
        vm.startPrank(investee);
        investeeToken.approve(address(satellite), type(uint256).max);
        uint256 wethOut = satellite.payInstallment(1, 2);
        vm.stopPrank();

        assertEq(wethOut, 2 ether, "swapped against native liquidity");
        assertEq(satellite.pendingWeth(), 2 ether, "and discharged at that swap");

        // 2. The batch crosses. Permissionless, and the caller is paid from maintenance.
        stargate.setNativeFee(0.05 ether); // trigger at 1 WETH
        uint256 keeperBefore = satWeth.balanceOf(keeper);
        vm.prank(keeper);
        satellite.bridgeBatch();
        assertEq(satWeth.balanceOf(keeper) - keeperBefore, 0.002 ether, "bounty paid");

        // 3. It lands on the home chain and the manifest arrives with it.
        weth.mint(address(stargate), 10 ether); // the pool's home-side liquidity
        uint256 bufferBefore = homeAdapter.feeBuffer();
        stargate.deliver(
            lzEndpoint, address(homeAdapter), SAT_EID, ComposeMsgCodec.addressToBytes32(address(satAdapter))
        );

        assertEq(p.receiver.queueLength(), 1, "queued, not converted immediately");
        assertEq(p.receiver.queuedWeth(), 2 ether, "the full manifest value, fee absorbed");
        assertLt(homeAdapter.feeBuffer(), bufferBefore, "by maintenance, not by the vintage");

        // 4. The vintage has to freeze before it can be credited (§10.1: weights freeze at season
        //    close, and a vintage record never reopens). Until then the repayment waits in the queue.
        vm.warp(block.timestamp + 10 minutes);
        vm.expectRevert(abi.encodeWithSignature("SeasonNotFrozen()"));
        p.receiver.executeBuyback();

        vm.warp(p.dcode.seasonEnd(1) + 1);
        p.dcode.rollover();

        // 5. The buyback converts it, burns half, credits half to the funding vintage.
        uint256 supplyBefore = p.code.totalSupply();
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(keeper);
        uint256 codeOut = p.receiver.executeBuyback();

        assertEq(codeOut, 2 * CODE_PER_WETH);

        uint256 burned = supplyBefore - p.code.totalSupply();
        uint256 vaultHolds = p.code.balanceOf(address(p.vault));

        // The tight invariant: every token bought is either destroyed or claimable by someone. No
        // third destination exists.
        assertEq(burned + vaultHolds, codeOut, "no token bought goes anywhere else");

        // At least half, and slightly more than half here. The receiver burns its 50% (§15), and then
        // the vault burns the penalty differential on distribution (§2.3), because season one carried
        // non-vote penalties and a slashed participant's share is destroyed rather than handed to
        // their neighbours.
        assertGe(burned, codeOut / 2, "half burns by rule, plus the penalty differential");
        assertGt(burned, codeOut / 2, "and the differential is real, not zero");
        assertLt(vaultHolds, codeOut / 2);
        assertEq(p.receiver.queuedWeth(), 0, "nothing stranded");
        assertEq(weth.balanceOf(address(p.receiver)), 0);
    }

    function test_returnLeg_creditsTheVintageThatCanActuallyClaimIt() public {
        _registerRemoteDeal();

        investeeToken.mint(investee, 10_000e18);
        vm.startPrank(investee);
        investeeToken.approve(address(satellite), type(uint256).max);
        satellite.payInstallment(1, 1);
        vm.stopPrank();

        stargate.setNativeFee(0.02 ether);
        satellite.bridgeBatch();
        weth.mint(address(stargate), 10 ether);
        stargate.deliver(
            lzEndpoint, address(homeAdapter), SAT_EID, ComposeMsgCodec.addressToBytes32(address(satAdapter))
        );

        // Season 1 has to close before its vintage can accept a credit (§10.1).
        vm.warp(p.dcode.seasonEnd(1) + 1);
        p.dcode.rollover();

        vm.warp(block.timestamp + 10 minutes);
        p.receiver.executeBuyback();

        assertGt(p.vault.getVintage(VINTAGE).accReturnPerWeight, 0, "the vintage accumulator advanced");
    }

    function test_returnLeg_repaymentSurvivesArrivingBeforeItsVintageFreezes() public {
        // A deal funded and repaid inside the same season is the awkward case: §10.1 freezes claim
        // weights at season close, so there is no weight base to distribute against yet. The queue is
        // durable, so the value waits rather than being lost or misrouted.
        _registerRemoteDeal();

        investeeToken.mint(investee, 10_000e18);
        vm.startPrank(investee);
        investeeToken.approve(address(satellite), type(uint256).max);
        satellite.payInstallment(1, 1);
        vm.stopPrank();

        stargate.setNativeFee(0.02 ether);
        satellite.bridgeBatch();
        weth.mint(address(stargate), 10 ether);
        stargate.deliver(
            lzEndpoint, address(homeAdapter), SAT_EID, ComposeMsgCodec.addressToBytes32(address(satAdapter))
        );

        vm.warp(block.timestamp + 10 minutes);
        vm.expectRevert(abi.encodeWithSignature("SeasonNotFrozen()"));
        p.receiver.executeBuyback();

        assertEq(p.receiver.queueLength(), 1, "still queued, nothing lost");
        assertEq(p.receiver.queuedWeth(), 1 ether);

        vm.warp(p.dcode.seasonEnd(1) + 1);
        p.dcode.rollover();
        vm.warp(block.timestamp + 10 minutes);
        p.receiver.executeBuyback();

        assertEq(p.receiver.queueLength(), 0, "and settles once the vintage exists");
        assertGt(p.vault.getVintage(VINTAGE).accReturnPerWeight, 0);
    }

    function test_returnLeg_floorSettlementCrossesWithNoValue() public {
        _registerRemoteDeal();

        // The satellite pool goes thin and stays thin.
        satDex.setRate(address(investeeToken), address(satWeth), 0.5e15);
        satellite.recordIlliquidity(1, 1);
        vm.warp(block.timestamp + 12 hours);
        satellite.recordIlliquidity(1, 1);
        vm.warp(block.timestamp + 12 hours);
        satellite.recordIlliquidity(1, 1);

        vm.prank(investee);
        satellite.settleViaFloor(1, 1);

        vm.warp(block.timestamp + 30 days);
        satellite.bridgeBatch();
        stargate.deliver(
            lzEndpoint, address(homeAdapter), SAT_EID, ComposeMsgCodec.addressToBytes32(address(satAdapter))
        );

        // Nothing to convert, and nothing queued.
        assertEq(p.receiver.queueLength(), 0);
        assertEq(p.receiver.queuedWeth(), 0);
    }
}
