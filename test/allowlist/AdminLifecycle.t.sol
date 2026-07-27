// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { BaseTest } from "../Base.t.sol";
import { StrandsCustodyToken } from "../../src/StrandsCustodyToken.sol";

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
        bytes32 role = token.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        token.grantRole(role, carol); // keep a live admin so the revoke is not a lockout
        vm.prank(carol);
        token.revokeRole(role, admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        token.setDestinationAllowed(alice, bob, true);

        vm.prank(carol);
        token.setDestinationAllowed(alice, bob, true); // the new admin still can
        assertTrue(token.allowedDestination(alice, bob));
    }

    /// @dev Pins the README warning: renouncing the last admin freezes the
    ///      allowlist, so unapproved balances become permanently non-transferable
    ///      while burn paths keep working.
    function test_RenouncedAdmin_FreezesAllowlistButBurnsStillWork() public {
        bytes32 role = token.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        token.renounceRole(role, admin);
        assertFalse(token.hasRole(role, admin));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        token.setDestinationAllowed(alice, bob, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, bob));
        token.transfer(bob, 1 ether);

        vm.prank(alice);
        token.burn(1 ether);
        vm.prank(custodian);
        token.custodyBurn(alice, 1 ether);
        assertEq(token.balanceOf(alice), 998 ether, "burn paths must survive a frozen allowlist");
    }

    /// @dev The freeze is a SNAPSHOT, not a shutdown: entries written before the
    ///      last admin disappeared keep working forever. Only the ability to add
    ///      or remove entries is lost.
    function test_RenouncedAdmin_PreExistingApprovalsKeepWorking() public {
        vm.startPrank(admin);
        token.setDestinationAllowed(alice, bob, true);
        token.renounceRole(token.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();

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
        bytes32 role = token.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        token.renounceRole(role, admin);

        address[5] memory parties = [admin, alice, minter, custodian, address(this)];
        for (uint256 i = 0; i < parties.length; i++) {
            vm.prank(parties[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, parties[i], role)
            );
            token.grantRole(role, carol);
        }
        assertFalse(token.hasRole(role, carol), "no party may bootstrap a new admin");
    }

    /// @dev `revokeRole` reaches the identical dead state as `renounceRole`, but
    ///      without the `callerConfirmation` footgun-guard, and one admin can do
    ///      it to another.
    function test_RevokingLastAdmin_ReachesSameDeadStateAsRenounce() public {
        bytes32 role = token.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        token.revokeRole(role, admin); // self-revoke: no confirmation argument required
        assertFalse(token.hasRole(role, admin));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        token.setDestinationAllowed(alice, bob, true);
    }

    /// @dev The whole role graph freezes, not just the allowlist: no new minters
    ///      or custodians can ever be appointed. Incumbents keep their powers, so
    ///      supply can still change while those keys live.
    function test_RenouncedAdmin_FreezesEntireRoleGraph() public {
        // hoisted: a `token.X_ROLE()` call inside a pranked/expectRevert line would
        // consume the cheatcode before the call under test runs
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        bytes32 minterRole = token.MINTER_ROLE();
        bytes32 custodianRole = token.CUSTODIAN_ROLE();

        vm.prank(admin);
        token.renounceRole(adminRole, admin);

        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, adminRole)
        );
        token.grantRole(minterRole, carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, adminRole)
        );
        token.grantRole(custodianRole, carol);
        vm.stopPrank();

        // incumbents are unaffected
        vm.prank(minter);
        token.mint(carol, 10 ether);
        vm.prank(custodian);
        token.custodyBurn(carol, 10 ether);

        // ...but if the incumbent custodian is also lost, that power is gone for good
        vm.prank(custodian);
        token.renounceRole(custodianRole, custodian);
        vm.prank(custodian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, custodian, custodianRole)
        );
        token.custodyBurn(alice, 1 ether);
    }

    /// @dev The economic exit survives: burn is self-service and allowlist-exempt,
    ///      so a holder can always redeem against the off-chain ledger even when
    ///      every transfer route is frozen. Tokens are immobile, not unredeemable.
    function test_RenouncedAdmin_HolderCanStillSelfRedeemEntireBalance() public {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        token.renounceRole(adminRole, admin);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, bob));
        token.transfer(bob, 1 ether);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, address(0), 1_000 ether);
        vm.prank(alice);
        token.burn(1_000 ether); // full exit, no admin involvement

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }
}
