// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "./Base.t.sol";

/// @title  Baseline integration test
/// @notice One end-to-end journey — deploy (via the fixture) -> mint -> transfer through the
///         destination allowlist -> burn — plus the core permission denials. Proves the pieces
///         compose; the edge cases live in the per-concern suites under test/token/.
contract IntegrationTest is BaseTest {
    // ---------- happy path ----------

    function test_HappyPath_MintTransferBurn() public {
        // Baseline that setUp established: token deployed, roles seated, alice funded.
        assertTrue(token.initialized());
        assertTrue(token.hasRole(MINTER_ROLE, minter));
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertEq(token.balanceOf(alice), INITIAL_MINT);
        assertEq(token.totalSupply(), INITIAL_MINT);

        // Mint: top alice up further.
        uint256 topUp = 500 ether;
        vm.prank(minter);
        token.mint(alice, topUp);
        assertEq(token.balanceOf(alice), INITIAL_MINT + topUp);
        assertEq(token.totalSupply(), INITIAL_MINT + topUp);

        // Transfer: fails until admin opens the destination, then lands.
        uint256 sent = 200 ether;
        _allow(bob);
        _expectTransferEvent(alice, bob, sent);
        vm.prank(alice);
        token.transfer(bob, sent);
        assertEq(token.balanceOf(alice), INITIAL_MINT + topUp - sent);
        assertEq(token.balanceOf(bob), sent);

        // Burn: minter redeems bob's balance; supply falls, Burned fires.
        uint256 supplyBefore = token.totalSupply();
        _expectBurnedEvent(minter, bob, sent);
        vm.prank(minter);
        token.adminBurn(bob, sent);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), supplyBefore - sent);
    }

    // ---------- unhappy paths (permission / allowlist denials) ----------

    function test_Unhappy_NonMinterCannotMint() public {
        vm.prank(alice);
        _expectNotMinter(alice);
        token.mint(alice, 1 ether);
    }

    function test_Unhappy_AdminCannotMint() public {
        // The admin owns the role graph but no supply authority.
        vm.prank(admin);
        _expectNotMinter(admin);
        token.mint(alice, 1 ether);
    }

    function test_Unhappy_NonMinterCannotBurn() public {
        vm.prank(alice);
        _expectNotMinter(alice);
        token.adminBurn(alice, 1 ether);
    }

    function test_Unhappy_TransferToDisallowedDestinationReverts() public {
        // carol is on no list; alice is funded but has nowhere to send.
        vm.prank(alice);
        _expectDestinationNotAllowed(carol);
        token.transfer(carol, 1 ether);
    }
}
