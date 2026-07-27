// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsCustodyToken } from "../../src/StrandsCustodyToken.sol";

/// @notice Constructor role wiring and basic grant/revoke behavior.
///         Allowlist-specific admin lifecycle lives in
///         `test/allowlist/AdminLifecycle.t.sol`.
contract RolesTest is BaseTest {
    function test_AdminHasDefaultAdminRole() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_Constructor_RevertsOnZeroAdmin() public {
        vm.expectRevert(bytes("admin=0"));
        new StrandsCustodyToken(address(0), 18);
    }

    function test_AdminCanRevokeCustodian() public {
        bytes32 role = token.CUSTODIAN_ROLE();
        vm.prank(admin);
        token.revokeRole(role, custodian);
        assertFalse(token.hasRole(role, custodian));
    }
}
