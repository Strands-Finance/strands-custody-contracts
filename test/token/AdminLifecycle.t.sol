// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice What the admin can and cannot reach, and what happens as
///         DEFAULT_ADMIN_ROLE changes hands. Three properties carry the security
///         story the README states:
///
///         1. The admin holds NO power over balances. It can reach one by
///            granting itself OPERATOR_ROLE, but that is a separate transaction
///            which lands on-chain as {RoleGranted} — a standing power converted
///            into a visible, auditable escalation. This is the property that
///            makes OpenZeppelin's "keep DEFAULT_ADMIN_ROLE cold" advice
///            actionable here, and the reason the operating surface was NOT
///            folded onto DEFAULT_ADMIN_ROLE when the roles were collapsed.
///         2. The admin DOES hold a standing power over MOBILITY: it writes the
///            destination allowlist. That can strand a balance where it is; it
///            can never move one, least of all to the admin.
///         3. DEFAULT_ADMIN_ROLE is its own role admin, so losing the last
///            holder freezes the role graph permanently — and the allowlist
///            with it.
///
/// @dev    This suite relies on the plain `BaseTest` fixture, where `admin` is
///         the ONLY holder of DEFAULT_ADMIN_ROLE. Adding a second holder to the
///         fixture would silently invalidate every "last admin" assertion below.
contract AdminLifecycleTest is BaseTest {
    // ---------- the admin has no standing power over balances ----------

    /// @dev The headline claim. An earlier version carried `adminTransfer`, a
    ///      DEFAULT_ADMIN_ROLE entrypoint that moved any balance anywhere; it is
    ///      gone and did not come back with the allowlist. The admin now has no
    ///      path to a balance at all without first appointing itself.
    function test_Admin_HasNoPowerOverBalances() public {
        vm.startPrank(admin);

        _expectNotOperator(admin);
        token.encode(admin, 1 ether);

        _expectNotOperator(admin);
        token.adminRetract(alice, 1 ether);

        vm.stopPrank();

        assertEq(token.balanceOf(alice), INITIAL_MINT, "the admin cannot touch a holder's balance");
        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev The admin cannot move someone else's tokens by any ordinary route
    ///      either — no allowance, no privileged transfer entrypoint.
    ///
    ///      `admin` is opened as a destination first, and that is the point
    ///      rather than a setup detail: the admin can make ITSELF a legal sink
    ///      for value and still cannot pull any. It also forces the allowance
    ///      to be the thing under test — the destination guard runs before
    ///      `_spendAllowance`, so with `admin` closed this would revert for a
    ///      reason that has nothing to do with the claim.
    function test_Admin_CannotMoveAnotherHoldersBalance() public {
        _allow(admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, admin, 0, 1 ether));
        token.transferFrom(alice, admin, 1 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT);
        assertEq(token.balanceOf(admin), 0);
    }

    /// @dev Escalation IS available — the admin administers OPERATOR_ROLE — but
    ///      only through a grant that is visible on-chain. That visibility is
    ///      the whole security argument for removing `adminTransfer`, so it is
    ///      asserted rather than left as prose.
    ///
    ///      With one operating role, that single grant now opens BOTH
    ///      directions at once: an admin who appoints itself to reach a burn has
    ///      simultaneously acquired the power to mint. Asserted here, because it
    ///      is the sharpest consequence of the collapse and a reviewer reasoning
    ///      about blast radius will look for it in this file.
    function test_Admin_ReachesSupplyOnlyViaAVisibleSelfGrant() public {
        vm.expectEmit(true, true, true, false, address(token));
        emit IAccessControl.RoleGranted(OPERATOR_ROLE, admin, admin);

        vm.prank(admin);
        token.grantRole(OPERATOR_ROLE, admin);

        vm.startPrank(admin);
        token.adminRetract(alice, 100 ether);
        token.encode(admin, 100 ether);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), INITIAL_MINT - 100 ether, "one grant opened the burn side");
        assertEq(token.balanceOf(admin), 100 ether, "and the mint side, in the same appointment");
        assertTrue(token.hasRole(OPERATOR_ROLE, admin), "the escalation is durable state, not a transient bypass");
    }

    // ---------- the standing power the admin DOES hold ----------

    /// @dev Stated at its limit. Closing the route immobilises alice completely
    ///      — and moves her balance nowhere, least of all to the admin. Mobility
    ///      and ownership are separate powers and the admin holds only the first.
    function test_Admin_CanStrandABalanceButNeverSeizeIt() public {
        _allow(bob);
        _disallow(bob);

        vm.prank(alice);
        _expectDestinationNotAllowed(bob);
        token.transfer(bob, 1 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT, "stranded, not seized");
        assertEq(token.balanceOf(admin), 0, "the admin gained nothing by closing the route");
    }

    // ---------- handover: the rotation that does not brick anything ----------

    /// @dev Granting the successor BEFORE revoking the predecessor is what makes
    ///      a rotation safe; the reverse order is the permanent lockout pinned
    ///      further down.
    function test_AdminHandover_StripsPredecessorAndEmpowersSuccessor() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);

        // the overlap window: both are live and either may act
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin), "predecessor still holds the role mid-rotation");
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, newAdmin), "successor holds it too");

        vm.prank(newAdmin);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin);
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, admin));

        // the successor holds the full admin surface
        vm.startPrank(newAdmin);
        token.grantRole(OPERATOR_ROLE, carol);
        token.revokeRole(OPERATOR_ROLE, carol);
        vm.stopPrank();
        assertFalse(token.hasRole(OPERATOR_ROLE, carol), "successor can grant and revoke");

        // ...and the predecessor holds none of it
        vm.startPrank(admin);
        _expectNotAdmin(admin);
        token.grantRole(OPERATOR_ROLE, bob);
        _expectNotAdmin(admin);
        token.revokeRole(OPERATOR_ROLE, operator);
        vm.stopPrank();

        assertFalse(token.hasRole(OPERATOR_ROLE, bob), "a stripped admin cannot appoint");
        assertTrue(token.hasRole(OPERATOR_ROLE, operator), "nor dismantle the role graph");
        assertEq(token.totalSupply(), INITIAL_MINT, "a rotation moves no supply");
    }

    /// @dev A rotation is scoped to DEFAULT_ADMIN_ROLE. The incumbent operator
    ///      keeps working across it, and the successor may be an address that
    ///      already holds the operating role.
    function test_AdminHandover_LeavesOtherRolesIntact() public {
        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, operator); // successor is an existing role holder
        vm.prank(operator);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin);

        assertTrue(token.hasRole(OPERATOR_ROLE, operator), "gaining admin must not displace the existing role");

        vm.startPrank(operator);
        token.encode(alice, 50 ether);
        token.adminRetract(alice, 50 ether);
        vm.stopPrank();
        assertEq(token.totalSupply(), INITIAL_MINT, "the incumbent still works after the rotation");
    }

    /// @dev Rotation is not a one-shot: nothing about the first handover
    ///      consumes a resource the next one needs.
    function test_AdminRotation_CanBeRepeated() public {
        address[3] memory chain = [makeAddr("admin2"), makeAddr("admin3"), makeAddr("admin4")];
        address current = admin;

        for (uint256 i = 0; i < chain.length; i++) {
            vm.prank(current);
            token.grantRole(DEFAULT_ADMIN_ROLE, chain[i]);
            vm.prank(chain[i]);
            token.revokeRole(DEFAULT_ADMIN_ROLE, current);

            assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, current), "each predecessor is stripped in turn");
            current = chain[i];

            vm.prank(current);
            token.grantRole(OPERATOR_ROLE, carol);
            assertTrue(token.hasRole(OPERATOR_ROLE, carol), "each successor holds full admin access");
            vm.prank(current);
            token.revokeRole(OPERATOR_ROLE, carol);
        }
    }

    /// @dev The footgun guard on the renounce path. `renounceRole` takes a
    ///      confirmation argument precisely so an operator cannot renounce on
    ///      someone else's behalf — the exact slip available mid-rotation, when
    ///      both addresses are in hand.
    function test_RenounceRole_RejectsMismatchedConfirmation() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);

        vm.prank(admin);
        _expectBadConfirmation();
        token.renounceRole(DEFAULT_ADMIN_ROLE, newAdmin); // meant `admin`

        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin), "a mismatched confirmation is a no-op");
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, newAdmin), "and must not strip the address named instead");
    }

    function test_AdminHandover_ViaRenounce_IsEquivalent() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, admin));

        vm.prank(newAdmin);
        token.grantRole(OPERATOR_ROLE, carol);
        assertTrue(token.hasRole(OPERATOR_ROLE, carol), "renouncing with a successor in place is not a freeze");
    }

    // ---------- losing the last admin ----------

    /// @dev Pins the README warning. The role graph freezes: no new operator,
    ///      ever.
    function test_RenouncedLastAdmin_FreezesTheRoleGraph() public {
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, admin));

        vm.startPrank(admin);
        _expectNotAdmin(admin);
        token.grantRole(OPERATOR_ROLE, carol);
        _expectNotAdmin(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, carol);
        vm.stopPrank();

        assertFalse(token.hasRole(OPERATOR_ROLE, carol));
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, carol));
    }

    /// @dev DEFAULT_ADMIN_ROLE is its own role admin, so re-granting it requires
    ///      already holding it. Once the last holder is gone there is no
    ///      bootstrap path from ANY party.
    function test_RenouncedLastAdmin_IsUnrecoverableByAnyParty() public {
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        address[5] memory parties = [admin, alice, operator, bob, address(this)];
        for (uint256 i = 0; i < parties.length; i++) {
            vm.prank(parties[i]);
            _expectNotAdmin(parties[i]);
            token.grantRole(DEFAULT_ADMIN_ROLE, carol);
        }

        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, carol), "no party may bootstrap a new admin");
    }

    /// @dev `revokeRole` reaches the identical dead state, without the
    ///      `callerConfirmation` guard — one admin can do it to another, or to
    ///      itself.
    function test_RevokingLastAdmin_ReachesTheSameDeadState() public {
        vm.prank(admin);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin); // self-revoke needs no confirmation
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, admin));

        vm.prank(admin);
        _expectNotAdmin(admin);
        token.grantRole(OPERATOR_ROLE, carol);
    }

    /// @dev The freeze is a snapshot, not a shutdown: incumbents keep every
    ///      power they already held. Supply can still move while those keys
    ///      live — but the allowlist freezes too, so balances move only along
    ///      routes opened BEFORE the last admin went. `bob` is opened first for
    ///      exactly that reason, and `carol` is left closed to show the other
    ///      half: no destination can ever be added again, by anyone.
    function test_FrozenRoleGraph_FreezesTheAllowlistWithIt() public {
        _allow(bob);

        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        vm.startPrank(operator);
        token.encode(carol, 10 ether);
        token.adminRetract(carol, 10 ether);
        vm.stopPrank();
        assertEq(token.totalSupply(), INITIAL_MINT, "incumbents are unaffected by the freeze");

        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether, "a destination open at the freeze stays open");

        vm.prank(admin);
        _expectNotAdmin(admin);
        token.setDestinationAllowed(carol, true);

        vm.prank(alice);
        _expectDestinationNotAllowed(carol);
        token.transfer(carol, 1 ether);
    }

    /// @dev The end state the README's "keep at least two holders of each role"
    ///      rule exists to prevent, and it now takes only TWO losses rather than
    ///      three: one operating role means the operator is the sole redemption
    ///      path, so admin + operator gone is terminal. Balances still move along
    ///      already-open routes but can never be redeemed by anyone, ever.
    ///
    ///      The narrower loss is worth stating too: losing ONLY the operator is
    ///      recoverable, because the admin can appoint a replacement — which is
    ///      what `test_OperatorLossAloneIsRecoverableWhileAnAdminSurvives` below
    ///      pins. It is the surviving admin, not the surviving operator, that
    ///      makes the difference.
    function test_LosingTheLastAdminAndOperator_MakesRedemptionImpossible() public {
        _allow(bob); // the last thing the admin can ever do for this balance

        vm.prank(operator);
        token.renounceRole(OPERATOR_ROLE, operator);
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        // every burn path is closed, for the incumbent and for the holder alike
        vm.startPrank(operator);
        _expectNotOperator(operator);
        token.adminRetract(alice, 1 ether);
        _expectNotOperator(operator);
        token.guardRetract(alice, 1 ether, INITIAL_MINT);
        vm.stopPrank();

        vm.prank(alice);
        _expectNotOperator(alice);
        token.adminRetract(alice, INITIAL_MINT);

        // and nobody can appoint a replacement
        vm.startPrank(admin);
        _expectNotAdmin(admin);
        token.grantRole(OPERATOR_ROLE, carol);
        _expectNotAdmin(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, carol);
        vm.stopPrank();

        // ...yet the balance still moves, along the route opened before the freeze
        vm.prank(alice);
        token.transfer(bob, INITIAL_MINT);

        assertEq(token.balanceOf(bob), INITIAL_MINT, "value still moves, but only where it was already allowed to");
        assertEq(token.totalSupply(), INITIAL_MINT, "but no supply can ever be destroyed again");
    }

    /// @dev The recoverable half of the same story, so the test above is not
    ///      read as "losing the operator is fatal". A surviving admin can appoint
    ///      a new one, and the new one reaches the full operating surface
    ///      immediately.
    function test_OperatorLossAloneIsRecoverableWhileAnAdminSurvives() public {
        vm.prank(operator);
        token.renounceRole(OPERATOR_ROLE, operator);

        vm.prank(operator);
        _expectNotOperator(operator);
        token.adminRetract(alice, 1 ether);

        vm.prank(admin);
        token.grantRole(OPERATOR_ROLE, carol);

        vm.startPrank(carol);
        token.adminRetract(alice, 1 ether);
        token.encode(alice, 1 ether);
        vm.stopPrank();

        assertEq(token.totalSupply(), INITIAL_MINT, "the replacement holds the whole operating surface");
    }
}
