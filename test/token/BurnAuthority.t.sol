// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice Destruction of supply is CUSTODIAN_ROLE-only. A holder has exactly
///         one capability — moving their balance. They cannot destroy it, and
///         they cannot delegate that power to anyone else via an ERC20
///         allowance. Both inherited `ERC20Burnable` entrypoints are gated
///         alongside `custodyBurn`, so every redemption goes through the
///         custodian and stays in step with the off-chain ledger.
///
/// @dev    A balance here is a claim against an off-chain ledger. A holder who
///         can burn unilaterally desyncs that ledger, which is the whole reason
///         `custodyBurn` exists — and the reason the `burn` / `burnFrom` that
///         OZ's `ERC20Burnable` hands every holder had to be gated rather than
///         left silently reachable.
///
///         The two positive controls at the bottom are what keeps the negative
///         cases honest: they pin that custody still works, so the gating
///         cannot be satisfied by breaking burning outright.
contract BurnAuthorityTest is BaseTest {
    function test_Holder_CannotBurnOwnBalance() public {
        vm.prank(alice);
        _expectNotCustodian(alice);
        token.burn(100 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT, "holder balance must be untouched");
        assertEq(token.totalSupply(), INITIAL_MINT, "supply must not move without the custodian");
    }

    /// @dev An allowance must not launder the burn. Ungated, `approve` +
    ///      `burnFrom` destroys a holder's balance with no custodian
    ///      involvement, so any address a user approves could wipe them out.
    function test_Holder_CannotBurnFromEvenWithAllowance() public {
        vm.prank(alice);
        token.approve(bob, 200 ether);

        vm.prank(bob);
        _expectNotCustodian(bob);
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
    function test_BurnFrom_RejectsNonCustodianRegardlessOfAllowance() public {
        vm.prank(bob);
        _expectNotCustodian(bob);
        token.burnFrom(alice, 1);

        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev A transfer recipient is just another holder — receiving a balance
    ///      grants it no power to destroy one.
    function test_Recipient_CannotBurnOwnBalance() public {
        vm.prank(alice);
        token.transfer(bob, 300 ether);

        vm.prank(bob);
        _expectNotCustodian(bob);
        token.burn(300 ether);

        assertEq(token.balanceOf(bob), 300 ether, "recipient balance must be untouched");
        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev Holding some other role is not a shortcut into the burn surface.
    ///      The admin is the sharpest case: it is the role admin for
    ///      CUSTODIAN_ROLE, but until it grants itself that role it cannot
    ///      destroy a balance — and the grant is visible on-chain as
    ///      `RoleGranted`.
    function test_MinterAndAdmin_CannotBurn() public {
        // fund both, so a failure cannot be explained by an empty balance
        vm.startPrank(minter);
        token.mint(minter, 100 ether);
        token.mint(admin, 100 ether);
        vm.stopPrank();

        vm.prank(minter);
        _expectNotCustodian(minter);
        token.burn(100 ether);

        vm.prank(admin);
        _expectNotCustodian(admin);
        token.burn(100 ether);

        assertEq(token.balanceOf(minter), 100 ether, "minter must not be exempt");
        assertEq(token.balanceOf(admin), 100 ether, "admin must not be exempt");
        assertEq(
            token.totalSupply(), INITIAL_MINT + 200 ether, "no privileged role but the custodian may destroy supply"
        );
    }

    /// @dev Every rejected path must unwind completely — no partial burn, no
    ///      supply drift, no allowance spent.
    function test_BurnAttempts_LeaveSupplyAndBalancesUntouched() public {
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.approve(carol, type(uint256).max);

        vm.prank(alice);
        _expectNotCustodian(alice);
        token.burn(1 ether);

        vm.prank(carol);
        _expectNotCustodian(carol);
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
        _expectNotCustodian(alice);
        token.burn(value);

        assertEq(token.totalSupply(), INITIAL_MINT, "no amount is small enough to slip through");
    }

    // ---------- positive controls: custody must keep working ----------

    function test_Custodian_CanBurn() public {
        vm.prank(minter);
        token.mint(custodian, 100 ether);

        vm.prank(custodian);
        token.burn(40 ether);

        assertEq(token.balanceOf(custodian), 60 ether);
        assertEq(token.totalSupply(), INITIAL_MINT + 60 ether);
    }

    function test_Custodian_CanBurnFromWithAllowance() public {
        vm.prank(alice);
        token.approve(custodian, 200 ether);

        vm.prank(custodian);
        token.burnFrom(alice, 200 ether);

        assertEq(token.balanceOf(alice), 800 ether);
        assertEq(token.allowance(alice, custodian), 0, "burnFrom still spends the allowance");
        assertEq(token.totalSupply(), 800 ether);
    }

    // ---------- observability: one event covers all three paths ----------

    /// @dev Three custodial burn entrypoints are only safe if a reconciler can
    ///      see all of them. Were `CustodyBurn` still exclusive to `custodyBurn`,
    ///      supply destroyed through the inherited paths would be invisible to
    ///      anything subscribed to it.
    function test_EveryBurnPath_EmitsCustodyBurn() public {
        vm.prank(minter);
        token.mint(custodian, 100 ether);
        vm.prank(alice);
        token.approve(custodian, 10 ether);

        _expectCustodyBurnEvent(custodian, custodian, 40 ether);
        vm.prank(custodian);
        token.burn(40 ether);

        _expectCustodyBurnEvent(custodian, alice, 10 ether);
        vm.prank(custodian);
        token.burnFrom(alice, 10 ether);

        _expectCustodyBurnEvent(custodian, alice, 5 ether);
        vm.prank(custodian);
        token.custodyBurn(alice, 5 ether);

        assertEq(token.totalSupply(), INITIAL_MINT + 45 ether, "100 minted, 55 destroyed across three paths");
    }
}
