// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title  Strands Custody Token
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
    /// @param name_     ERC20 name. Per-deployment rather than baked in, so one token is distinguishable from the
    ///                  next on an explorer: the backend composes asset + custodian, e.g. "Strands Custody USDC
    ///                  (BitGo)". It identifies the ASSET and CUSTODIAN only — never the holder.
    /// @param symbol_   ERC20 symbol, likewise per-deployment, e.g. "scUSDC".
    constructor(address admin, uint8 decimals_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        require(admin != address(0), "admin=0");
        // Empty metadata is UNRECOVERABLE: there is no setter, so the token would be permanently anonymous and the
        // only remedy is redeploy-and-re-mint. Reverting the deploy is the cheap end of that trade.
        require(bytes(name_).length != 0, "name=0");
        require(bytes(symbol_).length != 0, "symbol=0");
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
