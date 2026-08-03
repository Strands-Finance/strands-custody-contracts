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
}
