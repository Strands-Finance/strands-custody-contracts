// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice What the admin can and cannot reach, and what happens as
///         DEFAULT_ADMIN_ROLE changes hands. Two properties carry the security
///         story the README states:
///
///         1. The admin holds NO power over balances. It can reach one by
///            granting itself CUSTODIAN_ROLE, but that is a separate
///            transaction which lands on-chain as {RoleGranted} — a standing
///            power converted into a visible, auditable escalation.
///         2. DEFAULT_ADMIN_ROLE is its own role admin, so losing the last
///            holder freezes the role graph permanently.
///
/// @dev    This suite relies on the plain `BaseTest` fixture, where `admin` is
///         the ONLY holder of DEFAULT_ADMIN_ROLE. Adding a second holder to the
///         fixture would silently invalidate every "last admin" assertion below.
contract AdminLifecycleTest is BaseTest {
    // ---------- the admin has no standing power over balances ----------

    /// @dev The headline claim. Before the transfer allowlist was removed the
    ///      admin could seize any balance via `adminTransfer`; it now has no
    ///      path to one at all without first appointing itself.
    function test_Admin_HasNoPowerOverBalances() public {
        vm.startPrank(admin);

        _expectNotMinter(admin);
        token.mint(admin, 1 ether);

        _expectNotCustodian(admin);
        token.custodyBurn(alice, 1 ether);

        _expectNotCustodian(admin);
        token.burnFrom(alice, 1 ether);

        vm.stopPrank();

        assertEq(token.balanceOf(alice), INITIAL_MINT, "the admin cannot touch a holder's balance");
        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev The admin cannot move someone else's tokens by any ordinary route
    ///      either — no allowance, no privileged transfer entrypoint.
    function test_Admin_CannotMoveAnotherHoldersBalance() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, CUSTODIAN_ROLE)
        );
        token.burnFrom(alice, 1 ether);

        vm.prank(admin);
        vm.expectRevert(); // no allowance from alice
        token.transferFrom(alice, admin, 1 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT);
        assertEq(token.balanceOf(admin), 0);
    }

    /// @dev Escalation IS available — the admin administers CUSTODIAN_ROLE — but
    ///      only through a grant that is visible on-chain. That visibility is
    ///      the whole security argument for removing `adminTransfer`, so it is
    ///      asserted rather than left as prose.
    function test_Admin_ReachesBalancesOnlyViaAVisibleSelfGrant() public {
        vm.expectEmit(true, true, true, false, address(token));
        emit IAccessControl.RoleGranted(CUSTODIAN_ROLE, admin, admin);

        vm.prank(admin);
        token.grantRole(CUSTODIAN_ROLE, admin);

        vm.prank(admin);
        token.custodyBurn(alice, 100 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT - 100 ether);
        assertTrue(token.hasRole(CUSTODIAN_ROLE, admin), "the escalation is durable state, not a transient bypass");
    }

    /// @dev The same shape on the issuance side.
    function test_Admin_ReachesMintingOnlyViaAVisibleSelfGrant() public {
        vm.expectEmit(true, true, true, false, address(token));
        emit IAccessControl.RoleGranted(MINTER_ROLE, admin, admin);

        vm.prank(admin);
        token.grantRole(MINTER_ROLE, admin);

        vm.prank(admin);
        token.mint(admin, 100 ether);

        assertEq(token.balanceOf(admin), 100 ether);
        assertEq(token.totalSupply(), INITIAL_MINT + 100 ether);
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
        token.grantRole(MINTER_ROLE, carol);
        token.revokeRole(MINTER_ROLE, carol);
        vm.stopPrank();
        assertFalse(token.hasRole(MINTER_ROLE, carol), "successor can grant and revoke");

        // ...and the predecessor holds none of it
        vm.startPrank(admin);
        _expectNotAdmin(admin);
        token.grantRole(CUSTODIAN_ROLE, bob);
        _expectNotAdmin(admin);
        token.revokeRole(CUSTODIAN_ROLE, custodian);
        vm.stopPrank();

        assertFalse(token.hasRole(CUSTODIAN_ROLE, bob), "a stripped admin cannot appoint");
        assertTrue(token.hasRole(CUSTODIAN_ROLE, custodian), "nor dismantle the role graph");
        assertEq(token.totalSupply(), INITIAL_MINT, "a rotation moves no supply");
    }

    /// @dev A rotation is scoped to DEFAULT_ADMIN_ROLE. Incumbents keep working
    ///      across it, and the successor may be an address that already holds
    ///      another role.
    function test_AdminHandover_LeavesOtherRolesIntact() public {
        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, custodian); // successor is an existing role holder
        vm.prank(custodian);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin);

        assertTrue(token.hasRole(CUSTODIAN_ROLE, custodian), "gaining admin must not displace the existing role");
        assertTrue(token.hasRole(MINTER_ROLE, minter), "an unrelated role holder is untouched");

        vm.prank(minter);
        token.mint(alice, 50 ether);
        vm.prank(custodian);
        token.custodyBurn(alice, 50 ether);
        assertEq(token.totalSupply(), INITIAL_MINT, "both incumbents still work after the rotation");
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
            token.grantRole(MINTER_ROLE, carol);
            assertTrue(token.hasRole(MINTER_ROLE, carol), "each successor holds full admin access");
            vm.prank(current);
            token.revokeRole(MINTER_ROLE, carol);
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
        token.grantRole(MINTER_ROLE, carol);
        assertTrue(token.hasRole(MINTER_ROLE, carol), "renouncing with a successor in place is not a freeze");
    }

    // ---------- losing the last admin ----------

    /// @dev Pins the README warning. The role graph freezes: no new minter, no
    ///      new custodian, ever.
    function test_RenouncedLastAdmin_FreezesTheRoleGraph() public {
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, admin));

        vm.startPrank(admin);
        _expectNotAdmin(admin);
        token.grantRole(MINTER_ROLE, carol);
        _expectNotAdmin(admin);
        token.grantRole(CUSTODIAN_ROLE, carol);
        vm.stopPrank();

        assertFalse(token.hasRole(MINTER_ROLE, carol));
        assertFalse(token.hasRole(CUSTODIAN_ROLE, carol));
    }

    /// @dev DEFAULT_ADMIN_ROLE is its own role admin, so re-granting it requires
    ///      already holding it. Once the last holder is gone there is no
    ///      bootstrap path from ANY party.
    function test_RenouncedLastAdmin_IsUnrecoverableByAnyParty() public {
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        address[5] memory parties = [admin, alice, minter, custodian, address(this)];
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
        token.grantRole(MINTER_ROLE, carol);
    }

    /// @dev The freeze is a snapshot, not a shutdown: incumbents keep every
    ///      power they already held. Supply can still move while those keys
    ///      live — and, now that transfers are unrestricted, so can balances.
    function test_FrozenRoleGraph_LeavesIncumbentsAndTransfersWorking() public {
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        vm.prank(minter);
        token.mint(carol, 10 ether);
        vm.prank(custodian);
        token.custodyBurn(carol, 10 ether);
        assertEq(token.totalSupply(), INITIAL_MINT, "incumbents are unaffected by the freeze");

        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether, "transfers need no privilege, so they survive the freeze");
    }

    /// @dev The end state the README's "keep at least two holders of each role"
    ///      rule exists to prevent. With the last admin AND the custodian gone,
    ///      balances still move freely but can never be redeemed — a holder
    ///      cannot burn their own claim, and no new custodian can be appointed.
    function test_LosingTheLastAdminAndCustodian_MakesRedemptionImpossible() public {
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);
        vm.prank(custodian);
        token.renounceRole(CUSTODIAN_ROLE, custodian);

        // the incumbent custodian is gone
        vm.prank(custodian);
        _expectNotCustodian(custodian);
        token.custodyBurn(alice, 1 ether);

        // the holder cannot let themselves out
        vm.prank(alice);
        _expectNotCustodian(alice);
        token.burn(INITIAL_MINT);

        // and nobody can appoint a replacement
        vm.prank(admin);
        _expectNotAdmin(admin);
        token.grantRole(CUSTODIAN_ROLE, carol);

        // ...yet the balance is still perfectly mobile
        vm.prank(alice);
        token.transfer(bob, INITIAL_MINT);

        assertEq(token.balanceOf(bob), INITIAL_MINT, "value still moves");
        assertEq(token.totalSupply(), INITIAL_MINT, "but no supply can ever be destroyed again");
    }
}
