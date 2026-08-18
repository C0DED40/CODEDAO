// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title CODE
/// @notice The CODE token. Fixed supply, transfer tax, two burn sinks, no issuance (§2).
/// @dev Custody of power, §14: "The token contract holds no ongoing power. The tax rate, the
///      split, and the exemption list are configured at deployment, after which ownership is
///      renounced. No pause, no upgrade, no tax change, no whitelist change, by anyone, ever."
///
///      That promise is enforced structurally here rather than by convention:
///        - There is no mint function. The entire supply is minted in the constructor.
///        - The tax rate and split are `constant`, not storage. There is no setter to forget.
///        - The exemption list is writable only by the deployer, and only inside a hard
///          `SEAL_WINDOW` from deployment. After that window every mutating admin call reverts
///          whether or not anyone remembered to call `seal()`. The contract seals itself.
///        - There is no owner role at all beyond the sealing deployer, so there is nothing for
///          governance or an attacker to capture later.
contract Code is ERC20, ERC20Permit {
    // ---------------------------------------------------------------------
    // Supply
    // ---------------------------------------------------------------------

    /// @notice §15: total supply is fixed at 1,000,000,000 CODE. There is no mint function.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    // ---------------------------------------------------------------------
    // Tax (§2.2)
    // ---------------------------------------------------------------------

    /// @dev Basis-point denominator.
    uint256 internal constant BPS = 10_000;

    /// @notice 0.40% of every taxed transfer accrues to the treasury as investable capital.
    uint256 public constant TREASURY_BPS = 40;

    /// @notice 0.09% of every taxed transfer funds agent inference, infrastructure and bridging.
    uint256 public constant MAINTENANCE_BPS = 9;

    /// @notice Total tax on a transfer between two non-exempt addresses: 0.49%.
    uint256 public constant TOTAL_TAX_BPS = TREASURY_BPS + MAINTENANCE_BPS;

    /// @notice Destination of the treasury slice. Immutable.
    address public immutable treasury;

    /// @notice Destination of the maintenance slice. Immutable, team-held, powerless (§14).
    address public immutable maintenance;

    // ---------------------------------------------------------------------
    // Exemptions (§2.2)
    // ---------------------------------------------------------------------

    /// @notice Addresses whose transfers are untaxed in either direction.
    /// @dev "Protocol-internal movements are exempt: treasury operations, staking deposits and
    ///      withdrawals, governance bond posting and return, vintage distributions, escrow
    ///      flows, and burns. The tax exists to grow the treasury from organic volume, not to
    ///      toll the protocol's own plumbing."
    mapping(address account => bool) public isExempt;

    /// @notice The address permitted to add exemptions, until sealing. Zeroed on seal.
    address public configurer;

    /// @notice Timestamp after which configuration is impossible regardless of `seal()`.
    uint64 public immutable sealDeadline;

    /// @notice How long after deployment the exemption list may be edited.
    /// @dev A deployment that forgets to call `seal()` still becomes immutable on schedule.
    uint64 public constant SEAL_WINDOW = 7 days;

    event Exempted(address indexed account);
    event Sealed();
    event Burned(address indexed from, uint256 amount);

    error NotConfigurer();
    error ConfigurationClosed();
    error ZeroAddress();

    /// @param recipient Receives the entire supply at genesis; the deploy script splits it into
    ///        treasury, sale, team vesting and operator allocations in the same transaction.
    /// @param treasury_ The DAO treasury (§11).
    /// @param maintenance_ The maintenance address (§2.2).
    constructor(address recipient, address treasury_, address maintenance_)
        ERC20("CODE", "CODE")
        ERC20Permit("CODE")
    {
        if (recipient == address(0) || treasury_ == address(0) || maintenance_ == address(0)) {
            revert ZeroAddress();
        }
        treasury = treasury_;
        maintenance = maintenance_;
        configurer = msg.sender;
        sealDeadline = uint64(block.timestamp) + SEAL_WINDOW;

        // The tax destinations are exempt by construction: without this, collecting the tax
        // would itself be a taxable transfer and recurse.
        isExempt[treasury_] = true;
        isExempt[maintenance_] = true;
        emit Exempted(treasury_);
        emit Exempted(maintenance_);

        _mint(recipient, TOTAL_SUPPLY);
    }

    // ---------------------------------------------------------------------
    // Configuration, then permanent silence
    // ---------------------------------------------------------------------

    /// @notice Mark protocol contracts exempt. Deployer only, and only before sealing.
    /// @dev Exemptions can only ever be added, never removed. An address that was exempt at
    ///      seal time is exempt forever, and an address that was not can never become exempt.
    function setExempt(address[] calldata accounts) external {
        if (msg.sender != configurer) revert NotConfigurer();
        if (block.timestamp > sealDeadline) revert ConfigurationClosed();
        for (uint256 i; i < accounts.length; ++i) {
            address a = accounts[i];
            if (a == address(0)) revert ZeroAddress();
            if (!isExempt[a]) {
                isExempt[a] = true;
                emit Exempted(a);
            }
        }
    }

    /// @notice Renounce configuration permanently. Idempotent in effect, callable once.
    function seal() external {
        if (msg.sender != configurer) revert NotConfigurer();
        configurer = address(0);
        emit Sealed();
    }

    /// @notice True once no further configuration is possible by anyone.
    function isSealed() public view returns (bool) {
        return configurer == address(0) || block.timestamp > sealDeadline;
    }

    // ---------------------------------------------------------------------
    // Burn (§2.3)
    // ---------------------------------------------------------------------

    /// @notice Destroy tokens, permanently reducing total supply.
    /// @dev §2.3 describes the sinks as sending to "the dead address". This implementation
    ///      performs a true burn so that `totalSupply()` reflects the deflation directly and
    ///      no address holds a balance that could ever be argued to be recoverable. The
    ///      economic effect is identical and the accounting is more legible.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
        emit Burned(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Taxed transfer
    // ---------------------------------------------------------------------

    /// @notice Split every non-exempt transfer 0.40 / 0.09 / remainder at the point of transfer.
    /// @dev Mints and burns are never taxed: a tax on a burn would defeat the burn, and there
    ///      are no mints after genesis. Self-transfers are taxed like any other, deliberately,
    ///      since exempting them would create a trivial laundering path through a second wallet.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || value == 0 || isExempt[from] || isExempt[to]) {
            super._update(from, to, value);
            return;
        }

        uint256 treasuryCut = (value * TREASURY_BPS) / BPS;
        uint256 maintenanceCut = (value * MAINTENANCE_BPS) / BPS;

        // Rounding leaves the remainder with the recipient rather than the tax destinations,
        // so the tax can never exceed the stated 0.49% on any individual transfer.
        uint256 net = value - treasuryCut - maintenanceCut;

        if (treasuryCut != 0) super._update(from, treasury, treasuryCut);
        if (maintenanceCut != 0) super._update(from, maintenance, maintenanceCut);
        super._update(from, to, net);
    }

    /// @notice The amount that would actually land if `value` were sent between non-exempt parties.
    /// @dev Exposed for interfaces and for the escrow's floor-path arithmetic, so no caller has
    ///      to re-derive the split and risk drifting from it.
    function amountAfterTax(address from, address to, uint256 value)
        external
        view
        returns (uint256 net, uint256 treasuryCut, uint256 maintenanceCut)
    {
        if (isExempt[from] || isExempt[to]) return (value, 0, 0);
        treasuryCut = (value * TREASURY_BPS) / BPS;
        maintenanceCut = (value * MAINTENANCE_BPS) / BPS;
        net = value - treasuryCut - maintenanceCut;
    }
}
