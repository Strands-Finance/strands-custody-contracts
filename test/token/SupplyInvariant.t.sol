// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice The completeness half of "an external user cannot mint or burn".
///         `ExternalUserSurface.t.sol` walks the six supply-changing
///         entrypoints by hand, which is legible but is a CHECKLIST: it says
///         nothing about an entrypoint that does not exist yet. This suite says
///         something about all of them.
///
/// @dev    Foundry's invariant fuzzer enumerates the target contract's ENTIRE
///         external ABI and drives it with random arguments, in random order,
///         across many runs. A seventh supply-changing function added later —
///         ungated, or gated on the wrong role — is exercised here with no test
///         edit, and trips the assertion below. That is the property worth
///         having: the checklist goes stale, this does not.
///
///         Senders are pinned rather than random, and every one of them is an
///         ordinary user: `alice` holds the fixture's entire supply (so a burn
///         that slipped through would actually have something to destroy),
///         `bob` and `carol` hold nothing. Neither `minter` nor `admin` appears,
///         which is what makes the assertion "no unprivileged caller can change
///         supply" rather than "supply never changes".
///
///         `fail_on_revert = false` in `foundry.toml` is load-bearing: almost
///         every call the fuzzer makes here is SUPPOSED to revert, and the run
///         would otherwise stop at the first refusal instead of continuing to
///         probe. `test_TheFuzzersTargetsAreReachable` below is the control
///         that stops "everything reverted" from passing as "the invariant
///         holds".
contract SupplyInvariantTest is BaseTest {
    function setUp() public override {
        super.setUp();

        // The whole token, not a handler: routing through a handler would limit
        // the fuzzer to the functions the handler chose to expose, which is
        // exactly the staleness this suite exists to avoid.
        //
        // Named by interface because the token is a proxy: the address resolves
        // to `BeaconProxy`, which has no ABI of its own, and `targetContract`
        // would find nothing to fuzz. Naming the artifact still enumerates the
        // implementation's ENTIRE ABI — nothing is listed by hand — and every
        // call goes through the proxy, as a real one would.
        string[] memory artifacts = new string[](1);
        artifacts[0] = "StrandsDACAP";
        targetInterface(FuzzInterface({ addr: address(token), artifacts: artifacts }));

        // `targetInterface` ADDS a target; it does not narrow the set. With no
        // `targetContract` call, every contract `setUp` deployed is fuzzed too —
        // the bare implementation and the beacon — and they took more than half
        // of every run's calls away from the token. Neither is what these
        // invariants are about: no assertion reads the implementation's own
        // storage, and who may upgrade the beacon is `Proxy.t.sol`'s.
        excludeContract(address(implementation));
        excludeContract(address(beacon));

        // Ordinary users only. Listing senders explicitly (rather than letting
        // the fuzzer invent addresses) is what puts a FUNDED holder in the
        // population — an address with a zero balance cannot distinguish "the
        // role gate refused me" from "I had nothing to burn".
        targetSender(alice);
        targetSender(bob);
        targetSender(carol);
    }

    /// @dev The property in one line: no address without MINTER_ROLE can change
    ///      how many tokens exist, by any route, in any order.
    function invariant_TotalSupplyIsUnreachableWithoutMinterRole() public view {
        assertEq(token.totalSupply(), INITIAL_MINT, "an unprivileged caller changed the supply");
    }

    /// @dev The other half of the same guarantee. Supply could also be reached
    ///      indirectly — by a stranger acquiring MINTER_ROLE, or by the role's
    ///      admin being repointed at something they can obtain. Neither may
    ///      happen through any call an ordinary user can make.
    ///
    ///      A holder acquiring DEFAULT_ADMIN_ROLE is checked separately, because
    ///      it is one grant away from MINTER_ROLE and the fuzzer may never land
    ///      that second call. It matters since `initializeToken` became an
    ///      external function that grants DEFAULT_ADMIN_ROLE to its caller; the
    ///      constructor it replaced was not reachable after deploy at all.
    function invariant_TheRoleGraphIsUnreachableWithoutTheAdmin() public view {
        assertTrue(token.hasRole(MINTER_ROLE, minter), "the seated minter was unseated by a stranger");
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin), "the seated admin was unseated by a stranger");
        assertEq(token.getRoleAdmin(MINTER_ROLE), DEFAULT_ADMIN_ROLE, "MINTER_ROLE's admin was repointed");

        assertFalse(token.hasRole(MINTER_ROLE, alice), "a holder acquired the operating role");
        assertFalse(token.hasRole(MINTER_ROLE, bob), "a holder acquired the operating role");
        assertFalse(token.hasRole(MINTER_ROLE, carol), "a holder acquired the operating role");

        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, alice), "a holder acquired the admin role");
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, bob), "a holder acquired the admin role");
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, carol), "a holder acquired the admin role");
    }

    /// @dev The admin's OTHER standing power, held to the same standard. The
    ///      fuzzer enumerates the whole ABI, so `setDestinationAllowed` is being
    ///      driven from these three senders on every run — and every one of those
    ///      calls must be refused. The senders themselves are the addresses worth
    ///      asserting on, because opening a route for YOURSELF is the escalation
    ///      that would matter: `setUp` opens nothing, so any `true` here is a gate
    ///      that failed.
    function invariant_TheAllowlistIsUnreachableWithoutTheAdmin() public view {
        assertFalse(token.allowedDestination(alice), "an unprivileged caller opened a destination");
        assertFalse(token.allowedDestination(bob), "an unprivileged caller opened a destination");
        assertFalse(token.allowedDestination(carol), "an unprivileged caller opened a destination");
    }

    /// @dev The control. With `fail_on_revert = false` an invariant over a
    ///      contract nobody can successfully call is vacuously true, so this
    ///      pins that the pinned senders CAN in fact reach the token and move
    ///      state through it — they simply cannot move supply. If a future
    ///      change made every call above revert (a renamed function, a
    ///      mis-set target), this goes red while the invariants stay green.
    function test_TheFuzzersTargetsAreReachable() public {
        uint256 supplyBefore = token.totalSupply();

        // Opened here rather than in `setUp`, so the invariant runs keep facing a
        // wholly closed list and the assertion above stays about the gate.
        _allow(carol);

        vm.startPrank(alice);
        token.approve(bob, 1 ether);
        token.transfer(carol, 1 ether);
        vm.stopPrank();

        assertEq(token.allowance(alice, bob), 1 ether, "the sender set can reach the token's state");
        assertEq(token.balanceOf(carol), 1 ether);
        assertEq(token.totalSupply(), supplyBefore, "and none of it is supply");
    }
}
