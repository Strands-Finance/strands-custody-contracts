// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice `adminTransfer` — the one path that moves value without an approved
///         destination and without the holder's consent.
///
///         It is the deliberate exception to everything `test/allowlist/`
///         otherwise pins. `transfer` / `transferFrom` stay gated for every
///         caller including the admin (see `Scoping.t.sol`); this is a separate
///         entrypoint, not a role exemption bolted onto the transfer path.
///
///         What it must NOT become is a way around the other two roles. The
///         floor is `ERC20._transfer`, never a raw `_update`, so the zero-address
///         and balance checks still apply and supply cannot change — MINTER_ROLE
///         and CUSTODIAN_ROLE keep their monopolies.
contract AdminTransferTest is BaseTest {
    function test_MovesValueOnAClosedRoute() public {
        assertFalse(token.allowedDestination(alice, bob), "precondition: no route");

        vm.prank(admin);
        token.adminTransfer(alice, bob, 100 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT - 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
    }

    /// @dev Moving value must not leave an approval behind — the route the admin
    ///      just used is still closed to the holder afterwards.
    function test_OpensNoEdge() public {
        vm.prank(admin);
        token.adminTransfer(alice, bob, 100 ether);

        assertFalse(token.allowedDestination(alice, bob), "no edge may be implicitly created");
        assertFalse(token.allowedDestination(bob, alice));

        vm.prank(alice);
        _expectNotAllowed(alice, bob);
        token.transfer(bob, 1 ether);
    }

    function test_NeedsNoAllowance() public {
        assertEq(token.allowance(alice, admin), 0, "precondition: no allowance");

        vm.prank(admin);
        token.adminTransfer(alice, bob, 100 ether);

        assertEq(token.allowance(alice, admin), 0, "and none is consumed");
    }

    /// @dev In this order: the balance moves inside `super._update`, which emits
    ///      the standard `Transfer`, and `AdminTransfer` is appended after. A
    ///      reconciler pairing the two must expect `Transfer` first.
    function test_EmitsTransferThenAdminTransfer() public {
        _expectTransferEvent(alice, bob, 100 ether);
        _expectAdminTransferEvent(admin, alice, bob, 100 ether);

        vm.recordLogs();
        vm.prank(admin);
        token.adminTransfer(alice, bob, 100 ether);

        _assertLogCount(2, "exactly one Transfer and one AdminTransfer");
    }

    // ---------- authorization ----------

    function test_NonAdmin_CannotAdminTransfer() public {
        vm.recordLogs();

        vm.prank(bob);
        _expectNotAdmin(bob);
        token.adminTransfer(alice, bob, 100 ether);

        _assertLogCount(0, "a rejected admin transfer must emit nothing");
        assertEq(token.balanceOf(alice), INITIAL_MINT, "and must move nothing");
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Holding some other role is not a shortcut. The custodian can already
    ///      destroy a balance; that must not imply the power to redirect one.
    function test_MinterAndCustodian_CannotAdminTransfer() public {
        vm.prank(minter);
        _expectNotAdmin(minter);
        token.adminTransfer(alice, bob, 1 ether);

        vm.prank(custodian);
        _expectNotAdmin(custodian);
        token.adminTransfer(alice, bob, 1 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT);
    }

    /// @dev A holder cannot reach it for their own balance either — this is not
    ///      a self-service bypass of the allowlist.
    function test_Holder_CannotAdminTransferTheirOwnBalance() public {
        vm.prank(alice);
        _expectNotAdmin(alice);
        token.adminTransfer(alice, bob, 1 ether);
    }

    // ---------- not a mint or burn path ----------

    /// @dev `from == address(0)` would be a mint if this reached `_update`
    ///      directly. It must not: minting stays MINTER_ROLE-only.
    function test_IsNotAMintPath() public {
        uint256 supplyBefore = token.totalSupply();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.adminTransfer(address(0), bob, 100 ether);

        assertEq(token.totalSupply(), supplyBefore, "supply must be untouched");
    }

    /// @dev `to == address(0)` would be a burn. It must not: the entire burn
    ///      surface stays CUSTODIAN_ROLE-only.
    function test_IsNotABurnPath() public {
        uint256 supplyBefore = token.totalSupply();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.adminTransfer(alice, address(0), 100 ether);

        assertEq(token.totalSupply(), supplyBefore, "supply must be untouched");
    }

    /// @dev ...and approving `address(0)` as a destination does not change that.
    function test_IsNotABurnPath_EvenWhenZeroAddressIsAllowlisted() public {
        _allow(alice, address(0));
        uint256 supplyBefore = token.totalSupply();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.adminTransfer(alice, address(0), 100 ether);

        assertEq(token.totalSupply(), supplyBefore);
    }

    function test_TotalSupplyIsUnchangedByASuccessfulCall() public {
        uint256 supplyBefore = token.totalSupply();

        vm.prank(admin);
        token.adminTransfer(alice, bob, 250 ether);

        assertEq(token.totalSupply(), supplyBefore, "moving value must never change supply");
    }

    // ---------- balance accounting still applies ----------

    function test_InsufficientBalance_StillReverts() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, INITIAL_MINT, 1_001 ether)
        );
        token.adminTransfer(alice, bob, 1_001 ether);
    }

    /// @dev The admin is not exempt from the balance check even for an address
    ///      that has never held anything.
    function test_TransferFromAnEmptyBalance_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, carol, 0, 1 ether));
        token.adminTransfer(carol, bob, 1 ether);
    }

    function testFuzz_MovesValueToAnyDestination(address dest, uint256 amount) public {
        vm.assume(dest != address(0));
        vm.assume(dest != alice);
        amount = bound(amount, 0, INITIAL_MINT);

        vm.prank(admin);
        token.adminTransfer(alice, dest, amount);

        assertEq(token.balanceOf(dest), amount);
        assertEq(token.balanceOf(alice), INITIAL_MINT - amount);
        assertEq(token.totalSupply(), INITIAL_MINT, "supply is invariant");
    }
}
