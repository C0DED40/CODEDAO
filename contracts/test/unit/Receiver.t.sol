// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Code} from "../../src/Code.sol";
import {Receiver, ICodeBurnable3, IReceiverOracle} from "../../src/Receiver.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IExternal.sol";
import {IBridgeAdapter, IRepaymentReceiver, Repayment} from "../../src/interfaces/IBridge.sol";
import {IVintageVault} from "../../src/interfaces/IVintageVault.sol";
import {IEscrow} from "../../src/interfaces/IEscrow.sol";
import {MockToken, MockDex} from "../mocks/Mocks.sol";
import {MockBridgeAdapter, EscrowRecordSpy, VintageCreditSpy, OracleRateStub} from "../mocks/BridgeMocks.sol";

contract ReceiverTest is Test {
    Code internal code;
    MockToken internal weth;
    MockDex internal dex;
    Receiver internal receiver;
    MockBridgeAdapter internal bridge;
    EscrowRecordSpy internal escrow;
    VintageCreditSpy internal vault;
    OracleRateStub internal oracle;

    address internal genesis = makeAddr("genesis");
    address internal treasury = makeAddr("treasury");
    address internal maintenance = makeAddr("maintenance");
    address internal timelock = makeAddr("timelock");
    address internal keeper = makeAddr("keeper");

    uint32 internal constant VINTAGE = 3;
    uint256 internal constant DEAL = 7;

    /// @dev 1 WETH buys 100,000 CODE.
    uint256 internal constant CODE_PER_WETH = 100_000e18;

    function setUp() public {
        vm.warp(1_700_000_000);
        code = new Code(genesis, treasury, maintenance);
        weth = new MockToken("Wrapped Ether", "WETH");
        dex = new MockDex();
        escrow = new EscrowRecordSpy();
        vault = new VintageCreditSpy(IERC20(address(code)));
        oracle = new OracleRateStub();

        receiver = new Receiver(
            ICodeBurnable3(address(code)),
            IERC20(address(weth)),
            IUniswapV2Router02(address(dex)),
            IVintageVault(address(vault)),
            IEscrow(address(escrow)),
            timelock
        );
        bridge = new MockBridgeAdapter(IERC20(address(weth)));
        bridge.setReceiver(IRepaymentReceiver(address(receiver)));

        address[] memory adapters = new address[](1);
        adapters[0] = address(bridge);
        receiver.wire(IReceiverOracle(address(oracle)), adapters);

        address[] memory ex = new address[](4);
        ex[0] = genesis;
        ex[1] = address(receiver);
        ex[2] = address(dex);
        ex[3] = address(vault);
        code.setExempt(ex);
        code.seal();

        // Fund the pool with CODE so the buyback has something to buy.
        vm.prank(genesis);
        code.transfer(address(dex), 100_000_000e18);
        dex.setRate(address(weth), address(code), CODE_PER_WETH);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _batch(Repayment[] memory entries, uint256 wethTotal) internal {
        if (wethTotal != 0) weth.mint(address(receiver), wethTotal);
        vm.prank(address(bridge));
        receiver.receiveBatch(42, wethTotal, abi.encode(entries));
    }

    function _one(uint256 wethAmount, uint16 installments, bool viaFloor)
        internal
        pure
        returns (Repayment[] memory entries)
    {
        entries = new Repayment[](1);
        entries[0] = Repayment(DEAL, VINTAGE, installments, wethAmount, viaFloor);
    }

    // =================================================================
    // Arrival (§9 step 4)
    // =================================================================

    function test_receive_isAdapterOnly() public {
        Repayment[] memory entries = _one(1 ether, 1, false);
        vm.prank(keeper);
        vm.expectRevert(Receiver.NotAdapter.selector);
        receiver.receiveBatch(42, 1 ether, abi.encode(entries));
    }

    function test_receive_refusesValueThatWasNotActuallyDelivered() public {
        // A misreporting adapter must not be able to enqueue value it never sent, or it would drain
        // the queue's WETH through later legitimate arrivals.
        Repayment[] memory entries = _one(1 ether, 1, false);
        vm.prank(address(bridge));
        vm.expectRevert(Receiver.WethNotDelivered.selector);
        receiver.receiveBatch(42, 1 ether, abi.encode(entries));
    }

    function test_receive_queuesRatherThanBuyingImmediately() public {
        _batch(_one(1 ether, 1, false), 1 ether);
        assertEq(receiver.queueLength(), 1, "arrival and execution are separate");
        assertEq(receiver.queuedWeth(), 1 ether);
        assertEq(code.balanceOf(address(vault)), 0, "nothing bought yet");
    }

    function test_receive_floorEntriesAreRecordedWithoutABuyback() public {
        // A floor settlement paid CODE on this chain, so there is nothing to convert.
        _batch(_one(0, 2, true), 0);
        assertEq(receiver.queueLength(), 0);
        assertEq(escrow.count(), 1);
        (uint256 dealId, uint16 count, uint256 wethValue, bool viaFloor) = escrow.records(0);
        assertEq(dealId, DEAL);
        assertEq(uint256(count), 2);
        assertEq(wethValue, 0);
        assertTrue(viaFloor);
    }

    // =================================================================
    // Conversion and split (§9 step 5, §15)
    // =================================================================

    function test_buyback_splitsFiftyFiftyBurnAndVintage() public {
        _batch(_one(1 ether, 1, false), 1 ether);
        uint256 supplyBefore = code.totalSupply();

        vm.warp(block.timestamp + 10 minutes);
        vm.prank(keeper);
        uint256 codeOut = receiver.executeBuyback();

        assertEq(codeOut, CODE_PER_WETH, "1 WETH bought 100,000 CODE");
        assertEq(supplyBefore - code.totalSupply(), CODE_PER_WETH / 2, "half is burned");
        assertEq(vault.credited(VINTAGE), CODE_PER_WETH / 2, "half reaches the funding vintage");
    }

    function test_buyback_creditsTheVintageThatFundedTheDeal() public {
        // §10.1: "Every return from that deal, whenever it arrives, is credited to that season's
        // pool." The vintage travels with the entry rather than being looked up on arrival.
        Repayment[] memory entries = new Repayment[](2);
        entries[0] = Repayment(1, 2, 1, 1 ether, false);
        entries[1] = Repayment(2, 5, 1, 1 ether, false);
        _batch(entries, 2 ether);

        vm.warp(block.timestamp + 10 minutes);
        receiver.executeBuyback();
        vm.warp(block.timestamp + 10 minutes);
        receiver.executeBuyback();

        assertEq(vault.credited(2), CODE_PER_WETH / 2);
        assertEq(vault.credited(5), CODE_PER_WETH / 2);
    }

    function test_buyback_recordsTheObligationOnce() public {
        _batch(_one(1 ether, 3, false), 1 ether);
        vm.warp(block.timestamp + 10 minutes);
        receiver.executeBuyback();

        assertEq(escrow.count(), 1);
        (, uint16 count,, bool viaFloor) = escrow.records(0);
        assertEq(uint256(count), 3);
        assertFalse(viaFloor);
    }

    function test_buyback_enforcesTheInterval() public {
        Repayment[] memory entries = new Repayment[](2);
        entries[0] = Repayment(1, 2, 1, 1 ether, false);
        entries[1] = Repayment(2, 2, 1, 1 ether, false);
        _batch(entries, 2 ether);

        vm.warp(block.timestamp + 10 minutes);
        receiver.executeBuyback();
        vm.expectRevert(Receiver.IntervalNotElapsed.selector);
        receiver.executeBuyback();

        vm.warp(block.timestamp + 10 minutes);
        receiver.executeBuyback();
        assertEq(receiver.queueLength(), 0);
    }

    function test_buyback_splitsALargePurchaseAcrossIntervals() public {
        // §9: "large purchases split across intervals". 12 WETH against a 5 WETH cap is three passes.
        _batch(_one(12 ether, 4, false), 12 ether);

        vm.warp(block.timestamp + 10 minutes);
        receiver.executeBuyback();
        assertEq(receiver.queueAt(0).wethAmount, 7 ether, "remainder stays at the head");
        assertEq(escrow.count(), 0, "and the obligation is not yet reported");

        vm.warp(block.timestamp + 10 minutes);
        receiver.executeBuyback();
        assertEq(receiver.queueAt(0).wethAmount, 2 ether);
        assertEq(escrow.count(), 0);

        vm.warp(block.timestamp + 10 minutes);
        receiver.executeBuyback();
        assertEq(receiver.queueLength(), 0);
        assertEq(escrow.count(), 1, "reported once, when the last of it converts");

        // All 12 WETH ended as CODE, half burned and half to the vintage.
        assertEq(vault.credited(VINTAGE), (12 * CODE_PER_WETH) / 2);
    }

    function test_buyback_revertsRatherThanFillingBadly() public {
        _batch(_one(1 ether, 1, false), 1 ether);
        // The pool moves 2% against a 150 bps bound.
        dex.setRate(address(weth), address(code), (CODE_PER_WETH * 98) / 100);
        vm.warp(block.timestamp + 10 minutes);
        vm.expectRevert(MockDex.TooLittleOut.selector);
        receiver.executeBuyback();
    }

    function test_buyback_emptyQueueReverts() public {
        vm.warp(block.timestamp + 10 minutes);
        vm.expectRevert(Receiver.QueueEmpty.selector);
        receiver.executeBuyback();
    }

    function test_buyback_isPermissionless() public {
        // Unbountied on purpose: the vintage holders who benefit are already motivated, and a bounty
        // would be paid out of the distribution it exists to deliver.
        _batch(_one(1 ether, 1, false), 1 ether);
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(makeAddr("anybody"));
        receiver.executeBuyback();
        assertEq(vault.calls(), 1);
    }

    // =================================================================
    // Every repayment ends as buy pressure and a supply cut (§2.3)
    // =================================================================

    function testFuzz_halfOfEveryRepaymentIsBurned(uint96 raw) public {
        uint256 amount = uint256(raw) % 4 ether + 0.001 ether;
        _batch(_one(amount, 1, false), amount);

        uint256 supplyBefore = code.totalSupply();
        vm.warp(block.timestamp + 10 minutes);
        uint256 codeOut = receiver.executeBuyback();

        uint256 burned = supplyBefore - code.totalSupply();
        assertEq(burned, codeOut / 2, "exactly half, every time");
        assertEq(vault.credited(VINTAGE), codeOut - burned);
    }

    // =================================================================
    // Governance
    // =================================================================

    function test_parameters_areTimelockOnlyAndBounded() public {
        vm.prank(keeper);
        vm.expectRevert(Receiver.NotTimelock.selector);
        receiver.setParameters(200, 5 minutes, 10 ether);

        vm.startPrank(timelock);
        vm.expectRevert(Receiver.OutOfRange.selector);
        receiver.setParameters(0, 5 minutes, 10 ether); // zero bound reverts every buyback
        vm.expectRevert(Receiver.OutOfRange.selector);
        receiver.setParameters(200, 0, 10 ether); // no interval removes the splitting §9 requires
        receiver.setParameters(200, 5 minutes, 10 ether);
        vm.stopPrank();

        assertEq(uint256(receiver.buybackSlippageBps()), 200);
        assertEq(uint256(receiver.maxPerExecution()), 10 ether);
    }

    function test_adapters_areTimelockControlled() public {
        address rogue = makeAddr("rogue");
        Repayment[] memory entries = _one(1 ether, 1, false);
        weth.mint(address(receiver), 1 ether);

        vm.prank(rogue);
        vm.expectRevert(Receiver.NotAdapter.selector);
        receiver.receiveBatch(42, 1 ether, abi.encode(entries));

        vm.prank(timelock);
        receiver.setAdapter(rogue, true);
        vm.prank(rogue);
        receiver.receiveBatch(42, 1 ether, abi.encode(entries));
        assertEq(receiver.queueLength(), 1);
    }

    // =================================================================
    // End to end across the bridge
    // =================================================================

    function test_endToEnd_valueCrossesAndLandsInTheRightPlaces() public {
        // Simulate the satellite side by funding the adapter and delivering.
        weth.mint(address(bridge), 3 ether);
        Repayment[] memory entries = _one(3 ether, 2, false);
        vm.prank(address(bridge));
        // The adapter records the batch as if it had been sent, then delivers it.
        receiver.receiveBatch(42, 0, abi.encode(new Repayment[](0)));

        weth.mint(address(receiver), 3 ether);
        vm.prank(address(bridge));
        receiver.receiveBatch(42, 3 ether, abi.encode(entries));

        uint256 supplyBefore = code.totalSupply();
        vm.warp(block.timestamp + 10 minutes);
        receiver.executeBuyback();

        assertEq(supplyBefore - code.totalSupply(), (3 * CODE_PER_WETH) / 2);
        assertEq(vault.credited(VINTAGE), (3 * CODE_PER_WETH) / 2);
        assertEq(escrow.count(), 1);
        assertEq(receiver.queuedWeth(), 0, "nothing stranded");
    }
}
