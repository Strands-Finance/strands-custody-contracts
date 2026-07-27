// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsCustodyToken } from "../../src/StrandsCustodyToken.sol";

/// @notice The documented end-to-end flow, in order, as one executable
///         narrative: deploy -> grant -> mint -> (blocked) -> link -> transfer
///         both ways -> burn -> revoke -> (blocked again).
///
///         Read `alice` as the user's main address and `bob` as their smart
///         contract wallet; from the token's perspective an SCW is just another
///         address.
contract SubaccountLifecycleTest is BaseTest {
    /// @dev Step 1-2. A freshly deployed token has no supply and an empty
    ///      allowlist — nothing can move until both are seeded.
    function test_Step1_FreshDeployHasNoSupplyAndNoRoutes() public {
        StrandsCustodyToken fresh = new StrandsCustodyToken(admin, 18);

        assertEq(fresh.totalSupply(), 0);
        assertTrue(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(fresh.hasRole(fresh.MINTER_ROLE(), minter), "minter must be granted explicitly");
        assertFalse(fresh.allowedDestination(alice, bob), "allowlist starts empty");
    }

    /// @dev Step 3. Issuance is exempt from the allowlist, so tokens reach the
    ///      user with ZERO edges configured. This is why minting directly to the
    ///      user is preferred over minting to a treasury and transferring out —
    ///      the latter would need one edge per user, permanently.
    function test_Step3_MintReachesTheUserWithNoEdgesConfigured() public {
        assertEq(token.balanceOf(alice), 1_000 ether, "funded by setUp, allowlist untouched");

        vm.prank(minter);
        token.mint(carol, 500 ether);
        assertEq(token.balanceOf(carol), 500 ether);
    }

    /// @dev Step 4. Default-deny: a funded user still cannot reach their SCW.
    function test_Step4_TransferToSubaccountIsBlockedBeforeLinking() public {
        assertFalse(token.isLinked(alice, bob));

        vm.prank(alice);
        _expectNotAllowed(alice, bob);
        token.transfer(bob, 100 ether);
    }

    /// @dev Step 5-6. One admin transaction opens the link; value then moves
    ///      both ways, and only between those two addresses.
    function test_Step5to6_LinkThenTransferBothWays() public {
        vm.prank(admin);
        token.setPairs(_edges(alice, bob), true);
        assertTrue(token.isLinked(alice, bob));

        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.balanceOf(alice), 900 ether);

        vm.prank(bob);
        token.transfer(alice, 40 ether);
        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.balanceOf(alice), 940 ether);
    }

    /// @dev Redemption never needs an edge either, so a user is never trapped.
    function test_BurnStaysAvailableThroughout() public {
        vm.prank(alice);
        token.burn(50 ether);
        assertEq(token.balanceOf(alice), 950 ether);
        assertEq(token.totalSupply(), 950 ether);
    }

    /// @dev Step 7. Unlinking closes the same edge set the link opened.
    function test_Step7_RevokeClosesTheRouteAgain() public {
        vm.startPrank(admin);
        token.setPairs(_edges(alice, bob), true);
        token.setPairs(_edges(alice, bob), false);
        vm.stopPrank();

        assertFalse(token.isLinked(alice, bob));

        vm.prank(alice);
        _expectNotAllowed(alice, bob);
        token.transfer(bob, 1 ether);
    }

    /// @dev The whole narrative in one test, so a reader can follow the sequence
    ///      without stitching the steps above together.
    function test_FullLifecycle() public {
        // funded, but no routes
        vm.prank(alice);
        _expectNotAllowed(alice, bob);
        token.transfer(bob, 100 ether);

        // one transaction links the subaccount
        vm.prank(admin);
        token.setPairs(_edges(alice, bob), true);

        // value flows both ways
        vm.prank(alice);
        token.transfer(bob, 300 ether);
        vm.prank(bob);
        token.transfer(alice, 100 ether);
        assertEq(token.balanceOf(alice), 800 ether);
        assertEq(token.balanceOf(bob), 200 ether);

        // ...but the SCW is itself a holder: onward routes need their own edge
        vm.prank(bob);
        _expectNotAllowed(bob, carol);
        token.transfer(carol, 1 ether);

        // redemption works regardless of routing
        vm.prank(bob);
        token.burn(200 ether);
        assertEq(token.balanceOf(bob), 0);

        // custody redemption too
        vm.prank(custodian);
        token.custodyBurn(alice, 800 ether);
        assertEq(token.totalSupply(), 0);

        // offboarding closes the link
        vm.prank(admin);
        token.setPairs(_edges(alice, bob), false);
        assertFalse(token.isLinked(alice, bob));
    }

    /// @dev Linking many users in a single transaction is the operational point
    ///      of the batch surface.
    function test_ManySubaccountsLinkedInOneTransaction() public {
        vm.prank(minter);
        token.mint(carol, 100 ether);

        vm.recordLogs();
        vm.prank(admin);
        token.setPairs(_edges(alice, bob, carol, minter), true);

        assertEq(vm.getRecordedLogs().length, 4, "2 links x 2 edges each");
        assertTrue(token.isLinked(alice, bob));
        assertTrue(token.isLinked(carol, minter));

        vm.prank(alice);
        token.transfer(bob, 10 ether);
        vm.prank(carol);
        token.transfer(minter, 10 ether);
        assertEq(token.balanceOf(bob), 10 ether);
        assertEq(token.balanceOf(minter), 10 ether);
    }
}
