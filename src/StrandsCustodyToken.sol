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
///         ERC20 allowance.
///         Holder-to-holder transfers are default-deny: a holder may only
///         transfer to destinations the admin has approved for that holder.
///         The admin can move any balance regardless of the allowlist via
///         {adminTransfer}.
contract StrandsCustodyToken is ERC20Burnable, AccessControl {
    bytes32 public constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Token decimals, fixed at deploy time to match the custodied
    ///         asset's native base unit (e.g. USDC = 6, BTC = 8, ETH = 18).
    uint8 private immutable _decimals;

    /// @notice allowedDestination[holder][destination] is true when `holder`
    ///         may transfer tokens to `destination`.
    mapping(address holder => mapping(address destination => bool)) public allowedDestination;

    /// @notice Emitted on every burn, whichever entrypoint the custodian used.
    /// @dev    A reconciler tracking the off-chain ledger can subscribe to this
    ///         alone: `custodyBurn`, `burn` and `burnFrom` all emit it, so no
    ///         destroyed supply is invisible here. `from == custodian` means the
    ///         custodian burned their own balance via `burn`.
    event CustodyBurn(address indexed custodian, address indexed from, uint256 amount);

    /// @notice Emitted when the admin allows or disallows a transfer
    ///         destination for a holder.
    event DestinationAllowedSet(address indexed holder, address indexed destination, bool allowed);

    /// @notice Emitted when an admin moves a balance without the holder's
    ///         consent.
    /// @dev    {adminTransfer} also emits the standard ERC20 {Transfer}, which
    ///         is indistinguishable from an ordinary one, so a reconciler that
    ///         needs to tell the two apart must subscribe to this.
    event AdminTransfer(address indexed admin, address indexed from, address indexed to, uint256 amount);

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

    /// @notice Allow or disallow `holder` to transfer tokens to `destination`.
    ///         One directed edge. Restricted to DEFAULT_ADMIN_ROLE.
    function setDestinationAllowed(address holder, address destination, bool allowed)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _setDestinationAllowed(holder, destination, allowed);
    }

    /// @notice Open or close BOTH directions between `holder` and `destination`.
    ///         Restricted to DEFAULT_ADMIN_ROLE.
    /// @dev    Exactly two edges and nothing else, so linking `a <-> b` and
    ///         `a <-> c` leaves `b -> c` closed. Self-linking is rejected
    ///         rather than silently opening a self-route; `x -> x` is an
    ///         ordinary edge an admin must approve on purpose via
    ///         `setDestinationAllowed`.
    function setLink(address holder, address destination, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(holder != destination, "self-link");
        _setDestinationAllowed(holder, destination, allowed);
        _setDestinationAllowed(destination, holder, allowed);
    }

    /// @notice Move `amount` from `from` to `to`, bypassing the destination
    ///         allowlist and without spending any ERC20 allowance.
    ///         Restricted to DEFAULT_ADMIN_ROLE.
    /// @dev    Reaches `super._update` because the guard lives in `_update` and
    ///         `ERC20._transfer` is not virtual. The two checks below are what
    ///         that parent would have done, restated so skipping the allowlist
    ///         does not also skip them — they keep this from becoming a mint or
    ///         burn path, leaving total supply unchanged.
    function adminTransfer(address from, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));

        super._update(from, to, amount);
        emit AdminTransfer(msg.sender, from, to, amount);
    }

    /// @dev The single allowlist write, shared by both setters.
    function _setDestinationAllowed(address holder, address destination, bool allowed) private {
        allowedDestination[holder][destination] = allowed;
        emit DestinationAllowedSet(holder, destination, allowed);
    }

    /// @dev Enforce the per-holder destination allowlist on holder-to-holder
    ///      transfers only. Mints (`from == 0`) and burns (`to == 0`) bypass
    ///      the check, so issuance and redemption need no edges. That is an
    ///      exemption from the ALLOWLIST and nothing more: `mint` is still
    ///      MINTER_ROLE and every burn path is still CUSTODIAN_ROLE.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && !allowedDestination[from][to]) {
            revert TransferDestinationNotAllowed(from, to);
        }
        super._update(from, to, value);
    }
}
