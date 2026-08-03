// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsAllowlistBatch } from "../../src/StrandsAllowlistBatch.sol";

/// @notice `setPairs` — the bidirectional helper the subaccount flow calls, and
///         the only batch writer on the token.
///         A link is exactly 2 edges: `user -> sub` and `sub -> user`.
///
///         It writes no self-edge. Self-transfers are gated like any other
///         route, so `x -> x` stays closed unless an admin approves it
///         explicitly; a contract that self-transfers without that approval is
///         supposed to fail rather than be silently accommodated.
///
/// @dev    `setPairs` is the subject here, so it is called directly rather than
///         through the fixture's `_link` / `_unlink` wrappers.
contract BatchLinkTest is BaseTest {
    function test_SetPairs_OpensBothDirections() public {
        vm.prank(admin);
        token.setPairs(_edges(alice, bob), true);

        assertTrue(token.allowedDestination(alice, bob));
        assertTrue(token.allowedDestination(bob, alice));
    }

    function test_SetPairs_WritesExactlyTwoEdgesPerPair() public {
        vm.recordLogs();
        vm.prank(admin);
        token.setPairs(_edges(alice, bob), true);

        _assertLogCount(2, "a link is 2 edges, no more");
    }

    /// @dev The behavior this change is about: linking must not quietly open a
    ///      self-route for either party.
    function test_SetPairs_WritesNoSelfEdge() public {
        vm.prank(admin);
        token.setPairs(_edges(alice, bob), true);

        assertFalse(token.allowedDestination(alice, alice), "user self-edge must stay closed");
        assertFalse(token.allowedDestination(bob, bob), "subaccount self-edge must stay closed");
    }

    /// @dev ...and a self-transfer therefore still reverts after linking.
    function test_SelfTransfer_StillRevertsAfterLinking() public {
        vm.prank(admin);
        token.setPairs(_edges(alice, bob), true);

        vm.prank(alice);
        _expectNotAllowed(alice, alice);
        token.transfer(alice, 1 ether);
    }

    /// @dev A self-route is reachable, but only by approving it on purpose with
    ///      the single setter — no batch entrypoint can produce an asymmetric
    ///      edge, which is the point of `setPairs` being the only one.
    function test_SelfEdge_RequiresExplicitApproval() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, alice, true);

        vm.prank(alice);
        token.transfer(alice, 1 ether);
        assertEq(token.balanceOf(alice), INITIAL_MINT, "self-transfer is balance-neutral");
    }

    function test_SetPairs_ClosesBothDirections() public {
        vm.startPrank(admin);
        token.setPairs(_edges(alice, bob), true);
        token.setPairs(_edges(alice, bob), false);
        vm.stopPrank();

        assertFalse(token.allowedDestination(alice, bob));
        assertFalse(token.allowedDestination(bob, alice));
    }

    function test_SetPairs_LinksManyPairsInOneCall() public {
        vm.prank(admin);
        token.setPairs(_edges(alice, bob, carol, minter), true);

        assertTrue(token.isLinked(alice, bob));
        assertTrue(token.isLinked(carol, minter));
        assertFalse(token.allowedDestination(alice, carol), "unrelated pairs stay closed");
    }

    /// @dev The behavioral payoff: after one linking transaction, value moves
    ///      both ways between the user and their subaccount, and nowhere else.
    function test_LinkedSubaccount_CanTransferBothWaysButNotOnward() public {
        vm.prank(admin);
        token.setPairs(_edges(alice, bob), true);

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

    function test_EmptyBatch_IsASuccessfulNoOp() public {
        StrandsAllowlistBatch.Edge[] memory none = new StrandsAllowlistBatch.Edge[](0);

        vm.recordLogs();
        vm.prank(admin);
        token.setPairs(none, true);

        _assertLogCount(0, "empty batch must emit nothing");
    }
}
