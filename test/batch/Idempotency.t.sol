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
contract IdempotencyTest is BaseTest {
    function test_ReRunningAppliedBatch_EmitsNothing() public {
        vm.prank(admin);
        token.linkSubaccounts(_edges(alice, bob), true, true);

        vm.recordLogs();
        vm.prank(admin);
        token.linkSubaccounts(_edges(alice, bob), true, true);

        assertEq(vm.getRecordedLogs().length, 0, "re-applied batch must be silent");
        assertTrue(token.isLinked(alice, bob), "state must be unchanged, not cleared");
        assertTrue(token.allowedDestination(bob, bob));
    }

    function test_PartiallyAppliedBatch_EmitsOnlyTheMissingEdges() public {
        vm.prank(admin);
        token.setDestinations(_edges(alice, bob), true); // one of the two already applied

        vm.recordLogs();
        vm.prank(admin);
        token.setDestinations(_edges(alice, bob, alice, carol), true);

        assertEq(vm.getRecordedLogs().length, 1, "only the genuinely new edge emits");
        assertTrue(token.allowedDestination(alice, bob));
        assertTrue(token.allowedDestination(alice, carol));
    }

    function test_ClosingAnAlreadyClosedEdge_EmitsNothing() public {
        vm.recordLogs();
        vm.prank(admin);
        token.setDestinations(_edges(alice, bob, alice, carol), false); // never opened

        assertEq(vm.getRecordedLogs().length, 0, "closing a closed edge is a no-op");
    }

    /// @dev Side-by-side contrast with the single setter, so the divergence is
    ///      visible in one place rather than inferred across two suites.
    function test_SingleSetterReEmits_WhereBatchDoesNot() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true);

        vm.recordLogs();
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true); // redundant
        assertEq(vm.getRecordedLogs().length, 1, "single setter re-emits by design");

        vm.recordLogs();
        vm.prank(admin);
        token.setDestinations(_edges(alice, bob), true); // same redundant write, batched
        assertEq(vm.getRecordedLogs().length, 0, "batch path skips it");
    }

    /// @dev Skipping must not corrupt a mixed batch: untouched edges keep their
    ///      value while genuinely-changed ones are written.
    function test_MixedBatch_SkipsOnlyUnchangedEdges() public {
        vm.startPrank(admin);
        token.setDestinations(_edges(alice, bob), true);

        vm.recordLogs();
        // alice->bob already true (skip), alice->carol goes false->false (skip)
        token.setDestinationsMixed(_edges(alice, bob, alice, carol), _bools(true, false));
        vm.stopPrank();

        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(token.allowedDestination(alice, bob));
        assertFalse(token.allowedDestination(alice, carol));
    }
}
