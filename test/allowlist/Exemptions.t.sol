// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice Issuance and custodial redemption bypass the allowlist entirely,
///         because `_update` only guards when both `from` and `to` are non-zero.
///         This is what lets tokens reach a user with zero edges configured, and
///         lets the custodian redeem them again without one.
///
/// @dev    The exemption is from the ALLOWLIST, and nothing more — it is not a
///         licence for holders to burn. Every burn path is CUSTODIAN_ROLE-gated;
///         see `test/token/BurnAuthority.t.sol`.
contract ExemptionsTest is BaseTest {
    function test_MintAndCustodialBurnPaths_ExemptFromAllowlist() public {
        // no allowlist entries exist at all
        vm.prank(minter);
        token.mint(carol, 10 ether); // mint: from == address(0)
        vm.prank(minter);
        token.mint(custodian, 5 ether);

        vm.prank(custodian);
        token.custodyBurn(carol, 3 ether); // custodyBurn: to == address(0)
        vm.prank(custodian);
        token.burn(1 ether); // burn: to == address(0)

        vm.prank(carol);
        token.approve(custodian, 2 ether);
        vm.prank(custodian);
        token.burnFrom(carol, 2 ether); // burnFrom: to == address(0)

        assertEq(token.balanceOf(carol), 5 ether);
        assertEq(token.balanceOf(custodian), 4 ether);
    }
}
