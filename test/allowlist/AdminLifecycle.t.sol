// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice What happens to the allowlist as DEFAULT_ADMIN_ROLE changes hands —
///         and the blast radius of losing the last admin. DEFAULT_ADMIN_ROLE is
///         its own role admin, so once the last holder is gone there is no
///         bootstrap path from any party and the allowlist is frozen forever.
///
/// @dev    This suite intentionally extends the plain `BaseTest` fixture, where
///         `admin` really is the ONLY holder of DEFAULT_ADMIN_ROLE. Adding a
///         second holder to the fixture would silently invalidate every
///         "last admin" assertion below.
contract AdminLifecycleTest is BaseTest {
    function test_RevokedAdmin_CannotSetDestination() public {
        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, carol); // keep a live admin so the revoke is not a lockout
        vm.prank(carol);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin);

        vm.prank(admin);
        _expectNotAdmin(admin);
        token.setDestinationAllowed(alice, bob, true);

        vm.prank(carol);
        token.setDestinationAllowed(alice, bob, true); // the new admin still can
        assertTrue(token.allowedDestination(alice, bob));
    }

    /// @dev Pins the README warning: renouncing the last admin freezes the
    ///      allowlist, so unapproved balances become permanently non-transferable
    ///      while the custodian's redemption path keeps working.
    function test_RenouncedAdmin_FreezesAllowlistButCustodyBurnStillWorks() public {
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, admin));

        vm.prank(admin);
        _expectNotAdmin(admin);
        token.setDestinationAllowed(alice, bob, true);

        vm.prank(alice);
        _expectNotAllowed(alice, bob);
        token.transfer(bob, 1 ether);

        vm.prank(custodian);
        token.custodyBurn(alice, 1 ether);
        assertEq(token.balanceOf(alice), 999 ether, "the custodial burn path must survive a frozen allowlist");
    }

    /// @dev The freeze is a SNAPSHOT, not a shutdown: entries written before the
    ///      last admin disappeared keep working forever. Only the ability to add
    ///      or remove entries is lost.
    function test_RenouncedAdmin_PreExistingApprovalsKeepWorking() public {
        _allow(alice, bob);
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether, "pre-approved route must survive the freeze");

        // ...but it can never be revoked again, so this route is now permanent.
        vm.prank(admin);
        vm.expectRevert();
        token.setDestinationAllowed(alice, bob, false);

        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 200 ether, "route is now irrevocable");
    }

    /// @dev DEFAULT_ADMIN_ROLE is its own role admin, so re-granting it requires
    ///      already holding it. Once the last holder is gone there is no bootstrap
    ///      path from any party.
    function test_RenouncedAdmin_IsUnrecoverableByAnyParty() public {
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

    /// @dev `revokeRole` reaches the identical dead state as `renounceRole`, but
    ///      without the `callerConfirmation` footgun-guard, and one admin can do
    ///      it to another.
    function test_RevokingLastAdmin_ReachesSameDeadStateAsRenounce() public {
        vm.prank(admin);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin); // self-revoke: no confirmation argument required
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, admin));

        vm.prank(admin);
        _expectNotAdmin(admin);
        token.setDestinationAllowed(alice, bob, true);
    }

    /// @dev The whole role graph freezes, not just the allowlist: no new minters
    ///      or custodians can ever be appointed. Incumbents keep their powers, so
    ///      supply can still change while those keys live.
    function test_RenouncedAdmin_FreezesEntireRoleGraph() public {
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        vm.startPrank(admin);
        _expectNotAdmin(admin);
        token.grantRole(MINTER_ROLE, carol);
        _expectNotAdmin(admin);
        token.grantRole(CUSTODIAN_ROLE, carol);
        vm.stopPrank();

        // incumbents are unaffected
        vm.prank(minter);
        token.mint(carol, 10 ether);
        vm.prank(custodian);
        token.custodyBurn(carol, 10 ether);

        // ...but if the incumbent custodian is also lost, that power is gone for good
        vm.prank(custodian);
        token.renounceRole(CUSTODIAN_ROLE, custodian);
        vm.prank(custodian);
        _expectNotCustodian(custodian);
        token.custodyBurn(alice, 1 ether);
    }

    /// @dev There is NO self-service exit. Redemption is custodian-only, so a
    ///      frozen allowlist leaves a holder's balance both immobile and
    ///      unredeemable without the custodian — losing the last admin and the
    ///      custodian key together strands it permanently. That is the reason
    ///      the README insists on keeping at least two holders of each role.
    function test_RenouncedAdmin_OnlyTheCustodianCanRedeem() public {
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        vm.prank(alice);
        _expectNotAllowed(alice, bob);
        token.transfer(bob, 1 ether);

        // the holder cannot let themselves out
        vm.prank(alice);
        _expectNotCustodian(alice);
        token.burn(INITIAL_MINT);
        assertEq(token.totalSupply(), INITIAL_MINT, "supply must not move without the custodian");

        // ...the custodian is the only remaining exit
        _expectTransferEvent(alice, address(0), INITIAL_MINT);
        vm.prank(custodian);
        token.custodyBurn(alice, INITIAL_MINT);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }

    // ---------- rotation: the handover that does NOT brick anything ----------
    //
    // Everything above is the failure mode. These are the success mode: a
    // deliberate handover from one admin to another, which is routine key
    // hygiene and sits one ordering mistake away from the permanent brick.
    //
    // The `_allow` / `_link` helpers in `Base.t.sol` prank as `admin`, so they
    // are unusable once `admin` has been rotated out — post-handover writes call
    // the setters directly, which also keeps the acting admin visible at the call
    // site. A locally declared `newAdmin` keeps admin identity from colliding
    // with holder identity in an assertion, and leaves the fixture's single-admin
    // invariant (see the contract docstring) untouched.

    /// @dev The positive control for `test_RenouncedAdmin_IsUnrecoverableByAnyParty`.
    ///      Granting the successor BEFORE revoking the predecessor is what makes a
    ///      rotation safe; the reverse order is the lockout the tests above pin.
    ///
    ///      All five admin powers are exercised, not just the allowlist setter.
    ///      `test_RevokedAdmin_CannotSetDestination` checks only
    ///      `setDestinationAllowed`, so a rotation that silently stranded
    ///      `adminTransfer` or `grantRole` would pass the suite — and those two
    ///      are the least likely to be missed until the moment they are needed.
    function test_AdminHandover_SuccessorHoldsEveryAdminPower() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);

        // the overlap window: both are live, and either may act
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin), "predecessor still holds the role mid-rotation");
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, newAdmin), "successor holds it too");
        vm.prank(admin);
        token.setDestinationAllowed(carol, bob, true);
        vm.prank(newAdmin);
        token.setDestinationAllowed(carol, bob, false);
        assertFalse(token.allowedDestination(carol, bob), "either admin may write during the overlap");

        vm.prank(newAdmin);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin);
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, admin));

        // the successor holds every admin power
        vm.startPrank(newAdmin);
        token.setDestinationAllowed(alice, bob, true);
        token.setLink(bob, carol, true);
        token.adminTransfer(alice, carol, 100 ether); // alice -> carol is CLOSED: the bypass still works
        token.grantRole(MINTER_ROLE, carol);
        token.revokeRole(MINTER_ROLE, carol);
        vm.stopPrank();

        assertTrue(token.allowedDestination(alice, bob), "successor can write a single edge");
        assertTrue(_isLinked(bob, carol), "successor can write both edges of a link");
        assertFalse(token.allowedDestination(alice, carol), "adminTransfer still opens no edge");
        assertEq(token.balanceOf(carol), 100 ether, "successor can move a balance out of band");
        assertFalse(token.hasRole(MINTER_ROLE, carol), "successor can grant and revoke other roles");
        assertEq(token.totalSupply(), INITIAL_MINT, "rotation and adminTransfer must not move supply");

        // ...and the predecessor holds none of them
        vm.startPrank(admin);
        _expectNotAdmin(admin);
        token.setDestinationAllowed(alice, carol, true);
        _expectNotAdmin(admin);
        token.setLink(alice, bob, true);
        _expectNotAdmin(admin);
        token.adminTransfer(alice, bob, 1 ether);
        _expectNotAdmin(admin);
        token.grantRole(CUSTODIAN_ROLE, bob);
        _expectNotAdmin(admin);
        token.revokeRole(CUSTODIAN_ROLE, custodian);
        vm.stopPrank();

        assertTrue(token.hasRole(CUSTODIAN_ROLE, custodian), "a stripped admin cannot dismantle the role graph");
    }

    /// @dev Rotation is a change of key, not of policy: entries written by the
    ///      outgoing admin survive it and — unlike
    ///      `test_RenouncedAdmin_PreExistingApprovalsKeepWorking`, where they
    ///      become irrevocable — remain closeable by the successor.
    function test_AdminHandover_PreservesAllowlistStateAndKeepsItRevocable() public {
        address newAdmin = makeAddr("newAdmin");
        _link(alice, bob); // written by the outgoing admin

        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        vm.prank(newAdmin);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin);

        assertTrue(_isLinked(alice, bob), "rotation must not clear the allowlist");

        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether, "an approved route survives the handover");

        vm.prank(newAdmin);
        token.setLink(alice, bob, false);

        vm.prank(alice);
        _expectNotAllowed(alice, bob);
        token.transfer(bob, 1 ether);
        assertEq(token.totalSupply(), INITIAL_MINT, "no supply moved across the whole rotation");
    }

    /// @dev An admin rotation is scoped to DEFAULT_ADMIN_ROLE. Incumbent minters
    ///      and custodians keep working across it — and the successor may be an
    ///      address that already holds one of those roles, since AccessControl
    ///      roles stack rather than displace.
    function test_AdminHandover_LeavesOtherRolesIntact_AndSuccessorMayStackRoles() public {
        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, custodian); // the successor is an existing role holder
        vm.prank(custodian);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin);

        assertTrue(token.hasRole(CUSTODIAN_ROLE, custodian), "gaining admin must not displace the existing role");
        assertTrue(token.hasRole(MINTER_ROLE, minter), "an unrelated role holder is untouched by the rotation");

        vm.prank(minter);
        token.mint(alice, 50 ether);
        vm.prank(custodian);
        token.custodyBurn(alice, 50 ether);
        assertEq(token.totalSupply(), INITIAL_MINT, "both incumbents still work after the rotation");

        // ...and the stacked successor wields both sets of powers
        vm.startPrank(custodian);
        token.adminTransfer(alice, bob, 10 ether);
        token.custodyBurn(bob, 10 ether);
        vm.stopPrank();
        assertEq(token.totalSupply(), INITIAL_MINT - 10 ether);
    }

    /// @dev The self-exit variant: the predecessor renounces rather than being
    ///      revoked. Same end state, different entrypoint — and the one an
    ///      operator is most likely to use, since it needs no cooperation from the
    ///      successor. Compare `test_RevokingLastAdmin_ReachesSameDeadStateAsRenounce`
    ///      for the version with no successor in place.
    function test_AdminHandover_ViaRenounce_IsEquivalent() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        vm.prank(admin);
        token.renounceRole(DEFAULT_ADMIN_ROLE, admin);

        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, newAdmin));

        vm.prank(newAdmin);
        token.setLink(alice, bob, true);
        assertTrue(_isLinked(alice, bob), "renouncing with a successor in place is not a freeze");

        vm.prank(admin);
        _expectNotAdmin(admin);
        token.setLink(alice, carol, true);
    }

    /// @dev The footgun guard on the renounce path. `renounceRole` takes a
    ///      confirmation argument precisely so an operator cannot renounce on
    ///      someone else's behalf by passing the wrong address — the exact slip
    ///      available mid-rotation, when both addresses are in hand.
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

    /// @dev Rotation is not a one-shot. Nothing about the first handover consumes
    ///      a resource the second one needs, so the key can keep moving for the
    ///      life of the contract.
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
            token.setDestinationAllowed(alice, bob, i % 2 == 0);
            assertEq(token.allowedDestination(alice, bob), i % 2 == 0, "each successor holds full write access");
        }

        vm.prank(current);
        token.adminTransfer(alice, carol, 1 ether);
        assertEq(token.balanceOf(carol), 1 ether, "the final admin in the chain is fully operational");
    }
}
