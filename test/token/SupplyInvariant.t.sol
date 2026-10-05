// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { BaseTest } from "../Base.t.sol";
import { StrandsDACAP } from "../../src/StrandsDACAP.sol";

/// @notice The completeness half of "an external user cannot mint or burn".
///         `ExternalUserSurface.t.sol` walks the six supply-changing
///         entrypoints by hand, which is legible but is a CHECKLIST: it says
///         nothing about an entrypoint that does not exist yet. This suite says
///         something about all of them.
///
/// @dev    Foundry's invariant fuzzer enumerates the token's ENTIRE external
///         ABI and drives it with random arguments, in random order, across
///         many runs. A seventh supply-changing function added later — ungated,
///         or gated on the wrong role — is exercised here with no test edit,
///         and trips the assertion below. That is the property worth having:
///         the checklist goes stale, this does not.
///
///         The token runs in its PRODUCTION shape: the holders' wallets and an
///         escrow are open destinations, as enrolment and the Derive deposit
///         route leave them. With a closed list every `transfer` reverts, so a
///         new function that routes value through `transfer` before burning it
///         — exactly what the contract header tells such a function to do —
///         reverted on every call, and the suite could not see it. A route the
///         admin never opens is refused in production too, so it is not a path
///         to supply worth fuzzing.
///
///         `OpenRouteHandler` keeps real balances moving between those wallets,
///         so the fuzzer's direct calls run against a token whose balances and
///         allowances actually change, and against holders other than `alice`
///         who have something to burn. It also counts every move it attempts,
///         which is what `afterInvariant` checks.
///
///         Senders are pinned rather than random, and every one of them is an
///         ordinary user: `alice` starts with the fixture's entire supply, `bob`
///         and `carol` with nothing. Neither `minter` nor `admin` appears, which
///         is what makes the assertion "no unprivileged caller can change
///         supply" rather than "supply never changes".
///
///         `fail_on_revert = false` in `foundry.toml` is load-bearing: most calls
///         the fuzzer makes here are SUPPOSED to revert, and the run would
///         otherwise stop at the first refusal instead of continuing to probe.
contract SupplyInvariantTest is BaseTest {
    OpenRouteHandler internal handler;

    /// @dev Where a holder deposits: an open destination that is not one of the senders.
    address internal escrow = makeAddr("escrow");

    function setUp() public override {
        super.setUp();

        // The production shape: every holder's wallet and the escrow are open, opened by the admin before any target
        // is named.
        _allow(alice);
        _allow(bob);
        _allow(carol);
        _allow(escrow);

        address[] memory wallets = new address[](4);
        wallets[0] = alice;
        wallets[1] = bob;
        wallets[2] = carol;
        wallets[3] = escrow;
        handler = new OpenRouteHandler(token, wallets);

        // The whole token, named by interface because the token is a proxy: the address resolves to `BeaconProxy`,
        // which has no ABI of its own, and `targetContract` would find nothing to fuzz. Naming the artifact still
        // enumerates the implementation's ENTIRE ABI — nothing is listed by hand — and every call goes through the
        // proxy, as a real one would. The handler is a second target, not a replacement: it adds realistic balance
        // movement and narrows nothing.
        string[] memory artifacts = new string[](1);
        artifacts[0] = "StrandsDACAP";
        targetInterface(FuzzInterface({ addr: address(token), artifacts: artifacts }));
        targetContract(address(handler));

        // Naming a target contract already stops Foundry fuzzing everything `setUp` deployed. Excluded anyway, so the
        // targeting does not rest on that rule: no assertion reads the implementation's own storage, and who may
        // upgrade the beacon is `Proxy.t.sol`'s.
        excludeContract(address(implementation));
        excludeContract(address(beacon));

        // Ordinary users only. Listing senders explicitly (rather than letting the fuzzer invent addresses) is what
        // puts a FUNDED holder in the population — an address with a zero balance cannot distinguish "the role gate
        // refused me" from "I had nothing to burn".
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
    ///      external function that grants DEFAULT_ADMIN_ROLE and MINTER_ROLE to
    ///      its caller; the constructor it replaced was not reachable after
    ///      deploy at all.
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

    /// @dev The admin's OTHER standing power, held to the same standard: the list
    ///      is exactly what the admin made it. The fuzzer drives
    ///      `setDestinationAllowed` from these three senders on every run, in
    ///      both directions, so a failed gate shows up either as a route a
    ///      stranger CLOSED (the wallets and escrow `setUp` opened) or as one a
    ///      stranger OPENED (addresses the fuzzer already knows, which nobody
    ///      opened).
    function invariant_TheAllowlistIsUnreachableWithoutTheAdmin() public view {
        assertTrue(token.allowedDestination(alice), "an unprivileged caller closed a destination");
        assertTrue(token.allowedDestination(bob), "an unprivileged caller closed a destination");
        assertTrue(token.allowedDestination(carol), "an unprivileged caller closed a destination");
        assertTrue(token.allowedDestination(escrow), "an unprivileged caller closed a destination");

        assertFalse(token.allowedDestination(address(token)), "an unprivileged caller opened a destination");
        assertFalse(token.allowedDestination(address(handler)), "an unprivileged caller opened a destination");
        assertFalse(token.allowedDestination(address(this)), "an unprivileged caller opened a destination");
    }

    /// @dev The control, checked at the end of EVERY run rather than once in a unit test: every realistic move the
    ///      handler attempted — a transfer, or an approve-then-transferFrom, between open wallets and within balance —
    ///      landed. With `fail_on_revert = false` an invariant over a token whose calls all revert is vacuously true;
    ///      if a change ever made ordinary movement revert, this goes red while the invariants above stay green.
    function afterInvariant() public view {
        assertEq(handler.landed(), handler.attempts(), "a move between open wallets reverted: state is not reachable");
    }

    /// @dev Pins WHAT is fuzzed. A target pointed at the wrong address — the beacon, say — leaves every invariant
    ///      vacuously green, because every call reverts, and the control above only watches the handler. So the
    ///      targeting is asserted directly: the token's whole ABI by interface, the handler, and nothing else, from
    ///      ordinary users only.
    function test_TheFuzzerTargetsTheTokenAndTheHandler_FromOrdinaryUsers() public view {
        StdInvariant.FuzzInterface[] memory interfaces = targetInterfaces();
        assertEq(interfaces.length, 1, "exactly one interface target");
        assertEq(interfaces[0].addr, address(token), "the interface target is the token's proxy");
        assertEq(interfaces[0].artifacts.length, 1);
        assertEq(interfaces[0].artifacts[0], "StrandsDACAP", "fuzzed with the token's whole ABI");

        address[] memory contracts = targetContracts();
        assertEq(contracts.length, 1, "exactly one contract target");
        assertEq(contracts[0], address(handler), "and it is the handler");

        address[] memory senders = targetSenders();
        assertEq(senders.length, 3);
        for (uint256 i = 0; i < senders.length; i++) {
            assertFalse(token.hasRole(MINTER_ROLE, senders[i]), "no sender can mint");
            assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, senders[i]), "no sender is admin");
        }
    }
}

/// @notice Moves real balances between open wallets, so the token the fuzzer probes is one whose balances and
///         allowances change, and counts every move it attempts and every one that lands. Amounts are bounded to the
///         sender's balance and every wallet is open, so a move that reverts is a broken token, not a bad input.
contract OpenRouteHandler is Test {
    StrandsDACAP internal immutable token;
    address[] internal wallets;

    uint256 public attempts;
    uint256 public landed;

    constructor(StrandsDACAP token_, address[] memory wallets_) {
        token = token_;
        wallets = wallets_;
    }

    function transferBetweenWallets(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = wallets[fromSeed % wallets.length];
        address to = wallets[toSeed % wallets.length];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));

        attempts++;
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            if (ok) landed++;
        } catch { }
    }

    function approveThenTransferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed)
        external
    {
        address owner = wallets[ownerSeed % wallets.length];
        address spender = wallets[spenderSeed % wallets.length];
        address to = wallets[toSeed % wallets.length];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(owner));

        attempts++;
        vm.prank(owner);
        token.approve(spender, amount);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            if (ok) landed++;
        } catch { }
    }
}
