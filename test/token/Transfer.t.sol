// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice What `transfer` does ONCE THE DESTINATION IS PERMITTED: ordinary
///         ERC20 mechanics, with no approval step and no privileged role
///         involved. Self-transfers and zero-value transfers still behave
///         exactly as the standard requires.
///
/// @dev    The destination allowlist is the subject of `Allowlist.t.sol`, not
///         of this file. The `setUp` override below opens the addresses this
///         suite sends to so that every assertion here stays about the transfer
///         itself — without it the guard, which runs first, would swallow the
///         `ERC20Insufficient*` errors this file exists to pin.
contract TransferTest is BaseTest {
    /// @dev Opens only what this file transfers to. The SHARED fixture still
    ///      opens nothing, so no other suite loses its default-deny posture to
    ///      this override.
    function setUp() public override {
        super.setUp();
        _allow(bob);
        _allow(carol);
        _allow(alice); // the self-transfer below is a transfer to `alice` like any other
    }

    function test_Transfer_MovesBalanceAndEmitsTransfer() public {
        _expectTransferEvent(alice, bob, 100 ether);
        vm.prank(alice);
        token.transfer(bob, 100 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT - 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.totalSupply(), INITIAL_MINT, "a transfer must never change supply");
    }

    /// @dev An allowed destination needs no approval on top: the ERC20
    ///      allowance governs `transferFrom` only, and `carol` has given `alice`
    ///      nothing.
    function test_Transfer_ToAnAllowedDestination_NeedsNoApproval() public {
        assertEq(token.allowance(alice, carol), 0, "precondition: no allowance in either direction");

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
    ///      guard treats `alice -> alice` as any other destination, so with
    ///      `alice` open the standard behaviour is what remains.
    function test_SelfTransfer_SucceedsAndIsBalanceNeutral() public {
        _expectTransferEvent(alice, alice, 1 ether);
        vm.prank(alice);
        token.transfer(alice, 1 ether);

        assertEq(token.balanceOf(alice), INITIAL_MINT);
    }

    /// @dev Likewise zero-value: ERC20 requires it to behave like any other
    ///      transfer. The guard never reads `value`, so an open destination
    ///      leaves this untouched.
    function test_ZeroValueTransfer_Succeeds() public {
        _expectTransferEvent(alice, bob, 0);
        vm.prank(alice);
        token.transfer(bob, 0);

        assertEq(token.balanceOf(alice), INITIAL_MINT);
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev Holding a role neither exempts an address from anything nor
    ///      restricts it. Every one of these moves for the ordinary reason —
    ///      `bob` is open, and that is the whole permission any of them needs.
    function test_PrivilegedRoles_TransferLikeAnyOtherHolder() public {
        vm.startPrank(minter);
        token.mint(admin, 10 ether);
        token.mint(minter, 10 ether);
        vm.stopPrank();

        vm.prank(admin);
        token.transfer(bob, 10 ether);
        vm.prank(minter);
        token.transfer(bob, 10 ether);

        assertEq(token.balanceOf(bob), 20 ether);
        assertEq(token.balanceOf(admin), 0);
        assertEq(token.balanceOf(minter), 0);
    }

    // ---------- the checks that DO still reject ----------

    function test_Transfer_InsufficientBalance_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, INITIAL_MINT, 1_001 ether)
        );
        token.transfer(bob, 1_001 ether);
    }

    /// @dev Transfer is not a burn path. Burning is MINTER_ROLE-only, so
    ///      reaching `address(0)` through `transfer` would be a way around that
    ///      gate. It is now refused twice over: `address(0)` is on no allowlist,
    ///      so the guard answers first and OZ's own `ERC20InvalidReceiver` never
    ///      gets the chance. `setUp` deliberately does not open it.
    function test_Transfer_ToZeroAddress_Reverts() public {
        vm.prank(alice);
        _expectDestinationNotAllowed(address(0));
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

    /// @dev No destination is special: being absent from the list is the only
    ///      thing that matters, and every address starts absent. The three this
    ///      file's `setUp` opens are excluded, since they are the subject of the
    ///      positive cases above.
    function testFuzz_Transfer_RevertsForAnyUnallowedDestination(address destination, uint96 amount) public {
        vm.assume(destination != alice && destination != bob && destination != carol);
        uint256 value = bound(uint256(amount), 0, INITIAL_MINT);

        vm.prank(alice);
        _expectDestinationNotAllowed(destination);
        token.transfer(destination, value);

        assertEq(token.balanceOf(alice), INITIAL_MINT, "a refused transfer moves nothing");
        assertEq(token.balanceOf(destination), 0);
    }

    // ---------- the PER-HOLDER allowlist surface is genuinely gone ----------

    /// @dev The current allowlist is keyed by destination alone, so none of the
    ///      per-holder machinery came back with it: no directed edges, no
    ///      pair-linking, no admin bypass. The typed API cannot express these
    ///      calls — the functions do not exist, so a test that named them would
    ///      not compile. Probing by raw selector is what proves the DEPLOYED
    ///      contract has no dispatch entry either, which is the form the
    ///      backend's Nethereum bindings would reach it by. The token has no
    ///      fallback, so an absent selector reverts.
    ///
    ///      These are the TWO-ARGUMENT forms, distinct from today's one-argument
    ///      `setDestinationAllowed(address,bool)` / `allowedDestination(address)`
    ///      — different signatures, different selectors, and only the latter pair
    ///      exists. `test_AllowlistSelectors_HaveADispatchEntry` is the other
    ///      half of that claim.
    ///
    ///      Pranked as `admin` deliberately: three of these four were
    ///      DEFAULT_ADMIN_ROLE-gated, so an unprivileged probe would fail the
    ///      role check and this would pass whether or not the entrypoint
    ///      existed. As the admin, the ONLY reason left for a failure is the
    ///      missing selector.
    function test_PerHolderAllowlistSelectors_HaveNoDispatchEntry() public {
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

    /// @dev The counterpart, and what stops the test above from passing for the
    ///      wrong reason: the one-argument pair the token DOES carry is
    ///      dispatchable. Without this, deleting the allowlist entirely would
    ///      leave that test green.
    function test_AllowlistSelectors_HaveADispatchEntry() public {
        vm.prank(admin);
        (bool wrote,) = address(token)
            .call(abi.encodeWithSelector(bytes4(keccak256("setDestinationAllowed(address,bool)")), carol, true));
        assertTrue(wrote, "the setter must be dispatchable");

        (bool read, bytes memory data) =
            address(token).staticcall(abi.encodeWithSelector(bytes4(keccak256("allowedDestination(address)")), carol));
        assertTrue(read, "the getter must be dispatchable");
        assertTrue(abi.decode(data, (bool)), "and must report the write");
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
