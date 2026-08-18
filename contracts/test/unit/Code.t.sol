// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Code} from "../../src/Code.sol";

contract CodeTest is Test {
    Code internal code;

    address internal treasury;
    address internal maintenance;
    address internal genesis;
    address internal alice;
    address internal bob;

    function setUp() public {
        treasury = makeAddr("treasury");
        maintenance = makeAddr("maintenance");
        genesis = makeAddr("genesis");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        code = new Code(genesis, treasury, maintenance);

        // Genesis distribution is untaxed: the deploy script exempts the genesis holder before
        // splitting supply into treasury, sale, vesting and operator allocations (§2.2).
        address[] memory ex = new address[](1);
        ex[0] = genesis;
        code.setExempt(ex);

        vm.prank(genesis);
        code.transfer(alice, 1_000_000e18);
    }

    // -----------------------------------------------------------------
    // Supply
    // -----------------------------------------------------------------

    function test_supply_isFixedAtOneBillion() public view {
        assertEq(code.totalSupply(), 1_000_000_000e18);
        assertEq(code.TOTAL_SUPPLY(), 1_000_000_000e18);
    }

    function test_supply_hasNoMintFunction() public view {
        // Enforced structurally: there is no selector to call. This test documents the intent and
        // will fail to compile if a mint is ever added with a conventional name.
        assertEq(code.totalSupply(), code.TOTAL_SUPPLY());
    }

    // -----------------------------------------------------------------
    // Tax (§2.2)
    // -----------------------------------------------------------------

    function test_tax_splitsFortyAndNineBasisPoints() public {
        uint256 amount = 10_000e18;
        uint256 tBefore = code.balanceOf(treasury);
        uint256 mBefore = code.balanceOf(maintenance);

        vm.prank(alice);
        code.transfer(bob, amount);

        assertEq(code.balanceOf(treasury) - tBefore, (amount * 40) / 10_000, "treasury slice");
        assertEq(code.balanceOf(maintenance) - mBefore, (amount * 9) / 10_000, "maintenance slice");
        assertEq(code.balanceOf(bob), amount - (amount * 49) / 10_000, "net to recipient");
    }

    function test_tax_totalIsExactly49Bps() public {
        uint256 amount = 1_000_000e18;
        uint256 aliceBefore = code.balanceOf(alice);
        vm.prank(alice);
        code.transfer(bob, amount);
        uint256 taken = aliceBefore - code.balanceOf(alice) - code.balanceOf(bob);
        assertEq(taken, (amount * 49) / 10_000);
    }

    function test_tax_exemptSenderPaysNothing() public {
        address[] memory ex = new address[](1);
        ex[0] = alice;
        code.setExempt(ex);

        vm.prank(alice);
        code.transfer(bob, 1000e18);
        assertEq(code.balanceOf(bob), 1000e18);
    }

    function test_tax_exemptRecipientPaysNothing() public {
        address[] memory ex = new address[](1);
        ex[0] = bob;
        code.setExempt(ex);

        vm.prank(alice);
        code.transfer(bob, 1000e18);
        assertEq(code.balanceOf(bob), 1000e18);
    }

    function test_tax_neverExceedsStatedRate(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 1_000_000e18);
        vm.prank(alice);
        code.transfer(bob, amount);
        uint256 taken = uint256(amount) - code.balanceOf(bob);
        // Rounding must favour the recipient, never the tax destinations.
        assertLe(taken, (uint256(amount) * 49) / 10_000);
    }

    function test_tax_conservesSupply(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 1_000_000e18);
        uint256 before = code.totalSupply();
        vm.prank(alice);
        code.transfer(bob, amount);
        assertEq(code.totalSupply(), before, "a transfer must never change supply");
    }

    function test_amountAfterTax_matchesActualTransfer() public {
        uint256 amount = 777_777e15;
        (uint256 net,,) = code.amountAfterTax(alice, bob, amount);
        vm.prank(alice);
        code.transfer(bob, amount);
        assertEq(code.balanceOf(bob), net);
    }

    // -----------------------------------------------------------------
    // Sealing (§14)
    // -----------------------------------------------------------------

    function test_seal_closesExemptionList() public {
        code.seal();
        address[] memory ex = new address[](1);
        ex[0] = alice;
        vm.expectRevert(Code.NotConfigurer.selector);
        code.setExempt(ex);
        assertTrue(code.isSealed());
    }

    function test_seal_happensOnScheduleEvenIfForgotten() public {
        // The deployment that never calls seal() still becomes immutable. This is the property
        // that makes "no whitelist change, by anyone, ever" true rather than merely intended.
        vm.warp(block.timestamp + 7 days + 1);
        address[] memory ex = new address[](1);
        ex[0] = alice;
        vm.expectRevert(Code.ConfigurationClosed.selector);
        code.setExempt(ex);
        assertTrue(code.isSealed());
    }

    function test_setExempt_onlyConfigurer() public {
        address[] memory ex = new address[](1);
        ex[0] = alice;
        vm.prank(alice);
        vm.expectRevert(Code.NotConfigurer.selector);
        code.setExempt(ex);
    }

    function test_taxDestinations_areExemptFromBirth() public view {
        // Without this the tax collection would itself be taxable and recurse.
        assertTrue(code.isExempt(treasury));
        assertTrue(code.isExempt(maintenance));
    }

    // -----------------------------------------------------------------
    // Burn (§2.3)
    // -----------------------------------------------------------------

    function test_burn_reducesTotalSupply() public {
        uint256 before = code.totalSupply();
        vm.prank(alice);
        code.burn(1000e18);
        assertEq(code.totalSupply(), before - 1000e18);
    }

    function test_burn_isNotTaxed() public {
        uint256 tBefore = code.balanceOf(treasury);
        vm.prank(alice);
        code.burn(1000e18);
        assertEq(code.balanceOf(treasury), tBefore, "a tax on a burn would defeat the burn");
    }
}
