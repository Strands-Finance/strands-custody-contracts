// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice Destruction of supply is PRIVILEGED, and the privilege is NOT split:
///         both burn entrypoints — `adminRetract` and `guardRetract` — are
///         OPERATOR_ROLE. That is what this suite owns. `AdminRetract.t.sol` and
///         `GuardRetract.t.sol` own the mechanics of the two paths; here the
///         subject is who may reach either of them.
///
///         What holds for every holder is that they can do nothing. They have
///         exactly one capability — moving their balance. They cannot destroy
///         it, and they cannot delegate that power to anyone else via an ERC20
///         allowance: no burn path reads an allowance at all.
///
/// @dev    A balance here is a claim against an off-chain ledger. A holder who
///         can burn unilaterally desyncs that ledger. The contract no longer
///         inherits `ERC20Burnable`, so there is no holder-reachable `burn` /
///         `burnFrom` to gate — the only burn paths are the two written here,
///         and both are role-checked. `ExternalUserSurface.t.sol` pins that the
///         inherited surface stays gone.
///
///         One operating role means `revokeRole(OPERATOR_ROLE, ...)` is the single
///         lever that stops minting AND burning; there is no burn-only revoke.
///         `Roles.t.sol:test_RevokedOperator_LosesEveryBurnAndMintPathImmediately`
///         is where that is asserted rather than left to be discovered.
///
///         The positive controls at the bottom are what keeps the negative
///         cases honest: they pin that burning still works, so the gating
///         cannot be satisfied by breaking it outright.
contract RetractAuthorityTest is BaseTest {
    function test_Holder_CannotBurnOwnBalance() public {
        vm.prank(alice);
        _expectNotOperator(alice);
        token.adminRetract(alice, 100 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT, "holder balance must be untouched");
        assertEq(token.totalSupply(), INITIAL_MINT, "supply must not move without the operator");
    }

    /// @dev An allowance must not launder the burn: no burn path consults an
    ///      allowance, so an approved spender is refused exactly like a
    ///      stranger — and the allowance survives the rejection intact.
    function test_ApprovedSpender_CannotBurn() public {
        vm.prank(alice);
        token.approve(bob, 200 ether);

        vm.prank(bob);
        _expectNotOperator(bob);
        token.adminRetract(alice, 200 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT, "an allowance must not destroy value");
        assertEq(token.allowance(alice, bob), 200 ether, "rejected burn must not consume allowance");
        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev A transfer recipient is just another holder — receiving a balance
    ///      grants it no power to destroy one. Being an ALLOWED destination
    ///      grants it none either: the allowlist says where value may land, and
    ///      nothing about what the recipient may then do with it.
    function test_Recipient_CannotBurnOwnBalance() public {
        _allow(bob);

        vm.prank(alice);
        token.transfer(bob, 300 ether);

        vm.prank(bob);
        _expectNotOperator(bob);
        token.adminRetract(bob, 300 ether);

        assertEq(token.balanceOf(bob), 300 ether, "recipient balance must be untouched");
        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev The admin is the sharpest case, and the one property the single-role
    ///      collapse was chosen to preserve. DEFAULT_ADMIN_ROLE is the role admin
    ///      for OPERATOR_ROLE, so it CAN reach every burn path — but only by first
    ///      granting itself the role, and that grant is visible on-chain as
    ///      `RoleGranted`. Until it does, it is refused like any other holder.
    function test_Admin_ReachesBurningOnlyViaAVisibleSelfGrant() public {
        vm.prank(operator);
        token.encode(admin, 100 ether);

        // Before the grant: refused on both paths.
        vm.startPrank(admin);
        _expectNotOperator(admin);
        token.adminRetract(alice, 10 ether);
        _expectNotOperator(admin);
        token.guardRetract(alice, 10 ether, INITIAL_MINT + 100 ether);
        vm.stopPrank();

        assertEq(token.totalSupply(), INITIAL_MINT + 100 ether, "the admin holds no operating power of its own");

        // The grant announces itself, and only then does the burn land.
        vm.prank(admin);
        token.grantRole(OPERATOR_ROLE, admin);

        vm.prank(admin);
        token.adminRetract(admin, 10 ether);

        assertEq(token.totalSupply(), INITIAL_MINT + 90 ether, "the escalation works, but never silently");
    }

    /// @dev The whole burn surface, from the one role that owns it. The
    ///      counterpart to `test_Admin_ReachesBurningOnlyViaAVisibleSelfGrant`:
    ///      together they say the operator reaches everything and the admin
    ///      reaches nothing without asking first.
    function test_Operator_ReachesEveryBurnPath() public {
        vm.prank(alice);
        token.approve(operator, 100 ether);
        vm.prank(operator);
        token.encode(operator, 100 ether);

        vm.startPrank(operator);
        token.adminRetract(operator, 10 ether);
        token.adminRetract(alice, 10 ether);
        token.guardRetract(alice, 10 ether, INITIAL_MINT + 80 ether);
        vm.stopPrank();

        assertEq(token.totalSupply(), INITIAL_MINT + 70 ether, "100 minted, 30 destroyed across both paths");
        assertEq(token.allowance(alice, operator), 100 ether, "no burn path spends an allowance");
    }

    /// @dev Every rejected path must unwind completely — no partial burn, no
    ///      supply drift, no allowance spent.
    function test_BurnAttempts_LeaveSupplyAndBalancesUntouched() public {
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.approve(carol, type(uint256).max);

        vm.prank(alice);
        _expectNotOperator(alice);
        token.adminRetract(alice, 1 ether);

        vm.prank(carol);
        _expectNotOperator(carol);
        token.adminRetract(alice, 1 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT);
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.allowance(alice, carol), type(uint256).max, "allowance must survive intact");
        assertEq(token.totalSupply(), supplyBefore, "supply must be exactly what it was");
    }

    /// @dev Bounded to a balance the holder actually has, so "insufficient
    ///      balance" is never an available explanation for the rejection.
    function testFuzz_Holder_CannotBurnAnyAmount(uint96 amount) public {
        uint256 value = bound(uint256(amount), 1, token.balanceOf(alice));

        vm.prank(alice);
        _expectNotOperator(alice);
        token.adminRetract(alice, value);

        assertEq(token.totalSupply(), INITIAL_MINT, "no amount is small enough to slip through");
    }

    // ---------- positive controls: burning must keep working ----------

    function test_Operator_CanBurnOwnBalance() public {
        vm.prank(operator);
        token.encode(operator, 100 ether);

        vm.prank(operator);
        token.adminRetract(operator, 40 ether);

        assertEq(token.balanceOf(operator), 60 ether);
        assertEq(token.totalSupply(), INITIAL_MINT + 60 ether);
    }

    function test_Operator_CanBurnWithoutAllowance() public {
        vm.prank(operator);
        token.adminRetract(alice, 200 ether);

        assertEq(token.balanceOf(alice), 800 ether);
        assertEq(token.totalSupply(), 800 ether);
    }

    // ---------- observability: one event covers both paths ----------

    /// @dev Two burn entrypoints are only safe if a reconciler can see both of
    ///      them from ONE subscription. This is the invariant the contract asks
    ///      it to rely on — "every burn emits {Retracted}" — and it is asserted
    ///      path by path rather than argued, because an entrypoint that forgot
    ///      the event would still pass every balance and supply assertion in
    ///      this file.
    function test_EveryBurnPath_EmitsRetracted() public {
        vm.prank(operator);
        token.encode(operator, 100 ether);

        _expectBurnedEvent(operator, operator, 40 ether);
        vm.prank(operator);
        token.adminRetract(operator, 40 ether);

        _expectBurnedEvent(operator, alice, 5 ether);
        vm.prank(operator);
        token.guardRetract(alice, 5 ether, INITIAL_MINT + 60 ether);

        assertEq(token.totalSupply(), INITIAL_MINT + 55 ether, "100 minted, 45 destroyed across both paths");
    }
}
