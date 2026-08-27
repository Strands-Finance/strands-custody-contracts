// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice The admin control surface: which role administers which, and who may
///         grant or revoke. How the roles are first seated is
///         `Initialization.t.sol`; rotation, renounce and the last-admin failure
///         mode live in `AdminLifecycle.t.sol`.
///
/// @dev    Two roles, following OpenZeppelin's own division: DEFAULT_ADMIN_ROLE
///         is governance and OPERATOR_ROLE is the single operating capability.
///         DEFAULT_ADMIN_ROLE has exactly two powers — moving OPERATOR_ROLE
///         around, and writing the transfer destination allowlist. This file
///         owns the first, `grantRole` / `revokeRole`; `Allowlist.t.sol` owns the
///         second. Between them they are the WHOLE admin surface, so both are
///         pinned directly rather than only implied by the mint and burn suites'
///         negative cases.
contract RolesTest is BaseTest {
    // ---------- the seated role graph ----------

    function test_AdminHasDefaultAdminRole() public view {
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    /// @dev The admin holds the admin role and nothing else. An admin that came
    ///      out of `initialize` holding OPERATOR_ROLE would be able to mint or burn
    ///      with no visible grant, which is the whole point of keeping governance
    ///      and operations apart. `Initialization.t.sol` owns the seating itself;
    ///      this is the standing state every suite here assumes.
    function test_Admin_HoldsNoOperatingRole() public view {
        assertFalse(token.hasRole(OPERATOR_ROLE, admin), "admin must not be a operator");
    }

    // ---------- role id / role admin wiring ----------

    /// @dev The id is part of the deployed ABI: the backend's Nethereum bindings
    ///      resolve it by calling `OPERATOR_ROLE()` and then grant against the
    ///      returned bytes32. Changing the string would silently orphan every
    ///      already-granted role on a live token.
    function test_RoleIds_AreTheKeccakOfTheirNames() public view {
        assertEq(OPERATOR_ROLE, keccak256("OPERATOR_ROLE"));
        assertEq(DEFAULT_ADMIN_ROLE, bytes32(0), "OZ's DEFAULT_ADMIN_ROLE is the zero id");
    }

    /// @dev Nothing calls `_setRoleAdmin`, so OZ's default applies and
    ///      DEFAULT_ADMIN_ROLE administers everything. Pinned because a
    ///      re-pointed role admin would move the whole control surface without
    ///      changing a single function signature.
    function test_DefaultAdminRole_AdministersEveryRole() public view {
        assertEq(token.getRoleAdmin(OPERATOR_ROLE), DEFAULT_ADMIN_ROLE);
    }

    /// @dev DEFAULT_ADMIN_ROLE being its own admin is what makes the last-admin
    ///      loss in `AdminLifecycle.t.sol` unrecoverable — there is no outer
    ///      role to bootstrap from.
    function test_DefaultAdminRole_IsItsOwnAdmin() public view {
        assertEq(token.getRoleAdmin(DEFAULT_ADMIN_ROLE), DEFAULT_ADMIN_ROLE);
    }

    /// @dev The role that used to gate the unguarded burn surface is GONE, not
    ///      merely unused — asserted rather than assumed, because a stale
    ///      `CUSTODIAN_ROLE()` left on the ABI would let an operator grant a role
    ///      that no longer opens anything and believe a key was provisioned.
    ///      Probed by selector so it does not depend on the binding: an absent
    ///      function has no dispatch entry and the raw call fails.
    function test_CustodianRole_HasNoDispatchEntry() public {
        (bool custodianRoleExists,) = address(token).call(abi.encodeWithSignature("CUSTODIAN_ROLE()"));
        assertFalse(custodianRoleExists, "CUSTODIAN_ROLE() must no longer be part of the ABI");

        (bool custodyBurnExists,) =
            address(token).call(abi.encodeWithSignature("custodyBurn(address,uint256)", alice, uint256(1)));
        assertFalse(custodyBurnExists, "custodyBurn was renamed to adminRetract; the old selector must be gone");

        // The control: the same probe against a function that DOES exist succeeds, so the two assertions above
        // are about these selectors and not about the probe technique.
        (bool operatorRoleExists,) = address(token).call(abi.encodeWithSignature("OPERATOR_ROLE()"));
        assertTrue(operatorRoleExists, "the probe must be able to find a live entrypoint");
    }

    // ---------- who may grant and revoke ----------

    function test_Admin_CanGrantAndRevoke() public {
        vm.prank(admin);
        token.grantRole(OPERATOR_ROLE, carol);
        assertTrue(token.hasRole(OPERATOR_ROLE, carol));

        vm.prank(admin);
        token.revokeRole(OPERATOR_ROLE, carol);
        assertFalse(token.hasRole(OPERATOR_ROLE, carol));
    }

    function test_AdminCanRevokeTheSeatedOperator() public {
        vm.prank(admin);
        token.revokeRole(OPERATOR_ROLE, operator);
        assertFalse(token.hasRole(OPERATOR_ROLE, operator));
    }

    /// @dev The load-bearing admin control. Without this the roles are
    ///      decorative: anyone could appoint themselves a operator and burn.
    function test_NonAdmin_CannotGrantRole() public {
        vm.prank(alice);
        _expectNotAdmin(alice);
        token.grantRole(OPERATOR_ROLE, alice);

        assertFalse(token.hasRole(OPERATOR_ROLE, alice), "no self-appointment");
    }

    function test_NonAdmin_CannotRevokeRole() public {
        vm.prank(alice);
        _expectNotAdmin(alice);
        token.revokeRole(OPERATOR_ROLE, operator);

        assertTrue(token.hasRole(OPERATOR_ROLE, operator), "an outsider cannot dismantle the role graph");
    }

    /// @dev Holding the operating role is not a shortcut into the admin one. A
    ///      operator who could grant would be able to appoint a second operator and
    ///      defeat any "keep the governance key separate" policy single-handedly
    ///      — and with one operating role covering both mint and burn, that is
    ///      now the whole of the operating power.
    function test_Operator_CannotGrantRoles() public {
        vm.prank(operator);
        _expectNotAdmin(operator);
        token.grantRole(OPERATOR_ROLE, carol);

        assertFalse(token.hasRole(OPERATOR_ROLE, carol));
    }

    /// @dev No address is special. `admin` is excluded because it is the one
    ///      address for which the call legitimately succeeds; `operator` because
    ///      `setUp` already granted it the role this may pick, so the closing
    ///      `hasRole` would read `true` for a reason that has nothing to do with
    ///      the rejected grant. That the operator cannot grant either is
    ///      `test_Operator_CannotGrantRoles` above.
    function testFuzz_ArbitraryNonAdmin_CannotGrantAnyRole(address caller, uint8 which) public {
        vm.assume(caller != admin && caller != operator);
        bytes32 role = which % 2 == 0 ? OPERATOR_ROLE : DEFAULT_ADMIN_ROLE;

        vm.prank(caller);
        _expectNotAdmin(caller);
        token.grantRole(role, caller);

        assertFalse(token.hasRole(role, caller));
    }

    /// @dev Reads are open — an integration can check its own standing without
    ///      privileges, and does not have to guess from a reverting write.
    function testFuzz_AnyCaller_CanReadTheRoleGraph(address caller) public {
        vm.prank(caller);
        assertTrue(token.hasRole(OPERATOR_ROLE, operator));
        vm.prank(caller);
        assertEq(token.getRoleAdmin(OPERATOR_ROLE), DEFAULT_ADMIN_ROLE);
    }

    // ---------- grants and revokes take effect immediately ----------

    function test_NewlyGrantedOperator_CanMintImmediately() public {
        vm.prank(carol);
        _expectNotOperator(carol);
        token.encode(carol, 1 ether);

        vm.prank(admin);
        token.grantRole(OPERATOR_ROLE, carol);

        vm.prank(carol);
        token.encode(carol, 1 ether);
        assertEq(token.balanceOf(carol), 1 ether, "a grant is effective in the very next call");
    }

    function test_NewlyGrantedOperator_CanBurnImmediately() public {
        vm.prank(carol);
        _expectNotOperator(carol);
        token.adminRetract(alice, 1 ether);

        vm.prank(admin);
        token.grantRole(OPERATOR_ROLE, carol);

        vm.prank(carol);
        token.adminRetract(alice, 1 ether);
        assertEq(token.totalSupply(), INITIAL_MINT - 1 ether);
    }

    /// @dev The single most important consequence of collapsing the operating
    ///      roles into one, and the assertion an operator's incident response
    ///      rests on: `revokeRole(OPERATOR_ROLE, ...)` closes EVERY path that can
    ///      change supply — both directions, all six entrypoints — in one
    ///      transaction. Before this change it would have closed only `mint`,
    ///      `guardEncode` and `guardRetract`, leaving three custodial burn paths open.
    ///      The flip side is that there is no longer a burn-only revoke; stopping
    ///      burning stops minting too.
    function test_RevokedOperator_LosesEveryBurnAndMintPathImmediately() public {
        vm.prank(alice);
        token.approve(operator, 10 ether);
        vm.prank(operator);
        token.encode(operator, 10 ether);

        vm.prank(admin);
        token.revokeRole(OPERATOR_ROLE, operator);

        vm.startPrank(operator);
        _expectNotOperator(operator);
        token.encode(bob, 1 ether);
        _expectNotOperator(operator);
        token.guardEncode(bob, 1 ether, INITIAL_MINT + 10 ether);
        _expectNotOperator(operator);
        token.adminRetract(alice, 1 ether);
        _expectNotOperator(operator);
        token.guardRetract(alice, 1 ether, INITIAL_MINT + 10 ether);
        vm.stopPrank();

        assertEq(token.totalSupply(), INITIAL_MINT + 10 ether, "one revoke closes both directions at once");
        assertEq(token.allowance(alice, operator), 10 ether, "and no rejected path consumed the allowance");
    }

    /// @dev Roles stack rather than displace: one address may legitimately hold
    ///      both. Worth pinning because it is also the shape of an escalation,
    ///      which `AdminLifecycle.t.sol` covers from that angle — and it is the
    ///      backend's own shape, where one mint-authority EOA is admin and
    ///      operator at once.
    function test_RolesStack_OneAddressMayHoldSeveral() public {
        vm.startPrank(admin);
        token.grantRole(OPERATOR_ROLE, carol);
        token.grantRole(DEFAULT_ADMIN_ROLE, carol);
        vm.stopPrank();

        assertTrue(token.hasRole(OPERATOR_ROLE, carol));
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, carol));

        vm.startPrank(carol);
        token.encode(carol, 5 ether);
        token.adminRetract(carol, 5 ether);
        vm.stopPrank();

        assertEq(token.totalSupply(), INITIAL_MINT);

        // ...and revoking one leaves the other standing
        vm.prank(admin);
        token.revokeRole(OPERATOR_ROLE, carol);
        assertFalse(token.hasRole(OPERATOR_ROLE, carol));
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, carol), "revoking one role must not strip the others");
    }

    /// @dev Re-granting a held role and revoking an unheld one are both no-ops
    ///      rather than reverts, which is what lets an operator re-run a role fix
    ///      without first working out which half of it already landed. Note the
    ///      contrast with `initialize`, which is deliberately NOT idempotent —
    ///      see `Initialization.t.sol`.
    function test_GrantAndRevoke_AreIdempotent() public {
        vm.startPrank(admin);
        token.grantRole(OPERATOR_ROLE, operator); // already held
        assertTrue(token.hasRole(OPERATOR_ROLE, operator));

        token.revokeRole(OPERATOR_ROLE, carol); // never held
        assertFalse(token.hasRole(OPERATOR_ROLE, carol));
        vm.stopPrank();
    }

    /// @dev A redundant grant emits nothing, so an event-driven reconciler does
    ///      not see phantom appointments when a recovery pass re-runs.
    function test_RedundantGrant_EmitsNothing() public {
        vm.recordLogs();
        vm.prank(admin);
        token.grantRole(OPERATOR_ROLE, operator); // already held

        assertEq(vm.getRecordedLogs().length, 0, "a no-op grant must not emit RoleGranted");
    }

    function test_Grant_EmitsRoleGranted() public {
        vm.expectEmit(true, true, true, false, address(token));
        emit IAccessControl.RoleGranted(OPERATOR_ROLE, carol, admin);

        vm.prank(admin);
        token.grantRole(OPERATOR_ROLE, carol);
    }

    function test_Revoke_EmitsRoleRevoked() public {
        vm.expectEmit(true, true, true, false, address(token));
        emit IAccessControl.RoleRevoked(OPERATOR_ROLE, operator, admin);

        vm.prank(admin);
        token.revokeRole(OPERATOR_ROLE, operator);
    }
}
