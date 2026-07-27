// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { StrandsAllowlistBatch } from "./StrandsAllowlistBatch.sol";

/// @title  Strands Custody Token (SCT)
/// @notice ERC20Burnable token with a privileged custodial burn path.
///         Users may burn their own balance (or burn another's via allowance)
///         using the standard `burn` / `burnFrom`. Accounts holding
///         CUSTODIAN_ROLE may additionally call `custodyBurn` to destroy
///         tokens from any holder without requiring prior allowance.
///         Holder-to-holder transfers are default-deny: a holder may only
///         transfer to destinations the admin has approved for that holder.
///         Batch helpers for managing that allowlist live in
///         {StrandsAllowlistBatch}.
contract StrandsCustodyToken is ERC20Burnable, AccessControl, StrandsAllowlistBatch {
    bytes32 public constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Token decimals, fixed at deploy time to match the custodied
    ///         asset's native base unit (e.g. USDC = 6, BTC = 8, ETH = 18).
    uint8 private immutable _decimals;

    /// @notice allowedDestination[holder][destination] is true when `holder`
    ///         may transfer tokens to `destination`.
    mapping(address holder => mapping(address destination => bool)) public allowedDestination;

    /// @notice Emitted when a custodian burns tokens from a holder
    ///         without using the ERC20 allowance flow.
    event CustodyBurn(address indexed custodian, address indexed from, uint256 amount);

    /// @notice Emitted when the admin allows or disallows a transfer
    ///         destination for a holder.
    event DestinationAllowedSet(address indexed holder, address indexed destination, bool allowed);

    /// @notice Thrown when `holder` attempts a transfer to a `destination`
    ///         the admin has not approved for them.
    error TransferDestinationNotAllowed(address holder, address destination);

    /// @param admin     Address that will receive DEFAULT_ADMIN_ROLE.
    /// @param decimals_ Native decimals of the custodied asset; returned by `decimals()`.
    constructor(address admin, uint8 decimals_) ERC20("Strands Custody Token", "SCT") {
        require(admin != address(0), "admin=0");
        _decimals = decimals_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Decimals of this token, set at deploy time to match the custodied asset.
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint `amount` tokens to `to`. Restricted to MINTER_ROLE.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Burn `amount` tokens from `from` without consuming allowance.
    ///         Restricted to CUSTODIAN_ROLE.
    /// @dev    Reverts (via `_burn`) if `from` has insufficient balance.
    function custodyBurn(address from, uint256 amount) external onlyRole(CUSTODIAN_ROLE) {
        _burn(from, amount);
        emit CustodyBurn(msg.sender, from, amount);
    }

    /// @notice Allow or disallow `holder` to transfer tokens to `destination`.
    ///         Restricted to DEFAULT_ADMIN_ROLE.
    function setDestinationAllowed(address holder, address destination, bool allowed)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setDestinationAllowed(holder, destination, allowed);
    }

    /// @dev {StrandsAllowlistBatch} hook: gate batch writes on the same role the
    ///      single setter uses, producing an identical
    ///      `AccessControlUnauthorizedAccount` revert.
    function _checkAllowlistAdmin() internal view override {
        _checkRole(DEFAULT_ADMIN_ROLE);
    }

    /// @dev {StrandsAllowlistBatch} hook: the single write, shared by the public
    ///      setter and every batch entrypoint.
    function _setDestinationAllowed(address holder, address destination, bool allowed) internal override {
        allowedDestination[holder][destination] = allowed;
        emit DestinationAllowedSet(holder, destination, allowed);
    }

    /// @dev {StrandsAllowlistBatch} hook: read an edge.
    function _allowedDestination(address holder, address destination) internal view override returns (bool) {
        return allowedDestination[holder][destination];
    }

    /// @dev Enforce the per-holder destination allowlist on holder-to-holder
    ///      transfers only. Mints (`from == 0`) and burns (`to == 0`) bypass
    ///      the check, keeping `mint` / `burn` / `burnFrom` / `custodyBurn`
    ///      unrestricted.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && !allowedDestination[from][to]) {
            revert TransferDestinationNotAllowed(from, to);
        }
        super._update(from, to, value);
    }
}
