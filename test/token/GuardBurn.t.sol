// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { stdError } from "forge-std/StdError.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { BaseTest } from "../Base.t.sol";
import { StrandsDACAP } from "../../src/StrandsDACAP.sol";

/// @notice `guardBurn` — the supply-checked burn entrypoint and its MINTER_ROLE gate.
///
/// @dev    The mirror of `GuardMint.t.sol`, and deliberately structured the same way: the guard is the same
///         comparison against the same `totalSupply()`, so the same classes of fault apply (a zero read as a
///         sentinel, an amount-zero early-out, a decimals-scaled comparison) and the same tests kill them.
///
///         The role is mirrored too: `guardBurn` is MINTER_ROLE, as is every other burn entrypoint.
///         `BurnAuthority.t.sol` owns who may reach the burn surface at all; this file owns what the GUARD does
///         once they are through the gate.
contract GuardBurnTest is BaseTest {
    function test_MinterCanGuardBurn_WhenEstimateMatches() public {
        vm.prank(minter);
        token.guardBurn(alice, 50 ether, INITIAL_MINT);

        assertEq(token.balanceOf(alice), INITIAL_MINT - 50 ether);
        assertEq(token.totalSupply(), INITIAL_MINT - 50 ether);
    }

    function test_GuardBurn_RevertsOnWrongEstimate() public {
        vm.prank(minter);
        _expectSupplyMismatch(INITIAL_MINT, INITIAL_MINT - 1);
        token.guardBurn(alice, 50 ether, INITIAL_MINT - 1);

        assertEq(token.totalSupply(), INITIAL_MINT, "a refused burn must not change supply");
        assertEq(token.balanceOf(alice), INITIAL_MINT, "a refused burn must not debit the holder");
    }

    /// @dev The exact incident shape, in the burn direction: a supply moving AFTER the caller read it (here: a
    ///      mint between read and burn) must void the estimate. This is the atomicity a plain `adminBurn`
    ///      cannot give.
    function test_GuardBurn_RevertsWhenSupplyMovedAfterTheRead() public {
        uint256 estimate = token.totalSupply();

        vm.prank(minter);
        token.mint(bob, 1 ether);

        vm.prank(minter);
        _expectSupplyMismatch(INITIAL_MINT + 1 ether, estimate);
        token.guardBurn(alice, 50 ether, estimate);
    }

    // ---------- the role gate ----------

    function test_NonMinter_CannotGuardBurn() public {
        vm.prank(alice);
        _expectNotMinter(alice);
        token.guardBurn(alice, 1, INITIAL_MINT);
    }

    /// @dev A holder with a balance is refused here just as they are at every other burn entrypoint — owning
    ///      the tokens is not authority to destroy them. Written against `bob` rather than `alice` so the
    ///      refusal cannot be confused with a self-burn restriction, and paired with the minter succeeding on
    ///      the same call so the rejection is about the ROLE GATE and not the arguments.
    function test_FundedHolder_CannotGuardBurn() public {
        _allow(bob); // funding bob is a transfer like any other, so the route has to be open first

        vm.prank(alice);
        token.transfer(bob, 50 ether);

        vm.prank(bob);
        _expectNotMinter(bob);
        token.guardBurn(bob, 50 ether, INITIAL_MINT);

        assertEq(token.totalSupply(), INITIAL_MINT, "holding the balance is not authority to destroy it");

        vm.prank(minter);
        token.guardBurn(bob, 50 ether, INITIAL_MINT);
        assertEq(token.totalSupply(), INITIAL_MINT - 50 ether, "the identical call lands for the minter");
    }

    /// @dev The admin administers MINTER_ROLE but does not hold it, so it reaches `guardBurn` only through a
    ///      visible self-grant — the same escalation shape `AdminLifecycle.t.sol` pins for the other powers.
    function test_Admin_CannotGuardBurnWithoutASelfGrant() public {
        vm.prank(admin);
        _expectNotMinter(admin);
        token.guardBurn(alice, 1 ether, INITIAL_MINT);

        vm.prank(admin);
        token.grantRole(MINTER_ROLE, admin);

        vm.prank(admin);
        token.guardBurn(alice, 1 ether, INITIAL_MINT);
        assertEq(token.totalSupply(), INITIAL_MINT - 1 ether, "the escalation is available, but only in the open");
    }

    /// @dev No address is special. Bounded to an amount alice actually holds and an estimate that is actually
    ///      correct, so neither "insufficient balance" nor "wrong estimate" is an available explanation for
    ///      the rejection — only the missing role.
    function testFuzz_ArbitraryNonMinter_CannotGuardBurn(address caller, uint96 amount) public {
        vm.assume(caller != minter);
        uint256 value = bound(uint256(amount), 1, INITIAL_MINT);

        vm.prank(caller);
        _expectMissingRole(caller, MINTER_ROLE);
        token.guardBurn(alice, value, INITIAL_MINT);

        assertEq(token.totalSupply(), INITIAL_MINT, "no caller but the minter may take this path");
    }

    /// @dev Revoking MINTER_ROLE closes the guarded burn immediately — the same beat `Roles.t.sol` pins for
    ///      minting, restated here because a burn reached through the minter role is easy to forget when
    ///      reasoning about what a revocation costs.
    function test_RevokedMinter_LosesGuardBurnImmediately() public {
        vm.prank(admin);
        token.revokeRole(MINTER_ROLE, minter);

        vm.prank(minter);
        _expectNotMinter(minter);
        token.guardBurn(alice, 1 ether, INITIAL_MINT);

        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    // ---------- the guard itself ----------

    /// @dev The parameter is `uint256` rather than a narrower type because a wrong estimate is wrong at any
    ///      magnitude: a `uint96` draw explores the bottom 2^96 of the range and never reaches the top of it.
    function testFuzz_GuardBurn_AnyWrongEstimateReverts(uint256 estimate) public {
        uint256 supply = token.totalSupply();
        vm.assume(estimate != supply);

        vm.prank(minter);
        _expectSupplyMismatch(supply, estimate);
        token.guardBurn(alice, 1 ether, estimate);

        assertEq(token.totalSupply(), supply, "a refused burn must not change supply, whatever the estimate was");
    }

    // ---------- zero is a value, not a sentinel ----------
    //
    // The same pair of mutants `GuardMint.t.sol` documents applies verbatim here: a guard reading
    // `estimatedSupply == 0` as "unknown, skip the check", and an `amount == 0` early-out that returns before
    // the comparison. Both pass a suite in which every zero is only ever RIGHT.

    /// @dev A zero estimate against a funded token is the sentinel mutant's exact input, and must be refused
    ///      like any other wrong number.
    function test_GuardBurn_ZeroEstimate_RevertsAgainstANonZeroSupply() public {
        vm.prank(minter);
        _expectSupplyMismatch(INITIAL_MINT, 0);
        token.guardBurn(alice, 50 ether, 0);

        assertEq(token.totalSupply(), INITIAL_MINT, "a zero estimate is a wrong estimate, not a waiver");
        assertEq(token.balanceOf(alice), INITIAL_MINT);
    }

    /// @dev A zero-amount burn is a legitimate no-op — the backend acts on a delta, and a delta of zero is
    ///      what a reconciliation pass finds when nothing moved. It must succeed and change nothing.
    function test_GuardBurn_ZeroAmount_SucceedsAndMovesNothing() public {
        _expectTransferEvent(alice, address(0), 0);
        vm.prank(minter);
        token.guardBurn(alice, 0, INITIAL_MINT);

        assertEq(token.totalSupply(), INITIAL_MINT, "a zero delta leaves supply exactly where it was");
        assertEq(token.balanceOf(alice), INITIAL_MINT);
    }

    /// @dev And it is still GUARDED. This is the test that kills an `if (amount == 0) return;` early-out:
    ///      under that mutant the call below succeeds silently, telling a backend with a stale read that its
    ///      estimate was accepted — the precise false confirmation the guard exists to prevent.
    function test_GuardBurn_ZeroAmount_StillRejectsAWrongEstimate() public {
        vm.prank(minter);
        _expectSupplyMismatch(INITIAL_MINT, INITIAL_MINT - 1);
        token.guardBurn(alice, 0, INITIAL_MINT - 1);

        assertEq(token.totalSupply(), INITIAL_MINT, "a refused no-op is still a refusal");
    }

    /// @dev A zero-amount burn against an EMPTY token: both zeros at once, on the one supply where a zero
    ///      estimate is right. The mint-side equivalent is `test_GuardMint_ZeroAmountAndZeroEstimate_...`.
    function test_GuardBurn_ZeroAmountAndZeroEstimate_OnAnEmptyToken() public {
        StrandsDACAP t = _deployWithDecimals(18);

        vm.prank(minter);
        t.guardBurn(alice, 0, 0);
        assertEq(t.totalSupply(), 0, "a no-op burn on an empty token leaves it empty");

        // ...and the path is not wedged: the next call's estimate is still zero.
        vm.prank(minter);
        t.guardMint(alice, 1 ether, 0);
        assertEq(t.totalSupply(), 1 ether);
    }

    // ---------- what a caller observes ----------

    /// @dev Two audiences, two events. An indexer reconciling balances reads `Transfer(from, 0x0, amount)`, so
    ///      the guarded path must be indistinguishable from any other burn there; a reconciler tracking the
    ///      off-chain ledger reads {Burned}, which is the invariant this contract asks it to rely on.
    ///      Both are asserted because a burn visible to only one of them is the failure this event exists to
    ///      prevent.
    function test_GuardBurn_EmitsBurnedAndTransferToZero() public {
        _expectTransferEvent(alice, address(0), 50 ether);
        _expectBurnedEvent(minter, alice, 50 ether);

        vm.prank(minter);
        token.guardBurn(alice, 50 ether, INITIAL_MINT);
    }

    /// @dev The `burnedBy` parameter reports WHOEVER burned, not the fixture's own minter — pinned with a
    ///      second, freshly granted minter so a hardcoded `msg.sender` substitute would go red.
    function test_GuardBurn_ReportsTheActualBurner() public {
        vm.prank(admin);
        token.grantRole(MINTER_ROLE, carol);

        _expectBurnedEvent(carol, alice, 10 ether);
        vm.prank(carol);
        token.guardBurn(alice, 10 ether, INITIAL_MINT);
    }

    /// @dev What separates `guardBurn` from `burnFrom`: it needs no allowance and spends none. A minter that
    ///      quietly consumed an allowance would make a holder's approval to some unrelated spender evaporate.
    function test_GuardBurn_NeedsNoAllowanceAndConsumesNone() public {
        vm.prank(alice);
        token.approve(minter, 200 ether);

        vm.prank(minter);
        token.guardBurn(alice, 50 ether, INITIAL_MINT);

        assertEq(token.allowance(alice, minter), 200 ether, "the allowance must be untouched");
        assertEq(token.totalSupply(), INITIAL_MINT - 50 ether, "and the burn needed none of it");
    }

    /// @dev The zero-allowance half of the same claim: with no approval at all the burn still goes through.
    function test_GuardBurn_WorksWithNoAllowanceAtAll() public {
        assertEq(token.allowance(alice, minter), 0, "precondition: alice has approved nobody");

        vm.prank(minter);
        token.guardBurn(alice, 50 ether, INITIAL_MINT);

        assertEq(token.balanceOf(alice), INITIAL_MINT - 50 ether);
    }

    /// @dev The operator's remedy: a refusal is recoverable by re-reading and retrying. `SupplyMismatch`
    ///      carries `actualSupply` precisely so the corrected estimate is in the revert data — this asserts
    ///      that value is usable, not merely present, and that the retry burns once rather than twice.
    function test_GuardBurn_RetryWithTheCorrectedEstimateSucceeds() public {
        uint256 stale = INITIAL_MINT - 1;

        vm.prank(minter);
        _expectSupplyMismatch(INITIAL_MINT, stale);
        token.guardBurn(alice, 50 ether, stale);

        vm.prank(minter);
        token.guardBurn(alice, 50 ether, INITIAL_MINT); // the `actualSupply` the revert just reported

        assertEq(token.totalSupply(), INITIAL_MINT - 50 ether, "a refusal must not latch the burn path shut");
        assertEq(token.balanceOf(alice), INITIAL_MINT - 50 ether, "and the retry burns exactly once, not twice");
    }

    // ---------- boundaries ----------

    /// @dev `_burn` is reached DIRECTLY rather than through `adminBurn`, so ERC20's own balance check
    ///      arrives by a different route and is worth stating once. The guard must not mask it: an
    ///      over-burn is an insufficient-balance fault, not a supply mismatch, and misreporting it would
    ///      send an operator re-reading a supply that was never the problem.
    function test_GuardBurn_ExceedingBalance_RevertsWithInsufficientBalance() public {
        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, alice, INITIAL_MINT, INITIAL_MINT + 1
            )
        );
        token.guardBurn(alice, INITIAL_MINT + 1, INITIAL_MINT);

        assertEq(token.totalSupply(), INITIAL_MINT, "a failed burn must leave supply where it was");
    }

    /// @dev A correct estimate does not license burning from an address with no balance at all.
    function test_GuardBurn_FromAnEmptyHolder_Reverts() public {
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1));
        token.guardBurn(bob, 1, INITIAL_MINT);
    }

    /// @dev The mirror of `guardMint`'s zero-recipient case, reached through `_burn`'s own sender check.
    function test_GuardBurn_FromTheZeroAddress_Reverts() public {
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.guardBurn(address(0), 0, INITIAL_MINT);
    }

    /// @dev Burning the supply to exactly zero must work, and must leave the token re-mintable from a zero
    ///      estimate. The two guards have to agree on what "empty" means, or a fully-redeemed token could
    ///      never be re-minted without a redeploy.
    function test_GuardBurn_ToZeroSupply_LeavesTheTokenReMintable() public {
        vm.prank(minter);
        token.guardBurn(alice, INITIAL_MINT, INITIAL_MINT);
        assertEq(token.totalSupply(), 0, "the entire supply is destroyed");

        vm.prank(minter);
        token.guardMint(bob, 50 ether, 0);
        assertEq(token.totalSupply(), 50 ether, "zero is the real supply here, so the mint guard must honour it");
    }

    /// @dev At the ceiling the guard still gates, and still does not mask arithmetic — the burn-side
    ///      counterpart of `test_GuardMint_AtMaxSupply_GatesAndLetsOverflowPanic`. Burning more than the
    ///      supply from a holder who holds all of it is ERC20's insufficient-balance error, not a panic;
    ///      the panic case is the mint side's.
    function test_GuardBurn_AtMaxSupply_StillGates() public {
        StrandsDACAP t = _deployWithDecimals(18);

        vm.prank(minter);
        t.guardMint(bob, type(uint256).max, 0);
        assertEq(t.totalSupply(), type(uint256).max, "precondition: supply is at the ceiling");

        vm.prank(minter);
        _expectSupplyMismatch(type(uint256).max, type(uint256).max - 1);
        t.guardBurn(bob, 1, type(uint256).max - 1);

        vm.prank(minter);
        t.guardBurn(bob, 1, type(uint256).max); // a matching estimate still passes at the extreme
        assertEq(t.totalSupply(), type(uint256).max - 1);
    }

    // ---------- every path that moves supply ----------
    //
    // The guard reads `totalSupply()` and nothing else, so ANY entrypoint that moves it must void an estimate
    // read beforehand. `mint` and `guardMint` move it up; `adminBurn`, `burn` and `burnFrom` move it down.
    // Which of them the estimate was invalidated by is the property under test, not an accident of ordering.

    enum MintPath {
        Plain,
        Guarded
    }

    /// @dev The supply is read BEFORE the prank on purpose: a `token.*` call in the argument list is still an
    ///      external call, and it would consume the cheatcode so that `guardMint` ran unpranked and failed the
    ///      role gate. Same reason `Base.t.sol` caches the role ids.
    function _mintVia(MintPath path, address to, uint256 amount) private {
        uint256 supply = token.totalSupply();

        vm.prank(minter);
        if (path == MintPath.Plain) {
            token.mint(to, amount);
        } else {
            token.guardMint(to, amount, supply);
        }
    }

    /// @dev One statement, two entrypoints: a mint voids an estimate read before it, AND the post-mint supply
    ///      is the estimate the guard then accepts. The second half matters as much as the first — a guard
    ///      that refused everything after a mint would pass a revert-only test while bricking the burn path.
    function _assertGuardTracksSupplyMintedVia(MintPath path) private {
        uint256 estimate = token.totalSupply();

        _mintVia(path, bob, 100 ether);
        uint256 postMint = estimate + 100 ether;
        assertEq(token.totalSupply(), postMint, "precondition: this path issued exactly 100 ether");

        vm.prank(minter);
        _expectSupplyMismatch(postMint, estimate);
        token.guardBurn(alice, 50 ether, estimate);
        assertEq(token.totalSupply(), postMint, "a refused burn must not move supply");

        vm.prank(minter);
        token.guardBurn(alice, 50 ether, postMint);
        assertEq(token.totalSupply(), postMint - 50 ether, "the corrected estimate goes through");
    }

    function test_GuardBurn_TracksSupplyMintedVia_Mint() public {
        _assertGuardTracksSupplyMintedVia(MintPath.Plain);
    }

    function test_GuardBurn_TracksSupplyMintedVia_GuardMint() public {
        _assertGuardTracksSupplyMintedVia(MintPath.Guarded);
    }

    /// @dev And the unguarded burn paths move it the other way. An operator reaching for `adminBurn` between
    ///      the backend's read and its send is the realistic production interleaving — two independent
    ///      parties, one supply — and it is precisely the case `adminBurn` itself cannot detect.
    function test_GuardBurn_TracksSupplyBurnedByAdminBurn() public {
        uint256 estimate = token.totalSupply();

        vm.prank(minter);
        token.adminBurn(alice, 100 ether);

        vm.prank(minter);
        _expectSupplyMismatch(INITIAL_MINT - 100 ether, estimate);
        token.guardBurn(alice, 50 ether, estimate);

        vm.prank(minter);
        token.guardBurn(alice, 50 ether, INITIAL_MINT - 100 ether);
        assertEq(token.totalSupply(), INITIAL_MINT - 150 ether);
    }

    /// @dev The burn-side race, and the likelier production incident: two minters (a retried job, two backend
    ///      replicas) read the same supply, and only the first may act on it. The second's estimate is stale
    ///      for a reason no other party caused, and must be refused rather than double-burning the same delta.
    function test_GuardBurn_SecondMinterActingOnTheSameReadIsRefused() public {
        vm.prank(admin);
        token.grantRole(MINTER_ROLE, carol);

        uint256 sharedRead = token.totalSupply();

        vm.prank(minter);
        token.guardBurn(alice, 50 ether, sharedRead);

        vm.prank(carol);
        _expectSupplyMismatch(sharedRead - 50 ether, sharedRead);
        token.guardBurn(alice, 50 ether, sharedRead);

        assertEq(token.balanceOf(alice), INITIAL_MINT - 50 ether, "the delta lands once, not once per replica");
        assertEq(token.totalSupply(), INITIAL_MINT - 50 ether);
    }

    // ---------- interleaved mints and burns ----------

    /// @dev The general claim the scripted tests above are instances of: through ANY interleaving of guarded
    ///      burns and mints, the estimate the guard accepts is exactly the running supply — and the one next
    ///      to it is refused. Every step asserts both directions, so a guard that drifted by one, or that
    ///      latched after the first mint, fails here even having passed every fixed script. Burn amounts are
    ///      drawn from 0 upward, so zero-amount burns occur INSIDE the sequence too, at supplies no fixed test
    ///      visits.
    function testFuzz_GuardBurn_TracksSupplyThroughAnyMintBurnSequence(uint8 steps, uint256 seed) public {
        uint256 supply = token.totalSupply();
        uint256 n = bound(uint256(steps), 1, 16);

        for (uint256 i = 0; i < n; i++) {
            // A fresh draw per step — `seed` alone would make every iteration take the same branch.
            uint256 draw = uint256(keccak256(abi.encode(seed, i)));
            bool minting = (draw & 1 == 1) || token.balanceOf(alice) == 0;

            if (minting) {
                uint256 amount = bound(draw >> 1, 1, 1_000 ether);
                vm.prank(minter);
                token.mint(alice, amount);
                supply += amount;
            } else {
                uint256 amount = bound(draw >> 1, 0, token.balanceOf(alice));

                // The neighbouring estimate must be refused at EVERY point in the sequence, not just the first.
                if (supply != 0) {
                    vm.prank(minter);
                    _expectSupplyMismatch(supply, supply - 1);
                    token.guardBurn(alice, amount, supply - 1);
                }

                vm.prank(minter);
                token.guardBurn(alice, amount, supply);
                supply -= amount;
            }

            assertEq(token.totalSupply(), supply, "the running supply is the guard's contract with the caller");
        }
    }

    // ---------- decimals independence ----------
    //
    // `decimals()` is ERC20 display metadata and never enters `totalSupply` or `_burn`, both raw uint256, so
    // the guard's comparison is in native base units by construction. Real deployments are mostly not 18: usdc
    // is 6 and btc is 8. These pin that — if a change ever scaled by `decimals()`, every 18-dp test above would
    // still pass while every real USDC and BTC token broke.
    //
    // Killing a scaling mutant needs reachability, INFECTION (the mutated expression yields a different value)
    // and propagation to an assertion. Zero is a fixed point of division, so a step whose estimate is zero has
    // only the first. Hence the rule these follow: every magnitude is exercised with a NON-ZERO estimate.

    uint256 internal constant ONE_USDC = 1e6;

    /// @dev The whole guard contract, asserted at ONE magnitude. Every step works in raw base units and none
    ///      of the expectations mention `decimals_`, which is the property under test: the same script must
    ///      produce the same numbers at 6, 8 and 18. `amount` is deliberately not a whole number of display
    ///      units at any magnitude, so a scaling fault cannot coincidentally land on the right answer.
    function _assertGuardBurnInvariantsAt(uint8 decimals_) private {
        StrandsDACAP t = _deployWithDecimals(decimals_);
        assertEq(t.decimals(), decimals_, "precondition: the token reports the magnitude under test");

        uint256 amount = 123_456_789;

        vm.prank(minter);
        t.guardMint(bob, 3 * amount, 0);
        assertEq(t.totalSupply(), 3 * amount, "precondition: the raw amount is the supply");

        // 1. A NON-ZERO estimate must be the raw supply. This is the step with teeth: a comparison scaled by
        //    decimals() would divide it to a different number and revert.
        vm.prank(minter);
        t.guardBurn(bob, amount, 3 * amount);
        assertEq(t.totalSupply(), 2 * amount, "a matching raw estimate burns the raw amount");
        assertEq(t.balanceOf(bob), 2 * amount);

        // 2. A stale estimate reverts, and the revert DATA carries raw base units at every magnitude — that
        //    data is the diagnosis an operator reads, so a scaled `actual` would misreport the chain's state.
        vm.prank(minter);
        _expectSupplyMismatch(2 * amount, 3 * amount);
        t.guardBurn(bob, amount, 3 * amount);
        assertEq(t.totalSupply(), 2 * amount, "a refused burn must not move supply");
        assertEq(t.balanceOf(bob), 2 * amount, "nor debit the holder");

        // 3. A decimal-adjusted estimate — supply expressed in display units — must be refused rather than
        //    read as "close enough". Skipped at 0 dp, where the scaled value IS the raw one and there is no
        //    fault to express (that is also why 0 dp cannot detect a scaling mutant).
        if (decimals_ > 0) {
            uint256 displayUnits = (2 * amount) / (10 ** decimals_);
            vm.prank(minter);
            _expectSupplyMismatch(2 * amount, displayUnits);
            t.guardBurn(bob, amount, displayUnits);
        }

        // 4. The guard tracks whatever moved supply, not just burns: after a mint the estimate must be the NEW
        //    raw supply. Pairs the guarded burn with the mint path at every magnitude.
        vm.prank(minter);
        t.mint(bob, amount);
        assertEq(t.totalSupply(), 3 * amount, "the mint adds exactly the raw amount");

        vm.prank(minter);
        t.guardBurn(bob, amount, 3 * amount);
        assertEq(t.totalSupply(), 2 * amount, "the post-mint supply is the estimate the guard now expects");
    }

    function test_GuardBurn_Invariants_At6Decimals() public {
        _assertGuardBurnInvariantsAt(6); // usdc
    }

    function test_GuardBurn_Invariants_At8Decimals() public {
        _assertGuardBurnInvariantsAt(8); // btc
    }

    function test_GuardBurn_Invariants_At18Decimals() public {
        _assertGuardBurnInvariantsAt(18); // eth / hteth
    }

    /// @dev The general form of the three above: no magnitude in the ERC20 range changes the guard's
    ///      behaviour. The named cases are kept alongside it because they fail deterministically at the
    ///      magnitudes actually deployed, whereas a fuzz run only reaches them by chance.
    function testFuzz_GuardBurn_InvariantsHoldAtAnyDecimals(uint8 decimals_) public {
        _assertGuardBurnInvariantsAt(uint8(bound(uint256(decimals_), 0, 18)));
    }

    /// @dev The decimal-fault case. A backend that normalised supply to human units before handing it back
    ///      would pass 5 where the chain holds 5_000_000. The comparison is raw base units, so that must
    ///      revert rather than read as "5 USDC, close enough" — the estimate carries no scale of its own.
    function test_GuardBurn_6dp_RejectsADecimalAdjustedEstimate() public {
        StrandsDACAP usdc = _deployWithDecimals(6);
        vm.prank(minter);
        usdc.guardMint(alice, 5 * ONE_USDC, 0);
        assertEq(usdc.totalSupply(), 5 * ONE_USDC, "precondition: five whole USDC, i.e. 5_000_000 base units");

        vm.prank(minter);
        _expectSupplyMismatch(5 * ONE_USDC, 5);
        usdc.guardBurn(alice, ONE_USDC, 5);

        assertEq(usdc.totalSupply(), 5 * ONE_USDC, "a decimal-adjusted estimate must not be honoured");
    }

    /// @dev The general statement the three tests above are instances of: the same integer burned from tokens
    ///      of different decimals yields the same totalSupply, because decimals() is not part of the
    ///      arithmetic. The burns are what give this teeth — their estimates are non-zero, and a comparison
    ///      scaled by decimals() would divide them to a different number and revert.
    function test_GuardBurn_DecimalsDoNotAffectSupplyArithmetic() public {
        StrandsDACAP sixDp = _deployWithDecimals(6);
        StrandsDACAP eighteenDp = _deployWithDecimals(18);
        uint256 amount = 123_456_789;

        vm.startPrank(minter);
        sixDp.guardMint(bob, 2 * amount, 0);
        eighteenDp.guardMint(bob, 2 * amount, 0);
        sixDp.guardBurn(bob, amount, 2 * amount);
        eighteenDp.guardBurn(bob, amount, 2 * amount);
        vm.stopPrank();

        assertEq(sixDp.totalSupply(), eighteenDp.totalSupply(), "decimals() must not scale totalSupply");
        assertEq(sixDp.totalSupply(), amount, "the raw amount is the supply, at either magnitude");
        assertEq(sixDp.balanceOf(bob), eighteenDp.balanceOf(bob), "nor scale a holder's balance");
    }
}
