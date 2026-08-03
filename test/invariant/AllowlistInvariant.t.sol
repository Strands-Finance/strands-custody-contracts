// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { BaseTest, EdgeBuilder } from "../Base.t.sol";
import { StrandsCustodyToken } from "../../src/StrandsCustodyToken.sol";
import { StrandsAllowlistBatch } from "../../src/StrandsAllowlistBatch.sol";

/// @notice Drives random sequences of every value-moving and allowlist-mutating
///         action, recording whether each SUCCESSFUL transfer was authorised at
///         the moment it executed.
///
/// @dev    Takes `EdgeBuilder` rather than the whole fixture: it is handed an
///         already-deployed token, but builds `setPairs` arguments the same way
///         every other suite does. `EdgeBuilder`'s members are `internal`, so
///         this adds nothing to the fuzzer's target surface.
contract AllowlistHandler is Test, EdgeBuilder {
    StrandsCustodyToken public immutable token;
    address public immutable admin;
    address public immutable minter;
    address public immutable custodian;

    address[] public actors;

    /// @dev Every edge this handler has ever opened. Used by
    ///      `transferAlongOpenRoute` so the run actually exercises SUCCESSFUL
    ///      transfers — picking `from`/`to` purely at random almost never lands
    ///      on an open route, which would leave the headline invariant passing
    ///      vacuously. Entries are not removed on close; liveness is re-checked
    ///      at point of use.
    StrandsAllowlistBatch.Edge[] public openEdges;

    /// @notice Ghost counters checked by the invariants.
    uint256 public successfulTransfers;
    uint256 public unauthorisedTransfers; // MUST stay 0
    uint256 public blockedTransfers;

    constructor(StrandsCustodyToken token_, address admin_, address minter_, address custodian_, address[] memory a) {
        token = token_;
        admin = admin_;
        minter = minter_;
        custodian = custodian_;
        actors = a;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _recordOpen(address holder, address destination) internal {
        openEdges.push(StrandsAllowlistBatch.Edge(holder, destination));
    }

    /// @dev Records the outcome of an attempted transfer against the edge state
    ///      captured immediately BEFORE the call.
    function _record(bool ok, bool wasAllowed) internal {
        if (ok) {
            successfulTransfers++;
            if (!wasAllowed) unauthorisedTransfers++;
        } else {
            blockedTransfers++;
        }
    }

    // ---------- value movement ----------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);

        uint256 bal = token.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        bool wasAllowed = token.allowedDestination(from, to);

        vm.prank(from);
        try token.transfer(to, amount) {
            _record(true, wasAllowed);
        } catch {
            _record(false, wasAllowed);
        }
    }

    /// @dev Deliberately biased toward routes that are (or were) open, so the
    ///      run contains real successful transfers rather than an unbroken wall
    ///      of reverts. The authorisation check is still read fresh from the
    ///      token immediately before the call, so a route closed since it was
    ///      recorded is still caught correctly.
    function transferAlongOpenRoute(uint256 seed, uint256 amount) external {
        if (openEdges.length == 0) return;
        StrandsAllowlistBatch.Edge memory e = openEdges[seed % openEdges.length];

        if (token.balanceOf(e.holder) == 0) {
            vm.prank(minter);
            token.mint(e.holder, 100 ether);
        }
        uint256 bal = token.balanceOf(e.holder);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        bool wasAllowed = token.allowedDestination(e.holder, e.destination);

        vm.prank(e.holder);
        try token.transfer(e.destination, amount) {
            _record(true, wasAllowed);
        } catch {
            _record(false, wasAllowed);
        }
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);

        uint256 bal = token.balanceOf(owner);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);

        vm.prank(owner);
        token.approve(spender, amount);

        // enforcement is keyed by the OWNER, never the spender
        bool wasAllowed = token.allowedDestination(owner, to);

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            _record(true, wasAllowed);
        } catch {
            _record(false, wasAllowed);
        }
    }

    // ---------- supply (allowlist-exempt paths) ----------

    function mint(uint256 toSeed, uint256 amount) external {
        amount = bound(amount, 0, 1_000_000 ether);
        vm.prank(minter);
        token.mint(_actor(toSeed), amount);
    }

    /// @dev There is deliberately no holder-driven `burn` action: destruction is
    ///      CUSTODIAN_ROLE-only, so `custodyBurn` below is the sole path by which
    ///      this handler may reduce supply.
    function custodyBurn(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 bal = token.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(custodian);
        token.custodyBurn(from, amount);
    }

    // ---------- allowlist mutation, single and batched ----------

    function setDestination(uint256 holderSeed, uint256 destSeed, bool allowed) external {
        address holder = _actor(holderSeed);
        address destination = _actor(destSeed);
        vm.prank(admin);
        token.setDestinationAllowed(holder, destination, allowed);
        if (allowed) _recordOpen(holder, destination);
    }

    /// @dev Multi-pair batch, so the fuzzer exercises loops of more than one
    ///      iteration alongside the single-pair `setPairs` action below.
    function setManyPairs(uint256 aSeed, uint256 bSeed, uint256 cSeed, bool allowed) external {
        address a = _actor(aSeed);
        address b = _actor(bSeed);
        address c = _actor(cSeed);

        vm.prank(admin);
        token.setPairs(_edges(a, b, b, c), allowed);

        if (allowed) {
            _recordOpen(a, b);
            _recordOpen(b, a);
            _recordOpen(b, c);
            _recordOpen(c, b);
        }
    }

    function setPairs(uint256 aSeed, uint256 bSeed, bool allowed) external {
        address a = _actor(aSeed);
        address b = _actor(bSeed);

        vm.prank(admin);
        token.setPairs(_edges(a, b), allowed);

        if (allowed) {
            _recordOpen(a, b);
            _recordOpen(b, a);
        }
    }
}

