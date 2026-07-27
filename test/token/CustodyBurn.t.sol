// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice `custodyBurn` — the privileged burn that destroys a holder's balance
///         without consuming ERC20 allowance. This is the hook that keeps total
///         supply consistent with the off-chain ledger on redemption.
contract CustodyBurnTest is BaseTest {
    function test_Custodian_CanBurnFromAnyHolder_WithoutAllowance() public {
        assertEq(token.allowance(alice, custodian), 0, "precondition: no allowance");

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, address(0), 400 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit CustodyBurn(custodian, alice, 400 ether);

        vm.prank(custodian);
        token.custodyBurn(alice, 400 ether);

        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.totalSupply(), 600 ether);
    }

    function test_NonCustodian_CannotCustodyBurn() public {
        bytes32 role = token.CUSTODIAN_ROLE();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, role));
        token.custodyBurn(alice, 1);
    }

    function test_CustodyBurn_RevertsOnInsufficientBalance() public {
        vm.prank(custodian);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1_000 ether, 1_001 ether)
        );
        token.custodyBurn(alice, 1_001 ether);
    }

    function testFuzz_CustodyBurn_BurnsExactAmount(uint96 amount) public {
        amount = uint96(bound(amount, 0, 1_000 ether));
        vm.prank(custodian);
        token.custodyBurn(alice, amount);
        assertEq(token.balanceOf(alice), 1_000 ether - amount);
        assertEq(token.totalSupply(), 1_000 ether - amount);
    }
}
