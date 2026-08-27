// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice The one question an integrator asks first: can an ordinary user mint
///         or burn? No — and this suite is where that is answered for the WHOLE
///         supply-changing surface in one place, rather than a path at a time
///         across `Mint.t.sol`, `AdminBurn.t.sol`, `BurnAuthority.t.sol` and
///         `guardEncode/Authority.t.sol`.
///
/// @dev    Every supply-changing entrypoint (`encode`, `guardEncode`,
///         `adminRetract`, `guardRetract`) is written gated, and the contract
///         inherits plain {ERC20} rather than {ERC20Burnable}, so there is no
///         holder-reachable `burn` / `burnFrom` at all — the gate is structural,
///         not an override that a merge could silently drop.
///
///         `SupplyInvariant.t.sol` covers the same property from the other
///         direction — fuzzer-enumerated over the entire ABI, so an entrypoint
///         that does not exist yet is covered without editing a test. This file
///         is the legible statement; that one is the completeness argument.
contract ExternalUserSurfaceTest is BaseTest {
    /// @dev Every supply-changing entrypoint, refused for one arbitrary caller,
    ///      in one place. `caller` is bounded away from the seated roles so the
    ///      rejection is about the ROLE and never about the address, and a max
    ///      allowance is granted first so it can never be about a missing
    ///      approval either.
    function testFuzz_ArbitraryCaller_IsRefusedByEveryMintAndBurnEntrypoint(address caller) public {
        vm.assume(caller != minter && caller != admin && caller != address(0));

        uint256 supplyBefore = token.totalSupply();
        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(alice);
        token.approve(caller, type(uint256).max);

        vm.startPrank(caller);
        _expectNotMinter(caller);
        token.encode(caller, 1 ether);
        _expectNotMinter(caller);
        token.guardEncode(caller, 1 ether, supplyBefore);
        _expectNotMinter(caller);
        token.adminRetract(alice, 1 ether);
        _expectNotMinter(caller);
        token.guardRetract(alice, 1 ether, supplyBefore);
        vm.stopPrank();

        assertEq(token.totalSupply(), supplyBefore, "no rejected call may move supply");
        assertEq(token.balanceOf(alice), aliceBefore, "nor a balance");
        assertEq(token.allowance(alice, caller), type(uint256).max, "nor spend the allowance");
    }

    /// @dev The same four, for a caller who is unambiguously a HOLDER — funded,
    ///      and burning an amount they actually own. The fuzz above bounds
    ///      `caller` away from the roles but says nothing about its balance, so
    ///      "insufficient balance" remains an available explanation there.
    ///      Here it is not.
    function test_FundedHolder_IsRefusedByEveryMintAndBurnEntrypoint() public {
        _allow(bob); // funding bob is a transfer like any other, so the route has to be open first

        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether, "precondition: bob owns what he is trying to burn");

        vm.startPrank(bob);
        _expectNotMinter(bob);
        token.encode(bob, 1 ether);
        _expectNotMinter(bob);
        token.guardEncode(bob, 1 ether, INITIAL_MINT);
        _expectNotMinter(bob);
        token.adminRetract(bob, 1 ether);
        _expectNotMinter(bob);
        token.guardRetract(bob, 1 ether, INITIAL_MINT);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 100 ether, "owning the balance is not authority to destroy it");
        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev The gate is not a balance check in disguise. A holder with a
    ///      genuinely insufficient balance must STILL be refused for the role,
    ///      not for the balance — otherwise a reader could conclude that funding
    ///      the caller is what changes the outcome.
    function test_HolderWithNoBalance_IsRefusedForTheRole_NotTheBalance() public {
        assertEq(token.balanceOf(bob), 0, "precondition: bob holds nothing");

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, OPERATOR_ROLE)
        );
        token.adminRetract(bob, 1 ether);
    }

    /// @dev And the control that keeps the assertions above honest: with
    ///      the role held, the very same call succeeds. Without this, every test
    ///      here would keep passing if burning were broken outright.
    function test_TheSameCallSucceedsForTheMinter() public {
        vm.prank(minter);
        token.encode(minter, 1 ether);

        vm.prank(minter);
        token.adminRetract(minter, 1 ether);

        assertEq(token.totalSupply(), INITIAL_MINT, "the refusals above are about the role, not the call");
    }

    /// @dev What an external user CAN do, so the boundary is drawn from both
    ///      sides: move their own balance, and approve someone else to. Neither
    ///      changes how many tokens exist — which is the line the role gate
    ///      draws.
    ///
    ///      `destination` is OPENED first. Without that the allowlist refuses
    ///      every fuzzed address and the assertion below holds vacuously — supply
    ///      is trivially unchanged when nothing moved. Opening it is what keeps
    ///      this a statement about transfers rather than about the guard, which
    ///      `Allowlist.t.sol` owns.
    function testFuzz_UnprivilegedActions_AreSupplyNeutral(address destination, uint96 amount) public {
        vm.assume(destination != address(0) && destination != alice);
        uint256 value = bound(uint256(amount), 0, INITIAL_MINT);

        _allow(destination);

        vm.startPrank(alice);
        token.approve(bob, type(uint256).max);
        token.transfer(destination, value);
        vm.stopPrank();

        assertEq(token.balanceOf(destination), value, "the transfer actually landed");
        assertEq(token.totalSupply(), INITIAL_MINT, "transfer and approve never change supply");
    }

    /// @dev Belt and braces on the error identity, so `_expectNotMinter` above
    ///      cannot silently start matching something else: the rejection names
    ///      OPERATOR_ROLE specifically, not merely "some role".
    function test_TheRejectionNamesMinterRole() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, OPERATOR_ROLE)
        );
        token.adminRetract(alice, 1 ether);
    }

    /// @dev A holder cannot reach the burn by handing their balance to the
    ///      contract itself, either — a common shape in tokens that implement a
    ///      "send to burn" convention. There is no such convention here: the
    ///      transfer succeeds as an ordinary transfer and supply is unmoved.
    function test_TransferringToTheTokenItself_DoesNotBurn() public {
        _allow(address(token)); // the token is an ordinary destination, and holds no standing of its own

        vm.prank(alice);
        token.transfer(address(token), 100 ether);

        assertEq(token.balanceOf(address(token)), 100 ether, "the tokens are parked, not destroyed");
        assertEq(token.totalSupply(), INITIAL_MINT, "supply is unmoved");
    }

    /// @dev The zero address is refused, and is NOT a back door to a burn. Which
    ///      check refuses it is worth being exact about: `address(0)` is on no
    ///      allowlist and the guard runs before `ERC20._transfer`, so the
    ///      allowlist answers and OZ's own `ERC20InvalidReceiver` is never
    ///      reached. Both would refuse it; only one of them gets to. That is why
    ///      this asserts the destination error rather than the ERC20 one — the
    ///      same ordering `Transfer.t.sol` and `TransferFrom.t.sol` pin.
    ///
    ///      What the file still does NOT protect against: a holder can strand
    ///      value by sending it to an ALLOWED address nobody controls. That
    ///      reduces the CIRCULATING claim without reducing totalSupply, which is
    ///      exactly why the backend reconciles against totalSupply and never
    ///      against a sum of balances. The allowlist narrows that surface to
    ///      addresses an admin opened; it does not close it.
    function test_SendingToTheZeroAddress_IsRefused_NotSilentlyABurn() public {
        vm.prank(alice);
        _expectDestinationNotAllowed(address(0));
        token.transfer(address(0), 1 ether);

        assertEq(token.totalSupply(), INITIAL_MINT);
    }
}
