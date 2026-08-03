// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice The single-edge setter: who may call it, what it emits, and that a
///         redundant write still emits. That last property is deliberate and is
///         what the batch paths intentionally diverge from — see
///         `test/batch/Idempotency.t.sol`.
///
/// @dev    `setDestinationAllowed` is the subject here, so it is called directly
///         rather than through the fixture's `_allow` / `_disallow` wrappers.
contract SetDestinationTest is BaseTest {
    function test_Admin_CanSetAndUnsetDestination() public {
        _expectDestinationAllowedSetEvent(alice, bob, true);
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true);
        assertTrue(token.allowedDestination(alice, bob));

        _expectDestinationAllowedSetEvent(alice, bob, false);
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, false);
        assertFalse(token.allowedDestination(alice, bob));
    }

    function test_NonAdmin_CannotSetDestination() public {
        vm.prank(alice);
        _expectNotAdmin(alice);
        token.setDestinationAllowed(alice, bob, true);
    }

    function test_SetDestinationAllowed_ReEmitsOnRedundantWrite() public {
        vm.startPrank(admin);
        token.setDestinationAllowed(alice, bob, true);

        _expectDestinationAllowedSetEvent(alice, bob, true);
        token.setDestinationAllowed(alice, bob, true);
        vm.stopPrank();

        assertTrue(token.allowedDestination(alice, bob));
    }
}
