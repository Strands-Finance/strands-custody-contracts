// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";

/// @notice Which `from -> to` transfers the contract permits for one user, in the
///         shape it actually deploys in: a smart contract wallet with TWO linked
///         subaccounts, alongside a second user's wallet and subaccount and an
///         unrelated stranger.
///
///         Two subaccounts is the minimum shape that can express the sibling
///         rule — `sub1 -> sub2` must stay closed even though both are linked to
///         the same wallet, because `setPairs` opens exactly the two edges it
///         names and nothing else. The suites in `test/allowlist/` verify edges
///         one at a time; this verifies that a fully provisioned world still
///         leaks nothing.
///
///         `allowedDestination` after one `setPairs` call per user:
///
///              ┌──────┐        ┌────────┐        ┌──────┐
///              │ sub1 │◄──────►│ wallet │◄──────►│ sub2 │
///              └──────┘        └────────┘        └──────┘
///                  └─────── sub1 -> sub2: closed ──────┘
///              every other `from -> to`, inbound or outbound: closed
contract SubaccountTransfersTest is BaseTest {
    address internal wallet = makeAddr("wallet");
    address internal sub1 = makeAddr("sub1");
    address internal sub2 = makeAddr("sub2");
    address internal otherWallet = makeAddr("otherWallet");
    address internal otherSub = makeAddr("otherSub");
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();

        // funded to the same level `super.setUp()` gives `alice`
        vm.startPrank(minter);
        token.mint(wallet, INITIAL_MINT);
        token.mint(otherWallet, INITIAL_MINT);
        vm.stopPrank();

        // one linking transaction per user, exactly as the README runbook describes
        vm.startPrank(admin);
        token.setPairs(_edges(wallet, sub1, wallet, sub2), true);
        token.setPairs(_edges(otherWallet, otherSub), true);
        vm.stopPrank();
    }

    /// @dev Move value out to both subaccounts so the outbound direction can be
    ///      exercised from each of them.
    function _fundSubaccounts(uint256 each) internal {
        vm.startPrank(wallet);
        token.transfer(sub1, each);
        token.transfer(sub2, each);
        vm.stopPrank();
    }

    function test_Wallet_CanTransferToAndFromEverySubaccount() public {
        assertTrue(token.isLinked(wallet, sub1));
        assertTrue(token.isLinked(wallet, sub2));

        _fundSubaccounts(100 ether);
        assertEq(token.balanceOf(sub1), 100 ether);
        assertEq(token.balanceOf(sub2), 100 ether);

        vm.prank(sub1);
        token.transfer(wallet, 40 ether);
        vm.prank(sub2);
        token.transfer(wallet, 40 ether);

        assertEq(token.balanceOf(wallet), 880 ether, "value returns from both subaccounts");
    }

    /// @dev Linking two subaccounts to one wallet does NOT connect them to each
    ///      other. Sibling traffic has to route through the main address, which
    ///      is what keeps the edge count linear rather than quadratic.
    function test_Subaccount_CannotTransferToSiblingSubaccount() public {
        _fundSubaccounts(100 ether);

        vm.prank(sub1);
        _expectNotAllowed(sub1, sub2);
        token.transfer(sub2, 1 ether);

        vm.prank(sub2);
        _expectNotAllowed(sub2, sub1);
        token.transfer(sub1, 1 ether);

        // ...but the documented two-hop route works
        vm.prank(sub1);
        token.transfer(wallet, 10 ether);
        vm.prank(wallet);
        token.transfer(sub2, 10 ether);

        assertEq(token.balanceOf(sub1), 90 ether);
        assertEq(token.balanceOf(sub2), 110 ether, "sibling value must route via the wallet");
    }

    /// @dev `allowedDestination` is per-`from` and never transitive: for neither
    ///      the wallet nor its subaccounts is another user's wallet, another
    ///      user's subaccount, or a stranger an approved `to`.
    function test_Wallet_CannotTransferToAnotherUsersWalletOrSubaccount() public {
        _fundSubaccounts(100 ether);

        vm.startPrank(wallet);
        _expectNotAllowed(wallet, otherWallet);
        token.transfer(otherWallet, 1 ether);
        _expectNotAllowed(wallet, otherSub);
        token.transfer(otherSub, 1 ether);
        _expectNotAllowed(wallet, stranger);
        token.transfer(stranger, 1 ether);
        vm.stopPrank();

        vm.prank(sub1);
        _expectNotAllowed(sub1, otherSub);
        token.transfer(otherSub, 1 ether);

        assertEq(token.balanceOf(otherWallet), INITIAL_MINT, "no value moved to the other user's wallet");
        assertEq(token.balanceOf(otherSub), 0);
        assertEq(token.balanceOf(stranger), 0);
    }

    /// @dev Fuzzed against a wallet whose approved destinations are ALREADY
    ///      OPEN, which is the distinct claim here: an open `from -> to` does not
    ///      open any other `to`. `test/allowlist/Fuzz.t.sol` fuzzes from an empty
    ///      allowlist and so only proves default-deny.
    function testFuzz_WalletCannotTransferToAnyUnapprovedDestination(address dest) public {
        vm.assume(dest != sub1 && dest != sub2);
        vm.assume(dest != address(0)); // ERC20InvalidReceiver, a different rejection

        vm.prank(wallet);
        _expectNotAllowed(wallet, dest);
        token.transfer(dest, 1 ether);

        assertEq(token.balanceOf(wallet), INITIAL_MINT, "wallet balance must be untouched");
    }
}
