// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Targets} from "../../src/Targets.sol";
import {CodeTimelock} from "../../src/CodeTimelock.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

contract TargetsTest is Test {
    Targets internal targets;
    address internal timelock = makeAddr("timelock");
    address internal router = makeAddr("router");
    address internal stranger = makeAddr("stranger");

    bytes4 internal constant SWAP = bytes4(keccak256("swapExactTokensForTokens(uint256,uint256,address[],address,uint256)"));
    bytes4 internal constant SET_OWNER = bytes4(keccak256("setOwner(address)"));

    function setUp() public {
        targets = new Targets(timelock);
        address[] memory t = new address[](1);
        bytes4[] memory s = new bytes4[](1);
        t[0] = router;
        s[0] = SWAP;
        targets.seed(t, s);
    }

    function test_registry_isPerSelectorNotPerAddress() public view {
        // The whole point: registering a router's swap must not register its admin surface.
        assertTrue(targets.isKnown(router, SWAP));
        assertFalse(targets.isKnown(router, SET_OWNER), "an address-level entry would wave this through");
    }

    function test_registry_isTimelockOnly() public {
        vm.prank(stranger);
        vm.expectRevert(Targets.NotTimelock.selector);
        targets.register(router, SET_OWNER, "nope");
    }

    function test_registry_configurerIsSpentAfterSeeding() public {
        address[] memory t = new address[](1);
        bytes4[] memory s = new bytes4[](1);
        t[0] = router;
        s[0] = SET_OWNER;
        vm.expectRevert(Targets.NotConfigurer.selector);
        targets.seed(t, s);
    }

    function test_allKnown_reportsRatherThanReverts() public {
        // §6.2 lets an unregistered target through when it is flagged, so this must be a question
        // the governor can ask, not a wall it runs into.
        address[] memory t = new address[](2);
        bytes4[] memory s = new bytes4[](2);
        t[0] = router;
        s[0] = SWAP;
        t[1] = router;
        s[1] = SET_OWNER;
        assertFalse(targets.allKnown(t, s));

        vm.prank(timelock);
        targets.register(router, SET_OWNER, "reviewed");
        assertTrue(targets.allKnown(t, s));
    }

    function test_remove_takesASelectorBackOut() public {
        vm.prank(timelock);
        targets.remove(router, SWAP);
        assertFalse(targets.isKnown(router, SWAP));
        assertEq(targets.knownSelectors(router), 0);
    }
}

contract CodeTimelockTest is Test {
    CodeTimelock internal timelock;
    address internal governor = makeAddr("governor");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        timelock = new CodeTimelock(governor);
    }

    function test_delayIsTwentyFourHours() public view {
        assertEq(timelock.getMinDelay(), 24 hours);
    }

    function test_governorIsTheOnlyProposer() public view {
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), governor));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), stranger));
    }

    function test_executionIsOpenToAnyone() public view {
        // A permissioned executor could sit on a passed proposal forever, which is a veto by
        // inaction. §14 leaves nobody holding that.
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
    }

    function test_theTimelockAdministersItselfAndNoDeployerRemains() public view {
        // §14: "The governance layer is owned by itself... nothing in it is fixable by the team."
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), governor));
    }

    function test_delayCannotBeChangedExceptThroughItself() public {
        vm.prank(governor);
        vm.expectRevert();
        timelock.updateDelay(1 hours);
    }

    function test_queuedOperationCannotExecuteEarly() public {
        address target = address(timelock);
        bytes memory data = abi.encodeCall(TimelockController.updateDelay, (48 hours));

        vm.prank(governor);
        timelock.schedule(target, 0, data, bytes32(0), bytes32(0), 24 hours);

        vm.expectRevert();
        timelock.execute(target, 0, data, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + 24 hours + 1);
        timelock.execute(target, 0, data, bytes32(0), bytes32(0));
        assertEq(timelock.getMinDelay(), 48 hours, "and governance can retune itself by vote");
    }
}
