// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice `custodyBurn` — the privileged burn that destroys a holder's balance
///         without consuming ERC20 allowance. This is the hook that keeps total
///         supply consistent with the off-chain ledger on redemption.
contract CustodyBurnTest is BaseTest {
    function test_Custodian_CanBurnFromAnyHolder_WithoutAllowance() public {
        assertEq(token.allowance(alice, custodian), 0, "precondition: no allowance");

        _expectTransferEvent(alice, address(0), 400 ether);
        _expectCustodyBurnEvent(custodian, alice, 400 ether);

        vm.prank(custodian);
        token.custodyBurn(alice, 400 ether);

        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.totalSupply(), 600 ether);
    }

    function test_NonCustodian_CannotCustodyBurn() public {
        vm.prank(bob);
        _expectNotCustodian(bob);
        token.custodyBurn(alice, 1);
    }

    function test_CustodyBurn_RevertsOnInsufficientBalance() public {
        vm.prank(custodian);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, INITIAL_MINT, 1_001 ether)
        );
        token.custodyBurn(alice, 1_001 ether);
    }

    function testFuzz_CustodyBurn_BurnsExactAmount(uint96 amount) public {
        amount = uint96(bound(amount, 0, INITIAL_MINT));
        vm.prank(custodian);
        token.custodyBurn(alice, amount);
        assertEq(token.balanceOf(alice), INITIAL_MINT - amount);
        assertEq(token.totalSupply(), INITIAL_MINT - amount);
    }

    // ---------- the allowance surface is orthogonal ----------
    //
    // Every test above runs with a zero allowance, so together they only show
    // that a MISSING approval is not a blocker. These start from a PRESENT one:
    // redemption must not be something a holder can gate, cap, or revoke — and
    // an approval must not become a second way to reach the burn.

    /// @dev An allowance far below the burn amount is not a ceiling. Catches an
    ///      inserted `_spendAllowance` by the revert it would cause: burning
    ///      INITIAL_MINT against a 1 wei allowance would fail with
    ///      `ERC20InsufficientAllowance` instead of succeeding.
    function test_CustodyBurn_AllowanceIsNotACap() public {
        vm.prank(alice);
        token.approve(custodian, 1);

        vm.prank(custodian);
        token.custodyBurn(alice, INITIAL_MINT);

        assertEq(token.balanceOf(alice), 0, "a 1 wei allowance must not cap the burn");
        assertEq(token.allowance(alice, custodian), 1, "custodyBurn must not spend the allowance");
        assertEq(token.totalSupply(), 0);
    }

    /// @dev A holder cannot shield a balance by parking it behind a third party's
    ///      approval — an allowance reserves nothing. `max` is used because it is
    ///      the largest possible claim on the balance, not to detect a spend: OZ
    ///      skips the decrement for `max`, so a spend would leave no trace.
    function test_CustodyBurn_UnaffectedByThirdPartyAllowance() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(custodian);
        token.custodyBurn(alice, 400 ether);

        assertEq(token.balanceOf(alice), 600 ether, "an approval to bob must not reserve alice's balance");
        assertEq(token.allowance(alice, bob), type(uint256).max, "the third party's allowance is untouched");
        assertEq(token.totalSupply(), 600 ether);
    }

    /// @dev The complement to `test_CustodyBurn_AllowanceIsNotACap`: an allowance
    ///      EXACTLY equal to the burn amount. Here an inserted `_spendAllowance`
    ///      would succeed rather than revert, so the only thing that catches it is
    ///      the surviving allowance. Also re-asserts both events fire normally
    ///      with a live allowance in play — a reconciler must not be able to tell
    ///      the two situations apart.
    function test_CustodyBurn_ExactAllowanceSurvivesUnspent() public {
        vm.prank(alice);
        token.approve(custodian, 400 ether);

        _expectTransferEvent(alice, address(0), 400 ether);
        _expectCustodyBurnEvent(custodian, alice, 400 ether);

        vm.prank(custodian);
        token.custodyBurn(alice, 400 ether);

        assertEq(token.allowance(alice, custodian), 400 ether, "an exact allowance must survive unspent");
        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.totalSupply(), 600 ether);
    }

    /// @dev Error identity under contention. `test_CustodyBurn_RevertsOnInsufficientBalance`
    ///      above runs with no allowance, so both a balance check and an allowance
    ///      check would be reachable explanations for the revert there. With an
    ///      allowance present and smaller than the balance, only one error is
    ///      correct: the limit is the BALANCE, never the approval.
    function test_CustodyBurn_ExcessAmountFailsOnBalanceNotAllowance() public {
        vm.prank(alice);
        token.approve(custodian, 1 ether);

        vm.prank(custodian);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, INITIAL_MINT, 1_001 ether)
        );
        token.custodyBurn(alice, 1_001 ether);

        assertEq(token.allowance(alice, custodian), 1 ether, "a rejected burn must not consume the allowance");
        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev The general case: no allowance value and no burn amount changes the
    ///      outcome. `allowed` is unbounded so `max` and `0` are both in range;
    ///      `value` is bounded to the balance so "insufficient balance" is never
    ///      an available explanation for a failure.
    function testFuzz_CustodyBurn_IndependentOfAllowance(uint256 allowed, uint96 amount) public {
        uint256 value = bound(uint256(amount), 0, INITIAL_MINT);

        vm.prank(alice);
        token.approve(custodian, allowed);

        vm.prank(custodian);
        token.custodyBurn(alice, value);

        assertEq(token.balanceOf(alice), INITIAL_MINT - value);
        assertEq(token.allowance(alice, custodian), allowed, "allowance survives intact whatever its size");
        assertEq(token.totalSupply(), INITIAL_MINT - value);
    }

    /// @dev The mirror direction, and the reason this section is not merely about
    ///      convenience. `test_NonCustodian_CannotCustodyBurn` above gives `bob`
    ///      no allowance, so it cannot distinguish "role required" from "role OR
    ///      allowance required". An unlimited approval must not be a second key
    ///      into the burn surface — it is not one for `burnFrom`
    ///      (`BurnAuthority.t.sol:test_Holder_CannotBurnFromEvenWithAllowance`)
    ///      and must not become one here.
    function test_NonCustodian_CannotCustodyBurn_EvenWithMaxAllowance() public {
        vm.prank(alice);
        token.approve(bob, type(uint256).max);

        vm.prank(bob);
        _expectNotCustodian(bob);
        token.custodyBurn(alice, 400 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT, "an allowance must not destroy value");
        assertEq(token.allowance(alice, bob), type(uint256).max, "a rejected call must not consume the allowance");
        assertEq(token.totalSupply(), INITIAL_MINT);
    }
}
