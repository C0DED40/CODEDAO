// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StargateSatelliteAdapter} from "../../src/StargateSatelliteAdapter.sol";
import {StargateHomeAdapter} from "../../src/StargateHomeAdapter.sol";
import {IRepaymentReceiver, Repayment} from "../../src/interfaces/IBridge.sol";
import {IStargate, ComposeMsgCodec} from "../../src/interfaces/ILayerZero.sol";
import {MockToken} from "../mocks/Mocks.sol";
import {MockStargate} from "../mocks/StargateMocks.sol";

contract ReceiverSpy is IRepaymentReceiver {
    uint32 public lastSrc;
    uint256 public lastWeth;
    Repayment[] public entries;
    uint256 public calls;

    function receiveBatch(uint32 srcChainId, uint256 wethAmount, bytes calldata payload) external {
        lastSrc = srcChainId;
        lastWeth = wethAmount;
        delete entries;
        Repayment[] memory decoded = abi.decode(payload, (Repayment[]));
        for (uint256 i; i < decoded.length; ++i) {
            entries.push(decoded[i]);
        }
        ++calls;
    }

    function entryCount() external view returns (uint256) {
        return entries.length;
    }

    function entryAt(uint256 i) external view returns (Repayment memory) {
        return entries[i];
    }
}

