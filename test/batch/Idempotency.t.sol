// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice Batch paths skip writes for edges already at the target value.
///
///         This is a DELIBERATE divergence from the single setter, which
///         re-emits on a redundant write (pinned by
///         `test/allowlist/SetDestination.t.sol`). At batch scale a re-applied
///         manifest would otherwise emit a wall of misleading
///         `DestinationAllowedSet` events, making the log useless for telling
///         "this route just opened" from "this route was already open".
///
/// @dev    Which entrypoint wrote what is exactly what is under test, so both
///         setters are called directly rather than through the fixture's
///         `_allow` / `_link` wrappers.
contract IdempotencyTest is BaseTest {
    function test_ReRunningAppliedBatch_EmitsNothing() public {
        vm.prank(admin);
        token.setPairs(_edges(alice, bob), true);

        vm.recordLogs();
        vm.prank(admin);
        token.setPairs(_edges(alice, bob), true);

        _assertLogCount(0, "re-applied batch must be silent");
        assertTrue(token.isLinked(alice, bob), "state must be unchanged, not cleared");
    }

    /// @dev The skip is per EDGE, not per pair: a half-linked pair completes with
    ///      exactly one write.
    function test_HalfLinkedPair_EmitsOnlyTheMissingDirection() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true); // one of the two legs already applied

        vm.recordLogs();
        vm.prank(admin);
        token.setPairs(_edges(alice, bob), true);

        _assertLogCount(1, "only the genuinely new edge emits");
        assertTrue(token.isLinked(alice, bob));
    }

    function test_ClosingAnAlreadyClosedEdge_EmitsNothing() public {
        vm.recordLogs();
        vm.prank(admin);
        token.setPairs(_edges(alice, bob, alice, carol), false); // never opened

        _assertLogCount(0, "closing a closed edge is a no-op");
    }

    /// @dev Side-by-side contrast with the single setter, so the divergence is
    ///      visible in one place rather than inferred across two suites.
    function test_SingleSetterReEmits_WhereBatchDoesNot() public {
        vm.startPrank(admin);
        token.setDestinationAllowed(alice, bob, true);
        token.setDestinationAllowed(bob, alice, true);

        vm.recordLogs();
        token.setDestinationAllowed(alice, bob, true); // redundant
        _assertLogCount(1, "single setter re-emits by design");

        vm.recordLogs();
        token.setPairs(_edges(alice, bob), true); // same redundant writes, batched
        _assertLogCount(0, "batch path skips them");
        vm.stopPrank();
    }

    /// @dev Skipping must not corrupt a multi-pair batch: an already-linked pair
    ///      is left alone while a genuinely new one is written in full.
    function test_MultiPairBatch_SkipsOnlyTheLinkedPair() public {
        vm.startPrank(admin);
        token.setPairs(_edges(alice, bob), true);

        vm.recordLogs();
        token.setPairs(_edges(alice, bob, carol, minter), true);
        vm.stopPrank();

        _assertLogCount(2, "only the new pair's 2 edges emit");
        assertTrue(token.isLinked(alice, bob), "the applied pair is untouched, not cleared");
        assertTrue(token.isLinked(carol, minter));
    }
}
