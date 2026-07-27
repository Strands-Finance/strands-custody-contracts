// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsCustodyToken } from "../../src/StrandsCustodyToken.sol";

/// @notice Property tests over arbitrary destinations: default-deny holds for
///         every address, and an approval authorises exactly one pair.
contract FuzzTest is BaseTest {
    function testFuzz_Transfer_RespectsAllowlist(address dest, uint96 amount) public {
        vm.assume(dest != address(0) && dest != alice);
        amount = uint96(bound(amount, 1, 1_000 ether));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, dest));
        token.transfer(dest, amount);

        vm.prank(admin);
        token.setDestinationAllowed(alice, dest, true);

        vm.prank(alice);
        token.transfer(dest, amount);
        assertEq(token.balanceOf(dest), amount);
        assertEq(token.balanceOf(alice), 1_000 ether - amount);
    }

    /// @dev Approving one (holder, destination) pair must never authorise any other.
    function testFuzz_Allowlist_OnlyExactPairIsAuthorised(address dest, address other) public {
        vm.assume(dest != address(0) && other != address(0) && dest != other);

        vm.prank(admin);
        token.setDestinationAllowed(alice, dest, true);

        assertTrue(token.allowedDestination(alice, dest));
        assertFalse(token.allowedDestination(alice, other));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, other)
        );
        token.transfer(other, 1 ether);
    }
}
