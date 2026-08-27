// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { GuardEncodeBase } from "./GuardEncodeBase.t.sol";
import { StrandsDACAP } from "../../../src/StrandsDACAP.sol";

/// @notice None of the claims the other files in this folder make depends on `decimals()`.
/// @dev    Every other suite here runs on the 18-dp fixture, and `Metadata.t.sol` only checks that `decimals()`
///         RETURNS 6/8/18 — nothing exercised BEHAVIOUR at another magnitude. Real deployments are mostly not
///         18: usdc is 6 and btc is 8 (the backend's CustodyAssetDecimals). `decimals()` is ERC20 display
///         metadata and never enters `totalSupply` or `_mint`, both raw uint256, so the guard's comparison is in
///         native base units by construction. These pin that: if a change ever scaled by `decimals()`, every
///         18-dp test in this folder would still pass while every real USDC and BTC token broke.
///
///         A REACHED line is not a TESTED line. The first version of the cross-magnitude test below minted once
///         into each of a 6-dp and an 18-dp token from a zero estimate, and survived a mutant that compared
///         `totalSupply() / (10 ** decimals())`: the mutated expression ran, but zero is a fixed point of
///         division, so it produced the same answer and nothing downstream could differ. Killing a mutant needs
///         all three of reachability, INFECTION (the mutated expression yields a different value) and
///         propagation to an assertion — that test had only the first. Hence the rule these follow: every
///         magnitude must be exercised with a NON-ZERO estimate, the only input at which a scaling fault is
///         observable.
contract GuardEncodeDecimalsTest is GuardEncodeBase {
    uint256 internal constant ONE_USDC = 1e6;

    /// @dev The whole guard contract, asserted at ONE magnitude. Every step works in raw base units and none of
    ///      the expectations mention `decimals_`, which is the property under test: the same script must produce
    ///      the same numbers at 6, 8 and 18. `amount` is deliberately not a whole number of display units at any
    ///      magnitude, so a scaling fault cannot coincidentally land on the right answer.
    function _assertGuardEncodeInvariantsAt(uint8 decimals_) private {
        StrandsDACAP t = _deployWithDecimals(decimals_);
        assertEq(t.decimals(), decimals_, "precondition: the token reports the magnitude under test");
        assertEq(t.totalSupply(), 0, "precondition: a fresh token has no supply");

        uint256 amount = 123_456_789;

        // 1. Fresh token: the estimate is definitionally zero, and the raw amount lands whatever decimals() says.
        vm.prank(operator);
        t.guardEncode(bob, amount, 0);
        assertEq(t.totalSupply(), amount, "a first mint lands the raw amount");
        assertEq(t.balanceOf(bob), amount);

        // 2. A NON-ZERO estimate must be the raw supply. This is the step with teeth — see the note above: step 1
        //    alone passes under a decimals-scaled comparison because zero survives any division.
        vm.prank(operator);
        t.guardEncode(bob, amount, amount);
        assertEq(t.totalSupply(), 2 * amount, "a matching raw estimate mints");
        assertEq(t.balanceOf(bob), 2 * amount);

        // 3. A stale estimate reverts, and the revert DATA carries raw base units at every magnitude — that data
        //    is the diagnosis an operator reads, so a scaled `actual` would misreport the chain's own state.
        vm.prank(operator);
        _expectSupplyMismatch(2 * amount, amount);
        t.guardEncode(bob, amount, amount);
        assertEq(t.totalSupply(), 2 * amount, "a refused mint must not move supply");
        assertEq(t.balanceOf(bob), 2 * amount, "nor credit the recipient");

        // 4. A decimal-adjusted estimate — supply expressed in display units — must be refused rather than read
        //    as "close enough". Skipped at 0 dp, where the scaled value IS the raw one and there is no fault to
        //    express (that is also why 0 dp cannot detect a scaling mutant).
        if (decimals_ > 0) {
            uint256 displayUnits = (2 * amount) / (10 ** decimals_);
            vm.prank(operator);
            _expectSupplyMismatch(2 * amount, displayUnits);
            t.guardEncode(bob, amount, displayUnits);
        }

        // 5. The guard tracks whatever moved supply, not just mints: after a burn the estimate must be the NEW
        //    raw supply. Pairs the guard with the unguarded burn path at every magnitude.
        vm.prank(operator);
        t.adminRetract(bob, amount);
        assertEq(t.totalSupply(), amount, "the burn removes exactly the raw amount");

        vm.prank(operator);
        t.guardEncode(bob, amount, amount);
        assertEq(t.totalSupply(), 2 * amount, "the post-burn supply is the estimate the guard now expects");
    }

    function test_GuardEncode_Invariants_At6Decimals() public {
        _assertGuardEncodeInvariantsAt(6); // usdc
    }

    function test_GuardEncode_Invariants_At18Decimals() public {
        _assertGuardEncodeInvariantsAt(18); // eth / hteth
    }

    function test_GuardEncode_Invariants_At8Decimals() public {
        _assertGuardEncodeInvariantsAt(8); // btc
    }

    /// @dev The general form of the three above: no magnitude in the ERC20 range changes the guard's behaviour.
    ///      The named cases are kept alongside it because they fail deterministically at the magnitudes actually
    ///      deployed, whereas a fuzz run only reaches them by chance.
    function testFuzz_GuardEncode_InvariantsHoldAtAnyDecimals(uint8 decimals_) public {
        _assertGuardEncodeInvariantsAt(uint8(bound(uint256(decimals_), 0, 18)));
    }

    /// @dev The decimal-fault case. A backend that normalised supply to human units before handing it back would
    ///      pass 5 where the chain holds 5_000_000. The comparison is raw base units, so that must revert rather
    ///      than read as "5 USDC, close enough" — the estimate carries no scale of its own to reconcile.
    function test_GuardEncode_6dp_RejectsADecimalAdjustedEstimate() public {
        StrandsDACAP usdc = _deployWithDecimals(6);
        vm.prank(operator);
        usdc.guardEncode(alice, 5 * ONE_USDC, 0);
        assertEq(usdc.totalSupply(), 5 * ONE_USDC, "precondition: five whole USDC, i.e. 5_000_000 base units");

        vm.prank(operator);
        _expectSupplyMismatch(5 * ONE_USDC, 5);
        usdc.guardEncode(bob, ONE_USDC, 5);

        assertEq(usdc.totalSupply(), 5 * ONE_USDC, "a decimal-adjusted estimate must not be honoured");
    }

    /// @dev The general statement the three tests above are instances of: the same integer minted into tokens of
    ///      different decimals yields the same totalSupply, because decimals() is not part of the arithmetic.
    ///      The SECOND mint on each token is what gives this test teeth — it is the only one whose estimate is
    ///      non-zero, and a comparison scaled by decimals() would divide that estimate to a different number and
    ///      revert. A single mint from zero cannot detect the fault, because zero survives any division.
    function test_GuardEncode_DecimalsDoNotAffectSupplyArithmetic() public {
        StrandsDACAP sixDp = _deployWithDecimals(6);
        StrandsDACAP eighteenDp = _deployWithDecimals(18);
        uint256 amount = 123_456_789;

        vm.startPrank(operator);
        sixDp.guardEncode(bob, amount, 0);
        eighteenDp.guardEncode(bob, amount, 0);
        sixDp.guardEncode(bob, amount, amount);
        eighteenDp.guardEncode(bob, amount, amount);
        vm.stopPrank();

        assertEq(sixDp.totalSupply(), eighteenDp.totalSupply(), "decimals() must not scale totalSupply");
        assertEq(sixDp.totalSupply(), 2 * amount, "the raw amount is the supply, at either magnitude");
        assertEq(sixDp.balanceOf(bob), eighteenDp.balanceOf(bob), "nor scale a holder's balance");
    }
}
