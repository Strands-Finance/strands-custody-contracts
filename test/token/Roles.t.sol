// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsCustodyToken } from "../../src/StrandsCustodyToken.sol";

/// @notice Constructor role wiring and basic grant/revoke behavior.
///         Allowlist-specific admin lifecycle lives in
///         `test/allowlist/AdminLifecycle.t.sol`.
contract RolesTest is BaseTest {
    function test_AdminHasDefaultAdminRole() public view {
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_Constructor_RevertsOnZeroAdmin() public {
        vm.expectRevert(bytes("admin=0"));
        new StrandsCustodyToken(address(0), 18);
    }

    function test_AdminCanRevokeCustodian() public {
        vm.prank(admin);
        token.revokeRole(CUSTODIAN_ROLE, custodian);
        assertFalse(token.hasRole(CUSTODIAN_ROLE, custodian));
    }
}
