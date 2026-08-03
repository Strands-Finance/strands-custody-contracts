// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  Strands Allowlist Batch
/// @notice Batched subaccount linking for a per-holder destination allowlist,
///         collapsing 2N single-edge writes into one transaction. The saving is
///         the fixed 21,000 gas base cost and the signature paid per
///         transaction, not the per-edge write cost.
/// @dev    The authorised topology is a set of disjoint user ↔ subaccount
///         2-cycles, so `setPairs` is the only batch WRITER: it is exactly the
///         shape the policy permits, and it cannot express any other. Anything
///         asymmetric — a self-edge, one leg of a link — is a deliberate,
///         one-at-a-time decision for the inheritor's single setter, not
///         something to make convenient in bulk.
///
///         Mixin with no storage of its own, so it does not disturb the
///         inheritor's storage layout. The inheriting contract supplies the
///         three hooks below.
///
///         Authorization is NOT re-implemented here. Every entrypoint reaches
///         `_checkAllowlistAdmin` and `_setDestinationAllowed` by internal jump
///         rather than an external call, so `msg.sender` is the original caller
///         and the inheritor's existing access control applies unchanged. A
///         separately *deployed* helper could not do this: OZ's `onlyRole`
///         resolves to `_msgSender()`, so the helper itself would be the caller
///         and would need the admin role granted to it.
abstract contract StrandsAllowlistBatch {
    /// @param holder      The address whose outbound transfers are being authorised.
    /// @param destination The address `holder` may send to.
    struct Edge {
        address holder;
        address destination;
    }

    /// @dev Must revert unless the caller may write allowlist edges.
    function _checkAllowlistAdmin() internal view virtual;

    /// @dev Must write the edge and emit the same event as the single setter.
    function _setDestinationAllowed(address holder, address destination, bool allowed) internal virtual;

    /// @dev Must read the current edge value.
    function _allowedDestination(address holder, address destination) internal view virtual returns (bool);

    /// @notice Open or close BOTH directions for each pair — exactly 2 edges per
    ///         pair and nothing else. This is the subaccount-linking call:
    ///         `holder` is the user's main address, `destination` the subaccount.
    /// @dev    Self-edges are deliberately NOT written. A self-transfer is gated
    ///         like every other route, so `x -> x` stays closed unless an admin
    ///         approves it explicitly with the single setter. Anything that
    ///         self-transfers without that approval is meant to fail.
    function setPairs(Edge[] calldata pairs, bool allowed) external {
        _checkAllowlistAdmin();
        for (uint256 i = 0; i < pairs.length; ++i) {
            _setIfChanged(pairs[i].holder, pairs[i].destination, allowed);
            _setIfChanged(pairs[i].destination, pairs[i].holder, allowed);
        }
    }

    // ---------- views: preflight, no authorization required ----------

    /// @notice Batch preflight. Use this instead of probing a route with a
    ///         zero-value transfer, which the allowlist also blocks.
    function areAllowed(Edge[] calldata edges) external view returns (bool[] memory out) {
        out = new bool[](edges.length);
        for (uint256 i = 0; i < edges.length; ++i) {
            out[i] = _allowedDestination(edges[i].holder, edges[i].destination);
        }
    }

    /// @notice True only when BOTH directions between `user` and `sub` are open.
    function isLinked(address user, address sub) external view returns (bool) {
        return _allowedDestination(user, sub) && _allowedDestination(sub, user);
    }

    /// @dev Skip no-op writes. The single setter has no short-circuit, so a
    ///      same-value write costs an SSTORE and emits a misleading event; at
    ///      batch scale a re-applied manifest would emit a wall of them. The
    ///      read also warms the slot the write then uses, so this is roughly
    ///      gas-neutral on fresh edges and a clear win on no-ops.
    function _setIfChanged(address holder, address destination, bool allowed) private {
        if (_allowedDestination(holder, destination) == allowed) return;
        _setDestinationAllowed(holder, destination, allowed);
    }
}
