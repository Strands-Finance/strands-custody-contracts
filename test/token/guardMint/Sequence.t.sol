// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { GuardMintBase } from "./GuardMintBase.t.sol";

/// @notice Through any interleaving of guarded mints and burns, the estimate the guard accepts is exactly the
///         running supply — and the one next to it is refused.
/// @dev    The general form of every scripted test in this folder. Those check the guard at a handful of hand-
///         picked supplies; these check that it holds at every supply a sequence walks through, so a guard that
///         drifted by one, or that latched after the first burn, fails here even having passed all of them.
contract GuardMintSequenceTest is GuardMintBase {
    /// @dev The deterministic companion to the fuzz below, and the simplest statement of the claim: an
    ///      excursion that closes leaves no trace. The estimate that was correct before the round trip is
    ///      correct again afterwards, and the one that was correct mid-excursion is now refused — the guard
    ///      carries no memory of a supply it used to have.
    function test_GuardMint_MintBurnRoundTrip_ReturnsToTheStartingEstimate() public {
        uint256 start = token.totalSupply();

        vm.prank(minter);
        token.guardMint(bob, 300 ether, start);

        vm.prank(minter);
        token.adminBurn(bob, 300 ether);
        assertEq(token.totalSupply(), start, "precondition: the round trip is closed");

        vm.prank(minter);
        _expectSupplyMismatch(start, start + 300 ether);
        token.guardMint(bob, 50 ether, start + 300 ether);

        vm.prank(minter);
        token.guardMint(bob, 50 ether, start);
        assertEq(token.totalSupply(), start + 50 ether, "the pre-excursion estimate is correct again");
    }

    /// @dev Every step asserts both directions. Mint amounts are drawn from 0 upward, so zero-amount mints occur
    ///      INSIDE the sequence too, at supplies no fixed test visits.
    function testFuzz_GuardMint_TracksSupplyThroughAnyMintBurnSequence(uint8 steps, uint256 seed) public {
        uint256 supply = token.totalSupply();
        uint256 n = bound(uint256(steps), 1, 16);

        for (uint256 i = 0; i < n; i++) {
            // A fresh draw per step — `seed` alone would make every iteration take the same branch.
            uint256 draw = uint256(keccak256(abi.encode(seed, i)));
            bool burning = (draw & 1 == 1) && token.balanceOf(alice) > 0;

            if (burning) {
                uint256 amount = bound(draw >> 1, 1, token.balanceOf(alice));
                vm.prank(minter);
                token.adminBurn(alice, amount);
                supply -= amount;
            } else {
                uint256 amount = bound(draw >> 1, 0, 1_000 ether);

                // The neighbouring estimate must be refused at EVERY point in the sequence, not just the first.
                if (supply != 0) {
                    vm.prank(minter);
                    _expectSupplyMismatch(supply, supply - 1);
                    token.guardMint(alice, amount, supply - 1);
                }

                vm.prank(minter);
                token.guardMint(alice, amount, supply);
                supply += amount;
            }

            assertEq(token.totalSupply(), supply, "the running supply is the guard's contract with the caller");
        }
    }
}
