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
    ///      The parameter is `uint256` rather than a narrower type because a wrong estimate is wrong at any
    ///      magnitude: a `uint96` draw explores the bottom 2^96 of the range and never reaches the top of it.
    function testFuzz_GuardMint_AnyWrongEstimateReverts(uint256 estimate) public {
        uint256 supply = token.totalSupply();
        vm.assume(estimate != supply);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.SupplyMismatch.selector, supply, estimate));
        token.guardMint(bob, 1 ether, estimate);

        assertEq(token.totalSupply(), supply, "a refused mint must not change supply, whatever the estimate was");
    }

    // ---------- zero is a value, not a sentinel ----------
    //
    // Every test above this line that passes `estimatedSupply == 0` does so on a token whose supply IS zero, and
    // every test that mints passes a non-zero `amount`. Both zeros are therefore only ever RIGHT, which is exactly
    // the input at which a special case hides: a guard reading `estimatedSupply == 0` as "unknown, skip the
    // check", or an `amount == 0` early-out that returns before the comparison, passes the whole suite as it
    // stands. These pin both zeros as ordinary values — checked like any other, correct only when actually right.

    /// @dev The deterministic form of a case `testFuzz_GuardMint_AnyWrongEstimateReverts` only reaches by chance.
    ///      A zero estimate against a funded token is the sentinel mutant's exact input, and it must be refused
    ///      like any other wrong number.
    function test_GuardMint_ZeroEstimate_RevertsAgainstANonZeroSupply() public {
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.SupplyMismatch.selector, INITIAL_MINT, 0));
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
        vm.expectRevert(
            abi.encodeWithSelector(StrandsCustodyToken.SupplyMismatch.selector, INITIAL_MINT, INITIAL_MINT - 1)
        );
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

    // ---------- what a caller observes ----------

    /// @dev No test above asserts that `guardMint` mints via the ordinary ERC20 event, only that balances move.
    ///      An indexer reconciling the ledger reads `Transfer(0x0, to, amount)`, so the guarded path must be
    ///      indistinguishable from plain `mint` once the estimate passes.
    function test_GuardMint_EmitsTransferFromTheZeroAddress() public {
        _expectTransferEvent(address(0), bob, 50 ether);
        vm.prank(minter);
        token.guardMint(bob, 50 ether, INITIAL_MINT);
    }

    /// @dev The operator's remedy: a refusal is recoverable by re-reading and retrying. `SupplyMismatch` carries
    ///      `actualSupply` precisely so the corrected estimate is in the revert data — this asserts that value
    ///      is usable, not merely present, and that the retry mints once rather than replaying the refused call.
    function test_GuardMint_RetryWithTheCorrectedEstimateSucceeds() public {
        uint256 stale = INITIAL_MINT - 1;

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.SupplyMismatch.selector, INITIAL_MINT, stale));
        token.guardMint(bob, 50 ether, stale);

        vm.prank(minter);
        token.guardMint(bob, 50 ether, INITIAL_MINT); // the `actualSupply` the revert just reported

        assertEq(token.totalSupply(), INITIAL_MINT + 50 ether, "a refusal must not latch the mint path shut");
        assertEq(token.balanceOf(bob), 50 ether, "and the retry mints exactly once, not twice");
    }

    // ---------- every path that moves supply ----------
    //
    // `custodyBurn` is the only supply-moving call the guard has ever been paired with. `burn` and `burnFrom`
    // reduce totalSupply by exactly as much, and a concurrent MINT moves it the other way. The guard reads
    // `totalSupply()` and nothing else, so all four are interchangeable here — which is the property under test,
    // not an accident of how these are written.

    enum BurnPath {
        Custody,
        Self,
        From
    }

    /// @dev Destroy `amount` of `from`'s balance through `path`, doing whatever setup that path requires.
    ///      `BurnAuthority.t.sol` owns which caller may use which entrypoint; here they differ only in route.
    function _burnVia(BurnPath path, address from, uint256 amount) private {
        if (path == BurnPath.Custody) {
            vm.prank(custodian);
            token.custodyBurn(from, amount);
        } else if (path == BurnPath.Self) {
            vm.prank(from); // `burn` destroys the CALLER's balance, so it has to be the custodian's first
            token.transfer(custodian, amount);
            vm.prank(custodian);
            token.burn(amount);
        } else {
            vm.prank(from);
            token.approve(custodian, amount);
            vm.prank(custodian);
            token.burnFrom(from, amount);
        }
    }

    /// @dev One statement, three entrypoints: a burn voids an estimate read before it, AND the post-burn supply
    ///      is the estimate the guard then accepts. The second half matters as much as the first — a guard that
    ///      refused everything after a burn would pass a revert-only test while bricking the mint path.
    function _assertGuardTracksSupplyBurnedVia(BurnPath path) private {
        uint256 estimate = token.totalSupply();

        _burnVia(path, alice, 100 ether);
        uint256 postBurn = estimate - 100 ether;
        assertEq(token.totalSupply(), postBurn, "precondition: this path destroyed exactly 100 ether");

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.SupplyMismatch.selector, postBurn, estimate));
        token.guardMint(bob, 50 ether, estimate);
        assertEq(token.totalSupply(), postBurn, "a refused mint must not move supply");

        vm.prank(minter);
        token.guardMint(bob, 50 ether, postBurn);
        assertEq(token.totalSupply(), postBurn + 50 ether, "the corrected estimate goes through");
        assertEq(token.balanceOf(bob), 50 ether);
    }

    function test_GuardMint_TracksSupplyBurnedVia_CustodyBurn() public {
        _assertGuardTracksSupplyBurnedVia(BurnPath.Custody);
    }

    function test_GuardMint_TracksSupplyBurnedVia_Burn() public {
        _assertGuardTracksSupplyBurnedVia(BurnPath.Self);
    }

    function test_GuardMint_TracksSupplyBurnedVia_BurnFrom() public {
        _assertGuardTracksSupplyBurnedVia(BurnPath.From);
    }

    /// @dev The mint-side race, and the likelier production incident: two minters (a retried job, two backend
    ///      replicas) read the same supply, and only the first may act on it. The second's estimate is stale for
    ///      a reason no burn caused, and must be refused rather than double-minting the same delta.
    function test_GuardMint_SecondMinterActingOnTheSameReadIsRefused() public {
        vm.prank(admin);
        token.grantRole(MINTER_ROLE, carol);

        uint256 sharedRead = token.totalSupply();

        vm.prank(minter);
        token.guardMint(bob, 50 ether, sharedRead);

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(StrandsCustodyToken.SupplyMismatch.selector, sharedRead + 50 ether, sharedRead)
        );
        token.guardMint(bob, 50 ether, sharedRead);

        assertEq(token.balanceOf(bob), 50 ether, "the delta lands once, not once per replica");
        assertEq(token.totalSupply(), INITIAL_MINT + 50 ether);
    }

    // ---------- interleaved mints and burns ----------

    /// @dev The general claim the scripted tests above are instances of: through ANY interleaving of guarded
    ///      mints and burns, the estimate the guard accepts is exactly the running supply — and the one next to
    ///      it is refused. Every step asserts both directions, so a guard that drifted by one, or that latched
    ///      after the first burn, fails here even having passed every fixed script. Mint amounts are drawn from
    ///      0 upward, so zero-amount mints occur INSIDE the sequence too, at supplies no fixed test visits.
    function testFuzz_GuardMint_TracksSupplyThroughAnyMintBurnSequence(uint8 steps, uint256 seed) public {
        uint256 supply = token.totalSupply();
        uint256 n = bound(uint256(steps), 1, 16);

        for (uint256 i = 0; i < n; i++) {
            // A fresh draw per step — `seed` alone would make every iteration take the same branch.
            uint256 draw = uint256(keccak256(abi.encode(seed, i)));
            bool burning = (draw & 1 == 1) && token.balanceOf(alice) > 0;

            if (burning) {
                uint256 amount = bound(draw >> 1, 1, token.balanceOf(alice));
                vm.prank(custodian);
                token.custodyBurn(alice, amount);
                supply -= amount;
            } else {
                uint256 amount = bound(draw >> 1, 0, 1_000 ether);

                // The neighbouring estimate must be refused at EVERY point in the sequence, not just the first.
                if (supply != 0) {
                    vm.prank(minter);
                    vm.expectRevert(
                        abi.encodeWithSelector(StrandsCustodyToken.SupplyMismatch.selector, supply, supply - 1)
                    );
                    token.guardMint(alice, amount, supply - 1);
                }

                vm.prank(minter);
                token.guardMint(alice, amount, supply);
                supply += amount;
            }

            assertEq(token.totalSupply(), supply, "the running supply is the guard's contract with the caller");
        }
    }

    // ---------- boundaries ----------

    /// @dev `guardMint` calls `_mint` DIRECTLY rather than through `mint` (see its @dev note), so ERC20's own
    ///      recipient check is reached by a different route and is worth stating once.
    function test_GuardMint_ToTheZeroAddress_Reverts() public {
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.guardMint(address(0), 50 ether, INITIAL_MINT);

        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev At the ceiling the guard still gates — a zero-amount mint with the right estimate goes through — and
    ///      still does not mask arithmetic: the overflow surfaces as ERC20's own panic, not as a silent no-op or
    ///      a SupplyMismatch that would misdiagnose the failure to whoever reads the revert.
    function test_GuardMint_AtMaxSupply_GatesAndLetsOverflowPanic() public {
        StrandsCustodyToken t = _deployWithDecimals(18);

        vm.prank(minter);
        t.guardMint(bob, type(uint256).max, 0);
        assertEq(t.totalSupply(), type(uint256).max, "precondition: supply is at the ceiling");

        vm.prank(minter);
        t.guardMint(bob, 0, type(uint256).max); // a matching estimate still passes at the extreme

        vm.prank(minter);
        vm.expectRevert(stdError.arithmeticError);
        t.guardMint(bob, 1, type(uint256).max);

        assertEq(t.totalSupply(), type(uint256).max, "an overflowing mint must leave supply where it was");
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
