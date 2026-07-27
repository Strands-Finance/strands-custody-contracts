// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice Standard ERC20Burnable paths: self-burn and allowance-based burnFrom.
///         The privileged, allowance-free path is in `CustodyBurn.t.sol`.
contract BurnTest is BaseTest {
    function test_Holder_CanBurnOwnBalance() public {
        vm.prank(alice);
        token.burn(100 ether);
        assertEq(token.balanceOf(alice), 900 ether);
        assertEq(token.totalSupply(), 900 ether);
    }

    function test_BurnFrom_RequiresAllowance() public {
        vm.prank(bob);
        vm.expectRevert();
        token.burnFrom(alice, 1);
    }

    function test_BurnFrom_WorksWithAllowance() public {
        vm.prank(alice);
        token.approve(bob, 200 ether);

        vm.prank(bob);
        token.burnFrom(alice, 200 ether);

        assertEq(token.balanceOf(alice), 800 ether);
        assertEq(token.allowance(alice, bob), 0);
    }
}
