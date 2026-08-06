// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice Destruction of supply is PRIVILEGED, and the privilege is NOT split:
///         all four burn entrypoints — `adminBurn`, `guardBurn` and the
///         inherited `burn` / `burnFrom` — are MINTER_ROLE. That is what this
///         suite owns. `AdminBurn.t.sol` and `GuardBurn.t.sol` own the mechanics
///         of the two Strands-specific paths; here the subject is who may reach
///         any of them.
///
///         What holds for every holder is that they can do nothing. They have
///         exactly one capability — moving their balance. They cannot destroy
///         it, and they cannot delegate that power to anyone else via an ERC20
///         allowance.
///
/// @dev    A balance here is a claim against an off-chain ledger. A holder who
///         can burn unilaterally desyncs that ledger, which is the whole reason
///         `adminBurn` exists — and the reason the `burn` / `burnFrom` that
///         OZ's `ERC20Burnable` hands every holder had to be gated rather than
///         left silently reachable.
///
///         One operating role means `revokeRole(MINTER_ROLE, ...)` is the single
///         lever that stops minting AND burning; there is no burn-only revoke.
///         `Roles.t.sol:test_RevokedMinter_LosesEveryBurnAndMintPathImmediately`
///         is where that is asserted rather than left to be discovered.
///
///         The positive controls at the bottom are what keeps the negative
///         cases honest: they pin that burning still works, so the gating
///         cannot be satisfied by breaking it outright.
contract BurnAuthorityTest is BaseTest {
    function test_Holder_CannotBurnOwnBalance() public {
        vm.prank(alice);
        _expectNotMinter(alice);
        token.burn(100 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT, "holder balance must be untouched");
        assertEq(token.totalSupply(), INITIAL_MINT, "supply must not move without the minter");
    }

    /// @dev An allowance must not launder the burn. Ungated, `approve` +
    ///      `burnFrom` destroys a holder's balance with no privileged party
    ///      involved, so any address a user approves could wipe them out.
    function test_Holder_CannotBurnFromEvenWithAllowance() public {
        vm.prank(alice);
        token.approve(bob, 200 ether);

        vm.prank(bob);
        _expectNotMinter(bob);
        token.burnFrom(alice, 200 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT, "an allowance must not destroy value");
        assertEq(token.allowance(alice, bob), 200 ether, "rejected burn must not consume allowance");
        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev The counterpart with NO allowance at all. Previously asserted with a
    ///      bare `vm.expectRevert()`. That would keep passing once burning is
    ///      gated, but for the wrong reason — catching the role rejection while
    ///      claiming to prove an allowance is required. Pinning the exact error
    ///      keeps the two causes distinguishable.
    function test_BurnFrom_RejectsNonMinterRegardlessOfAllowance() public {
        vm.prank(bob);
        _expectNotMinter(bob);
        token.burnFrom(alice, 1);

        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev A transfer recipient is just another holder — receiving a balance
    ///      grants it no power to destroy one.
    function test_Recipient_CannotBurnOwnBalance() public {
        vm.prank(alice);
        token.transfer(bob, 300 ether);

        vm.prank(bob);
        _expectNotMinter(bob);
        token.burn(300 ether);

        assertEq(token.balanceOf(bob), 300 ether, "recipient balance must be untouched");
        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev The admin is the sharpest case, and the one property the single-role
    ///      collapse was chosen to preserve. DEFAULT_ADMIN_ROLE is the role admin
    ///      for MINTER_ROLE, so it CAN reach every burn path — but only by first
    ///      granting itself the role, and that grant is visible on-chain as
    ///      `RoleGranted`. Until it does, it is refused like any other holder.
    function test_Admin_ReachesBurningOnlyViaAVisibleSelfGrant() public {
        vm.prank(minter);
        token.mint(admin, 100 ether);

        // Before the grant: refused on all four paths.
        vm.startPrank(admin);
        _expectNotMinter(admin);
        token.burn(10 ether);
        _expectNotMinter(admin);
        token.burnFrom(alice, 10 ether);
        _expectNotMinter(admin);
        token.adminBurn(alice, 10 ether);
        _expectNotMinter(admin);
        token.guardBurn(alice, 10 ether, INITIAL_MINT + 100 ether);
        vm.stopPrank();

        assertEq(token.totalSupply(), INITIAL_MINT + 100 ether, "the admin holds no operating power of its own");

        // The grant announces itself, and only then does the burn land.
        vm.prank(admin);
        token.grantRole(MINTER_ROLE, admin);

        vm.prank(admin);
        token.burn(10 ether);

        assertEq(token.totalSupply(), INITIAL_MINT + 90 ether, "the escalation works, but never silently");
    }

    /// @dev The whole burn surface, from the one role that owns it. The
    ///      counterpart to `test_Admin_ReachesBurningOnlyViaAVisibleSelfGrant`:
    ///      together they say the minter reaches everything and the admin
    ///      reaches nothing without asking first.
    function test_Minter_ReachesEveryBurnPath() public {
        vm.prank(alice);
        token.approve(minter, 100 ether);
        vm.prank(minter);
        token.mint(minter, 100 ether);

        vm.startPrank(minter);
        token.burn(10 ether);
        token.burnFrom(alice, 10 ether);
        token.adminBurn(alice, 10 ether);
        token.guardBurn(alice, 10 ether, INITIAL_MINT + 70 ether);
        vm.stopPrank();

        assertEq(token.totalSupply(), INITIAL_MINT + 60 ether, "100 minted, 40 destroyed across four paths");
        assertEq(token.allowance(alice, minter), 90 ether, "only burnFrom spends allowance; the other three do not");
    }

    /// @dev Every rejected path must unwind completely — no partial burn, no
    ///      supply drift, no allowance spent.
    function test_BurnAttempts_LeaveSupplyAndBalancesUntouched() public {
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.approve(carol, type(uint256).max);

        vm.prank(alice);
        _expectNotMinter(alice);
        token.burn(1 ether);

        vm.prank(carol);
        _expectNotMinter(carol);
        token.burnFrom(alice, 1 ether);

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
        _expectNotMinter(alice);
        token.burn(value);

        assertEq(token.totalSupply(), INITIAL_MINT, "no amount is small enough to slip through");
    }

    // ---------- positive controls: burning must keep working ----------

    function test_Minter_CanBurn() public {
        vm.prank(minter);
        token.mint(minter, 100 ether);

        vm.prank(minter);
        token.burn(40 ether);

        assertEq(token.balanceOf(minter), 60 ether);
        assertEq(token.totalSupply(), INITIAL_MINT + 60 ether);
    }

    function test_Minter_CanBurnFromWithAllowance() public {
        vm.prank(alice);
        token.approve(minter, 200 ether);

        vm.prank(minter);
        token.burnFrom(alice, 200 ether);

        assertEq(token.balanceOf(alice), 800 ether);
        assertEq(token.allowance(alice, minter), 0, "burnFrom still spends the allowance");
        assertEq(token.totalSupply(), 800 ether);
    }

    // ---------- observability: one event covers all four paths ----------

    /// @dev Four burn entrypoints are only safe if a reconciler can see all of
    ///      them from ONE subscription. This is the invariant the contract asks
    ///      it to rely on — "every burn emits {Burned}" — and it is asserted
    ///      path by path rather than argued, because an entrypoint that forgot
    ///      the event would still pass every balance and supply assertion in
    ///      this file.
    function test_EveryBurnPath_EmitsBurned() public {
        vm.prank(minter);
        token.mint(minter, 100 ether);
        vm.prank(alice);
        token.approve(minter, 10 ether);

        _expectBurnedEvent(minter, minter, 40 ether);
        vm.prank(minter);
        token.burn(40 ether);

        _expectBurnedEvent(minter, alice, 10 ether);
        vm.prank(minter);
        token.burnFrom(alice, 10 ether);

        _expectBurnedEvent(minter, alice, 5 ether);
        vm.prank(minter);
        token.adminBurn(alice, 5 ether);

        _expectBurnedEvent(minter, alice, 5 ether);
        vm.prank(minter);
        token.guardBurn(alice, 5 ether, INITIAL_MINT + 45 ether);

        assertEq(token.totalSupply(), INITIAL_MINT + 40 ether, "100 minted, 60 destroyed across four paths");
    }
}
