// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice How narrowly an approval applies: per-holder, per-destination,
///         directional, reusable, and binding on privileged roles too.
///         Together these pin that an edge authorises exactly one ordered pair.
contract ScopingTest is BaseTest {
    function test_DestinationApproval_IsPerHolder() public {
        _allow(alice, bob); // alice -> bob only
        vm.prank(minter);
        token.mint(carol, 10 ether);

        vm.prank(carol);
        _expectNotAllowed(carol, bob);
        token.transfer(bob, 1 ether);
    }

    function test_Allowlist_IsDirectional() public {
        _allow(alice, bob);
        assertFalse(token.allowedDestination(bob, alice), "alice->bob must not imply bob->alice");

        vm.prank(alice);
        token.transfer(bob, 100 ether);

        vm.prank(bob);
        _expectNotAllowed(bob, alice);
        token.transfer(alice, 1 ether);
    }

    function test_Allowlist_IsPerDestination() public {
        _allow(alice, bob);

        vm.prank(alice);
        _expectNotAllowed(alice, carol);
        token.transfer(carol, 1 ether);
    }

    function test_Allowlist_EntryIsReusable() public {
        _allow(alice, bob);

        vm.startPrank(alice);
        token.transfer(bob, 100 ether);
        token.transfer(bob, 100 ether);
        vm.stopPrank();

        assertTrue(token.allowedDestination(alice, bob), "approval must not be consumed by a transfer");
        assertEq(token.balanceOf(bob), 200 ether);
    }

    /// @dev No role buys a way around the allowlist ON THE TRANSFER PATH. The
    ///      admin's ability to move a balance is a separate entrypoint,
    ///      `adminTransfer`, not an exemption bolted onto `transfer` — see
    ///      `test/allowlist/AdminTransfer.t.sol`. The two do not contradict.
    function test_PrivilegedRoles_AreNotExemptFromAllowlist() public {
        vm.startPrank(minter);
        token.mint(admin, 10 ether);
        token.mint(minter, 10 ether);
        token.mint(custodian, 10 ether);
        vm.stopPrank();

        vm.prank(admin);
        _expectNotAllowed(admin, bob);
        token.transfer(bob, 1 ether);

        vm.prank(minter);
        _expectNotAllowed(minter, bob);
        token.transfer(bob, 1 ether);

        vm.prank(custodian);
        _expectNotAllowed(custodian, bob);
        token.transfer(bob, 1 ether);
    }
}
