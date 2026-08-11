// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  Transfer destination allowlist
/// @notice The complete allowlist surface of a custody token: one read, one write, one log, one
///         revert. Broken out so an integration can depend on the RESTRICTION without depending on
///         the token — a reconciler decoding {DestinationAllowedSet}, or a caller that needs to
///         answer "will this transfer land?" before spending gas on it, needs exactly these four
///         members and nothing from ERC20 or AccessControl.
///
/// @dev    The list is keyed by DESTINATION ALONE. It is a global set of permitted sinks, not a
///         graph of permitted routes: it says which addresses may RECEIVE, never which addresses
///         may SEND, and never which pairs may trade. `allowedDestination[x]` therefore authorises
///         every holder to reach `x`, and authorises `x` to reach nothing.
///
///         Default-deny. Every address starts `false`, so a freshly deployed token cannot transfer
///         anywhere until the writer opens a destination. That is the intended posture, not an
///         initialisation gap — see the warning on {setDestinationAllowed}.
///
///         Issuance and redemption are OUTSIDE this interface and unaffected by it: minting and
///         burning never pass through a destination check, so a balance can always be created at,
///         and destroyed from, an address that appears nowhere in this list. That is what keeps a
///         stranded balance redeemable rather than trapped.
///
///         Deliberately NOT advertised through ERC165. The implementing token does not advertise
///         `IERC20` either — OZ v5's `ERC20` is not ERC165 — so answering true for this one alone
///         would make `supportsInterface` a half-true capability signal, and would pin the id as a
///         de-facto ABI constant that silently changes the moment this interface gains a member.
interface ITransferAllowlist {
    /// @notice Emitted on every write, INCLUDING one that changes nothing.
    /// @dev    Deliberately unconditional. There is no on-chain enumeration of the list, so an
    ///         operator reconstructing it does so from this log alone — and the log is more useful
    ///         as a record of what the writer ASSERTED than of what changed. A re-run of a
    ///         provisioning job must therefore be visible, not silent.
    /// @param destination The address whose standing was written.
    /// @param allowed     The value written, not the delta.
    event DestinationAllowedSet(address indexed destination, bool allowed);

    /// @notice Thrown when a transfer names a destination that is not allowed.
    /// @dev    Carries the DESTINATION only, because the destination is the only thing that was
    ///         examined. An error that also named the sender would imply the sender's standing was
    ///         consulted, and a caller debugging a rejection would go looking for a per-holder
    ///         entry that does not exist.
    /// @param destination The `to` address that was refused.
    error TransferDestinationNotAllowed(address destination);

    /// @notice Whether `destination` may receive tokens by transfer.
    /// @dev    Open to any caller. A rejected transfer costs gas and reverts, so an integration
    ///         must be able to ask instead of probing.
    function allowedDestination(address destination) external view returns (bool);

    /// @notice Allow or disallow `destination` as a transfer recipient.
    /// @dev    One entry per call, by design — there is no batch form, so a partially-applied
    ///         provisioning run is a set of independent transactions with independent outcomes
    ///         rather than one all-or-nothing call whose failure is ambiguous.
    ///
    ///         WRITER LIVENESS IS A TRANSFER LIVENESS DEPENDENCY. If the writer role loses its last
    ///         holder, this function becomes permanently uncallable and the list freezes at
    ///         whatever it held in that block. If it was empty, no transfer will ever succeed
    ///         again. Redemption survives that (it does not consult this list); mobility does not.
    ///
    ///         `destination == address(0)` is an ordinary value and is NOT rejected: allowing it
    ///         opens nothing, because ERC20 refuses a zero receiver independently of this list.
    function setDestinationAllowed(address destination, bool allowed) external;
}
