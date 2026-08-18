// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Code} from "../../src/Code.sol";
import {VintageVault, ICodeBurnable} from "../../src/VintageVault.sol";
import {IDCode} from "../../src/interfaces/IDCode.sol";

/// @dev A staking-vault stand-in whose weights the test sets directly. The real DCode's derivation
///      of those weights is exercised in its own suite; what matters here is the vault's arithmetic
///      given a set of frozen weights, which is far easier to reason about when the inputs are
///      stated rather than simulated.
contract DCodeStub {
    mapping(uint32 => bool) public isSeasonClosed;
    mapping(uint32 => uint256) public vintagePreSlashWeight;
    mapping(uint32 => uint256) public vintageEffectiveWeight;
    mapping(uint32 => mapping(address => uint256)) internal _principal;
    mapping(uint32 => mapping(address => uint256)) internal _frozen;
    mapping(uint32 => mapping(address => uint256)) internal _live;

    function setSeason(uint32 s, uint256 pre, uint256 eff) external {
        isSeasonClosed[s] = true;
        vintagePreSlashWeight[s] = pre;
        vintageEffectiveWeight[s] = eff;
    }

    function setParticipant(uint32 s, address a, uint256 principal, uint256 frozen) external {
        _principal[s][a] = principal;
        _frozen[s][a] = frozen;
        _live[s][a] = frozen;
    }

    function setLive(uint32 s, address a, uint256 live) external {
        _live[s][a] = live;
    }

    /// @dev Argument order matters: IDCode takes (account, season), not (season, account).
    function snapshotPrincipalOf(address a, uint32 s) external view returns (uint256) {
        return _principal[s][a];
    }

    function frozenWeightOf(address a, uint32 s) external view returns (uint256) {
        return _frozen[s][a];
    }

    function liveVintageWeightOf(address a, uint32 s) external view returns (uint256) {
        return _live[s][a];
    }

    function sync(VintageVault vault, address a, uint32 s, uint256 w) external {
        vault.syncVintageWeight(a, s, w);
    }
}

