// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice The bidirectional helpers — `setPairs` and `linkSubaccounts` — which
///         are what the subaccount flow actually calls. A "link" is 2 edges, or
///         3 when the subaccount self-edge is included.
contract BatchLinkTest is BaseTest {
    function test_SetPairs_OpensBothDirections() public {
        vm.prank(admin);
        token.setPairs(_edges(alice, bob), true);

        assertTrue(token.allowedDestination(alice, bob));
        assertTrue(token.allowedDestination(bob, alice));
    }

    function test_SetPairs_DoesNotOpenSelfEdges() public {
        vm.prank(admin);
        token.setPairs(_edges(alice, bob), true);

        assertFalse(token.allowedDestination(alice, alice));
        assertFalse(token.allowedDestination(bob, bob));
    }

    function test_SetPairs_ClosesBothDirections() public {
        vm.startPrank(admin);
        token.setPairs(_edges(alice, bob), true);
        token.setPairs(_edges(alice, bob), false);
        vm.stopPrank();

        assertFalse(token.allowedDestination(alice, bob));
        assertFalse(token.allowedDestination(bob, alice));
    }

    function test_LinkSubaccounts_WithoutSelfEdge_WritesTwoEdges() public {
        vm.recordLogs();
        vm.prank(admin);
        token.linkSubaccounts(_edges(alice, bob), false, true);

        assertEq(vm.getRecordedLogs().length, 2, "2 edges per link without self-edge");
        assertTrue(token.allowedDestination(alice, bob));
        assertTrue(token.allowedDestination(bob, alice));
        assertFalse(token.allowedDestination(bob, bob));
    }

    function test_LinkSubaccounts_WithSelfEdge_WritesThreeEdges() public {
        vm.recordLogs();
        vm.prank(admin);
        token.linkSubaccounts(_edges(alice, bob), true, true);

        assertEq(vm.getRecordedLogs().length, 3, "3 edges per link with self-edge");
        assertTrue(token.allowedDestination(alice, bob));
        assertTrue(token.allowedDestination(bob, alice));
        assertTrue(token.allowedDestination(bob, bob), "subaccount self-edge");
        assertFalse(token.allowedDestination(alice, alice), "user self-edge is NOT implied");
    }

    function test_LinkSubaccounts_UnlinkClosesTheSameEdgeSet() public {
        vm.startPrank(admin);
        token.linkSubaccounts(_edges(alice, bob), true, true);
        token.linkSubaccounts(_edges(alice, bob), true, false);
        vm.stopPrank();

        assertFalse(token.allowedDestination(alice, bob));
        assertFalse(token.allowedDestination(bob, alice));
        assertFalse(token.allowedDestination(bob, bob));
    }

    function test_LinkSubaccounts_LinksManyPairsInOneCall() public {
        vm.prank(admin);
        token.linkSubaccounts(_edges(alice, bob, carol, minter), false, true);

        assertTrue(token.isLinked(alice, bob));
        assertTrue(token.isLinked(carol, minter));
        assertFalse(token.allowedDestination(alice, carol), "unrelated pairs stay closed");
    }

    /// @dev The behavioral payoff: after one linking transaction, value moves
    ///      both ways between the user and their subaccount, and nowhere else.
    function test_LinkedSubaccount_CanTransferBothWaysButNotOnward() public {
        vm.prank(admin);
        token.linkSubaccounts(_edges(alice, bob), true, true);

        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether, "user -> subaccount");

        vm.prank(bob);
        token.transfer(alice, 40 ether);
        assertEq(token.balanceOf(bob), 60 ether, "subaccount -> user");

        // the subaccount is itself a holder: onward routes are separate edges
        vm.prank(bob);
        _expectNotAllowed(bob, carol);
        token.transfer(carol, 1 ether);
    }
}