contract StargateAdaptersTest is Test {
    MockToken internal weth;
    MockStargate internal stargate;
    StargateSatelliteAdapter internal satAdapter;
    StargateHomeAdapter internal homeAdapter;
    ReceiverSpy internal receiver;

    address internal endpoint = makeAddr("lzEndpoint");
    address internal satellite = makeAddr("satellite");
    address internal governor = makeAddr("crossChainGovernor");
    address internal timelock = makeAddr("timelock");
    address internal maintenance = makeAddr("maintenance");

    uint32 internal constant HOME_EID = 30_110;
    uint32 internal constant SAT_EID = 30_111;

    function setUp() public {
        weth = new MockToken("Wrapped Ether", "WETH");
        stargate = new MockStargate(IERC20(address(weth)), IERC20(address(weth)));
        receiver = new ReceiverSpy();

        homeAdapter = new StargateHomeAdapter(
            IERC20(address(weth)), IRepaymentReceiver(address(receiver)), endpoint, address(stargate), timelock
        );
        satAdapter = new StargateSatelliteAdapter(
            IStargate(address(stargate)), IERC20(address(weth)), satellite, HOME_EID, address(homeAdapter), governor
        );

        vm.prank(timelock);
        homeAdapter.registerSatellite(SAT_EID, address(satAdapter));

        weth.mint(satellite, 100 ether);
        vm.prank(satellite);
        weth.approve(address(satAdapter), type(uint256).max);
        vm.deal(satellite, 10 ether);

        weth.mint(maintenance, 100 ether);
        vm.startPrank(maintenance);
        weth.approve(address(homeAdapter), type(uint256).max);
        homeAdapter.fundBuffer(1 ether);
        vm.stopPrank();
    }

    function _batch(uint256 amount, uint32 vintage) internal pure returns (Repayment[] memory e) {
        e = new Repayment[](1);
        e[0] = Repayment(1, vintage, 1, amount, false);
    }

    function _send(Repayment[] memory entries, uint256 total) internal {
        bytes memory payload = abi.encode(entries);
        uint256 fee = satAdapter.quoteFee(payload);
        vm.prank(satellite);
        satAdapter.send{value: fee}(total, payload);
    }

    function _deliver() internal {
        stargate.deliver(endpoint, address(homeAdapter), SAT_EID, ComposeMsgCodec.addressToBytes32(address(satAdapter)));
    }

    // =================================================================
    // Sending
    // =================================================================

    function test_send_isSatelliteOnly() public {
        bytes memory payload = abi.encode(_batch(1 ether, 3));
        vm.deal(address(this), 1 ether);
        vm.expectRevert(StargateSatelliteAdapter.NotSatellite.selector);
        satAdapter.send{value: 0.01 ether}(1 ether, payload);
    }

    function test_send_refusesWithoutTheFee() public {
        bytes memory payload = abi.encode(_batch(1 ether, 3));
        vm.prank(satellite);
        vm.expectRevert(StargateSatelliteAdapter.FeeNotCovered.selector);
        satAdapter.send{value: 0}(1 ether, payload);
    }

    function test_send_boundsWhatMayArrive() public {
        // Default tolerance is 50 bps. A pool taking 1% must not be able to deliver silently thin.
        stargate.setProtocolFeeBps(100);
        bytes memory payload = abi.encode(_batch(1 ether, 3));
        uint256 fee = satAdapter.quoteFee(payload);
        vm.prank(satellite);
        vm.expectRevert(MockStargate.SlippageBound.selector);
        satAdapter.send{value: fee}(1 ether, payload);
    }

    function test_send_carriesTheManifestAsTheComposedMessage() public {
        // Value and manifest cross together, so they cannot be separated or replayed independently.
        Repayment[] memory entries = _batch(2 ether, 5);
        _send(entries, 2 ether);

        assertEq(stargate.sends(), 1);
        Repayment[] memory sent = abi.decode(stargate.lastComposeMsg(), (Repayment[]));
        assertEq(sent.length, 1);
        assertEq(uint256(sent[0].vintage), 5);
        assertEq(sent[0].wethAmount, 2 ether);
    }

    function test_send_leavesNoStandingApproval() public {
        _send(_batch(2 ether, 5), 2 ether);
        assertEq(weth.allowance(address(satAdapter), address(stargate)), 0);
    }

    // =================================================================
    // Receiving: authentication
    // =================================================================

    function test_compose_isEndpointOnly() public {
        _send(_batch(1 ether, 3), 1 ether);
        bytes memory framed = abi.encodePacked(
            uint64(1),
            SAT_EID,
            uint256(1 ether),
            ComposeMsgCodec.addressToBytes32(address(satAdapter)),
            abi.encode(_batch(1 ether, 3))
        );
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(StargateHomeAdapter.NotEndpoint.selector);
        homeAdapter.lzCompose(address(stargate), bytes32(0), framed, address(0), "");
    }

    function test_compose_rejectsAComposerThatIsNotStargate() public {
        bytes memory framed = abi.encodePacked(
            uint64(1),
            SAT_EID,
            uint256(1 ether),
            ComposeMsgCodec.addressToBytes32(address(satAdapter)),
            abi.encode(_batch(1 ether, 3))
        );
        vm.prank(endpoint);
        vm.expectRevert(StargateHomeAdapter.NotStargate.selector);
        homeAdapter.lzCompose(makeAddr("notStargate"), bytes32(0), framed, address(0), "");
    }

    function test_compose_rejectsAnUnregisteredSatellite() public {
        // Without this, any Stargate user on any connected chain could send dust with a fabricated
        // manifest and have it credited to a vintage.
        bytes memory framed = abi.encodePacked(
            uint64(1),
            SAT_EID,
            uint256(1 ether),
            ComposeMsgCodec.addressToBytes32(makeAddr("rogue")),
            abi.encode(_batch(1 ether, 3))
        );
        vm.prank(endpoint);
        vm.expectRevert(StargateHomeAdapter.UnknownSatellite.selector);
        homeAdapter.lzCompose(address(stargate), bytes32(0), framed, address(0), "");
    }

    function test_compose_rejectsAnUnknownSourceChain() public {
        bytes memory framed = abi.encodePacked(
            uint64(1),
            uint32(9999),
            uint256(1 ether),
            ComposeMsgCodec.addressToBytes32(address(satAdapter)),
            abi.encode(_batch(1 ether, 3))
        );
        vm.prank(endpoint);
        vm.expectRevert(StargateHomeAdapter.UnknownSatellite.selector);
        homeAdapter.lzCompose(address(stargate), bytes32(0), framed, address(0), "");
    }

    // =================================================================
    // Receiving: the fee buffer (§9)
    // =================================================================

    function test_buffer_coversTheBridgeFeeSoTheVintageIsWhole() public {
        // §9: "Bridge and swap costs are paid from the maintenance slice, so stakers' distributions
        // are never haircut by infrastructure."
        _send(_batch(2 ether, 5), 2 ether);
        uint256 bufferBefore = homeAdapter.feeBuffer();

        _deliver();

        // Stargate took 0.1%, so 1.998 landed against a 2.0 manifest.
        assertEq(receiver.lastWeth(), 2 ether, "the full manifest value reaches the receiver");
        assertEq(bufferBefore - homeAdapter.feeBuffer(), 0.002 ether, "maintenance absorbed the fee");
        assertEq(weth.balanceOf(address(receiver)), 2 ether);
    }

    function test_buffer_scalesAndAnnouncesWhenItRunsDry() public {
        // The degradation has to be loud. A silent haircut would make §9's promise false in exactly
        // the case where nobody was watching.
        vm.prank(timelock);
        homeAdapter.sweepBuffer(1 ether, maintenance);
        assertEq(homeAdapter.feeBuffer(), 0);

        _send(_batch(2 ether, 5), 2 ether);

        vm.expectEmit(true, false, false, true, address(homeAdapter));
        emit StargateHomeAdapter.ShortfallSocialised(SAT_EID, 2 ether, 1.998 ether);
        _deliver();

        assertEq(receiver.lastWeth(), 1.998 ether, "scaled to what actually arrived");
        assertEq(receiver.entryAt(0).wethAmount, 1.998 ether);
    }

    function test_buffer_surplusGoesToTheBufferNotAnArbitraryVintage() public {
        stargate.setProtocolFeeBps(0);
        // The satellite over-sends: manifest claims 1, transfer carries 2.
        bytes memory payload = abi.encode(_batch(1 ether, 5));
        uint256 fee = satAdapter.quoteFee(payload);
        vm.prank(satellite);
        satAdapter.send{value: fee}(2 ether, payload);

        uint256 bufferBefore = homeAdapter.feeBuffer();
        _deliver();

        assertEq(receiver.lastWeth(), 1 ether, "only what the manifest claims is forwarded");
        assertEq(homeAdapter.feeBuffer() - bufferBefore, 1 ether, "the surplus funds the crossing, not a vintage");
    }

    function test_buffer_isSweepableByGovernanceOnly() public {
        vm.prank(maintenance);
        vm.expectRevert(StargateHomeAdapter.NotTimelock.selector);
        homeAdapter.sweepBuffer(1 ether, maintenance);
    }

    function test_registry_isGovernanceOnly() public {
        vm.prank(maintenance);
        vm.expectRevert(StargateHomeAdapter.NotTimelock.selector);
        homeAdapter.registerSatellite(SAT_EID, makeAddr("x"));
    }

    // =================================================================
    // Zero-value crossings (floor settlements)
    // =================================================================

    function test_floorOnlyBatchCrossesWithNoValue() public {
        Repayment[] memory e = new Repayment[](1);
        e[0] = Repayment(1, 5, 2, 0, true);
        _send(e, 0);
        _deliver();

        assertEq(receiver.lastWeth(), 0);
        assertEq(receiver.entryCount(), 1);
        assertTrue(receiver.entryAt(0).viaFloor);
    }

    // =================================================================
    // Parameters
    // =================================================================

    function test_parameters_areGovernorOnlyAndBounded() public {
        vm.prank(maintenance);
        vm.expectRevert(StargateSatelliteAdapter.NotGovernor.selector);
        satAdapter.setParameters(100, 500_000);

        vm.startPrank(governor);
        vm.expectRevert(StargateSatelliteAdapter.OutOfRange.selector);
        satAdapter.setParameters(0, 500_000); // zero tolerance reverts every crossing
        vm.expectRevert(StargateSatelliteAdapter.OutOfRange.selector);
        satAdapter.setParameters(100, 50_000); // too little gas for lzCompose
        satAdapter.setParameters(100, 800_000);
        vm.stopPrank();

        assertEq(uint256(satAdapter.deliveryToleranceBps()), 100);
        assertEq(uint256(satAdapter.composeGasLimit()), 800_000);
    }
}
