// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { StrandsCustodyToken } from "../src/StrandsCustodyToken.sol";

contract StrandsCustodyTokenTest is Test {
    StrandsCustodyToken internal token;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
    address internal custodian = makeAddr("custodian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    event CustodyBurn(address indexed custodian, address indexed from, uint256 amount);
    event DestinationAllowedSet(address indexed holder, address indexed destination, bool allowed);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        token = new StrandsCustodyToken(admin, 18);

        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        token.grantRole(token.CUSTODIAN_ROLE(), custodian);
        vm.stopPrank();

        vm.prank(minter);
        token.mint(alice, 1_000 ether);
    }

    // ---------- metadata ----------
    function test_Metadata() public view {
        assertEq(token.name(), "Strands Custody Token");
        assertEq(token.symbol(), "SCT");
        assertEq(token.decimals(), 18);
    }

    function test_Decimals_AreSetByConstructor() public {
        assertEq(new StrandsCustodyToken(admin, 6).decimals(), 6, "usdc");
        assertEq(new StrandsCustodyToken(admin, 8).decimals(), 8, "btc");
        assertEq(new StrandsCustodyToken(admin, 18).decimals(), 18, "eth");
    }

    // ---------- roles ----------
    function test_AdminHasDefaultAdminRole() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_Constructor_RevertsOnZeroAdmin() public {
        vm.expectRevert(bytes("admin=0"));
        new StrandsCustodyToken(address(0), 18);
    }

    function test_AdminCanRevokeCustodian() public {
        bytes32 role = token.CUSTODIAN_ROLE();
        vm.prank(admin);
        token.revokeRole(role, custodian);
        assertFalse(token.hasRole(role, custodian));
    }

    // ---------- mint ----------
    function test_MinterCanMint() public {
        vm.prank(minter);
        token.mint(bob, 50 ether);
        assertEq(token.balanceOf(bob), 50 ether);
        assertEq(token.totalSupply(), 1_050 ether);
    }

    function test_NonMinter_CannotMint() public {
        bytes32 role = token.MINTER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        token.mint(bob, 1);
    }

    // ---------- custodyBurn (core feature) ----------
    function test_Custodian_CanBurnFromAnyHolder_WithoutAllowance() public {
        assertEq(token.allowance(alice, custodian), 0, "precondition: no allowance");

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, address(0), 400 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit CustodyBurn(custodian, alice, 400 ether);

        vm.prank(custodian);
        token.custodyBurn(alice, 400 ether);

        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.totalSupply(), 600 ether);
    }

    function test_NonCustodian_CannotCustodyBurn() public {
        bytes32 role = token.CUSTODIAN_ROLE();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, role));
        token.custodyBurn(alice, 1);
    }

    function test_CustodyBurn_RevertsOnInsufficientBalance() public {
        vm.prank(custodian);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1_000 ether, 1_001 ether)
        );
        token.custodyBurn(alice, 1_001 ether);
    }

    // ---------- standard burn paths still work ----------
    function test_Holder_CanBurnOwnBalance() public {
        vm.prank(alice);
        token.burn(100 ether);
        assertEq(token.balanceOf(alice), 900 ether);
        assertEq(token.totalSupply(), 900 ether);
    }

    function test_BurnFrom_RequiresAllowance() public {
        vm.prank(bob);
        vm.expectRevert();
        token.burnFrom(alice, 1);
    }

    function test_BurnFrom_WorksWithAllowance() public {
        vm.prank(alice);
        token.approve(bob, 200 ether);

        vm.prank(bob);
        token.burnFrom(alice, 200 ether);

        assertEq(token.balanceOf(alice), 800 ether);
        assertEq(token.allowance(alice, bob), 0);
    }

    // ---------- destination allowlist ----------
    function test_Admin_CanSetAndUnsetDestination() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit DestinationAllowedSet(alice, bob, true);
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true);
        assertTrue(token.allowedDestination(alice, bob));

        vm.expectEmit(true, true, false, true, address(token));
        emit DestinationAllowedSet(alice, bob, false);
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, false);
        assertFalse(token.allowedDestination(alice, bob));
    }

    function test_NonAdmin_CannotSetDestination() public {
        bytes32 role = token.DEFAULT_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        token.setDestinationAllowed(alice, bob, true);
    }

    function test_Transfer_ToApprovedDestination() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 100 ether);
        vm.prank(alice);
        token.transfer(bob, 100 ether);

        assertEq(token.balanceOf(alice), 900 ether);
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function test_Transfer_RevertsOnUnapprovedDestination() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, bob));
        token.transfer(bob, 100 ether);
    }

    function test_Transfer_RevertsAfterDestinationUnset() public {
        vm.startPrank(admin);
        token.setDestinationAllowed(alice, bob, true);
        token.setDestinationAllowed(alice, bob, false);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, bob));
        token.transfer(bob, 1);
    }

    function test_DestinationApproval_IsPerHolder() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true); // alice -> bob only
        vm.prank(minter);
        token.mint(carol, 10 ether);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, carol, bob));
        token.transfer(bob, 1 ether);
    }

    function test_TransferFrom_ChecksOwnerNotSpender() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true); // approval keyed by owner alice, not spender carol
        vm.prank(alice);
        token.approve(carol, 300 ether);

        vm.prank(carol);
        token.transferFrom(alice, bob, 300 ether);

        assertEq(token.balanceOf(bob), 300 ether);
        assertEq(token.allowance(alice, carol), 0);
    }

    function test_TransferFrom_RevertsOnUnapprovedDestination() public {
        vm.prank(alice);
        token.approve(carol, 300 ether); // ERC20 allowance alone is not enough

        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, carol)
        );
        token.transferFrom(alice, carol, 300 ether);
    }

    function test_MintAndBurnPaths_ExemptFromAllowlist() public {
        // no allowlist entries exist at all
        vm.prank(minter);
        token.mint(carol, 10 ether); // mint: from == address(0)
        vm.prank(carol);
        token.burn(1 ether); // burn: to == address(0)
        vm.prank(carol);
        token.approve(bob, 2 ether);
        vm.prank(bob);
        token.burnFrom(carol, 2 ether); // burnFrom: to == address(0)
        vm.prank(custodian);
        token.custodyBurn(carol, 3 ether); // custodyBurn: to == address(0)

        assertEq(token.balanceOf(carol), 4 ether);
    }

    // ---------- allowlist: scoping ----------
    function test_Allowlist_IsDirectional() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true);
        assertFalse(token.allowedDestination(bob, alice), "alice->bob must not imply bob->alice");

        vm.prank(alice);
        token.transfer(bob, 100 ether);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, bob, alice));
        token.transfer(alice, 1 ether);
    }

    function test_Allowlist_IsPerDestination() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, carol)
        );
        token.transfer(carol, 1 ether);
    }

    function test_Allowlist_EntryIsReusable() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true);

        vm.startPrank(alice);
        token.transfer(bob, 100 ether);
        token.transfer(bob, 100 ether);
        vm.stopPrank();

        assertTrue(token.allowedDestination(alice, bob), "approval must not be consumed by a transfer");
        assertEq(token.balanceOf(bob), 200 ether);
    }

    function test_PrivilegedRoles_AreNotExemptFromAllowlist() public {
        vm.startPrank(minter);
        token.mint(admin, 10 ether);
        token.mint(minter, 10 ether);
        token.mint(custodian, 10 ether);
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, admin, bob));
        token.transfer(bob, 1 ether);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, minter, bob));
        token.transfer(bob, 1 ether);

        vm.prank(custodian);
        vm.expectRevert(
            abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, custodian, bob)
        );
        token.transfer(bob, 1 ether);
    }

    // ---------- allowlist: edge cases the guard must still cover ----------
    function test_SelfTransfer_RevertsWhenNotAllowlisted() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, alice)
        );
        token.transfer(alice, 1 ether);
    }

    function test_SelfTransfer_SucceedsWhenAllowlisted() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, alice, true);

        vm.prank(alice);
        token.transfer(alice, 1 ether);
        assertEq(token.balanceOf(alice), 1_000 ether, "self-transfer must be balance-neutral");
    }

    /// @dev ERC20 requires zero-value transfers to behave like any other transfer.
    ///      The allowlist deliberately blocks them too; pin that so the deviation
    ///      from the spec is a decision and not an accident.
    function test_ZeroValueTransfer_RevertsWhenNotAllowlisted() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, bob));
        token.transfer(bob, 0);
    }

    function test_TransferToZeroAddress_StillRevertsWithErc20Error() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, address(0), true); // must not open a burn-by-transfer path

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);

        assertEq(token.totalSupply(), 1_000 ether, "supply must be untouched");
    }

    // ---------- allowlist: revert precedence ----------
    function test_Allowlist_CheckedBeforeBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, bob));
        token.transfer(bob, 5_000 ether); // also exceeds balance
    }

    function test_InsufficientBalance_StillRevertsWhenAllowlisted() public {
        vm.prank(admin);
        token.setDestinationAllowed(alice, bob, true);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1_000 ether, 1_001 ether)
        );
        token.transfer(bob, 1_001 ether);
    }

    /// @dev OZ spends the allowance before reaching `_transfer`/`_update`, so the
    ///      allowance error wins even though the destination is also disallowed.
    function test_TransferFrom_AllowanceCheckedBeforeAllowlist() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, carol, 0, 1 ether));
        token.transferFrom(alice, bob, 1 ether);
    }

    function test_TransferFrom_SpenderAllowlistEntryDoesNotAuthorise() public {
        vm.prank(admin);
        token.setDestinationAllowed(carol, bob, true); // spender's own entry, not the owner's
        vm.prank(alice);
        token.approve(carol, 300 ether);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, bob));
        token.transferFrom(alice, bob, 300 ether);
    }

    // ---------- allowlist: state is untouched when a transfer is blocked ----------
    function test_BlockedTransfer_LeavesBalancesAndSupplyUnchanged() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, bob));
        token.transfer(bob, 100 ether);

        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), 1_000 ether);
    }

    function test_BlockedTransferFrom_DoesNotConsumeAllowance() public {
        vm.prank(alice);
        token.approve(carol, 300 ether);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, bob));
        token.transferFrom(alice, bob, 300 ether);

        assertEq(token.allowance(alice, carol), 300 ether, "allowance must survive a blocked transferFrom");
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    // ---------- allowlist: admin lifecycle ----------
    function test_RevokedAdmin_CannotSetDestination() public {
        bytes32 role = token.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        token.grantRole(role, carol); // keep a live admin so the revoke is not a lockout
        vm.prank(carol);
        token.revokeRole(role, admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        token.setDestinationAllowed(alice, bob, true);

        vm.prank(carol);
        token.setDestinationAllowed(alice, bob, true); // the new admin still can
        assertTrue(token.allowedDestination(alice, bob));
    }

    /// @dev Pins the README warning: renouncing the last admin freezes the
    ///      allowlist, so unapproved balances become permanently non-transferable
    ///      while burn paths keep working.
    function test_RenouncedAdmin_FreezesAllowlistButBurnsStillWork() public {
        bytes32 role = token.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        token.renounceRole(role, admin);
        assertFalse(token.hasRole(role, admin));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        token.setDestinationAllowed(alice, bob, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, bob));
        token.transfer(bob, 1 ether);

        vm.prank(alice);
        token.burn(1 ether);
        vm.prank(custodian);
        token.custodyBurn(alice, 1 ether);
        assertEq(token.balanceOf(alice), 998 ether, "burn paths must survive a frozen allowlist");
    }

    // ---------- allowlist: blast radius of losing the last admin ----------

    /// @dev The freeze is a SNAPSHOT, not a shutdown: entries written before the
    ///      last admin disappeared keep working forever. Only the ability to add
    ///      or remove entries is lost.
    function test_RenouncedAdmin_PreExistingApprovalsKeepWorking() public {
        vm.startPrank(admin);
        token.setDestinationAllowed(alice, bob, true);
        token.renounceRole(token.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();

        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether, "pre-approved route must survive the freeze");

        // ...but it can never be revoked again, so this route is now permanent.
        vm.prank(admin);
        vm.expectRevert();
        token.setDestinationAllowed(alice, bob, false);

        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 200 ether, "route is now irrevocable");
    }

    /// @dev DEFAULT_ADMIN_ROLE is its own role admin, so re-granting it requires
    ///      already holding it. Once the last holder is gone there is no bootstrap
    ///      path from any party.
    function test_RenouncedAdmin_IsUnrecoverableByAnyParty() public {
        bytes32 role = token.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        token.renounceRole(role, admin);

        address[5] memory parties = [admin, alice, minter, custodian, address(this)];
        for (uint256 i = 0; i < parties.length; i++) {
            vm.prank(parties[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, parties[i], role)
            );
            token.grantRole(role, carol);
        }
        assertFalse(token.hasRole(role, carol), "no party may bootstrap a new admin");
    }

    /// @dev `revokeRole` reaches the identical dead state as `renounceRole`, but
    ///      without the `callerConfirmation` footgun-guard, and one admin can do
    ///      it to another.
    function test_RevokingLastAdmin_ReachesSameDeadStateAsRenounce() public {
        bytes32 role = token.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        token.revokeRole(role, admin); // self-revoke: no confirmation argument required
        assertFalse(token.hasRole(role, admin));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, role));
        token.setDestinationAllowed(alice, bob, true);
    }

    /// @dev The whole role graph freezes, not just the allowlist: no new minters
    ///      or custodians can ever be appointed. Incumbents keep their powers, so
    ///      supply can still change while those keys live.
    function test_RenouncedAdmin_FreezesEntireRoleGraph() public {
        // hoisted: a `token.X_ROLE()` call inside a pranked/expectRevert line would
        // consume the cheatcode before the call under test runs
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        bytes32 minterRole = token.MINTER_ROLE();
        bytes32 custodianRole = token.CUSTODIAN_ROLE();

        vm.prank(admin);
        token.renounceRole(adminRole, admin);

        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, adminRole)
        );
        token.grantRole(minterRole, carol);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, adminRole)
        );
        token.grantRole(custodianRole, carol);
        vm.stopPrank();

        // incumbents are unaffected
        vm.prank(minter);
        token.mint(carol, 10 ether);
        vm.prank(custodian);
        token.custodyBurn(carol, 10 ether);

        // ...but if the incumbent custodian is also lost, that power is gone for good
        vm.prank(custodian);
        token.renounceRole(custodianRole, custodian);
        vm.prank(custodian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, custodian, custodianRole)
        );
        token.custodyBurn(alice, 1 ether);
    }

    /// @dev The economic exit survives: burn is self-service and allowlist-exempt,
    ///      so a holder can always redeem against the off-chain ledger even when
    ///      every transfer route is frozen. Tokens are immobile, not unredeemable.
    function test_RenouncedAdmin_HolderCanStillSelfRedeemEntireBalance() public {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        token.renounceRole(adminRole, admin);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, bob));
        token.transfer(bob, 1 ether);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, address(0), 1_000 ether);
        vm.prank(alice);
        token.burn(1_000 ether); // full exit, no admin involvement

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_SetDestinationAllowed_ReEmitsOnRedundantWrite() public {
        vm.startPrank(admin);
        token.setDestinationAllowed(alice, bob, true);

        vm.expectEmit(true, true, false, true, address(token));
        emit DestinationAllowedSet(alice, bob, true);
        token.setDestinationAllowed(alice, bob, true);
        vm.stopPrank();

        assertTrue(token.allowedDestination(alice, bob));
    }

    // ---------- fuzz ----------
    function testFuzz_CustodyBurn_BurnsExactAmount(uint96 amount) public {
        amount = uint96(bound(amount, 0, 1_000 ether));
        vm.prank(custodian);
        token.custodyBurn(alice, amount);
        assertEq(token.balanceOf(alice), 1_000 ether - amount);
        assertEq(token.totalSupply(), 1_000 ether - amount);
    }

    function testFuzz_Transfer_RespectsAllowlist(address dest, uint96 amount) public {
        vm.assume(dest != address(0) && dest != alice);
        amount = uint96(bound(amount, 1, 1_000 ether));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, dest));
        token.transfer(dest, amount);

        vm.prank(admin);
        token.setDestinationAllowed(alice, dest, true);

        vm.prank(alice);
        token.transfer(dest, amount);
        assertEq(token.balanceOf(dest), amount);
        assertEq(token.balanceOf(alice), 1_000 ether - amount);
    }

    /// @dev Approving one (holder, destination) pair must never authorise any other.
    function testFuzz_Allowlist_OnlyExactPairIsAuthorised(address dest, address other) public {
        vm.assume(dest != address(0) && other != address(0) && dest != other);

        vm.prank(admin);
        token.setDestinationAllowed(alice, dest, true);

        assertTrue(token.allowedDestination(alice, dest));
        assertFalse(token.allowedDestination(alice, other));

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, alice, other)
        );
        token.transfer(other, 1 ether);
    }
}