contract VintageVaultTest is Test {
    Code internal code;
    VintageVault internal vault;
    DCodeStub internal dcode;

    address internal genesis = makeAddr("genesis");
    address internal treasury = makeAddr("treasury");
    address internal maintenance = makeAddr("maintenance");
    address internal timelock = makeAddr("timelock");
    address internal receiver = makeAddr("receiver");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint32 internal constant V1 = 1;

    function setUp() public {
        code = new Code(genesis, treasury, maintenance);
        dcode = new DCodeStub();
        vault = new VintageVault(ICodeBurnable(address(code)), IDCode(address(dcode)), treasury, timelock);
        vault.wire(receiver);

        address[] memory ex = new address[](3);
        ex[0] = genesis;
        ex[1] = address(vault);
        ex[2] = receiver;
        code.setExempt(ex);
        code.seal();

        // Vintage 1: three equal principals, one of them slashed 10% for a wrong vote.
        dcode.setSeason(V1, 300e18, 290e18);
        dcode.setParticipant(V1, alice, 100e18, 100e18);
        dcode.setParticipant(V1, bob, 100e18, 90e18);
        dcode.setParticipant(V1, carol, 100e18, 100e18);

        vm.prank(genesis);
        code.transfer(receiver, 100_000e18);
        vm.prank(receiver);
        code.approve(address(vault), type(uint256).max);
    }

    function _credit(uint32 v, uint256 amount) internal {
        vm.prank(receiver);
        vault.creditVintage(v, amount);
    }

    /// @dev Claims only when there is something to claim, since an empty claim reverts by design.
    function _claimIfAny(address who) internal returns (uint256) {
        if (vault.claimable(who, V1) == 0 && vault.settled(who) == 0) return 0;
        return _claim(who, V1);
    }

    function _claim(address who, uint32 v) internal returns (uint256) {
        uint32[] memory vs = new uint32[](1);
        vs[0] = v;
        vm.prank(who);
        return vault.claim(vs);
    }

    // =================================================================
    // The penalty differential burns, and is never redistributed (§2.3)
    // =================================================================

    function test_credit_distributesAgainstPreSlashBaseAndBurnsTheDifferential() public {
        uint256 supplyBefore = code.totalSupply();
        _credit(V1, 300e18);

        VintageVault.Vintage memory v = vault.getVintage(V1);
        assertEq(v.preSlashBase, 300e18);
        assertEq(v.effectiveBase, 290e18);
        assertEq(vault.liability(), 290e18, "only the penalised base is payable");
        assertEq(supplyBefore - code.totalSupply(), 10e18, "the slashed 10 is burned");
    }

    function test_credit_slashedShareDoesNotEnlargeAnyoneElsesClaim() public {
        // The point of §2.3: redistributing a slashed share "would create an appetite for seeing
        // neighbours slashed". Alice and Carol get exactly their own weight, not a third of Bob's.
        _credit(V1, 300e18);

        assertEq(_claim(alice, V1), 100e18);
        assertEq(_claim(bob, V1), 90e18, "claims only the reduced fraction");
        assertEq(_claim(carol, V1), 100e18);
        assertEq(vault.liability(), 0, "the distributable pot is exactly exhausted");
    }

    function test_claim_isIdempotent() public {
        _credit(V1, 300e18);
        _claim(alice, V1);
        uint32[] memory vs = new uint32[](1);
        vs[0] = V1;
        vm.prank(alice);
        vm.expectRevert(VintageVault.NothingToClaim.selector);
        vault.claim(vs);
    }

    function test_claim_batchesAcrossVintages() public {
        dcode.setSeason(2, 200e18, 200e18);
        dcode.setParticipant(2, alice, 100e18, 100e18);
        dcode.setParticipant(2, bob, 100e18, 100e18);

        _credit(V1, 300e18);
        _credit(2, 200e18);

        uint32[] memory vs = new uint32[](2);
        vs[0] = V1;
        vs[1] = 2;
        vm.prank(alice);
        uint256 got = vault.claim(vs);
        assertEq(got, 100e18 + 100e18, "one call, two vintages");
    }

    function test_credit_refusesAVintageThatHasNotFrozen() public {
        vm.prank(receiver);
        vm.expectRevert(VintageVault.SeasonNotFrozen.selector);
        vault.creditVintage(99, 1e18);
    }

    function test_credit_isReceiverOnly() public {
        vm.prank(alice);
        vm.expectRevert(VintageVault.NotReceiver.selector);
        vault.creditVintage(V1, 1e18);
    }

    // =================================================================
    // Exit forfeiture: departing carry accrues to remaining partners (§10.3)
    // =================================================================

    function test_exit_settlesEverythingAccruedBeforeTheBaseContracts() public {
        _credit(V1, 300e18); // carol accrues 100 but does not claim

        dcode.sync(vault, carol, V1, 0);

        assertEq(vault.settled(carol), 100e18, "already-arrived returns are hers and are settled");
        VintageVault.Vintage memory v = vault.getVintage(V1);
        assertEq(v.effectiveBase, 190e18);
        assertEq(v.preSlashBase, 200e18);
    }

    function test_exit_forfeitsFutureArrivalsToThoseWhoStayed() public {
        _credit(V1, 300e18);
        dcode.sync(vault, carol, V1, 0);

        // A second return arrives after Carol left. Her third of it goes to Alice and Bob, not to
        // the burn address and not to the treasury.
        _credit(V1, 200e18);

        // Alice: 100 from the first credit + 100 from the second (base is now 200, not 300).
        assertEq(_claim(alice, V1), 200e18);
        // Bob: 90 + 90.
        assertEq(_claim(bob, V1), 180e18);
        // Carol: only what had arrived before she left.
        assertEq(_claim(carol, V1), 100e18);
    }

    function test_exit_partialExitScalesBothBasesTogether() public {
        // A partial exit must preserve the participant's multiplier. Bob's 90/100 ratio survives.
        dcode.sync(vault, bob, V1, 45e18);

        VintageVault.Position memory p = vault.getPosition(bob, V1);
        assertEq(p.effWeight, 45e18);
        assertEq(p.preWeight, 50e18, "half of 100, so the 0.9 multiplier is intact");

        VintageVault.Vintage memory v = vault.getVintage(V1);
        assertEq(v.effectiveBase, 245e18);
        assertEq(v.preSlashBase, 250e18);
    }

    function test_exit_zeroedWeightNeverRevives() public {
        dcode.sync(vault, carol, V1, 0);
        assertTrue(vault.getPosition(carol, V1).dead);

        // Even if the staking vault were to report a larger weight later, it cannot grow.
        dcode.sync(vault, carol, V1, 100e18);
        assertEq(vault.getPosition(carol, V1).effWeight, 0);

        _credit(V1, 190e18);
        VintageVault.Vintage memory v = vault.getVintage(V1);
        assertEq(v.effectiveBase, 190e18, "carol is gone from the base for good");
    }

    function test_exit_weightCannotGrow() public {
        dcode.sync(vault, bob, V1, 45e18);
        dcode.sync(vault, bob, V1, 80e18);
        assertEq(vault.getPosition(bob, V1).effWeight, 45e18, "monotone non-increasing");
    }

    function test_sync_isStakingVaultOnly() public {
        vm.prank(alice);
        vm.expectRevert(VintageVault.NotStakingVault.selector);
        vault.syncVintageWeight(alice, V1, 0);
    }

    // =================================================================
    // The monotone cap applied before the vault ever saw the participant
    // =================================================================

    function test_register_appliesAMonotoneCapThatPredatesRegistration() public {
        // Carol's stake dipped before she ever touched this contract. Registering her must apply
        // the same contraction an exit would, or her weight would re-enter the base at the frozen
        // figure and §10.3's cap would be escapable by simply never claiming.
        dcode.setLive(V1, carol, 40e18);
        _credit(V1, 300e18);

        uint256 got = _claim(carol, V1);
        assertEq(got, 40e18, "capped at the low, not the frozen 100");

        VintageVault.Vintage memory v = vault.getVintage(V1);
        assertEq(v.effectiveBase, 230e18, "and the base contracted by the difference");
    }

    function test_register_burnsWhatWasAllocatedToWeightThatNeverExisted() public {
        // Carol's stake had already dipped to 40 before the vault knew her. The 60 of weight the
        // base credited her with was never claimable by anyone, so it is burned rather than left
        // sitting here as a liability against a claim that will never come.
        dcode.setLive(V1, carol, 40e18);
        _credit(V1, 300e18);

        uint256 supplyBefore = code.totalSupply();
        uint256 liabilityBefore = vault.liability();

        _claim(carol, V1);

        assertEq(supplyBefore - code.totalSupply(), 60e18, "the phantom 60 burns");
        assertEq(liabilityBefore - vault.liability(), 100e18, "60 burned, 40 paid to carol");
        assertLe(vault.liability(), code.balanceOf(address(vault)));
    }

    function test_register_capDoesNotTouchOtherParticipantsClaims() public {
        // The phantom burn must not enlarge Alice or Bob: a cap is not an exit, and §2.3's rule
        // against redistributing another participant's shortfall applies here too.
        dcode.setLive(V1, carol, 40e18);
        _credit(V1, 300e18);
        _claim(carol, V1);

        assertEq(_claim(alice, V1), 100e18);
        assertEq(_claim(bob, V1), 90e18);
    }

    // =================================================================
    // Stale vintages (§10.3)
    // =================================================================

    function test_staleVintage_routesArrivalsToTheTreasury() public {
        dcode.sync(vault, alice, V1, 0);
        dcode.sync(vault, bob, V1, 0);
        dcode.sync(vault, carol, V1, 0);

        VintageVault.Vintage memory v = vault.getVintage(V1);
        assertEq(v.preSlashBase, 0, "nobody left");

        uint256 before = code.balanceOf(treasury);
        _credit(V1, 50e18);
        assertEq(code.balanceOf(treasury) - before, 50e18, "not burned, not stranded");
        assertEq(vault.liability(), 0);
    }

    // =================================================================
    // Residue
    // =================================================================

    function test_residue_isSweepableToTheTreasuryByGovernanceOnly() public {
        _credit(V1, 300e18);
        // Simulate the documented dust: a stray transfer in beyond recorded liability.
        vm.prank(genesis);
        code.transfer(address(vault), 5e18);

        assertEq(vault.residue(), 5e18);

        vm.prank(alice);
        vm.expectRevert(VintageVault.NotTimelock.selector);
        vault.sweepResidue();

        uint256 before = code.balanceOf(treasury);
        vm.prank(timelock);
        vault.sweepResidue();
        assertEq(code.balanceOf(treasury) - before, 5e18);
    }

    function test_residue_neverEatsIntoWhatIsOwed() public {
        _credit(V1, 300e18);
        assertEq(vault.residue(), 0, "everything here is someone's");
        vm.prank(timelock);
        vm.expectRevert(VintageVault.ZeroAmount.selector);
        vault.sweepResidue();
    }

    // =================================================================
    // Accounting invariant under arbitrary credit and exit sequences
    // =================================================================

    function testFuzz_liabilityNeverExceedsBalance(uint96 a, uint96 b, uint96 exitAt) public {
        uint256 first = uint256(a) % 1_000e18 + 1e18;
        uint256 second = uint256(b) % 1_000e18 + 1e18;
        uint256 newWeight = uint256(exitAt) % 100e18;

        _credit(V1, first);
        dcode.sync(vault, carol, V1, newWeight);
        _credit(V1, second);

        assertLe(vault.liability(), code.balanceOf(address(vault)), "the vault can always pay");

        uint256 paid = _claimIfAny(alice) + _claimIfAny(bob) + _claimIfAny(carol);
        assertLe(paid, first + second, "nobody is paid from thin air");
    }
}
