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
}
