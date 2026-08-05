// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { GuardMintBase } from "./GuardMintBase.t.sol";

/// @notice The guard's core claim: `guardMint` mints when `estimatedSupply` equals `totalSupply()` and refuses
///         when it does not. Every test here is already past the role gate — `Authority.t.sol` owns that.
contract GuardMintEstimateTest is GuardMintBase {
    function test_MinterCanGuardMint_WhenEstimateMatches() public {
        vm.prank(minter);
        token.guardMint(bob, 50 ether, INITIAL_MINT);
        assertEq(token.balanceOf(bob), 50 ether);
        assertEq(token.totalSupply(), INITIAL_MINT + 50 ether);
    }

    /// @dev Once the estimate passes, the guarded path must be indistinguishable from plain `mint` to an indexer
    ///      reconciling the ledger — it reads `Transfer(0x0, to, amount)` and nothing else.
    function test_GuardMint_EmitsTransferFromTheZeroAddress() public {
        _expectTransferEvent(address(0), bob, 50 ether);
        vm.prank(minter);
        token.guardMint(bob, 50 ether, INITIAL_MINT);
    }

    function test_GuardMint_RevertsOnWrongEstimate() public {
        vm.prank(minter);
        _expectSupplyMismatch(INITIAL_MINT, INITIAL_MINT - 1);
        token.guardMint(bob, 50 ether, INITIAL_MINT - 1);

        assertEq(token.totalSupply(), INITIAL_MINT, "a refused mint must not change supply");
        assertEq(token.balanceOf(bob), 0, "a refused mint must not credit the recipient");
    }

    /// @dev The supply is read BEFORE the prank on purpose: a `token.*` call placed after a cheatcode consumes
    ///      it, so the call under test would run unpranked and fail the role gate instead of the guard. Same
    ///      reason `Base.t.sol` caches the role ids.
    ///      The parameter is `uint256` rather than a narrower type because a wrong estimate is wrong at any
    ///      magnitude: a `uint96` draw explores the bottom 2^96 of the range and never reaches the top of it.
    function testFuzz_GuardMint_AnyWrongEstimateReverts(uint256 estimate) public {
        uint256 supply = token.totalSupply();
        vm.assume(estimate != supply);

        vm.prank(minter);
        _expectSupplyMismatch(supply, estimate);
        token.guardMint(bob, 1 ether, estimate);

        assertEq(token.totalSupply(), supply, "a refused mint must not change supply, whatever the estimate was");
    }
}
