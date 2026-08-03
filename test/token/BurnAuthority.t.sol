// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice Destruction of supply is CUSTODIAN_ROLE-only. A holder — including a
///         smart contract wallet and every subaccount linked to it — has exactly
///         one capability: transferring along the routes the admin opened for
///         them. They cannot destroy their own balance, and they cannot delegate
///         that power to anyone else via an ERC20 allowance. Both inherited
///         `ERC20Burnable` entrypoints are gated alongside `custodyBurn`, so
///         every redemption goes through the custodian and stays in step with
///         the off-chain ledger.
///
/// @dev    A balance here is a claim against an off-chain ledger. A holder who
///         can burn unilaterally desyncs that ledger, which is the whole reason
///         `custodyBurn` exists. Inheriting OZ's `ERC20Burnable` currently hands
///         every holder a `burn` / `burnFrom` that bypasses both the allowlist
///         (`_update` exempts `to == address(0)`) and the custodian.
///
///         The tests below therefore encode INTENDED behaviour, not current
///         behaviour: the negative cases fail until `burn` and `burnFrom` are
///         gated on CUSTODIAN_ROLE. The two positive controls at the bottom pass
///         both before and after that change, so the fix cannot be achieved by
///         breaking custody instead.
contract BurnAuthorityTest is BaseTest {
    function test_Holder_CannotBurnOwnBalance() public {
        vm.prank(alice);
        _expectNotCustodian(alice);
        token.burn(100 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT, "holder balance must be untouched");
        assertEq(token.totalSupply(), INITIAL_MINT, "supply must not move without the custodian");
    }

    /// @dev An allowance must not launder the burn: today `approve` + `burnFrom`
    ///      destroys a holder's balance with no allowlist check and no custodian
    ///      involvement, so any address a user approves can wipe them out.
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

    /// @dev A linked subaccount is just another holder — being reachable from the
    ///      main wallet grants it no additional power.
    function test_Subaccount_CannotBurnOwnBalance() public {
        _link(alice, bob);
        vm.prank(alice);
        token.transfer(bob, 300 ether);

        vm.prank(bob);
        _expectNotCustodian(bob);
        token.burn(300 ether);

        assertEq(token.balanceOf(bob), 300 ether, "subaccount balance must be untouched");
        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev Holding some other role is not a shortcut into the burn surface,
    ///      mirroring `test/batch/Auth.t.sol::test_MinterAndCustodian_CannotBatch`.
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
