// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { ITransferAllowlist } from "./interfaces/ITransferAllowlist.sol";

/// @title  Strands Digital Asset Custodial Account Proxy
/// @notice ERC20 token where a balance is a claim against an off-chain ledger, so changing how many tokens
///         exist is a privileged act. ONE operating role owns both directions: `mint` and `guardMint` create
///         supply, `adminBurn`, `guardBurn`, `burn` and `burnFrom` destroy it, and all six are MINTER_ROLE.
///         A reconciler therefore gets two invariants rather than one — every burn emits {Burned}, AND every
///         burn is a MINTER_ROLE holder. A holder can do none of it, and cannot delegate the power via an
///         ERC20 allowance.
///
///         Transfers are default-deny against a destination allowlist: a holder may send only to addresses
///         DEFAULT_ADMIN_ROLE has opened. Issuance and redemption are exempt, so a balance can always be
///         minted to, and redeemed from, an address that is on no list.
///
/// @dev
///         This contract is an IMPLEMENTATION. It is never used directly: every token is a `BeaconProxy`
///         that delegates here, so each token's balances, roles, metadata and allowlist live in that proxy's
///         own storage and one deployment of this code backs all of them. The constructor locks the
///         implementation itself, and {initializeToken} does per token what a constructor would have done.
///
///         The logic behind every proxy is whatever the beacon names, so the BEACON'S OWNER can replace it for
///         all tokens at once. That power is outside this contract and outside its roles — DEFAULT_ADMIN_ROLE
///         cannot upgrade anything. Nothing here upgrades, and no upgrade function exists on the token.
///
///         State this contract adds lives in one ERC-7201 namespaced struct ({DACAPStorage}), as OpenZeppelin's
///         upgradeable bases keep theirs, so a later version can change its inheritance without moving a slot.
///         A LATER VERSION MAY ONLY APPEND TO THAT STRUCT.
///
///         Two things about WHERE the transfer guard lives, both deliberate:
///
///         It sits in the `transfer` / `transferFrom` OVERRIDES, not in `_update`. `_update` is the single
///         funnel for mints, burns AND transfers, so a guard there has to reconstruct which of the three it
///         is from zero-address sentinels — and an earlier version of this contract did exactly that.
///         Guarding the two user-callable entrypoints instead makes the exemption structural: `_mint` and
///         `_burn` do not route through them, so there is no exemption to encode and none to get wrong. The
///         cost is that the guard is NOT inherited by any future caller of `_transfer` or `_update` — OZ's
///         `_transfer` is not even virtual. There are none today. ANY NEW FUNCTION THAT MOVES A BALANCE MUST
///         GO THROUGH `transfer` / `transferFrom` OR RE-STATE THE GUARD.
///
///         It reads `to` and nothing else. Not `from`, not `msg.sender`. On `transferFrom` that means the
///         SPENDER'S standing and the OWNER'S standing are both irrelevant; the ERC20 allowance is still the
///         whole story of who may act, and the allowlist is the whole story of where value may land.
contract StrandsDACAP is ERC20BurnableUpgradeable, AccessControlUpgradeable, ITransferAllowlist {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @custom:storage-location erc7201:strands.storage.StrandsDACAP
    struct DACAPStorage {
        /// @dev Token decimals, fixed at deploy time to match the custodied asset's native base unit
        ///      (e.g. USDC = 6, BTC = 8, ETH = 18).
        uint8 decimals;
        /// @dev Whether a destination may receive tokens by transfer. Flat and destination-keyed on purpose. An
        ///      earlier version keyed this `[holder][destination]`, which made the list a graph of
        ///      O(holders x destinations) directed edges that an operator had to open one pair at a time and
        ///      could never enumerate. One key states the property that was actually being enforced: some
        ///      addresses are acceptable places for value to land, and the rest are not.
        mapping(address destination => bool) allowedDestination;
    }

    // keccak256(abi.encode(uint256(keccak256("strands.storage.StrandsDACAP")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant DACAP_STORAGE_LOCATION =
        0x94b7310252f3826cce10f0dba840c935d992f0d817174335cd814aafabd92d00;

    /// @notice Emitted on every burn, whichever entrypoint destroyed the supply.
    /// @dev    A reconciler tracking the off-chain ledger can subscribe to this alone: `adminBurn`,
    ///         `guardBurn`, `burn` and `burnFrom` all emit it, so no destroyed supply is invisible here.
    ///         `burnedBy` is whoever called — necessarily a MINTER_ROLE holder, on every path.
    ///         `burnedBy == from` means the caller burned their own balance via `burn`.
    event Burned(address indexed burnedBy, address indexed from, uint256 amount);

    /// @notice Thrown when a guarded call's supply estimate does not match the actual total supply.
    /// @param actualSupply    The chain's `totalSupply()` at execution time.
    /// @param estimatedSupply The caller's claimed supply.
    error SupplyMismatch(uint256 actualSupply, uint256 estimatedSupply);

    /// @dev Locks the implementation: nothing can initialize it, so the only state this code ever touches is a
    ///      proxy's.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Fix the token's metadata and seat the deployer as both admin and minter. The token's only
    ///         initializer: what a constructor would do, and called the same way, as part of the deploy itself.
    /// @param decimals_ Native decimals of the custodied asset; returned by `decimals()`.
    /// @param name_     ERC20 name. Per-deployment rather than baked in, so one token is distinguishable from the
    ///                  next on an explorer: the backend composes custodian + asset, e.g.
    ///                  "Strands.DACAP.BitGo.USDC". It identifies the CUSTODIAN and ASSET only — never the holder.
    /// @param symbol_   ERC20 symbol, likewise per-deployment, and the SAME string as `name_`: these labels
    ///                  identify a custodial claim rather than a tradeable ticker, so there is no short form
    ///                  worth having that a reader could not resolve back to the full name.
    /// @dev   MUST be passed as the proxy constructor's `data`, so it runs inside the proxy's own deploy
    ///        transaction. There `msg.sender` is whoever deployed the proxy, exactly as it was in a constructor,
    ///        and that address receives DEFAULT_ADMIN_ROLE and MINTER_ROLE. The token is live from the deploy:
    ///        there is no second transaction, so there is no window in which it exists without its roles for
    ///        anyone to step into. Handing either role on afterwards is ordinary AccessControl — `grantRole`,
    ///        then `renounceRole` — by the admin.
    ///
    ///        "Whoever deployed the proxy" is its IMMEDIATE creator. Deploy it directly from the key that should
    ///        hold the roles: a factory, a CREATE2 deployer or a batching contract that creates the proxy
    ///        receives both roles instead.
    ///
    ///        A PROXY DEPLOYED WITH EMPTY `data` HAS NO SUCH DEFENCE: the first caller of this function becomes
    ///        its admin and minter.
    ///
    ///        `initializer` makes this version 1. An initializer added by a later implementation is therefore
    ///        `reinitializer(2)`, and must also be `onlyRole(DEFAULT_ADMIN_ROLE)`: a beacon upgrade runs no
    ///        initializer, and `reinitializer` alone does not check who calls it.
    function initializeToken(uint8 decimals_, string calldata name_, string calldata symbol_) external initializer {
        // Empty metadata is UNRECOVERABLE: there is no setter, so the token would be permanently anonymous and the
        // only remedy is redeploy-and-re-mint. Reverting the deploy is the cheap end of that trade.
        require(bytes(name_).length != 0, "name=0");
        require(bytes(symbol_).length != 0, "symbol=0");

        // Behind a proxy the parents' constructors never run; these stand in for them, base-first in linearization
        // order. Only `__ERC20_init` writes state (name, symbol). The other two are empty in OpenZeppelin v5.1 and
        // called anyway, as OpenZeppelin's own Wizard does, so a later version that gives them state is covered.
        __ERC20_init(name_, symbol_);
        __ERC20Burnable_init();
        __AccessControl_init();

        _getDACAPStorage().decimals = decimals_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    /// @notice Decimals of this token, set at deploy time to match the custodied asset.
    function decimals() public view virtual override returns (uint8) {
        return _getDACAPStorage().decimals;
    }

    /// @notice Mint `amount` tokens to `to`. Restricted to MINTER_ROLE.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Mint `amount` tokens to `to`, but only if `totalSupply()` equals `estimatedSupply`.
    ///         Restricted to MINTER_ROLE.
    /// @dev Reverts if caller doesn't know state of the contract
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
    ///         `_burn` is called directly rather than through `adminBurn`: an external self-call would make
    ///         `msg.sender` this contract and fail the role check.
    function guardBurn(address from, uint256 amount, uint256 estimatedSupply) external onlyRole(MINTER_ROLE) {
        uint256 actual = totalSupply();
        if (actual != estimatedSupply) revert SupplyMismatch(actual, estimatedSupply);
        _burn(from, amount);
        emit Burned(msg.sender, from, amount);
    }

    /// @notice Burn `amount` tokens from `from` without consuming allowance.
    ///         Restricted to MINTER_ROLE.
    /// @dev    The UNGUARDED counterpart to `guardBurn` — it takes no supply
    ///         estimate and so cannot refuse a burn decided against a stale
    ///         read. The backend never sends it; it is the operator's manual
    ///         escape hatch, which is what the `admin` in the name refers to.
    ///         Reverts (via `_burn`) if `from` has insufficient balance.
    function adminBurn(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        _burn(from, amount);
        emit Burned(msg.sender, from, amount);
    }

    /// @notice Burn `amount` of the caller's own balance. Restricted to
    ///         MINTER_ROLE — a holder who could burn unilaterally would
    ///         desync the off-chain ledger the balance is a claim against.
    function burn(uint256 amount) public override onlyRole(MINTER_ROLE) {
        super.burn(amount);
        emit Burned(msg.sender, msg.sender, amount);
    }

    /// @notice Burn `amount` from `from`, spending the caller's allowance.
    ///         Restricted to MINTER_ROLE. Strictly weaker than `adminBurn`,
    ///         which needs no allowance; retained so the inherited
    ///         ERC20Burnable surface stays coherent rather than silently
    ///         reachable.
    /// @dev    The role check runs BEFORE `super`, so a rejected call never
    ///         reaches `_spendAllowance` and leaves the allowance intact.
    function burnFrom(address from, uint256 amount) public override onlyRole(MINTER_ROLE) {
        super.burnFrom(from, amount);
        emit Burned(msg.sender, from, amount);
    }

    /// @inheritdoc ITransferAllowlist
    function allowedDestination(address destination) external view override returns (bool) {
        return _getDACAPStorage().allowedDestination[destination];
    }

    /// @inheritdoc ITransferAllowlist
    /// @dev The write is unconditional and so is the event — see the note on
    ///      {ITransferAllowlist-DestinationAllowedSet}. Restricted to
    ///      DEFAULT_ADMIN_ROLE, which makes this the admin's SECOND standing
    ///      power after the role graph. It is a power over MOBILITY, not over
    ///      value: closing every destination strands a balance where it is, and
    ///      cannot move it anywhere, least of all to the admin. No burn path
    ///      consults this list, so a stranded balance is still redeemable.
    function setDestinationAllowed(address destination, bool allowed) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _getDACAPStorage().allowedDestination[destination] = allowed;
        emit DestinationAllowedSet(destination, allowed);
    }

    /// @notice Move `value` of the caller's balance to `to`, which must be an
    ///         allowed destination.
    /// @dev    The guard runs BEFORE `super`, so a refused transfer never
    ///         reaches `ERC20._transfer` and never reads a balance. It
    ///         therefore beats both of OZ's own checks: a call refused here
    ///         reports {ITransferAllowlist-TransferDestinationNotAllowed} even
    ///         when the amount also exceeds the balance, and even when `to` is
    ///         the zero address.
    function transfer(address to, uint256 value) public override returns (bool) {
        _requireDestinationAllowed(to);
        return super.transfer(to, value);
    }

    /// @notice Move `value` of `from`'s balance to `to`, spending the caller's
    ///         allowance. `to` must be an allowed destination.
    /// @dev    ONLY `to` is checked. Neither `from` nor `msg.sender` is
    ///         consulted, so an allowlisted spender gains nothing and a
    ///         non-allowlisted owner loses nothing — this is the one place a
    ///         per-holder list and a destination list visibly disagree, and the
    ///         destination list is what this contract enforces.
    ///
    ///         Same ordering argument as `transfer`, with one extra
    ///         consequence: the guard runs before `_spendAllowance`, so a
    ///         refused call does not merely have its allowance spend UNWOUND by
    ///         the revert — it never reaches the spend at all. Identical shape
    ///         to the role check on `burnFrom` above.
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _requireDestinationAllowed(to);
        return super.transferFrom(from, to, value);
    }

    /// @dev The single allowlist read, shared by both entrypoints. Private and
    ///      not `internal`: nothing outside these two calls it, and keeping it
    ///      unreachable from a subclass is what stops it becoming a check a
    ///      future entrypoint is assumed to have made.
    function _requireDestinationAllowed(address destination) private view {
        if (!_getDACAPStorage().allowedDestination[destination]) revert TransferDestinationNotAllowed(destination);
    }

    function _getDACAPStorage() private pure returns (DACAPStorage storage $) {
        assembly {
            $.slot := DACAP_STORAGE_LOCATION
        }
    }
}
