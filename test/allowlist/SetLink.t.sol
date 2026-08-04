// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice `setLink` — the bidirectional setter.
///         A link is exactly 2 edges: `a -> b` and `b -> a`.
///
///         It writes no self-edge. Self-transfers are gated like any other
///         route, so `x -> x` stays closed unless an admin approves it
///         explicitly; a contract that self-transfers without that approval is
///         supposed to fail rather than be silently accommodated.
///
/// @dev    `setLink` is the subject here, so it is called directly rather than
///         through the fixture's `_link` / `_unlink` wrappers.
contract SetLinkTest is BaseTest {
    function test_SetLink_OpensBothDirections() public {
        vm.prank(admin);
        token.setLink(alice, bob, true);

        assertTrue(token.allowedDestination(alice, bob));
        assertTrue(token.allowedDestination(bob, alice));
    }

    function test_SetLink_WritesExactlyTwoEdges() public {
        vm.recordLogs();
        vm.prank(admin);
        token.setLink(alice, bob, true);

        _assertLogCount(2, "a link is 2 edges, no more");
    }

    /// @dev Linking must not quietly open a self-route for either party.
    function test_SetLink_WritesNoSelfEdge() public {
        vm.prank(admin);
        token.setLink(alice, bob, true);

        assertFalse(token.allowedDestination(alice, alice), "holder self-edge must stay closed");
        assertFalse(token.allowedDestination(bob, bob), "destination self-edge must stay closed");
    }

    /// @dev ...and a self-transfer therefore still reverts after linking.
    function test_SelfTransfer_StillRevertsAfterLinking() public {
        vm.prank(admin);
        token.setLink(alice, bob, true);

        vm.prank(alice);
        _expectNotAllowed(alice, alice);
        token.transfer(alice, 1 ether);
    }

    /// @dev Linking an address to ITSELF is rejected outright rather than
    ///      silently writing the self-edge. The only way to a self-route is the
    ///      single setter, on purpose.
    function test_SetLink_RejectsSelfLink() public {
        vm.recordLogs();
        vm.prank(admin);
        vm.expectRevert("self-link");
        token.setLink(alice, alice, true);

        _assertLogCount(0, "a rejected self-link must emit nothing");
        assertFalse(token.allowedDestination(alice, alice), "and must write nothing");
    }

    /// @dev A self-route is reachable, but only by approving it on purpose with
    ///      the single setter.
    function test_SelfEdge_RequiresExplicitApproval() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, alice, true);

        vm.prank(alice);
        token.transfer(alice, 1 ether);
        assertEq(token.balanceOf(alice), INITIAL_MINT, "self-transfer is balance-neutral");
    }

    function test_SetLink_ClosesBothDirections() public {
        vm.startPrank(admin);
        token.setLink(alice, bob, true);
        token.setLink(alice, bob, false);
        vm.stopPrank();

        assertFalse(token.allowedDestination(alice, bob));
        assertFalse(token.allowedDestination(bob, alice));
    }

    function test_SetLink_LeavesUnrelatedRoutesClosed() public {
        vm.startPrank(admin);
        token.setLink(alice, bob, true);
        token.setLink(carol, minter, true);
        vm.stopPrank();

        assertTrue(_isLinked(alice, bob));
        assertTrue(_isLinked(carol, minter));
        assertFalse(token.allowedDestination(alice, carol), "unrelated pairs stay closed");
    }

    /// @dev The behavioral payoff: after one linking transaction, value moves
    ///      both ways between the two linked addresses, and nowhere else.
    function test_LinkedPair_CanTransferBothWaysButNotOnward() public {
        vm.prank(admin);
        token.setLink(alice, bob, true);

        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether, "holder -> destination");

        vm.prank(bob);
        token.transfer(alice, 40 ether);
        assertEq(token.balanceOf(bob), 60 ether, "destination -> holder");

        // the far side is itself a holder: onward routes are separate edges
        vm.prank(bob);
        _expectNotAllowed(bob, carol);
        token.transfer(carol, 1 ether);
    }
}
