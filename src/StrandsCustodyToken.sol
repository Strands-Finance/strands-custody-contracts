// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title  Strands Custody Token (SCT)
/// @notice ERC20Burnable token with a privileged custodial burn path.
///         Users may burn their own balance (or burn another's via allowance)
///         using the standard `burn` / `burnFrom`. Accounts holding
///         CUSTODIAN_ROLE may additionally call `custodyBurn` to destroy
///         tokens from any holder without requiring prior allowance.
contract StrandsCustodyToken is ERC20Burnable, AccessControl {
    bytes32 public constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Token decimals, fixed at deploy time to match the custodied
    ///         asset's native base unit (e.g. USDC = 6, BTC = 8, ETH = 18).
    uint8 private immutable _decimals;

    /// @notice Emitted when a custodian burns tokens from a holder
    ///         without using the ERC20 allowance flow.
    event CustodyBurn(address indexed custodian, address indexed from, uint256 amount);

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
}
