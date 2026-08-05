// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title  Strands Custody Token
/// @notice ERC20 token where a balance is a claim against an off-chain ledger, so destroying supply is a
///         privileged act. The invariant a reconciler may rely on is that EVERY burn emits {CustodyBurn} —
///         not that every burn is a custodian. `custodyBurn`, `burn` and `burnFrom` are CUSTODIAN_ROLE; the
///         supply-checked `guardBurn` is MINTER_ROLE (see its docs for why). A holder can do neither, and
///         cannot delegate that power via an ERC20 allowance. Transfers are ordinary, unrestricted ERC20.
///
/// @dev    Deployment is TWO steps: `constructor` then `initialize`. The constructor seats the deployer as
///         DEFAULT_ADMIN_ROLE and grants no operating role, so a deployed-but-uninitialized token is inert
///         (nothing mints, nothing burns) and recoverable (the deployer can still initialize it).
///
///         {Initializable} is used here as a call-this-exactly-once guard, in the same role
///         `SimpleInitializable` plays across the Strands contracts — NOT as an upgradeability story. This
///         token is NOT proxy-safe: `_decimals` is immutable and ERC20's name/symbol are written by the
///         constructor, so behind a proxy all three would read empty.
contract StrandsCustodyToken is ERC20Burnable, AccessControl, Initializable {
    bytes32 public constant CUSTODIAN_ROLE = keccak256("CUSTODIAN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Token decimals, fixed at deploy time to match the custodied
    ///         asset's native base unit (e.g. USDC = 6, BTC = 8, ETH = 18).
    uint8 private immutable _decimals;

    /// @notice Emitted on every burn, whichever entrypoint destroyed the supply.
    /// @dev    A reconciler tracking the off-chain ledger can subscribe to this alone: `custodyBurn`,
    ///         `guardBurn`, `burn` and `burnFrom` all emit it, so no destroyed supply is invisible here.
    ///         `burnedBy` is whoever called — a custodian on three of those paths and a minter on
    ///         `guardBurn`. `burnedBy == from` means the caller burned their own balance via `burn`.
    event CustodyBurn(address indexed burnedBy, address indexed from, uint256 amount);

    /// @notice Thrown when a guarded call's supply estimate does not match the actual total supply.
    /// @param actualSupply    The chain's `totalSupply()` at execution time.
    /// @param estimatedSupply The caller's claimed supply.
    error SupplyMismatch(uint256 actualSupply, uint256 estimatedSupply);

    /// @param decimals_ Native decimals of the custodied asset; returned by `decimals()`.
    /// @param name_     ERC20 name. Per-deployment rather than baked in, so one token is distinguishable from the
    ///                  next on an explorer: the backend composes asset + custodian, e.g. "Strands Custody USDC
    ///                  (BitGo)". It identifies the ASSET and CUSTODIAN only — never the holder.
    /// @param symbol_   ERC20 symbol, likewise per-deployment, e.g. "scUSDC".
    /// @dev   The DEPLOYER receives DEFAULT_ADMIN_ROLE, and is therefore the only address that can call
    ///        {initialize}. That is what closes the front-running window a bare `initializer`-only guard
    ///        would leave open on a CREATE-deployed contract: between the deploy landing and the operator's
    ///        second transaction, anyone could otherwise seat themselves as minter and custodian.
    constructor(uint8 decimals_, string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        // Empty metadata is UNRECOVERABLE: there is no setter, so the token would be permanently anonymous and the
        // only remedy is redeploy-and-re-mint. Reverting the deploy is the cheap end of that trade.
        require(bytes(name_).length != 0, "name=0");
        require(bytes(symbol_).length != 0, "symbol=0");
        _decimals = decimals_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Seat every operating role in one call. Callable exactly once, by the deployer only.
    /// @param admin     Receives DEFAULT_ADMIN_ROLE.
    /// @param minter    Receives MINTER_ROLE: `mint`, `guardMint`, `guardBurn`.
    /// @param custodian Receives CUSTODIAN_ROLE: `custodyBurn`, `burn`, `burnFrom`.
    /// @dev   Both guards are load-bearing and neither is sufficient alone: `onlyRole(DEFAULT_ADMIN_ROLE)` is
    ///        what makes this un-front-runnable, and `initializer` is what makes it un-repeatable. Without the
    ///        role check a stranger seats themselves first; without `initializer` an admin could silently
    ///        re-seat a different minter under a call named "initialize".
    ///
    ///        The deployer's own admin role is revoked unless it IS the admin, so the role graph afterwards is
    ///        exactly what the arguments say — no residual deployer privilege for an auditor to chase. When
    ///        `admin == msg.sender` (the backend's shape: one mint-authority EOA is deployer, admin, minter and
    ///        custodian) that revoke is skipped rather than performed-and-undone.
    ///
    ///        NOT IDEMPOTENT. A second call reverts with `InvalidInitialization()`, unlike the two `grantRole`
    ///        sends this replaces. A caller with a retry path must read `hasRole` first rather than re-calling.
    function initialize(address admin, address minter, address custodian)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        initializer
    {
        require(admin != address(0), "admin=0");
        require(minter != address(0), "minter=0");
        require(custodian != address(0), "custodian=0");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, minter);
        _grantRole(CUSTODIAN_ROLE, custodian);

        if (msg.sender != admin) _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Decimals of this token, set at deploy time to match the custodied asset.
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint `amount` tokens to `to`. Restricted to MINTER_ROLE.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Mint `amount` tokens to `to`, but only if `totalSupply()` equals `estimatedSupply`.
    ///         Restricted to MINTER_ROLE.
    /// @dev    The backend mints the DELTA between the custodian balance and the circulating supply it just
    ///         read. If that read was wrong — a stale RPC replica, a race with a concurrent burn or mint, a
    ///         crashed-and-repeated attempt — the delta is wrong by the same amount, and minting it desyncs the
    ///         token from the ledger it mirrors. Passing the read back in makes the assumption enforceable:
    ///         a mismatch reverts the mint instead of compounding the error. `estimatedSupply` is the
    ///         PRE-mint supply; a fresh deployment therefore passes 0.
    ///         `_mint` is called directly rather than through `mint`: an external self-call would make
    ///         `msg.sender` this contract and fail the role check.
    function guardMint(address to, uint256 amount, uint256 estimatedSupply) external onlyRole(MINTER_ROLE) {
        uint256 actual = totalSupply();
        if (actual != estimatedSupply) revert SupplyMismatch(actual, estimatedSupply);
        _mint(to, amount);
    }

    /// @notice Burn `amount` from `from` without consuming allowance, but only if `totalSupply()` equals
    ///         `estimatedSupply`. Restricted to MINTER_ROLE.
    /// @dev    The mirror of `guardMint`, for the mirror-image reason. The backend reads circulating supply,
    ///         decides an amount against it, and sends. If that read was stale — an RPC replica behind head, a
    ///         race with a concurrent mint, a crashed-and-repeated attempt — the burn destroys supply the
    ///         off-chain ledger never authorised. Passing the read back in makes the assumption enforceable:
    ///         a mismatch reverts instead of silently desyncing. `estimatedSupply` is the PRE-burn supply.
    ///
    ///         MINTER_ROLE, not CUSTODIAN_ROLE. This is the ONE burn path not gated on the custodian, and it
    ///         is why this contract's invariant is "every burn emits {CustodyBurn}" rather than "every burn is
    ///         a custodian" — a reconciler subscribed to that event still sees every destroyed unit, and the
    ///         `burnedBy` parameter reports a minter here. Splitting MINTER_ROLE and CUSTODIAN_ROLE across
    ///         different keys therefore hands the MINTER side the power to destroy supply; today the backend's
    ///         single mint-authority EOA holds both.
    ///
    ///         `_burn` is called directly rather than through `custodyBurn`: an external self-call would make
    ///         `msg.sender` this contract and fail the role check.
    function guardBurn(address from, uint256 amount, uint256 estimatedSupply) external onlyRole(MINTER_ROLE) {
        uint256 actual = totalSupply();
        if (actual != estimatedSupply) revert SupplyMismatch(actual, estimatedSupply);
        _burn(from, amount);
        emit CustodyBurn(msg.sender, from, amount);
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
