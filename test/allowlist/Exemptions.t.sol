// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice Issuance and redemption bypass the allowlist entirely, because
///         `_update` only guards when both `from` and `to` are non-zero.
///         This is what lets tokens reach a user with zero edges configured.
contract ExemptionsTest is BaseTest {
    function test_MintAndBurnPaths_ExemptFromAllowlist() public {
        // no allowlist entries exist at all
        vm.prank(minter);
        token.mint(carol, 10 ether); // mint: from == address(0)
        vm.prank(carol);
        token.burn(1 ether); // burn: to == address(0)
        vm.prank(carol);
        token.approve(bob, 2 ether);
        vm.prank(bob);
        token.burnFrom(carol, 2 ether); // burnFrom: to == address(0)
        vm.prank(custodian);
        token.custodyBurn(carol, 3 ether); // custodyBurn: to == address(0)

        assertEq(token.balanceOf(carol), 4 ether);
    }
}
