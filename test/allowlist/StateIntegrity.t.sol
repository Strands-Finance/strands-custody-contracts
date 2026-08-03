// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice A blocked transfer must be a complete no-op. Balances, total supply
///         and — importantly — ERC20 allowance all survive untouched, because
///         the revert unwinds the whole call including the allowance spend.
contract StateIntegrityTest is BaseTest {
    function test_BlockedTransfer_LeavesBalancesAndSupplyUnchanged() public {
        vm.prank(alice);
        _expectNotAllowed(alice, bob);
        token.transfer(bob, 100 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    function test_BlockedTransferFrom_DoesNotConsumeAllowance() public {
        vm.prank(alice);
        token.approve(carol, 300 ether);

        vm.prank(carol);
        _expectNotAllowed(alice, bob);
        token.transferFrom(alice, bob, 300 ether);

        assertEq(token.allowance(alice, carol), 300 ether, "allowance must survive a blocked transferFrom");
        assertEq(token.balanceOf(alice), INITIAL_MINT);
        assertEq(token.balanceOf(bob), 0);
    }
}