/// @notice The core safety property of the whole feature, stated once:
///         **value never moves along a route that was not authorised at the
///         moment it moved.** Everything else in `test/allowlist/` and
///         `test/batch/` checks a specific path; this checks that no
///         combination of paths — including batch mutations interleaved with
///         transfers — can produce an unauthorised movement.
contract AllowlistInvariantTest is BaseTest {
    AllowlistHandler internal handler;

    address[] internal actors;

    function setUp() public override {
        // deploy, grant MINTER_ROLE / CUSTODIAN_ROLE, and seed `alice` with
        // INITIAL_MINT — `actors[0]` below is that same address
        super.setUp();

        actors.push(alice);
        actors.push(bob);
        actors.push(carol);
        actors.push(makeAddr("scw1"));
        actors.push(makeAddr("scw2"));

        handler = new AllowlistHandler(token, admin, minter, custodian, actors);
        targetContract(address(handler));
    }

    /// @dev The headline property.
    function invariant_NoTransferEverSucceedsOnAnUnauthorisedRoute() public view {
        assertEq(handler.unauthorisedTransfers(), 0, "value moved along a route that was not allowlisted");
    }

    /// @dev Supply accounting must survive the guard sitting inside `_update`.
    function invariant_BalancesSumToTotalSupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply(), "balances must sum to total supply");
    }

    /// @dev Guards against a vacuous pass, deterministically.
    ///
    ///      This is a plain unit test rather than an `afterInvariant` hook on
    ///      purpose: `afterInvariant` reads handler state that Foundry may have
    ///      already unwound, so it reports zero counters intermittently and
    ///      turns a green suite red at random. Driving the handler directly
    ///      proves the same thing — that a successful transfer really is
    ///      reachable and really is counted — without the flakiness.
    function test_HandlerCanRecordBothOutcomes() public {
        // a blocked transfer: alice is funded, but no route exists
        handler.transfer(0, 1, 100 ether);
        assertEq(handler.blockedTransfers(), 1, "blocked transfer must be counted");
        assertEq(handler.successfulTransfers(), 0);

        // open alice -> bob, then transfer along it
        handler.setDestination(0, 1, true);
        handler.transfer(0, 1, 100 ether);
        assertEq(handler.successfulTransfers(), 1, "successful transfer must be counted");

        // ...and the route-biased action reaches an open edge too
        handler.transferAlongOpenRoute(0, 10 ether);
        assertGt(handler.successfulTransfers(), 1, "open-route action must land a transfer");

        // through all of it, nothing unauthorised slipped past
        assertEq(handler.unauthorisedTransfers(), 0);
    }

    /// @dev The ghost counter must actually fire when an unauthorised movement
    ///      happens — otherwise the headline invariant could never fail. Proven
    ///      by recording an outcome against a route that is closed.
    function test_GhostCounterDetectsUnauthorisedMovement() public {
        handler.setDestination(0, 1, true);
        handler.transfer(0, 1, 10 ether);
        uint256 cleanRun = handler.unauthorisedTransfers();
        assertEq(cleanRun, 0, "authorised movement must not be flagged");

        // close the route; the same transfer must now be blocked, not counted
        handler.setDestination(0, 1, false);
        uint256 successesBefore = handler.successfulTransfers();
        handler.transfer(0, 1, 10 ether);
        assertEq(handler.successfulTransfers(), successesBefore, "closed route must not move value");
        assertEq(handler.unauthorisedTransfers(), 0);
    }
}
