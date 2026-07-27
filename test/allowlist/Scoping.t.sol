// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsCustodyToken } from "../../src/StrandsCustodyToken.sol";

/// @notice How narrowly an approval applies: per-holder, per-destination,
///         directional, reusable, and binding on privileged roles too.
///         Together these pin that an edge authorises exactly one ordered pair.
contract ScopingTest is BaseTest {
    function test_DestinationApproval_IsPerHolder() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true); // alice -> bob only
        vm.prank(minter);
        token.mint(carol, 10 ether);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, carol, bob));
        token.transfer(bob, 1 ether);
    }

    function test_Allowlist_IsDirectional() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true);
        assertFalse(token.allowedDestination(bob, alice), "alice->bob must not imply bob->alice");

        vm.prank(alice);
        token.transfer(bob, 100 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, bob, alice));
        token.transfer(alice, 1 ether);
    }

    function test_Allowlist_IsPerDestination() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, carol)
        );
        token.transfer(carol, 1 ether);
    }

    function test_Allowlist_EntryIsReusable() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true);

        vm.startPrank(alice);
        token.transfer(bob, 100 ether);
        token.transfer(bob, 100 ether);
        vm.stopPrank();

        assertTrue(token.allowedDestination(alice, bob), "approval must not be consumed by a transfer");
        assertEq(token.balanceOf(bob), 200 ether);
    }

    function test_PrivilegedRoles_AreNotExemptFromAllowlist() public {
        vm.startPrank(minter);
        token.mint(admin, 10 ether);
        token.mint(minter, 10 ether);
        token.mint(custodian, 10 ether);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, admin, bob));
        token.transfer(bob, 1 ether);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, minter, bob));
        token.transfer(bob, 1 ether);

        vm.prank(custodian);
        vm.expectRevert(
            abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, custodian, bob)
        );
        token.transfer(bob, 1 ether);
    }
}
