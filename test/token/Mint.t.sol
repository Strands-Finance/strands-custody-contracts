// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice `mint` and its OPERATOR_ROLE gate.
contract MintTest is BaseTest {
    function test_MinterCanMint() public {
        vm.prank(minter);
        token.encode(bob, 50 ether);
        assertEq(token.balanceOf(bob), 50 ether);
        assertEq(token.totalSupply(), INITIAL_MINT + 50 ether);
    }

    function test_NonMinter_CannotMint() public {
        vm.prank(alice);
        _expectNotMinter(alice);
        token.encode(bob, 1);
    }
}
