// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice `transferFrom` gating. The load-bearing property here is that the
///         allowlist is keyed by the token OWNER, never the spender — OZ's
///         `_transfer(owner, to, v)` reaches `_update` with `from == owner`.
contract TransferFromTest is BaseTest {
    function test_TransferFrom_ChecksOwnerNotSpender() public {
        _allow(alice, bob); // approval keyed by owner alice, not spender carol
        vm.prank(alice);
        token.approve(carol, 300 ether);

        vm.prank(carol);
        token.transferFrom(alice, bob, 300 ether);

        assertEq(token.balanceOf(bob), 300 ether);
        assertEq(token.allowance(alice, carol), 0);
    }

    function test_TransferFrom_RevertsOnUnapprovedDestination() public {
        vm.prank(alice);
        token.approve(carol, 300 ether); // ERC20 allowance alone is not enough

        vm.prank(carol);
        _expectNotAllowed(alice, carol);
        token.transferFrom(alice, carol, 300 ether);
    }

    function test_TransferFrom_SpenderAllowlistEntryDoesNotAuthorise() public {
        _allow(carol, bob); // spender's own entry, not the owner's
        vm.prank(alice);
        token.approve(carol, 300 ether);

        vm.prank(carol);
        _expectNotAllowed(alice, bob);
        token.transferFrom(alice, bob, 300 ether);
    }
}
