// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { GuardMintBase } from "./GuardMintBase.t.sol";
import { StrandsCustodyToken } from "../../../src/StrandsCustodyToken.sol";

/// @notice Zero is a value, not a sentinel.
/// @dev    `guardMint` takes two numbers that can be zero, and the obvious tests only ever pass zero where it
///         happens to be RIGHT: a zero estimate on a fresh token, and never a zero amount at all. That is
///         exactly the input at which a special case hides. A guard reading `estimatedSupply == 0` as "unknown,
///         skip the check", or an `amount == 0` early-out that returns before the comparison, passes every
///         other suite in this folder. These pin both zeros as ordinary values — checked like any other number,
///         honoured only when they are actually correct.
contract GuardMintZeroValuesTest is GuardMintBase {
    /// @dev The deterministic form of a case `testFuzz_GuardMint_AnyWrongEstimateReverts` only reaches by
    ///      chance. A zero estimate against a funded token is the sentinel mutant's exact input, and it must be
    ///      refused like any other wrong number.
    function test_GuardMint_ZeroEstimate_RevertsAgainstANonZeroSupply() public {
        vm.prank(minter);
        _expectSupplyMismatch(INITIAL_MINT, 0);
        token.guardMint(bob, 50 ether, 0);

        assertEq(token.totalSupply(), INITIAL_MINT, "a zero estimate is a wrong estimate, not a waiver");
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev The other half of that pair: burn the supply away entirely and the SAME call refused above must now
    ///      go through. A token the custodian has emptied is back in the fresh-deployment state `guardMint`'s
    ///      docs describe, and the guard has to say so — otherwise a fully-redeemed token could never be
    ///      re-minted without a redeploy.
    function test_GuardMint_ZeroEstimate_IsAcceptedOnceSupplyIsBurnedToZero() public {
        vm.prank(custodian);
        token.custodyBurn(alice, INITIAL_MINT);
        assertEq(token.totalSupply(), 0, "precondition: the custodian destroyed the entire supply");

        vm.prank(minter);
        token.guardMint(bob, 50 ether, 0);

        assertEq(token.totalSupply(), 50 ether, "zero is the real supply here, so the guard must honour it");
        assertEq(token.balanceOf(bob), 50 ether);
    }

    /// @dev A zero-amount mint is a legitimate no-op — the backend mints a DELTA, and a delta of zero is what a
    ///      reconciliation pass finds when nothing moved. It must succeed and change nothing.
    function test_GuardMint_ZeroAmount_SucceedsAndMovesNothing() public {
        _expectTransferEvent(address(0), bob, 0);
        vm.prank(minter);
        token.guardMint(bob, 0, INITIAL_MINT);

        assertEq(token.totalSupply(), INITIAL_MINT, "a zero delta leaves supply exactly where it was");
        assertEq(token.balanceOf(bob), 0);
    }

    /// @dev And it is still GUARDED. This is the test that kills an `if (amount == 0) return;` early-out: under
    ///      that mutant the call below succeeds silently, telling a backend with a stale read that its estimate
    ///      was accepted — the precise false confirmation `guardMint` exists to prevent.
    function test_GuardMint_ZeroAmount_StillRejectsAWrongEstimate() public {
        vm.prank(minter);
        _expectSupplyMismatch(INITIAL_MINT, INITIAL_MINT - 1);
        token.guardMint(bob, 0, INITIAL_MINT - 1);

        assertEq(token.totalSupply(), INITIAL_MINT, "a refused no-op is still a refusal");
    }

    /// @dev Both zeros at once, on a fresh token, and the mint path is not wedged afterwards: a no-op first call
    ///      must leave the supply at zero so the NEXT call's estimate is still zero.
    function test_GuardMint_ZeroAmountAndZeroEstimate_OnAFreshToken() public {
        StrandsCustodyToken t = _deployWithDecimals(18);

        vm.prank(minter);
        t.guardMint(bob, 0, 0);
        assertEq(t.totalSupply(), 0, "a no-op mint on an empty token leaves it empty");

        vm.prank(minter);
        t.guardMint(bob, 1 ether, 0);
        assertEq(t.totalSupply(), 1 ether, "and the estimate the guard expects is still zero");
    }
}
