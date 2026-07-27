// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  Strands Allowlist Batch
/// @notice Batch helpers for a per-holder destination allowlist, collapsing N
///         single-edge writes into one transaction. The saving is the fixed
///         21,000 gas base cost and the signature paid per transaction, not the
///         per-edge write cost.
/// @dev    Mixin with no storage of its own, so it does not disturb the
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

    /// @notice Thrown when `setDestinationsMixed` is given mismatched arrays.
    error ArrayLengthMismatch(uint256 edgesLength, uint256 flagsLength);

    /// @dev Must revert unless the caller may write allowlist edges.
    function _checkAllowlistAdmin() internal view virtual;

    /// @dev Must write the edge and emit the same event as the single setter.
    function _setDestinationAllowed(address holder, address destination, bool allowed) internal virtual;

    /// @dev Must read the current edge value.
    function _allowedDestination(address holder, address destination) internal view virtual returns (bool);

    /// @notice Set many edges to the same value.
    function setDestinations(Edge[] calldata edges, bool allowed) external {
        _checkAllowlistAdmin();
        for (uint256 i = 0; i < edges.length; ++i) {
            _setIfChanged(edges[i].holder, edges[i].destination, allowed);
        }
    }

    /// @notice Set many edges to per-edge values, mixing opens and closes in one
    ///         transaction.
    function setDestinationsMixed(Edge[] calldata edges, bool[] calldata allowed) external {
        _checkAllowlistAdmin();
        if (edges.length != allowed.length) revert ArrayLengthMismatch(edges.length, allowed.length);
        for (uint256 i = 0; i < edges.length; ++i) {
            _setIfChanged(edges[i].holder, edges[i].destination, allowed[i]);
        }
    }

    /// @notice Open or close BOTH directions for each pair — exactly 2 edges per
    ///         pair and nothing else. This is the subaccount-linking call:
    ///         `holder` is the user's main address, `destination` the subaccount.
    /// @dev    Self-edges are deliberately NOT written. A self-transfer is gated
    ///         like every other route, so `x -> x` stays closed unless an admin
    ///         approves it explicitly via `setDestinations`. Anything that
    ///         self-transfers without that approval is meant to fail.
    function setPairs(Edge[] calldata pairs, bool allowed) external {
        _checkAllowlistAdmin();
        for (uint256 i = 0; i < pairs.length; ++i) {
            _setIfChanged(pairs[i].holder, pairs[i].destination, allowed);
            _setIfChanged(pairs[i].destination, pairs[i].holder, allowed);
        }
    }

    /// @notice Hub-and-spoke: one holder, many destinations.
    function setDestinationsForHolder(address holder, address[] calldata destinations, bool allowed) external {
        _checkAllowlistAdmin();
        for (uint256 i = 0; i < destinations.length; ++i) {
            _setIfChanged(holder, destinations[i], allowed);
        }
    }

    /// @notice Many holders, one destination (e.g. a shared settlement address).
    function setHoldersForDestination(address[] calldata holders, address destination, bool allowed) external {
        _checkAllowlistAdmin();
        for (uint256 i = 0; i < holders.length; ++i) {
            _setIfChanged(holders[i], destination, allowed);
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
