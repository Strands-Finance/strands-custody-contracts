// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice Which error wins when more than one check would fail. The allowlist
///         sits inside `_update`, so it fires BEFORE the balance check but
///         AFTER `transferFrom` has already spent the allowance.
contract RevertPrecedenceTest is BaseTest {
    function test_Allowlist_CheckedBeforeBalance() public {
        vm.prank(alice);
        _expectNotAllowed(alice, bob);
        token.transfer(bob, 5_000 ether); // also exceeds balance
    }

    function test_InsufficientBalance_StillRevertsWhenAllowlisted() public {
        _allow(alice, bob);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, INITIAL_MINT, 1_001 ether)
        );
        token.transfer(bob, 1_001 ether);
    }

    /// @dev OZ spends the allowance before reaching `_transfer`/`_update`, so the
    ///      allowance error wins even though the destination is also disallowed.
    function test_TransferFrom_AllowanceCheckedBeforeAllowlist() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, 1 ether));
        token.transferFrom(alice, bob, 1 ether);
    }
}
