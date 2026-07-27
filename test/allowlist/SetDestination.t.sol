// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice The single-edge setter: who may call it, what it emits, and that a
///         redundant write still emits. That last property is deliberate and is
///         what the batch paths intentionally diverge from — see
///         `test/batch/Idempotency.t.sol`.
contract SetDestinationTest is BaseTest {
    function test_Admin_CanSetAndUnsetDestination() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit DestinationAllowedSet(alice, bob, true);
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true);
        assertTrue(token.allowedDestination(alice, bob));

        vm.expectEmit(true, true, false, true, address(token));
        emit DestinationAllowedSet(alice, bob, false);
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, false);
        assertFalse(token.allowedDestination(alice, bob));
    }

    function test_NonAdmin_CannotSetDestination() public {
        bytes32 role = token.DEFAULT_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        token.setDestinationAllowed(alice, bob, true);
    }

    function test_SetDestinationAllowed_ReEmitsOnRedundantWrite() public {
        vm.startPrank(admin);
        token.setDestinationAllowed(alice, bob, true);

        vm.expectEmit(true, true, false, true, address(token));
        emit DestinationAllowedSet(alice, bob, true);
        token.setDestinationAllowed(alice, bob, true);
        vm.stopPrank();

        assertTrue(token.allowedDestination(alice, bob));
    }
}
