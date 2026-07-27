// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice `mint` and its MINTER_ROLE gate. That mint bypasses the destination
///         allowlist entirely is proven in `test/allowlist/Exemptions.t.sol`.
contract MintTest is BaseTest {
    function test_MinterCanMint() public {
        vm.prank(minter);
        token.mint(bob, 50 ether);
        assertEq(token.balanceOf(bob), 50 ether);
        assertEq(token.totalSupply(), 1_050 ether);
    }

    function test_NonMinter_CannotMint() public {
        bytes32 role = token.MINTER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        token.mint(bob, 1);
    }
}
