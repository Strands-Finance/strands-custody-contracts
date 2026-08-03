// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice `transfer` gating: the happy path, the default-deny path, and that
///         un-setting an edge closes the route again.
contract TransferTest is BaseTest {
    function test_Transfer_ToApprovedDestination() public {
        _allow(alice, bob);

        _expectTransferEvent(alice, bob, 100 ether);
        vm.prank(alice);
        token.transfer(bob, 100 ether);

        assertEq(token.balanceOf(alice), 900 ether);
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function test_Transfer_RevertsOnUnapprovedDestination() public {
        vm.prank(alice);
        _expectNotAllowed(alice, bob);
        token.transfer(bob, 100 ether);
    }

    function test_Transfer_RevertsAfterDestinationUnset() public {
        _allow(alice, bob);
        _disallow(alice, bob);

        vm.prank(alice);
        _expectNotAllowed(alice, bob);
        token.transfer(bob, 1);
    }
}
