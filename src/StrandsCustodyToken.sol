// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title  Strands Custody Token (SCT)
/// @notice ERC20 token where a balance is a claim against an off-chain ledger,
///         so destroying supply is CUSTODIAN_ROLE-only. That covers the whole
///         burn surface — the inherited `burn` / `burnFrom` are gated exactly
///         like `custodyBurn`, and all three emit {CustodyBurn}. A holder
///         cannot redeem themselves, and cannot delegate that power via an
///         ERC20 allowance. Transfers are ordinary, unrestricted ERC20.
contract StrandsCustodyToken is ERC20Burnable, AccessControl {
    bytes32 public constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Token decimals, fixed at deploy time to match the custodied
    ///         asset's native base unit (e.g. USDC = 6, BTC = 8, ETH = 18).
    uint8 private immutable _decimals;

    /// @notice Emitted on every burn, whichever entrypoint the custodian used.
    /// @dev    A reconciler tracking the off-chain ledger can subscribe to this
    ///         alone: `custodyBurn`, `burn` and `burnFrom` all emit it, so no
    ///         destroyed supply is invisible here. `from == custodian` means the
    ///         custodian burned their own balance via `burn`.
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

    /// @notice Burn `amount` of the caller's own balance. Restricted to
    ///         CUSTODIAN_ROLE — a holder who could burn unilaterally would
    ///         desync the off-chain ledger the balance is a claim against.
    function burn(uint256 amount) public override onlyRole(CUSTODIAN_ROLE) {
        super.burn(amount);
        emit CustodyBurn(msg.sender, msg.sender, amount);
    }

    /// @notice Burn `amount` from `from`, spending the caller's allowance.
    ///         Restricted to CUSTODIAN_ROLE. Strictly weaker than
    ///         `custodyBurn`, which needs no allowance; retained so the
    ///         inherited ERC20Burnable surface stays coherent rather than
    ///         silently reachable.
    /// @dev    The role check runs BEFORE `super`, so a rejected call never
    ///         reaches `_spendAllowance` and leaves the allowance intact.
    function burnFrom(address from, uint256 amount) public override onlyRole(CUSTODIAN_ROLE) {
        super.burnFrom(from, amount);
        emit CustodyBurn(msg.sender, from, amount);
    }
}
