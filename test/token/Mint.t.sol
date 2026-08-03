// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice `mint` and its MINTER_ROLE gate. That mint bypasses the destination
///         allowlist entirely is proven in `test/allowlist/Exemptions.t.sol`.
contract MintTest is BaseTest {
    function test_MinterCanMint() public {
        vm.prank(minter);
        token.mint(bob, 50 ether);
        assertEq(token.balanceOf(bob), 50 ether);
        assertEq(token.totalSupply(), INITIAL_MINT + 50 ether);
    }

    function test_NonMinter_CannotMint() public {
        vm.prank(alice);
        _expectNotMinter(alice);
        token.mint(bob, 1);
    }
}
