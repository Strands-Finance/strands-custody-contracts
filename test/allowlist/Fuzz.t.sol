// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice Property tests over arbitrary destinations: default-deny holds for
///         every address, and an approval authorises exactly one pair.
contract FuzzTest is BaseTest {
    function testFuzz_Transfer_RespectsAllowlist(address dest, uint96 amount) public {
        vm.assume(dest != address(0) && dest != alice);
        amount = uint96(bound(amount, 1, INITIAL_MINT));

        vm.prank(alice);
        _expectNotAllowed(alice, dest);
        token.transfer(dest, amount);

        _allow(alice, dest);

        vm.prank(alice);
        token.transfer(dest, amount);
        assertEq(token.balanceOf(dest), amount);
        assertEq(token.balanceOf(alice), INITIAL_MINT - amount);
    }

    /// @dev Approving one (holder, destination) pair must never authorise any other.
    function testFuzz_Allowlist_OnlyExactPairIsAuthorised(address dest, address other) public {
        vm.assume(dest != address(0) && other != address(0) && dest != other);

        _allow(alice, dest);

        assertTrue(token.allowedDestination(alice, dest));
        assertFalse(token.allowedDestination(alice, other));

        vm.prank(alice);
        _expectNotAllowed(alice, other);
        token.transfer(other, 1 ether);
    }
}
