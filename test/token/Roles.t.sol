// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice The admin control surface: which role administers which, and who may
///         grant or revoke. How the roles are first seated is
///         `Initialization.t.sol`; rotation, renounce and the last-admin failure
///         mode live in `AdminLifecycle.t.sol`.
///
/// @dev    With the transfer allowlist gone, `DEFAULT_ADMIN_ROLE` has exactly
///         one power left — moving `MINTER_ROLE` and `CUSTODIAN_ROLE` around.
///         That makes `grantRole` / `revokeRole` the WHOLE admin surface, so it
///         is pinned here directly rather than only implied by the mint and
///         burn suites' negative cases.
contract RolesTest is BaseTest {
    // ---------- the seated role graph ----------

    function test_AdminHasDefaultAdminRole() public view {
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    /// @dev The admin holds the admin role and nothing else. An admin that came
    ///      out of `initialize` holding MINTER_ROLE or CUSTODIAN_ROLE would be
    ///      able to mint or burn with no visible grant, which is the whole point
    ///      of keeping the roles separate. `Initialization.t.sol` owns the
    ///      seating itself; this is the standing state every suite here assumes.
    function test_Admin_HoldsNoOperatingRole() public view {
        assertFalse(token.hasRole(MINTER_ROLE, admin), "admin must not be a minter");
        assertFalse(token.hasRole(CUSTODIAN_ROLE, admin), "admin must not be a custodian");
    }

    // ---------- role id / role admin wiring ----------

    /// @dev The ids are part of the deployed ABI: the backend's Nethereum
    ///      bindings resolve them by calling `MINTER_ROLE()` / `CUSTODIAN_ROLE()`
    ///      and then grant against the returned bytes32. Changing either string
    ///      would silently orphan every already-granted role on a live token.
    function test_RoleIds_AreTheKeccakOfTheirNames() public view {
        assertEq(MINTER_ROLE, keccak256("MINTER_ROLE"));
        assertEq(CUSTODIAN_ROLE, keccak256("CUSTODIAN_ROLE"));
        assertEq(DEFAULT_ADMIN_ROLE, bytes32(0), "OZ's DEFAULT_ADMIN_ROLE is the zero id");
    }

    /// @dev Nothing calls `_setRoleAdmin`, so OZ's default applies and
    ///      DEFAULT_ADMIN_ROLE administers everything. Pinned because a
    ///      re-pointed role admin would move the whole control surface without
    ///      changing a single function signature.
    function test_DefaultAdminRole_AdministersEveryRole() public view {
        assertEq(token.getRoleAdmin(MINTER_ROLE), DEFAULT_ADMIN_ROLE);
        assertEq(token.getRoleAdmin(CUSTODIAN_ROLE), DEFAULT_ADMIN_ROLE);
    }

    /// @dev DEFAULT_ADMIN_ROLE being its own admin is what makes the last-admin
    ///      loss in `AdminLifecycle.t.sol` unrecoverable — there is no outer
    ///      role to bootstrap from.
    function test_DefaultAdminRole_IsItsOwnAdmin() public view {
        assertEq(token.getRoleAdmin(DEFAULT_ADMIN_ROLE), DEFAULT_ADMIN_ROLE);
    }

    // ---------- who may grant and revoke ----------

    function test_Admin_CanGrantAndRevoke() public {
        vm.prank(admin);
        token.grantRole(MINTER_ROLE, carol);
        assertTrue(token.hasRole(MINTER_ROLE, carol));

        vm.prank(admin);
        token.revokeRole(MINTER_ROLE, carol);
        assertFalse(token.hasRole(MINTER_ROLE, carol));
    }

    function test_AdminCanRevokeCustodian() public {
        vm.prank(admin);
        token.revokeRole(CUSTODIAN_ROLE, custodian);
        assertFalse(token.hasRole(CUSTODIAN_ROLE, custodian));
    }

    /// @dev The load-bearing admin control. Without this the roles are
    ///      decorative: anyone could appoint themselves a custodian and burn.
    function test_NonAdmin_CannotGrantRole() public {
        vm.prank(alice);
        _expectNotAdmin(alice);
        token.grantRole(CUSTODIAN_ROLE, alice);

        assertFalse(token.hasRole(CUSTODIAN_ROLE, alice), "no self-appointment");
    }

    function test_NonAdmin_CannotRevokeRole() public {
        vm.prank(alice);
        _expectNotAdmin(alice);
        token.revokeRole(CUSTODIAN_ROLE, custodian);

        assertTrue(token.hasRole(CUSTODIAN_ROLE, custodian), "an outsider cannot dismantle the role graph");
    }

    /// @dev Holding one of the operating roles is not a shortcut into the admin
    ///      one. The custodian case is the sharpest: a custodian who could grant
    ///      would be able to appoint a second custodian and defeat any
    ///      "keep two independent keys" policy single-handedly.
    function test_MinterAndCustodian_CannotGrantRoles() public {
        vm.prank(minter);
        _expectNotAdmin(minter);
        token.grantRole(MINTER_ROLE, carol);

        vm.prank(custodian);
        _expectNotAdmin(custodian);
        token.grantRole(CUSTODIAN_ROLE, carol);

        assertFalse(token.hasRole(MINTER_ROLE, carol));
        assertFalse(token.hasRole(CUSTODIAN_ROLE, carol));
    }

    /// @dev No address is special. `admin` is excluded because it is the one
    ///      address for which the call legitimately succeeds; `minter` and
    ///      `custodian` because `setUp` already granted them the role this may
    ///      pick, so the closing `hasRole` would read `true` for a reason that
    ///      has nothing to do with the rejected grant. That those two cannot
    ///      grant either is `test_MinterAndCustodian_CannotGrantRoles` above.
    function testFuzz_ArbitraryNonAdmin_CannotGrantAnyRole(address caller, uint8 which) public {
        vm.assume(caller != admin && caller != minter && caller != custodian);
        bytes32 role = which % 3 == 0 ? MINTER_ROLE : which % 3 == 1 ? CUSTODIAN_ROLE : DEFAULT_ADMIN_ROLE;

        vm.prank(caller);
        _expectNotAdmin(caller);
        token.grantRole(role, caller);

        assertFalse(token.hasRole(role, caller));
    }

    /// @dev Reads are open — an integration can check its own standing without
    ///      privileges, and does not have to guess from a reverting write.
    function testFuzz_AnyCaller_CanReadTheRoleGraph(address caller) public {
        vm.prank(caller);
        assertTrue(token.hasRole(CUSTODIAN_ROLE, custodian));
        vm.prank(caller);
        assertEq(token.getRoleAdmin(CUSTODIAN_ROLE), DEFAULT_ADMIN_ROLE);
    }

    // ---------- grants and revokes take effect immediately ----------

    function test_NewlyGrantedMinter_CanMintImmediately() public {
        vm.prank(carol);
        _expectNotMinter(carol);
        token.mint(carol, 1 ether);

        vm.prank(admin);
        token.grantRole(MINTER_ROLE, carol);

        vm.prank(carol);
        token.mint(carol, 1 ether);
        assertEq(token.balanceOf(carol), 1 ether, "a grant is effective in the very next call");
    }

    function test_RevokedMinter_LosesMintImmediately() public {
        vm.prank(admin);
        token.revokeRole(MINTER_ROLE, minter);

        vm.prank(minter);
        _expectNotMinter(minter);
        token.mint(bob, 1 ether);

        assertEq(token.totalSupply(), INITIAL_MINT, "a revoked minter cannot issue");
    }

    function test_NewlyGrantedCustodian_CanBurnImmediately() public {
        vm.prank(carol);
        _expectNotCustodian(carol);
        token.custodyBurn(alice, 1 ether);

        vm.prank(admin);
        token.grantRole(CUSTODIAN_ROLE, carol);

        vm.prank(carol);
        token.custodyBurn(alice, 1 ether);
        assertEq(token.totalSupply(), INITIAL_MINT - 1 ether);
    }

    /// @dev All three CUSTODIAN_ROLE entrypoints close together — and `guardBurn`
    ///      does NOT, because it is gated on MINTER_ROLE. Revoking the custodian
    ///      is therefore not the same as stopping every burn, which is the most
    ///      likely wrong assumption an operator could carry into an incident.
    function test_RevokedCustodian_LosesEveryCustodialBurnPathImmediately() public {
        vm.prank(alice);
        token.approve(custodian, 10 ether);

        vm.prank(admin);
        token.revokeRole(CUSTODIAN_ROLE, custodian);

        vm.startPrank(custodian);
        _expectNotCustodian(custodian);
        token.custodyBurn(alice, 1 ether);
        _expectNotCustodian(custodian);
        token.burnFrom(alice, 1 ether);
        _expectNotCustodian(custodian);
        token.burn(1 ether);
        vm.stopPrank();

        assertEq(token.totalSupply(), INITIAL_MINT, "revocation closes all three custodial entrypoints at once");

        // ...but the guarded burn is the minter's, and survives the custodian's revocation untouched.
        vm.prank(minter);
        token.guardBurn(alice, 1 ether, INITIAL_MINT);
        assertEq(token.totalSupply(), INITIAL_MINT - 1 ether, "guardBurn is closed by revoking MINTER_ROLE, not this");
    }

    /// @dev The converse, so the split is pinned from both sides: revoking the
    ///      MINTER closes `guardBurn` and leaves the custodial paths standing.
    function test_RevokedMinter_LosesGuardBurnButLeavesTheCustodianBurning() public {
        vm.prank(admin);
        token.revokeRole(MINTER_ROLE, minter);

        vm.prank(minter);
        _expectNotMinter(minter);
        token.guardBurn(alice, 1 ether, INITIAL_MINT);

        vm.prank(custodian);
        token.custodyBurn(alice, 1 ether);
        assertEq(token.totalSupply(), INITIAL_MINT - 1 ether, "the custodial surface is untouched by a minter revoke");
    }

    /// @dev Roles stack rather than displace: one address may legitimately hold
    ///      several. Worth pinning because it is also the shape of an
    ///      escalation, which `AdminLifecycle.t.sol` covers from that angle.
    function test_RolesStack_OneAddressMayHoldSeveral() public {
        vm.startPrank(admin);
        token.grantRole(MINTER_ROLE, carol);
        token.grantRole(CUSTODIAN_ROLE, carol);
        vm.stopPrank();

        assertTrue(token.hasRole(MINTER_ROLE, carol));
        assertTrue(token.hasRole(CUSTODIAN_ROLE, carol));

        vm.startPrank(carol);
        token.mint(carol, 5 ether);
        token.custodyBurn(carol, 5 ether);
        vm.stopPrank();

        assertEq(token.totalSupply(), INITIAL_MINT);

        // ...and revoking one leaves the other standing
        vm.prank(admin);
        token.revokeRole(MINTER_ROLE, carol);
        assertFalse(token.hasRole(MINTER_ROLE, carol));
        assertTrue(token.hasRole(CUSTODIAN_ROLE, carol), "revoking one role must not strip the others");
    }

    /// @dev Re-granting a held role and revoking an unheld one are both no-ops
    ///      rather than reverts, which is what lets an operator re-run a role fix
    ///      without first working out which half of it already landed. Note the
    ///      contrast with `initialize`, which is deliberately NOT idempotent —
    ///      see `Initialization.t.sol`.
    function test_GrantAndRevoke_AreIdempotent() public {
        vm.startPrank(admin);
        token.grantRole(MINTER_ROLE, minter); // already held
        assertTrue(token.hasRole(MINTER_ROLE, minter));

        token.revokeRole(MINTER_ROLE, carol); // never held
        assertFalse(token.hasRole(MINTER_ROLE, carol));
        vm.stopPrank();
    }

    /// @dev A redundant grant emits nothing, so an event-driven reconciler does
    ///      not see phantom appointments when a recovery pass re-runs.
    function test_RedundantGrant_EmitsNothing() public {
        vm.recordLogs();
        vm.prank(admin);
        token.grantRole(MINTER_ROLE, minter); // already held

        assertEq(vm.getRecordedLogs().length, 0, "a no-op grant must not emit RoleGranted");
    }

    function test_Grant_EmitsRoleGranted() public {
        vm.expectEmit(true, true, true, false, address(token));
        emit IAccessControl.RoleGranted(CUSTODIAN_ROLE, carol, admin);

        vm.prank(admin);
        token.grantRole(CUSTODIAN_ROLE, carol);
    }

    function test_Revoke_EmitsRoleRevoked() public {
        vm.expectEmit(true, true, true, false, address(token));
        emit IAccessControl.RoleRevoked(CUSTODIAN_ROLE, custodian, admin);

        vm.prank(admin);
        token.revokeRole(CUSTODIAN_ROLE, custodian);
    }
}
