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
contract BatchAuthTest is BaseTest {
    function test_Admin_CanCallEveryBatchEntrypoint() public {
        vm.startPrank(admin);
        token.setDestinations(_edges(alice, bob), true);
        token.setDestinationsMixed(_edges(alice, carol, bob, carol), _bools(true, true));
        token.setPairs(_edges(alice, minter), true);
        token.linkSubaccounts(_edges(alice, custodian), true, true);
        token.setDestinationsForHolder(alice, _addrs(bob, carol), true);
        token.setHoldersForDestination(_addrs(bob, carol), alice, true);
        vm.stopPrank();

        assertTrue(token.allowedDestination(alice, bob));
        assertTrue(token.allowedDestination(alice, minter));
        assertTrue(token.allowedDestination(alice, custodian));
        assertTrue(token.allowedDestination(bob, alice));
    }

    /// @dev The core proof: an ordinary caller is rejected with exactly the error
    ///      the single setter produces, because the same `_checkRole` runs.
    function test_NonAdmin_CannotCallAnyBatchEntrypoint() public {
        vm.startPrank(alice);

        _expectNotAdmin(alice);
        token.setDestinations(_edges(alice, bob), true);

        _expectNotAdmin(alice);
        token.setDestinationsMixed(_edges(alice, bob, alice, carol), _bools(true, true));

        _expectNotAdmin(alice);
        token.setPairs(_edges(alice, bob), true);

        _expectNotAdmin(alice);
        token.linkSubaccounts(_edges(alice, bob), true, true);

        _expectNotAdmin(alice);
        token.setDestinationsForHolder(alice, _addrs(bob), true);

        _expectNotAdmin(alice);
        token.setHoldersForDestination(_addrs(alice), bob, true);

        vm.stopPrank();
    }

    /// @dev `_setIfChanged` skips edges already at the target value, so an
    ///      all-no-op batch would never reach the setter. Without the explicit
    ///      `_checkAllowlistAdmin()` at the top of each entrypoint, an
    ///      unauthorized caller would get a silent success here.
    function test_NonAdmin_IsRejectedEvenWhenBatchIsEntirelyNoOp() public {
        vm.prank(admin);
        token.setDestinations(_edges(alice, bob), true); // already applied

        // Re-submitting the identical batch writes nothing at all...
        vm.prank(alice);
        _expectNotAdmin(alice);
        token.setDestinations(_edges(alice, bob), true); // ...and must STILL revert
    }

    function test_NonAdminBatch_LeavesNoStateChangeAndNoEvents() public {
        vm.recordLogs();

        vm.prank(alice);
        _expectNotAdmin(alice);
        token.setPairs(_edges(alice, bob), true);

        assertEq(vm.getRecordedLogs().length, 0, "a rejected batch must emit nothing");
        assertFalse(token.allowedDestination(alice, bob));
        assertFalse(token.allowedDestination(bob, alice));
    }

    /// @dev Authorization is sourced from the token's role registry, not cached,
    ///      so a grant takes effect on the very next call.
    function test_NewlyGrantedAdmin_CanBatchImmediately() public {
        // hoisted: a `token.X_ROLE()` call on a pranked line would consume the
        // cheatcode before the call under test runs
        bytes32 role = token.DEFAULT_ADMIN_ROLE();

        vm.prank(alice);
        _expectNotAdmin(alice);
        token.setDestinations(_edges(alice, bob), true);

        vm.prank(admin);
        token.grantRole(role, alice);

        vm.prank(alice);
        token.setDestinations(_edges(alice, bob), true);
        assertTrue(token.allowedDestination(alice, bob));
    }

    function test_RevokedAdmin_LosesBatchAccessImmediately() public {
        bytes32 role = token.DEFAULT_ADMIN_ROLE();
        vm.startPrank(admin);
        token.grantRole(role, carol); // keep a live admin so this is not a lockout
        token.setDestinations(_edges(alice, bob), true);
        vm.stopPrank();

        vm.prank(carol);
        token.revokeRole(role, admin);

        vm.prank(admin);
        _expectNotAdmin(admin);
        token.setDestinations(_edges(alice, carol), true);

        vm.prank(carol);
        token.setDestinations(_edges(alice, carol), true); // the surviving admin still can
        assertTrue(token.allowedDestination(alice, carol));
    }

    /// @dev Batch and single-setter paths must be indistinguishable to a caller
    ///      deciding how to handle a failure.
    function test_BatchRevert_MatchesSingleSetterRevertExactly() public {
        bytes memory expected = abi.encodeWithSelector(
            bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")), bob, bytes32(0)
        );

        vm.prank(bob);
        (bool okSingle, bytes memory single) =
            address(token).call(abi.encodeCall(token.setDestinationAllowed, (alice, bob, true)));

        vm.prank(bob);
        (bool okBatch, bytes memory batch) =
            address(token).call(abi.encodeCall(StrandsAllowlistBatch.setDestinations, (_edges(alice, bob), true)));

        assertFalse(okSingle);
        assertFalse(okBatch);
        assertEq(single, expected, "single setter revert");
        assertEq(batch, expected, "batch revert must be byte-identical");
    }
}
