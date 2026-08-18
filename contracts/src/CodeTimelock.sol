// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title CodeTimelock
/// @notice The admin of the governed layer (§16.1 #5, §14).
///
/// @dev Deliberately a thin wrapper over OpenZeppelin's `TimelockController`, which is
///      timestamp-based already and so satisfies §12's rule that "block-denominated logic is
///      incorrect by construction; none exists anywhere in the system".
///
///      The role wiring is the part worth reading, because §14 says "the governance layer is owned
///      by itself... nothing in it is fixable by the team":
///
///      - **Proposer** is the governor alone. Nothing else can queue an operation.
///      - **Executor** is `address(0)`, meaning open. Once an operation has sat out its delay,
///        anyone may execute it. A permissioned executor would give one key the power to sit on a
///        passed proposal indefinitely, which is a veto by inaction.
///      - **Canceller** is the governor, so a halt or a superseding vote can withdraw a queued
///        operation, and no individual can.
///      - **Admin** is the timelock itself. There is no deployer admin left behind, so every later
///        role change must itself pass a vote and wait out the delay.
contract CodeTimelock is TimelockController {
    /// @notice §15: the timelock delay is 24 hours.
    uint256 public constant INITIAL_DELAY = 24 hours;

    /// @param governor The only proposer and canceller.
    /// @dev `admin` is passed as `address(0)`, which makes the OZ constructor grant the admin role
    ///      to the timelock itself and to nobody else. The team holds nothing here from the first
    ///      block, which is what makes §5.8's "the registry is owned by the timelock from the first
    ///      block" true rather than aspirational.
    constructor(address governor) TimelockController(INITIAL_DELAY, _one(governor), _open(), address(0)) {}

    function _one(address who) private pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = who;
    }

    /// @dev A single zero entry is OZ's sentinel for "open role": anyone may execute.
    function _open() private pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = address(0);
    }
}
