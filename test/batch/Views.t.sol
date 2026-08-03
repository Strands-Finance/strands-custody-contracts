// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsAllowlistBatch } from "../../src/StrandsAllowlistBatch.sol";

/// @notice Preflight views. These exist so integrations can check a route
///         cheaply instead of probing with a zero-value transfer — which the
///         allowlist also blocks, and which would revert rather than answer.
contract ViewsTest is BaseTest {
    function test_AreAllowed_ReturnsResultsInInputOrder() public {
        _allow(alice, carol);

        // deliberately ordered so a naive implementation returning [true,false] fails
        bool[] memory out = token.areAllowed(_edges(alice, bob, alice, carol));

        assertEq(out.length, 2);
        assertFalse(out[0], "alice->bob is closed");
        assertTrue(out[1], "alice->carol is open");
    }

    function test_AreAllowed_EmptyInput() public view {
        bool[] memory out = token.areAllowed(new StrandsAllowlistBatch.Edge[](0));
        assertEq(out.length, 0);
    }

    function test_IsLinked_RequiresBothDirections() public {
        assertFalse(token.isLinked(alice, bob), "closed both ways");

        _allow(alice, bob);
        assertFalse(token.isLinked(alice, bob), "one direction is not a link");

        _allow(bob, alice);
        assertTrue(token.isLinked(alice, bob), "both directions open");
    }

    function test_IsLinked_IsSymmetric() public {
        _link(alice, bob);

        assertTrue(token.isLinked(alice, bob));
        assertTrue(token.isLinked(bob, alice), "argument order must not matter");
    }

    function test_Views_RequireNoAuthorization() public {
        _link(alice, bob);

        // an arbitrary unprivileged caller can still read
        vm.prank(carol);
        assertTrue(token.isLinked(alice, bob));

        vm.prank(carol);
        bool[] memory out = token.areAllowed(_edges(alice, bob));
        assertTrue(out[0]);
    }

    function test_IsLinked_TracksRevocation() public {
        _link(alice, bob);
        assertTrue(token.isLinked(alice, bob));

        _unlink(alice, bob);
        assertFalse(token.isLinked(alice, bob));
    }
}
