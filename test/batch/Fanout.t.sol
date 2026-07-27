// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice The one-to-many helpers. `setDestinationsForHolder` is the
///         hub-and-spoke primitive: it keeps a user's outbound routes to one
///         call, which is what stops edge count growing quadratically once
///         users have several subaccounts.
contract FanoutTest is BaseTest {
    function test_SetDestinationsForHolder_OpensOnlyOutboundEdges() public {
        vm.prank(admin);
        token.setDestinationsForHolder(alice, _addrs(bob, carol), true);

        assertTrue(token.allowedDestination(alice, bob));
        assertTrue(token.allowedDestination(alice, carol));
        assertFalse(token.allowedDestination(bob, alice), "must not open reverse edges");
        assertFalse(token.allowedDestination(carol, alice));
        assertFalse(token.allowedDestination(bob, carol), "must not link spokes to each other");
    }

    function test_SetDestinationsForHolder_Closes() public {
        vm.startPrank(admin);
        token.setDestinationsForHolder(alice, _addrs(bob, carol), true);
        token.setDestinationsForHolder(alice, _addrs(bob, carol), false);
        vm.stopPrank();

        assertFalse(token.allowedDestination(alice, bob));
        assertFalse(token.allowedDestination(alice, carol));
    }

    function test_SetHoldersForDestination_OpensOnlyInboundEdges() public {
        vm.prank(admin);
        token.setHoldersForDestination(_addrs(bob, carol), alice, true);

        assertTrue(token.allowedDestination(bob, alice));
        assertTrue(token.allowedDestination(carol, alice));
        assertFalse(token.allowedDestination(alice, bob), "must not open reverse edges");
        assertFalse(token.allowedDestination(alice, carol));
    }

    function test_SetHoldersForDestination_Closes() public {
        vm.startPrank(admin);
        token.setHoldersForDestination(_addrs(bob, carol), alice, true);
        token.setHoldersForDestination(_addrs(bob, carol), alice, false);
        vm.stopPrank();

        assertFalse(token.allowedDestination(bob, alice));
        assertFalse(token.allowedDestination(carol, alice));
    }

    /// @dev Hub-and-spoke in practice: the user reaches every subaccount, but
    ///      subaccounts cannot reach each other directly.
    function test_HubAndSpoke_SpokesCannotReachEachOther() public {
        vm.prank(admin);
        token.setDestinationsForHolder(alice, _addrs(bob, carol), true);

        vm.prank(alice);
        token.transfer(bob, 100 ether);

        vm.prank(bob);
        _expectNotAllowed(bob, carol);
        token.transfer(carol, 1 ether);
    }
}
