// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsAllowlistBatch } from "../../src/StrandsAllowlistBatch.sol";

/// @notice The load-bearing suite for the batching design.
///
///         Batching is a MIXIN rather than a separately deployed helper for one
///         reason: OZ's `onlyRole` resolves to `_msgSender()`, i.e. `msg.sender`
///         and never `tx.origin`. A deployed helper would therefore be the
///         caller the token sees, and would need DEFAULT_ADMIN_ROLE granted to
///         it. Inherited, the batch entrypoints reach the role check by internal
///         jump, so `msg.sender` is still the admin signer.
///
///         Every assertion below exists to prove that holds — if `msg.sender`
///         were not preserved, these fail and the whole approach is wrong.
///
/// @dev    Authorization of the batch entrypoints is the subject here, so
///         `setPairs` is called directly throughout rather than through the
///         fixture's `_link` wrapper.
contract BatchAuthTest is BaseTest {
    function test_Admin_CanBatch() public {
        vm.prank(admin);
        token.setPairs(_edges(alice, bob, carol, minter), true);

        assertTrue(token.isLinked(alice, bob));
        assertTrue(token.isLinked(carol, minter));
    }

    /// @dev The core proof: an ordinary caller is rejected with exactly the error
    ///      the single setter produces, because the same `_checkRole` runs.
    function test_NonAdmin_CannotBatch() public {
        vm.prank(alice);
        _expectNotAdmin(alice);
        token.setPairs(_edges(alice, bob), true);

        assertFalse(token.allowedDestination(alice, bob));
    }

    /// @dev `_setIfChanged` skips edges already at the target value, so an
    ///      all-no-op batch would never reach the setter. Without the explicit
    ///      `_checkAllowlistAdmin()` at the top of each entrypoint, an
    ///      unauthorized caller would get a silent success here.
    function test_NonAdmin_IsRejectedEvenWhenBatchIsEntirelyNoOp() public {
        vm.prank(admin);
        token.setPairs(_edges(alice, bob), true); // already applied

        // Re-submitting the identical batch writes nothing at all...
        vm.prank(alice);
        _expectNotAdmin(alice);
        token.setPairs(_edges(alice, bob), true); // ...and must STILL revert
    }

    function test_NonAdminBatch_LeavesNoStateChangeAndNoEvents() public {
        vm.recordLogs();

        vm.prank(alice);
        _expectNotAdmin(alice);
        token.setPairs(_edges(alice, bob), true);

        _assertLogCount(0, "a rejected batch must emit nothing");
        assertFalse(token.allowedDestination(alice, bob));
        assertFalse(token.allowedDestination(bob, alice));
    }

    /// @dev Authorization is sourced from the token's role registry, not cached,
    ///      so a grant takes effect on the very next call.
    function test_NewlyGrantedAdmin_CanBatchImmediately() public {
        vm.prank(alice);
        _expectNotAdmin(alice);
        token.setPairs(_edges(alice, bob), true);

        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, alice);

        vm.prank(alice);
        token.setPairs(_edges(alice, bob), true);
        assertTrue(token.isLinked(alice, bob));
    }

    function test_RevokedAdmin_LosesBatchAccessImmediately() public {
        vm.startPrank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, carol); // keep a live admin so this is not a lockout
        token.setPairs(_edges(alice, bob), true);
        vm.stopPrank();

        vm.prank(carol);
        token.revokeRole(DEFAULT_ADMIN_ROLE, admin);

        vm.prank(admin);
        _expectNotAdmin(admin);
        token.setPairs(_edges(alice, carol), true);

        vm.prank(carol);
        token.setPairs(_edges(alice, carol), true); // the surviving admin still can
        assertTrue(token.isLinked(alice, carol));
    }

    /// @dev The gate check over an ARBITRARY caller, via a low-level call so the
    ///      revert data is compared byte-for-byte rather than through a
    ///      cheatcode. `caller` is fuzzed, so this asserts the gate for arbitrary
    ///      addresses rather than for the handful of named actors in the fixture.
    function testFuzz_ArbitraryNonAdmin_CannotBatch(address caller) public {
        vm.assume(!token.hasRole(DEFAULT_ADMIN_ROLE, caller));

        bytes memory expected = _missingRoleData(caller, DEFAULT_ADMIN_ROLE);

        vm.prank(caller);
        (bool ok, bytes memory ret) = address(token)
            .call(abi.encodeCall(StrandsAllowlistBatch.setPairs, (_edges(alice, bob, alice, carol), true)));

        assertFalse(ok, "an unprivileged caller reached a batch write");
        assertEq(ret, expected, "wrong revert for a batch write");

        // nothing leaked through
        assertFalse(token.allowedDestination(alice, bob));
        assertFalse(token.allowedDestination(bob, alice));
        assertFalse(token.allowedDestination(alice, carol));
        assertFalse(token.allowedDestination(carol, alice));
    }

    /// @dev The read side is deliberately open — preflight must work for anyone,
    ///      otherwise integrations are pushed back to probing with transfers.
    function testFuzz_ArbitraryCaller_CanAlwaysReadViews(address caller) public {
        _link(alice, bob);

        vm.prank(caller);
        assertTrue(token.isLinked(alice, bob));

        vm.prank(caller);
        bool[] memory out = token.areAllowed(_edges(alice, bob));
        assertTrue(out[0]);
    }

    /// @dev Holding some other role is not a shortcut into the batch surface.
    function test_MinterAndCustodian_CannotBatch() public {
        vm.prank(minter);
        _expectNotAdmin(minter);
        token.setPairs(_edges(alice, bob), true);

        vm.prank(custodian);
        _expectNotAdmin(custodian);
        token.setPairs(_edges(alice, carol), true);

        assertFalse(token.allowedDestination(alice, bob));
        assertFalse(token.allowedDestination(alice, carol));
    }

    /// @dev Batch and single-setter paths must be indistinguishable to a caller
    ///      deciding how to handle a failure.
    function test_BatchRevert_MatchesSingleSetterRevertExactly() public {
        bytes memory expected = _missingRoleData(bob, DEFAULT_ADMIN_ROLE);

        vm.prank(bob);
        (bool okSingle, bytes memory single) =
            address(token).call(abi.encodeCall(token.setDestinationAllowed, (alice, bob, true)));

        vm.prank(bob);
        (bool okBatch, bytes memory batch) =
            address(token).call(abi.encodeCall(StrandsAllowlistBatch.setPairs, (_edges(alice, bob), true)));

        assertFalse(okSingle);
        assertFalse(okBatch);
        assertEq(single, expected, "single setter revert");
        assertEq(batch, expected, "batch revert must be byte-identical");
    }
}
