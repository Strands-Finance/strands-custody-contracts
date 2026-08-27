// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ITransferAllowlist } from "../../src/interfaces/ITransferAllowlist.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice The destination allowlist: `transfer` and `transferFrom` are
///         default-deny, and only DEFAULT_ADMIN_ROLE may open a destination.
///
/// @dev    The core surface only. Revert precedence against OZ's own checks,
///         `address(0)` handling, zero-value and self-transfers, and fuzz
///         breadth are deliberately NOT here — they are a follow-up. What this
///         file has to catch is a guard that is absent, inverted, one-sided, or
///         ungated.
///
///         Nothing here covers the mint / burn exemption, because the suites
///         that already own those paths cover it for free: `Encode.t.sol`,
///         `AdminRetract.t.sol`, `GuardRetract.t.sol`, `RetractAuthority.t.sol` and the
///         whole `guardEncode` tree run against the untouched fixture, whose
///         allowlist is empty. A guard that leaked into issuance or redemption
///         turns all of them red.
contract AllowlistTest is BaseTest {
    // ---------- transfer ----------

    /// @dev The headline denial. `bob` has no entry — the fixture opens
    ///      nothing. A guard mutated into a no-op fails here first.
    function test_Transfer_ToAnUnallowedDestination_Reverts() public {
        assertFalse(token.allowedDestination(bob), "precondition: the fixture opens nothing");

        vm.prank(alice);
        _expectDestinationNotAllowed(bob);
        token.transfer(bob, 100 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT, "a refused transfer moves nothing");
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev The other half, and the one that keeps the denial honest: a guard
    ///      that refused EVERYTHING would pass the test above while bricking the
    ///      token. One entry is the whole difference between the two.
    function test_Transfer_ToAnAllowedDestination_Succeeds() public {
        _allow(bob);

        _expectTransferEvent(alice, bob, 100 ether);
        vm.prank(alice);
        token.transfer(bob, 100 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT - 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.totalSupply(), INITIAL_MINT, "a transfer must never change supply");
    }

    /// @dev The list is a live read, not a one-time grant: closing a destination
    ///      takes effect on the next call, and an entry is not consumed by the
    ///      transfer that used it.
    function test_Transfer_RevertsAfterTheDestinationIsClosed() public {
        _allow(bob);
        vm.prank(alice);
        token.transfer(bob, 1 ether);

        _disallow(bob);
        vm.prank(alice);
        _expectDestinationNotAllowed(bob);
        token.transfer(bob, 1 ether);

        assertEq(token.balanceOf(bob), 1 ether, "only the first transfer landed");
    }

    // ---------- transferFrom ----------

    /// @dev The load-bearing scoping claim, and the one place a destination list
    ///      and the removed per-holder list visibly disagree. NEITHER the owner
    ///      nor the spender is on the list; only `bob` is. Under the old
    ///      `[holder][destination]` mapping this needed an `alice -> bob` edge
    ///      and would revert.
    function test_TransferFrom_ChecksTheDestinationOnly() public {
        _allow(bob);
        assertFalse(token.allowedDestination(alice), "the OWNER is not on the list");
        assertFalse(token.allowedDestination(carol), "nor is the SPENDER");

        vm.prank(alice);
        token.approve(carol, 300 ether);

        _expectTransferEvent(alice, bob, 300 ether);
        vm.prank(carol);
        token.transferFrom(alice, bob, 300 ether);

        assertEq(token.balanceOf(bob), 300 ether);
        assertEq(token.allowance(alice, carol), 0, "the allowance is spent exactly as usual");
    }

    /// @dev The mirror, and the mutant it kills: a guard that read `msg.sender`
    ///      instead of `to` passes the test above and fails here. `carol` — the
    ///      spender — is the one on the list, and it authorises nothing.
    function test_TransferFrom_ToAnUnallowedDestination_Reverts() public {
        _allow(carol);

        vm.prank(alice);
        token.approve(carol, 300 ether);

        vm.prank(carol);
        _expectDestinationNotAllowed(bob);
        token.transferFrom(alice, bob, 300 ether);

        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, carol), 300 ether, "and the allowance is untouched");
    }

    // ---------- the setter ----------

    function test_Admin_CanAllowAndDisallowADestination() public {
        assertFalse(token.allowedDestination(bob), "default-deny");

        vm.expectEmit(true, false, false, true, address(token));
        emit ITransferAllowlist.DestinationAllowedSet(bob, true);
        vm.prank(admin);
        token.setDestinationAllowed(bob, true);
        assertTrue(token.allowedDestination(bob));

        vm.expectEmit(true, false, false, true, address(token));
        emit ITransferAllowlist.DestinationAllowedSet(bob, false);
        vm.prank(admin);
        token.setDestinationAllowed(bob, false);
        assertFalse(token.allowedDestination(bob));
    }

    /// @dev The gate. `operator` is in the list because the operating role must
    ///      not be a shortcut into the writer — the whole restriction is worth
    ///      nothing if holding it lets you open your own destination. It is the
    ///      one that matters most now that OPERATOR_ROLE is the token's ONLY hot
    ///      capability, and so the role an operator's live key actually holds.
    ///      `alice` is a funded holder and `carol` an address with no standing
    ///      at all, so the three between them span every non-admin caller.
    function test_NonAdmin_CannotSetDestinationAllowed() public {
        address[3] memory outsiders = [alice, operator, carol];

        for (uint256 i = 0; i < outsiders.length; i++) {
            vm.prank(outsiders[i]);
            _expectNotAdmin(outsiders[i]);
            token.setDestinationAllowed(bob, true);
        }

        assertFalse(token.allowedDestination(bob), "no rejected call wrote anything");
    }
}
