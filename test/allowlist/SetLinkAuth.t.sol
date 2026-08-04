// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsCustodyToken } from "../../src/StrandsCustodyToken.sol";

/// @notice Authorization of `setLink`.
///
///         `setLink` writes two edges at once, so it is exactly as privileged
///         as two `setDestinationAllowed` calls and must be gated identically —
///         same role, same revert, no shortcut via any other role. These pin
///         that the convenience of the pair setter buys no extra reach.
///
/// @dev    Authorization is the subject here, so `setLink` is called directly
///         throughout rather than through the fixture's `_link` wrapper.
contract SetLinkAuthTest is BaseTest {
    function test_Admin_CanSetLink() public {
        vm.startPrank(admin);
        token.setLink(alice, bob, true);
        token.setLink(carol, minter, true);
        vm.stopPrank();

        assertTrue(_isLinked(alice, bob));
        assertTrue(_isLinked(carol, minter));
    }

    /// @dev The core proof: an ordinary caller is rejected with exactly the error
    ///      the single setter produces, because the same role gate runs.
    function test_NonAdmin_CannotSetLink() public {
        vm.prank(alice);
        _expectNotAdmin(alice);
        token.setLink(alice, bob, true);

        assertFalse(token.allowedDestination(alice, bob));
    }

    function test_NonAdminSetLink_LeavesNoStateChangeAndNoEvents() public {
        vm.recordLogs();

        vm.prank(alice);
        _expectNotAdmin(alice);
        token.setLink(alice, bob, true);

        _assertLogCount(0, "a rejected link must emit nothing");
        assertFalse(token.allowedDestination(alice, bob));
        assertFalse(token.allowedDestination(bob, alice));
    }

    /// @dev Authorization is sourced from the token's role registry, not cached,
    ///      so a grant takes effect on the very next call.
    function test_NewlyGrantedAdmin_CanSetLinkImmediately() public {
        vm.prank(alice);
        _expectNotAdmin(alice);
        token.setLink(alice, bob, true);

        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, alice);

        vm.prank(alice);
        token.setLink(alice, bob, true);
        assertTrue(_isLinked(alice, bob));
    }

    function test_RevokedAdmin_LosesSetLinkAccessImmediately() public {
        vm.startPrank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, carol); // keep a live admin so this is not a lockout
        token.setLink(alice, bob, true);
        vm.stopPrank();

        vm.prank(carol);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin);

        vm.prank(admin);
        _expectNotAdmin(admin);
        token.setLink(alice, carol, true);

        vm.prank(carol);
        token.setLink(alice, carol, true); // the surviving admin still can
        assertTrue(_isLinked(alice, carol));
    }

    /// @dev The gate check over an ARBITRARY caller, via a low-level call so the
    ///      revert data is compared byte-for-byte rather than through a
    ///      cheatcode. `caller` is fuzzed, so this asserts the gate for arbitrary
    ///      addresses rather than for the handful of named actors in the fixture.
    function testFuzz_ArbitraryNonAdmin_CannotSetLink(address caller) public {
        vm.assume(!token.hasRole(DEFAULT_ADMIN_ROLE, caller));

        bytes memory expected = _missingRoleData(caller, DEFAULT_ADMIN_ROLE);

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(token.setLink, (alice, bob, true)));

        assertFalse(ok, "an unprivileged caller reached a link write");
        assertEq(ret, expected, "wrong revert for a link write");

        // nothing leaked through
        assertFalse(token.allowedDestination(alice, bob));
        assertFalse(token.allowedDestination(bob, alice));
    }

    /// @dev The read side is deliberately open — preflight must work for anyone,
    ///      otherwise integrations are pushed back to probing with transfers.
    function testFuzz_ArbitraryCaller_CanAlwaysReadTheAllowlist(address caller) public {
        _link(alice, bob);

        vm.prank(caller);
        assertTrue(token.allowedDestination(alice, bob));

        vm.prank(caller);
        assertTrue(token.allowedDestination(bob, alice));
    }

    /// @dev Holding some other role is not a shortcut into the allowlist.
    function test_MinterAndCustodian_CannotSetLink() public {
        vm.prank(minter);
        _expectNotAdmin(minter);
        token.setLink(alice, bob, true);

        vm.prank(custodian);
        _expectNotAdmin(custodian);
        token.setLink(alice, carol, true);

        assertFalse(token.allowedDestination(alice, bob));
        assertFalse(token.allowedDestination(alice, carol));
    }

    /// @dev The two setters must be indistinguishable to a caller deciding how
    ///      to handle a failure.
    function test_SetLinkRevert_MatchesSingleSetterRevertExactly() public {
        bytes memory expected = _missingRoleData(bob, DEFAULT_ADMIN_ROLE);

        vm.prank(bob);
        (bool okSingle, bytes memory single) =
            address(token).call(abi.encodeCall(token.setDestinationAllowed, (alice, bob, true)));

        vm.prank(bob);
        (bool okLink, bytes memory link) =
            address(token).call(abi.encodeCall(StrandsCustodyToken.setLink, (alice, bob, true)));

        assertFalse(okSingle);
        assertFalse(okLink);
        assertEq(single, expected, "single setter revert");
        assertEq(link, expected, "setLink revert must be byte-identical");
    }

    /// @dev The role gate runs BEFORE the self-link guard, so an unprivileged
    ///      caller cannot distinguish a rejected self-link from any other.
    function test_RoleCheckedBeforeSelfLinkGuard() public {
        vm.prank(alice);
        _expectNotAdmin(alice);
        token.setLink(alice, alice, true);
    }
}
