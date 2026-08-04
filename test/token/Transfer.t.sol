// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice `transfer` is ordinary, unrestricted ERC20: any holder may send to
///         any address, with no approval step and no privileged role involved.
///
/// @dev    This suite exists because the token used to gate transfers behind a
///         per-holder destination allowlist. Removing that guard restored three
///         behaviours the guard had overridden — sending to an arbitrary
///         address, self-transfers, and zero-value transfers — and each is
///         pinned below, so a re-introduced gate fails here rather than in
///         production. `_update` is no longer overridden at all, so what is
///         actually being asserted is that OZ's `ERC20._update` reaches these
///         paths untouched.
contract TransferTest is BaseTest {
    function test_Transfer_MovesBalanceAndEmitsTransfer() public {
        _expectTransferEvent(alice, bob, 100 ether);
        vm.prank(alice);
        token.transfer(bob, 100 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT - 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.totalSupply(), INITIAL_MINT, "a transfer must never change supply");
    }

    /// @dev The headline regression guard. `carol` has no relationship to
    ///      `alice` of any kind — no approval, no role, never named together in
    ///      `setUp`. Under the allowlist this reverted; it is now the ordinary
    ///      case, and a returning default-deny would surface here first.
    function test_Transfer_ToAnUnrelatedAddress_NeedsNoApproval() public {
        vm.prank(alice);
        token.transfer(carol, 250 ether);

        assertEq(token.balanceOf(carol), 250 ether);
    }

    function test_Transfer_EntireBalance() public {
        vm.prank(alice);
        token.transfer(bob, INITIAL_MINT);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), INITIAL_MINT);
        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev Onward transfers work too: a recipient is a holder like any other,
    ///      so value is not confined to whatever path first delivered it.
    function test_Transfer_IsNotConfinedToOneHop() public {
        vm.prank(alice);
        token.transfer(bob, 300 ether);

        vm.prank(bob);
        token.transfer(carol, 300 ether);

        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(carol), 300 ether);
    }

    /// @dev ERC20 requires a self-transfer to be a balance-neutral no-op. The
    ///      allowlist used to reject it unless an admin had approved the
    ///      `x -> x` edge on purpose; standard behaviour is restored.
    function test_SelfTransfer_SucceedsAndIsBalanceNeutral() public {
        _expectTransferEvent(alice, alice, 1 ether);
        vm.prank(alice);
        token.transfer(alice, 1 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT);
    }

    /// @dev Likewise zero-value: ERC20 requires it to behave like any other
    ///      transfer, and the allowlist used to block it — which also meant a
    ///      `transfer(dest, 0)` route probe reverted instead of answering.
    function test_ZeroValueTransfer_Succeeds() public {
        _expectTransferEvent(alice, bob, 0);
        vm.prank(alice);
        token.transfer(bob, 0);

        assertEq(token.balanceOf(alice), INITIAL_MINT);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Holding a role neither exempts an address from anything nor
    ///      restricts it. Every one of these moves for the ordinary reason.
    function test_PrivilegedRoles_TransferLikeAnyOtherHolder() public {
        vm.startPrank(minter);
        token.mint(admin, 10 ether);
        token.mint(minter, 10 ether);
        token.mint(custodian, 10 ether);
        vm.stopPrank();

        vm.prank(admin);
        token.transfer(bob, 10 ether);
        vm.prank(minter);
        token.transfer(bob, 10 ether);
        vm.prank(custodian);
        token.transfer(bob, 10 ether);

        assertEq(token.balanceOf(bob), 30 ether);
        assertEq(token.balanceOf(admin), 0);
        assertEq(token.balanceOf(minter), 0);
        assertEq(token.balanceOf(custodian), 0);
    }

    // ---------- the checks that DO still reject ----------

    function test_Transfer_InsufficientBalance_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, INITIAL_MINT, 1_001 ether)
        );
        token.transfer(bob, 1_001 ether);
    }

    /// @dev Transfer is not a burn path. Burning is CUSTODIAN_ROLE-only, so
    ///      reaching `address(0)` through `transfer` would be a way around that
    ///      gate — OZ rejects it before any balance moves.
    function test_Transfer_ToZeroAddress_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT);
        assertEq(token.totalSupply(), INITIAL_MINT, "supply must be untouched");
    }

    function test_RejectedTransfer_LeavesBalancesAndSupplyUnchanged() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, INITIAL_MINT, 5_000 ether)
        );
        token.transfer(bob, 5_000 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    // ---------- fuzz ----------

    /// @dev No destination is special. `address(0)` is excluded because it is
    ///      the burn address and rejected on purpose; `alice` because a
    ///      self-transfer is balance-neutral and would fail the assertion for
    ///      the wrong reason — both are covered by their own tests above.
    function testFuzz_Transfer_ReachesAnyDestination(address destination, uint96 amount) public {
        vm.assume(destination != address(0) && destination != alice);
        uint256 value = bound(uint256(amount), 0, INITIAL_MINT);

        vm.prank(alice);
        token.transfer(destination, value);

        assertEq(token.balanceOf(alice), INITIAL_MINT - value);
        assertEq(token.balanceOf(destination), value);
        assertEq(token.totalSupply(), INITIAL_MINT, "no transfer changes supply");
    }

    // ---------- the removed allowlist surface is genuinely gone ----------

    /// @dev The typed API cannot express these calls any more — the functions
    ///      do not exist, so a test that named them would not compile. Probing
    ///      by raw selector is what proves the DEPLOYED contract has no dispatch
    ///      entry either, which is the form the backend's Nethereum bindings and
    ///      any external integration would reach it by. The token has no
    ///      fallback, so an absent selector reverts.
    ///
    ///      Pranked as `admin` deliberately: three of these four were
    ///      DEFAULT_ADMIN_ROLE-gated, so an unprivileged probe would fail the
    ///      role check and this would pass whether or not the entrypoint
    ///      existed. As the admin, the ONLY reason left for a failure is the
    ///      missing selector.
    function test_RemovedAllowlistSelectors_HaveNoDispatchEntry() public {
        bytes4[4] memory removed = [
            bytes4(keccak256("setLink(address,address,bool)")),
            bytes4(keccak256("setDestinationAllowed(address,address,bool)")),
            bytes4(keccak256("adminTransfer(address,address,uint256)")),
            bytes4(keccak256("allowedDestination(address,address)"))
        ];

        for (uint256 i = 0; i < removed.length; i++) {
            vm.prank(admin);
            (bool ok,) = address(token).call(abi.encodeWithSelector(removed[i], alice, bob, uint256(1)));
            assertFalse(ok, "a removed entrypoint must not be dispatchable");
        }
    }

    /// @dev The control for the test above: the same raw-call probe against a
    ///      selector that DOES exist succeeds, so `assertFalse` above is
    ///      rejecting the selector rather than the calling convention.
    function test_SelectorProbe_SucceedsForALiveEntrypoint() public {
        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeWithSelector(token.transfer.selector, bob, uint256(1 ether)));

        assertTrue(ok, "the probe itself must be able to reach a live entrypoint");
        assertEq(token.balanceOf(bob), 1 ether);
    }
}
