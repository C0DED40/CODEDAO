// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @title Targets
/// @notice The known-good target registry, maintained by governance (§16.1 #11).
///
/// @dev §6.2 requires that "every target address is either in the known-target registry or
///      explicitly flagged for SAINE review". The registry is therefore not a whitelist in the
///      usual sense, because it never blocks anything. It sorts calls into two piles: routine ones
///      the agents can skim, and novel ones the adjudication package annotates as unrecognised so
///      the board reads them closely. §5.3 puts that annotation in the agents' hands as evidence.
///
///      Registration is per (target, selector) rather than per address. An address-level entry would
///      register a router's `swap` and its `setOwner` on the same authority, and the second is
///      exactly the call a manifest should never be able to slip past a skim.
contract Targets {
    /// @notice Governance, the only writer (§14, invariant 18).
    address public immutable timelock;

    /// @dev Set at deployment for the protocol's own contracts, then frozen.
    address public configurer;

    mapping(address target => mapping(bytes4 selector => bool)) public isKnown;

    /// @notice Count of registered selectors per target, for interfaces that want to list them.
    mapping(address target => uint256) public knownSelectors;

    event TargetRegistered(address indexed target, bytes4 indexed selector, string note);
    event TargetRemoved(address indexed target, bytes4 indexed selector);

    error NotTimelock();
    error NotConfigurer();
    error AlreadyKnown();
    error NotRegistered();
    error ZeroAddress();

    constructor(address timelock_) {
        if (timelock_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
        configurer = msg.sender;
    }

    /// @notice Seed the protocol's own call surface at deployment, then close the door.
    function seed(address[] calldata targets, bytes4[] calldata selectors) external {
        if (msg.sender != configurer) revert NotConfigurer();
        for (uint256 i; i < targets.length; ++i) {
            _register(targets[i], selectors[i], "genesis");
        }
        configurer = address(0);
    }

    function register(address target, bytes4 selector, string calldata note) external {
        if (msg.sender != timelock) revert NotTimelock();
        _register(target, selector, note);
    }

    function remove(address target, bytes4 selector) external {
        if (msg.sender != timelock) revert NotTimelock();
        if (!isKnown[target][selector]) revert NotRegistered();
        isKnown[target][selector] = false;
        --knownSelectors[target];
        emit TargetRemoved(target, selector);
    }

    /// @notice Whether every (target, selector) pair in a proposal is registered.
    /// @dev Returns a boolean rather than reverting, because §6.2 lets an unregistered target
    ///      through when it is flagged: the governor records the flag, the agents receive it.
    function allKnown(address[] calldata targets, bytes4[] calldata selectors)
        external
        view
        returns (bool)
    {
        for (uint256 i; i < targets.length; ++i) {
            if (!isKnown[targets[i]][selectors[i]]) return false;
        }
        return true;
    }

    function _register(address target, bytes4 selector, string memory note) internal {
        if (target == address(0)) revert ZeroAddress();
        if (isKnown[target][selector]) revert AlreadyKnown();
        isKnown[target][selector] = true;
        ++knownSelectors[target];
        emit TargetRegistered(target, selector, note);
    }
}
