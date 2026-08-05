// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { stdError } from "forge-std/StdError.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { BaseTest } from "../Base.t.sol";
import { StrandsCustodyToken } from "../../src/StrandsCustodyToken.sol";

/// @notice `guardMint` — the supply-checked mint entrypoint and its MINTER_ROLE gate.
contract GuardMintTest is BaseTest {
    function test_MinterCanGuardMint_WhenEstimateMatches() public {
        vm.prank(minter);
        token.guardMint(bob, 50 ether, INITIAL_MINT);
        assertEq(token.balanceOf(bob), 50 ether);
        assertEq(token.totalSupply(), INITIAL_MINT + 50 ether);
    }

    function test_GuardMint_RevertsOnWrongEstimate() public {
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(StrandsCustodyToken.SupplyMismatch.selector, INITIAL_MINT, INITIAL_MINT - 1)
        );
        token.guardMint(bob, 50 ether, INITIAL_MINT - 1);

        assertEq(token.totalSupply(), INITIAL_MINT, "a refused mint must not change supply");
        assertEq(token.balanceOf(bob), 0, "a refused mint must not credit the recipient");
    }

    /// @dev The exact incident shape: a supply moving AFTER the caller read it (here: a burn between read and
    ///      mint) must void the estimate — this is the atomicity plain `mint` cannot give.
    function test_GuardMint_RevertsWhenSupplyMovedAfterTheRead() public {
        uint256 estimate = token.totalSupply();

        vm.prank(custodian);
        token.custodyBurn(alice, 1 ether);

        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(StrandsCustodyToken.SupplyMismatch.selector, INITIAL_MINT - 1 ether, estimate)
        );
        token.guardMint(bob, 50 ether, estimate);
    }

    function test_NonMinter_CannotGuardMint() public {
        vm.prank(alice);
        _expectNotMinter(alice);
        token.guardMint(bob, 1, INITIAL_MINT);
    }

    /// @dev The supply is read BEFORE the prank on purpose: a `token.*` call placed after a cheatcode consumes
    ///      it, so the call under test would run unpranked and fail the role gate instead of the guard. Same
    ///      reason `Base.t.sol` caches the role ids.
    function testFuzz_GuardMint_AnyWrongEstimateReverts(uint96 estimate) public {
        uint256 supply = token.totalSupply();
        vm.assume(estimate != supply);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.SupplyMismatch.selector, supply, estimate));
        token.guardMint(bob, 1 ether, estimate);

        assertEq(token.totalSupply(), supply, "a refused mint must not change supply, whatever the estimate was");
    }

    // ---------- decimals independence ----------
    //
    // Everything above runs on the 18-dp fixture, and `Metadata.t.sol` only checks that `decimals()` RETURNS
    // 6/8/18 — nothing exercised BEHAVIOUR at another magnitude. Real deployments are mostly not 18: usdc is 6
    // and btc is 8 (the backend's CustodyAssetDecimals). `decimals()` is ERC20 display metadata and never enters
    // `totalSupply` or `_mint`, both raw uint256, so the guard's comparison is in native base units by
    // construction. These pin that: if a change ever scaled by `decimals()`, every 18-dp test above would still
    // pass while every real USDC and BTC token broke.
    //
    // A REACHED line is not a TESTED line. The first version of the cross-magnitude test below minted once into
    // each of a 6-dp and an 18-dp token from a zero estimate, and survived a mutant that compared
    // `totalSupply() / (10 ** decimals())`: the mutated expression ran, but zero is a fixed point of division, so
    // it produced the same answer and nothing downstream could differ. Killing a mutant needs all three of
    // reachability, INFECTION (the mutated expression yields a different value) and propagation to an assertion —
    // that test had only the first. Hence the rule these follow: every magnitude must be exercised with a
    // NON-ZERO estimate, which is the only input at which a scaling fault is observable.

    uint256 internal constant ONE_USDC = 1e6;

    /// @dev A token at an arbitrary magnitude, wired like the fixture's. Metadata is deliberately generic — these
    ///      suites are about arithmetic, and `Metadata.t.sol` owns naming. The role ids are keccak constants, so
    ///      `Base.t.sol`'s cached MINTER_ROLE / CUSTODIAN_ROLE apply to any instance.
    function _deployWithDecimals(uint8 decimals_) private returns (StrandsCustodyToken t) {
        t = new StrandsCustodyToken(admin, decimals_, "Strands Custody Fixture", "scFIX");
        vm.startPrank(admin);
        t.grantRole(MINTER_ROLE, minter);
        t.grantRole(CUSTODIAN_ROLE, custodian);
        vm.stopPrank();
    }

    /// @dev The whole guard contract, asserted at ONE magnitude. Every step works in raw base units and none of
    ///      the expectations mention `decimals_`, which is the property under test: the same script must produce
    ///      the same numbers at 6, 8 and 18. `amount` is deliberately not a whole number of display units at any
    ///      magnitude, so a scaling fault cannot coincidentally land on the right answer.
    function _assertGuardMintInvariantsAt(uint8 decimals_) private {
        StrandsCustodyToken t = _deployWithDecimals(decimals_);
        assertEq(t.decimals(), decimals_, "precondition: the token reports the magnitude under test");
        assertEq(t.totalSupply(), 0, "precondition: a fresh token has no supply");

        uint256 amount = 123_456_789;

        // 1. Fresh token: the estimate is definitionally zero, and the raw amount lands whatever decimals() says.
        vm.prank(minter);
        t.guardMint(bob, amount, 0);
        assertEq(t.totalSupply(), amount, "a first mint lands the raw amount");
        assertEq(t.balanceOf(bob), amount);

        // 2. A NON-ZERO estimate must be the raw supply. This is the step with teeth — see the note above: step 1
        //    alone passes under a decimals-scaled comparison because zero survives any division.
        vm.prank(minter);
        t.guardMint(bob, amount, amount);
        assertEq(t.totalSupply(), 2 * amount, "a matching raw estimate mints");
        assertEq(t.balanceOf(bob), 2 * amount);

        // 3. A stale estimate reverts, and the revert DATA carries raw base units at every magnitude — that data
        //    is the diagnosis an operator reads, so a scaled `actual` would misreport the chain's own state.
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.SupplyMismatch.selector, 2 * amount, amount));
        t.guardMint(bob, amount, amount);
        assertEq(t.totalSupply(), 2 * amount, "a refused mint must not move supply");
        assertEq(t.balanceOf(bob), 2 * amount, "nor credit the recipient");

        // 4. A decimal-adjusted estimate — supply expressed in display units — must be refused rather than read
        //    as "close enough". Skipped at 0 dp, where the scaled value IS the raw one and there is no fault to
        //    express (that is also why 0 dp cannot detect a scaling mutant).
        if (decimals_ > 0) {
            uint256 displayUnits = (2 * amount) / (10 ** decimals_);
            vm.prank(minter);
            vm.expectRevert(
                abi.encodeWithSelector(StrandsCustodyToken.SupplyMismatch.selector, 2 * amount, displayUnits)
            );
            t.guardMint(bob, amount, displayUnits);
        }

        // 5. The guard tracks whatever moved supply, not just mints: after a burn the estimate must be the NEW
        //    raw supply. Pairs the guard with the custody burn path at every magnitude.
        vm.prank(custodian);
        t.custodyBurn(bob, amount);
        assertEq(t.totalSupply(), amount, "the burn removes exactly the raw amount");

        vm.prank(minter);
        t.guardMint(bob, amount, amount);
        assertEq(t.totalSupply(), 2 * amount, "the post-burn supply is the estimate the guard now expects");
    }

    function test_GuardMint_Invariants_At6Decimals() public {
        _assertGuardMintInvariantsAt(6); // usdc
    }

    function test_GuardMint_Invariants_At18Decimals() public {
        _assertGuardMintInvariantsAt(18); // eth / hteth
    }

    function test_GuardMint_Invariants_At8Decimals() public {
        _assertGuardMintInvariantsAt(8); // btc
    }

    /// @dev The general form of the three above: no magnitude in the ERC20 range changes the guard's behaviour.
    ///      The named cases are kept alongside it because they fail deterministically at the magnitudes actually
    ///      deployed, whereas a fuzz run only reaches them by chance.
    function testFuzz_GuardMint_InvariantsHoldAtAnyDecimals(uint8 decimals_) public {
        _assertGuardMintInvariantsAt(uint8(bound(uint256(decimals_), 0, 18)));
    }

    /// @dev The decimal-fault case. A backend that normalised supply to human units before handing it back would
    ///      pass 5 where the chain holds 5_000_000. The comparison is raw base units, so that must revert rather
    ///      than read as "5 USDC, close enough" — the estimate carries no scale of its own to reconcile.
    function test_GuardMint_6dp_RejectsADecimalAdjustedEstimate() public {
        StrandsCustodyToken usdc = _deployWithDecimals(6);
        vm.prank(minter);
        usdc.guardMint(alice, 5 * ONE_USDC, 0);
        assertEq(usdc.totalSupply(), 5 * ONE_USDC, "precondition: five whole USDC, i.e. 5_000_000 base units");

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.SupplyMismatch.selector, 5 * ONE_USDC, 5));
        usdc.guardMint(bob, ONE_USDC, 5);

        assertEq(usdc.totalSupply(), 5 * ONE_USDC, "a decimal-adjusted estimate must not be honoured");
    }

    /// @dev The general statement the three tests above are instances of: the same integer minted into tokens of
    ///      different decimals yields the same totalSupply, because decimals() is not part of the arithmetic.
    ///      The SECOND mint on each token is what gives this test teeth — it is the only one whose estimate is
    ///      non-zero, and a comparison scaled by decimals() would divide that estimate to a different number and
    ///      revert. A single mint from zero cannot detect the fault, because zero survives any division.
    function test_GuardMint_DecimalsDoNotAffectSupplyArithmetic() public {
        StrandsCustodyToken sixDp = _deployWithDecimals(6);
        StrandsCustodyToken eighteenDp = _deployWithDecimals(18);
        uint256 amount = 123_456_789;

        vm.startPrank(minter);
        sixDp.guardMint(bob, amount, 0);
        eighteenDp.guardMint(bob, amount, 0);
        sixDp.guardMint(bob, amount, amount);
        eighteenDp.guardMint(bob, amount, amount);
        vm.stopPrank();

        assertEq(sixDp.totalSupply(), eighteenDp.totalSupply(), "decimals() must not scale totalSupply");
        assertEq(sixDp.totalSupply(), 2 * amount, "the raw amount is the supply, at either magnitude");
        assertEq(sixDp.balanceOf(bob), eighteenDp.balanceOf(bob), "nor scale a holder's balance");
    }
}
