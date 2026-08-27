// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { GuardEncodeBase } from "./GuardEncodeBase.t.sol";

/// @notice Anything that moves supply between the caller's read and the call voids the estimate — and the
///         corrected estimate then works.
/// @dev    This is the incident `guardEncode` exists for, and it has more than one shape. A burn can shrink the
///         supply through `adminRetract`, and a second operator can grow it. The guard reads `totalSupply()` and
///         nothing else, so the routes are interchangeable here — which is the property under test, not an
///         accident of how these are written. Each case asserts BOTH halves: the stale read is refused, and the
///         fresh one goes through. A guard that refused everything after a burn would pass a revert-only test
///         while bricking the mint path.
contract GuardEncodeStaleEstimateTest is GuardEncodeBase {
    function _assertGuardTracksSupplyBurned() private {
        uint256 estimate = token.totalSupply();

        vm.prank(operator);
        token.adminRetract(alice, 100 ether);
        uint256 postBurn = estimate - 100 ether;
        assertEq(token.totalSupply(), postBurn, "precondition: this path destroyed exactly 100 ether");

        vm.prank(operator);
        _expectSupplyMismatch(postBurn, estimate);
        token.guardEncode(bob, 50 ether, estimate);
        assertEq(token.totalSupply(), postBurn, "a refused mint must not move supply");

        vm.prank(operator);
        token.guardEncode(bob, 50 ether, postBurn);
        assertEq(token.totalSupply(), postBurn + 50 ether, "the corrected estimate goes through");
        assertEq(token.balanceOf(bob), 50 ether);
    }

    /// @dev The named instance of the shape below, spelled out end to end: this is the atomicity plain `mint`
    ///      cannot give.
    function test_GuardEncode_RevertsWhenSupplyMovedAfterTheRead() public {
        uint256 estimate = token.totalSupply();

        vm.prank(operator);
        token.adminRetract(alice, 1 ether);

        vm.prank(operator);
        _expectSupplyMismatch(INITIAL_MINT - 1 ether, estimate);
        token.guardEncode(bob, 50 ether, estimate);
    }

    function test_GuardEncode_TracksSupplyBurnedVia_AdminRetract() public {
        _assertGuardTracksSupplyBurned();
    }

    /// @dev The mint-side race, and the likelier production incident: two operators (a retried job, two backend
    ///      replicas) read the same supply, and only the first may act on it. The second's estimate is stale for
    ///      a reason no burn caused, and must be refused rather than double-minting the same delta.
    function test_GuardEncode_SecondOperatorActingOnTheSameReadIsRefused() public {
        vm.prank(admin);
        token.grantRole(OPERATOR_ROLE, carol);

        uint256 sharedRead = token.totalSupply();

        vm.prank(operator);
        token.guardEncode(bob, 50 ether, sharedRead);

        vm.prank(carol);
        _expectSupplyMismatch(sharedRead + 50 ether, sharedRead);
        token.guardEncode(bob, 50 ether, sharedRead);

        assertEq(token.balanceOf(bob), 50 ether, "the delta lands once, not once per replica");
        assertEq(token.totalSupply(), INITIAL_MINT + 50 ether);
    }

    /// @dev The operator's remedy: a refusal is recoverable by re-reading and retrying. `SupplyMismatch` carries
    ///      `actualSupply` precisely so the corrected estimate is in the revert data — this asserts that value
    ///      is usable, not merely present, and that the retry mints once rather than replaying the refused call.
    function test_GuardEncode_RetryWithTheCorrectedEstimateSucceeds() public {
        uint256 stale = INITIAL_MINT - 1;

        vm.prank(operator);
        _expectSupplyMismatch(INITIAL_MINT, stale);
        token.guardEncode(bob, 50 ether, stale);

        vm.prank(operator);
        token.guardEncode(bob, 50 ether, INITIAL_MINT); // the `actualSupply` the revert just reported

        assertEq(token.totalSupply(), INITIAL_MINT + 50 ether, "a refusal must not latch the mint path shut");
        assertEq(token.balanceOf(bob), 50 ether, "and the retry mints exactly once, not twice");
    }
}
