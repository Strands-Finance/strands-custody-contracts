// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsCustodyToken } from "../../src/StrandsCustodyToken.sol";

/// @notice The documented end-to-end flow, in order, as one executable
///         narrative: deploy -> grant -> mint -> (blocked) -> link -> transfer
///         both ways -> burn -> revoke -> (blocked again).
///
///         This suite IS the README runbook. Every `cast` invocation in the
///         "Operating the allowlist" section has a step here, so the documented
///         sequence is proven by the test suite rather than by hand.
///
///         The subaccount reading — `alice` as someone's main address, `bob` as
///         their smart contract wallet — is the motivating case and lives here
///         deliberately. The contract has no such concept: to it these are two
///         addresses with two edges between them.
contract SubaccountLifecycleTest is BaseTest {
    address internal stranger = makeAddr("stranger");

    /// @dev Step 1-2. A freshly deployed token has no supply and an empty
    ///      allowlist — nothing can move until both are seeded.
    function test_Step1_FreshDeployHasNoSupplyAndNoRoutes() public {
        StrandsCustodyToken fresh = new StrandsCustodyToken(admin, 18);

        assertEq(fresh.totalSupply(), 0);
        assertTrue(fresh.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertFalse(fresh.hasRole(MINTER_ROLE, minter), "minter must be granted explicitly");
        assertFalse(fresh.allowedDestination(alice, bob), "allowlist starts empty");
    }

    /// @dev Step 3. Issuance is exempt from the allowlist, so tokens reach the
    ///      user with ZERO edges configured. This is why minting directly to the
    ///      user is preferred over minting to a treasury and transferring out —
    ///      the latter would need one edge per user, permanently.
    function test_Step3_MintReachesTheUserWithNoEdgesConfigured() public {
        assertEq(token.balanceOf(alice), INITIAL_MINT, "funded by setUp, allowlist untouched");

        vm.prank(minter);
        token.mint(carol, 500 ether);
        assertEq(token.balanceOf(carol), 500 ether);
    }

    /// @dev Step 4. Default-deny: a funded user still cannot reach their SCW.
    function test_Step4_TransferToSubaccountIsBlockedBeforeLinking() public {
        assertFalse(_isLinked(alice, bob));

        vm.prank(alice);
        _expectNotAllowed(alice, bob);
        token.transfer(bob, 100 ether);
    }

    /// @dev Step 5-6. One admin transaction opens the link; value then moves
    ///      both ways, and only between those two addresses.
    function test_Step5to6_LinkThenTransferBothWays() public {
        _link(alice, bob);

        // the two directed reads the runbook prescribes in place of a link view
        assertTrue(token.allowedDestination(alice, bob), "user -> subaccount");
        assertTrue(token.allowedDestination(bob, alice), "subaccount -> user");
        assertTrue(_isLinked(alice, bob));

        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.balanceOf(alice), 900 ether);

        vm.prank(bob);
        token.transfer(alice, 40 ether);
        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.balanceOf(alice), 940 ether);
    }

    /// @dev Redemption never needs an edge either — but it is custodian-only, so
    ///      a user cannot exit without the custodian acting for them.
    function test_RedemptionIsCustodianOnlyThroughout() public {
        vm.prank(alice);
        _expectNotCustodian(alice);
        token.burn(50 ether);

        vm.prank(custodian);
        token.custodyBurn(alice, 50 ether);
        assertEq(token.balanceOf(alice), 950 ether);
        assertEq(token.totalSupply(), 950 ether);
    }

    /// @dev Step 7. Unlinking closes the same edge set the link opened.
    function test_Step7_RevokeClosesTheRouteAgain() public {
        _link(alice, bob);
        _unlink(alice, bob);

        assertFalse(_isLinked(alice, bob));

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
        _link(alice, bob);

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

        // the admin escape hatch reaches where the holder cannot, without
        // opening a route the holder could then reuse
        vm.prank(admin);
        token.adminTransfer(bob, carol, 200 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(carol), 200 ether);
        assertFalse(token.allowedDestination(bob, carol), "the route stays closed to the holder");

        // redemption works regardless of routing, but only the custodian may do it
        vm.prank(custodian);
        token.custodyBurn(carol, 200 ether);
        assertEq(token.balanceOf(carol), 0);

        vm.prank(custodian);
        token.custodyBurn(alice, 800 ether);
        assertEq(token.totalSupply(), 0);

        // offboarding closes the link
        _unlink(alice, bob);
        assertFalse(_isLinked(alice, bob));
    }

    /// @dev Onboarding several users is one `setLink` per user, and the links
    ///      stay independent of one another.
    function test_ManySubaccountsLinkedOneCallEach() public {
        vm.prank(minter);
        token.mint(carol, 100 ether);

        vm.recordLogs();
        vm.startPrank(admin);
        token.setLink(alice, bob, true);
        token.setLink(carol, minter, true);
        vm.stopPrank();

        _assertLogCount(4, "2 links x 2 edges each");
        assertTrue(_isLinked(alice, bob));
        assertTrue(_isLinked(carol, minter));

        vm.prank(alice);
        token.transfer(bob, 10 ether);
        vm.prank(carol);
        token.transfer(minter, 10 ether);
        assertEq(token.balanceOf(bob), 10 ether);
        assertEq(token.balanceOf(minter), 10 ether);
    }

    /// @dev Linking a user to themselves is rejected, so the runbook cannot
    ///      accidentally open a self-route by passing the same address twice.
    function test_SelfLinkIsRejected() public {
        vm.prank(admin);
        vm.expectRevert("self-link");
        token.setLink(alice, alice, true);

        assertFalse(token.allowedDestination(alice, alice));
    }

    /// @dev The admin escape hatch, end to end: value reaches an address the
    ///      user was never approved to pay, the allowlist is untouched by it,
    ///      and supply does not move.
    function test_AdminTransferReachesAnAddressWithNoRouteInEitherDirection() public {
        assertFalse(token.allowedDestination(alice, stranger), "precondition: closed both ways");
        assertFalse(token.allowedDestination(stranger, alice));
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        _expectNotAllowed(alice, stranger);
        token.transfer(stranger, 100 ether); // the holder cannot get there...

        vm.prank(admin);
        token.adminTransfer(alice, stranger, 100 ether); // ...the admin can

        assertEq(token.balanceOf(stranger), 100 ether);
        assertEq(token.balanceOf(alice), INITIAL_MINT - 100 ether);
        assertEq(token.totalSupply(), supplyBefore, "moving value must never change supply");

        // and the route the admin used is still closed to the holder
        assertFalse(token.allowedDestination(alice, stranger), "no edge may be implicitly created");
        assertFalse(token.allowedDestination(stranger, alice));
    }
}
