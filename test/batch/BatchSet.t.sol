// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsAllowlistBatch } from "../../src/StrandsAllowlistBatch.sol";

/// @notice The two generic setters: `setDestinations` (one flag for the whole
///         batch) and `setDestinationsMixed` (a flag per edge).
contract BatchSetTest is BaseTest {
    function test_SetDestinations_WritesEveryEdge() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit DestinationAllowedSet(alice, bob, true);
        vm.expectEmit(true, true, false, true, address(token));
        emit DestinationAllowedSet(alice, carol, true);

        vm.prank(admin);
        token.setDestinations(_edges(alice, bob, alice, carol), true);

        assertTrue(token.allowedDestination(alice, bob));
        assertTrue(token.allowedDestination(alice, carol));
    }

    function test_SetDestinations_ClosesEveryEdge() public {
        vm.startPrank(admin);
        token.setDestinations(_edges(alice, bob, alice, carol), true);
        token.setDestinations(_edges(alice, bob, alice, carol), false);
        vm.stopPrank();

        assertFalse(token.allowedDestination(alice, bob));
        assertFalse(token.allowedDestination(alice, carol));
    }

    function test_SetDestinations_WritesOnlyTheGivenEdges() public {
        vm.prank(admin);
        token.setDestinations(_edges(alice, bob), true);

        assertFalse(token.allowedDestination(bob, alice), "must not open the reverse edge");
        assertFalse(token.allowedDestination(alice, carol));
        assertFalse(token.allowedDestination(alice, alice), "must not open a self edge");
    }

    function test_SetDestinationsMixed_AppliesPerEdgeFlags() public {
        vm.prank(admin);
        token.setDestinationsMixed(_edges(alice, bob, alice, carol), _bools(true, false));

        assertTrue(token.allowedDestination(alice, bob));
        assertFalse(token.allowedDestination(alice, carol));
    }

    /// @dev One transaction can both open and close routes — useful when a
    ///      reconciliation pass produces a mix of adds and removals.
    function test_SetDestinationsMixed_CanOpenAndCloseInOneCall() public {
        vm.startPrank(admin);
        token.setDestinations(_edges(alice, carol), true); // pre-existing route
        token.setDestinationsMixed(_edges(alice, bob, alice, carol), _bools(true, false));
        vm.stopPrank();

        assertTrue(token.allowedDestination(alice, bob), "opened");
        assertFalse(token.allowedDestination(alice, carol), "closed");
    }

    function test_SetDestinationsMixed_RevertsOnLengthMismatch() public {
        bool[] memory oneFlag = new bool[](1);
        oneFlag[0] = true;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StrandsAllowlistBatch.ArrayLengthMismatch.selector, 2, 1));
        token.setDestinationsMixed(_edges(alice, bob, alice, carol), oneFlag);
    }

    function test_EmptyBatch_IsASuccessfulNoOp() public {
        StrandsAllowlistBatch.Edge[] memory none = new StrandsAllowlistBatch.Edge[](0);

        vm.recordLogs();
        vm.prank(admin);
        token.setDestinations(none, true);

        assertEq(vm.getRecordedLogs().length, 0, "empty batch must emit nothing");
    }
}
