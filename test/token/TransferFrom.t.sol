// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice `transferFrom` is ordinary, unrestricted ERC20: the ERC20 allowance
///         is now the ONLY thing standing between a spender and the owner's
///         balance.
///
/// @dev    That is the load-bearing change. The token used to require BOTH an
///         allowance and an admin-approved destination — keyed by the token
///         owner, never the spender — so an allowance alone could not move
///         value. It can now, which makes the allowance the whole authorisation
///         story and worth pinning in detail: what spends it, what does not, and
///         what a rejected call leaves behind.
contract TransferFromTest is BaseTest {
    function test_TransferFrom_MovesOwnerBalanceAndSpendsAllowance() public {
        vm.prank(alice);
        token.approve(carol, 300 ether);

        _expectTransferEvent(alice, bob, 300 ether);
        vm.prank(carol);
        token.transferFrom(alice, bob, 300 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT - 300 ether);
        assertEq(token.balanceOf(bob), 300 ether);
        assertEq(token.allowance(alice, carol), 0, "an exact-size spend drains the allowance");
        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev The `Transfer` event is keyed by the OWNER, not the spender — the
    ///      spender never holds the value, so `carol` must not appear as
    ///      `from`. Asserted above via `_expectTransferEvent(alice, ...)`; here
    ///      the balance side of the same claim.
    function test_TransferFrom_SpenderNeedsNoBalanceOfTheirOwn() public {
        assertEq(token.balanceOf(carol), 0, "precondition: the spender is empty");

        vm.prank(alice);
        token.approve(carol, 100 ether);

        vm.prank(carol);
        token.transferFrom(alice, bob, 100 ether);

        assertEq(token.balanceOf(carol), 0, "the spender is a conduit, never a holder");
        assertEq(token.balanceOf(bob), 100 ether);
    }

    /// @dev A spender may route value to themselves. Under the allowlist this
    ///      needed a separate `alice -> carol` edge on top of the allowance.
    function test_TransferFrom_SpenderMayBeTheDestination() public {
        vm.prank(alice);
        token.approve(carol, 300 ether);

        vm.prank(carol);
        token.transferFrom(alice, carol, 300 ether);

        assertEq(token.balanceOf(carol), 300 ether);
        assertEq(token.allowance(alice, carol), 0);
    }

    function test_TransferFrom_PartialSpend_LeavesTheRemainder() public {
        vm.prank(alice);
        token.approve(carol, 300 ether);

        vm.prank(carol);
        token.transferFrom(alice, bob, 100 ether);

        assertEq(token.allowance(alice, carol), 200 ether);
    }

    /// @dev OZ v5 treats `type(uint256).max` as an infinite allowance and skips
    ///      the write, so the approval survives a spend intact.
    function test_TransferFrom_InfiniteAllowance_IsNotSpent() public {
        vm.prank(alice);
        token.approve(carol, type(uint256).max);

        vm.prank(carol);
        token.transferFrom(alice, bob, 400 ether);

        assertEq(token.allowance(alice, carol), type(uint256).max, "an infinite allowance is never decremented");
        assertEq(token.balanceOf(bob), 400 ether);
    }

    // ---------- the checks that DO still reject ----------

    function test_TransferFrom_WithoutAllowance_Reverts() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, 1 ether));
        token.transferFrom(alice, bob, 1 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT);
    }

    function test_TransferFrom_ExceedingAllowance_Reverts() public {
        vm.prank(alice);
        token.approve(carol, 100 ether);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 100 ether, 101 ether)
        );
        token.transferFrom(alice, bob, 101 ether);
    }

    /// @dev An allowance is a cap on authority, not a claim on value that isn't
    ///      there: the balance check still fires underneath it.
    function test_TransferFrom_InsufficientBalance_RevertsDespiteAmpleAllowance() public {
        vm.prank(alice);
        token.approve(carol, type(uint256).max);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, INITIAL_MINT, 1_001 ether)
        );
        token.transferFrom(alice, bob, 1_001 ether);
    }

    /// @dev `transferFrom` is not a burn path either — see the `transfer`
    ///      counterpart in `Transfer.t.sol`.
    function test_TransferFrom_ToZeroAddress_Reverts() public {
        vm.prank(alice);
        token.approve(carol, 100 ether);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 100 ether);

        assertEq(token.totalSupply(), INITIAL_MINT, "supply must be untouched");
    }

    /// @dev A rejected call unwinds completely, allowance included. OZ spends
    ///      the allowance BEFORE `_update`, so a failure downstream of the spend
    ///      would leave it consumed were the revert not unwinding the whole call.
    function test_RejectedTransferFrom_DoesNotConsumeAllowance() public {
        vm.prank(alice);
        token.approve(carol, 5_000 ether);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, INITIAL_MINT, 5_000 ether)
        );
        token.transferFrom(alice, bob, 5_000 ether);

        assertEq(token.allowance(alice, carol), 5_000 ether, "allowance must survive a rejected transferFrom");
        assertEq(token.balanceOf(alice), INITIAL_MINT);
        assertEq(token.balanceOf(bob), 0);
    }

    // ---------- fuzz ----------

    /// @dev Any spend within both the allowance and the balance goes through,
    ///      and the allowance decrements by exactly the amount moved.
    function testFuzz_TransferFrom_SpendsExactlyWhatItMoves(uint96 approved, uint96 amount) public {
        uint256 allowed = bound(uint256(approved), 0, INITIAL_MINT);
        uint256 value = bound(uint256(amount), 0, allowed);

        vm.prank(alice);
        token.approve(carol, allowed);

        vm.prank(carol);
        token.transferFrom(alice, bob, value);

        assertEq(token.balanceOf(bob), value);
        assertEq(token.allowance(alice, carol), allowed - value);
        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev Anything above the allowance is rejected, however small the excess.
    function testFuzz_TransferFrom_RejectsAnythingAboveTheAllowance(uint96 approved, uint96 excess) public {
        uint256 allowed = bound(uint256(approved), 0, INITIAL_MINT - 1);
        uint256 over = bound(uint256(excess), 1, INITIAL_MINT - allowed);

        vm.prank(alice);
        token.approve(carol, allowed);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, allowed, allowed + over)
        );
        token.transferFrom(alice, bob, allowed + over);

        assertEq(token.balanceOf(bob), 0, "no amount above the allowance slips through");
    }
}
