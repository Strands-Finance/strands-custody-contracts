// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsCustodyToken } from "../../src/StrandsCustodyToken.sol";

/// @notice `transfer` gating: the happy path, the default-deny path, and that
///         un-setting an edge closes the route again.
contract TransferTest is BaseTest {
    function test_Transfer_ToApprovedDestination() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 100 ether);
        vm.prank(alice);
        token.transfer(bob, 100 ether);

        assertEq(token.balanceOf(alice), 900 ether);
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function test_Transfer_RevertsOnUnapprovedDestination() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, bob));
        token.transfer(bob, 100 ether);
    }

    function test_Transfer_RevertsAfterDestinationUnset() public {
        vm.startPrank(admin);
        token.setDestinationAllowed(alice, bob, true);
        token.setDestinationAllowed(alice, bob, false);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, bob));
        token.transfer(bob, 1);
    }
}
