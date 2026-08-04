// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { StrandsCustodyToken } from "../src/StrandsCustodyToken.sol";

/// @title  Shared test fixture
/// @notice Deploys the token, wires MINTER_ROLE / CUSTODIAN_ROLE and funds
///         `alice` with `INITIAL_MINT`. Every suite under `test/` extends this
///         so the starting state is identical across files.
/// @dev    The allowlist starts EMPTY, which makes every inherited test double
///         as a regression test for the default-deny behavior.
abstract contract BaseTest is Test {
    StrandsCustodyToken internal token;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
    address internal custodian = makeAddr("custodian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    /// @dev What `setUp` seeds `alice` with. Suites assert against this rather
    ///      than a bare `1_000 ether` so the coupling to the fixture is visible.
    uint256 internal constant INITIAL_MINT = 1_000 ether;

    /// @dev Role ids, read from the token in `setUp` so the CONTRACT stays the
    ///      source of truth. Cached because a `token.X_ROLE()` call placed after
    ///      a `vm.prank` / `vm.expectRevert` would consume the cheatcode before
    ///      the call under test runs — every auth suite used to hoist this by
    ///      hand, one line at a time.
    bytes32 internal DEFAULT_ADMIN_ROLE;
    bytes32 internal MINTER_ROLE;
    bytes32 internal CUSTODIAN_ROLE;

    event CustodyBurn(address indexed custodian, address indexed from, uint256 amount);
    event DestinationAllowedSet(address indexed holder, address indexed destination, bool allowed);
    event AdminTransfer(address indexed admin, address indexed from, address indexed to, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public virtual {
        token = new StrandsCustodyToken(admin, 18);

        DEFAULT_ADMIN_ROLE = token.DEFAULT_ADMIN_ROLE();
        MINTER_ROLE = token.MINTER_ROLE();
        CUSTODIAN_ROLE = token.CUSTODIAN_ROLE();

        vm.startPrank(admin);
        token.grantRole(MINTER_ROLE, minter);
        token.grantRole(CUSTODIAN_ROLE, custodian);
        vm.stopPrank();

        vm.prank(minter);
        token.mint(alice, INITIAL_MINT);
    }

    // ---------- allowlist arrangement (admin-pranked) ----------
    //
    // These wrap ARRANGEMENT only. Suites where the setter itself is the subject
    // under test — `allowlist/SetDestination.t.sol`, `allowlist/SetLink.t.sol` —
    // keep calling the entrypoints directly, so what is being asserted about
    // stays visible at the call site.

    /// @dev Open one directed edge.
    function _allow(address holder, address destination) internal {
        vm.prank(admin);
        token.setDestinationAllowed(holder, destination, true);
    }

    /// @dev Close one directed edge.
    function _disallow(address holder, address destination) internal {
        vm.prank(admin);
        token.setDestinationAllowed(holder, destination, false);
    }

    /// @dev Open both directions between `a` and `b` — one link, two edges.
    function _link(address a, address b) internal {
        vm.prank(admin);
        token.setLink(a, b, true);
    }

    /// @dev Close both directions between `a` and `b`.
    function _unlink(address a, address b) internal {
        vm.prank(admin);
        token.setLink(a, b, false);
    }

    // ---------- allowlist reads ----------

    /// @dev Both directions open between `a` and `b`. Derived rather than
    ///      stored: the token exposes only the directed `allowedDestination`
    ///      mapping, so a link is two reads.
    function _isLinked(address a, address b) internal view returns (bool) {
        return token.allowedDestination(a, b) && token.allowedDestination(b, a);
    }

    // ---------- revert expectations ----------

    /// @dev Expect the next call to be rejected by the destination allowlist.
    function _expectNotAllowed(address holder, address destination) internal {
        vm.expectRevert(
            abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, holder, destination)
        );
    }

    /// @dev The `AccessControlUnauthorizedAccount` payload as raw bytes, for
    ///      tests that compare a low-level call's return data byte-for-byte
    ///      instead of going through a cheatcode.
    function _missingRoleData(address caller, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role);
    }

    /// @dev Expect the next call to be rejected for lacking `role`.
    function _expectMissingRole(address caller, bytes32 role) internal {
        vm.expectRevert(_missingRoleData(caller, role));
    }

    function _expectNotAdmin(address caller) internal {
        _expectMissingRole(caller, DEFAULT_ADMIN_ROLE);
    }

    function _expectNotMinter(address caller) internal {
        _expectMissingRole(caller, MINTER_ROLE);
    }

    function _expectNotCustodian(address caller) internal {
        _expectMissingRole(caller, CUSTODIAN_ROLE);
    }

    /// @dev Expect `renounceRole` to be rejected for a confirmation argument that
    ///      is not the caller. The one AccessControl error no role gate reaches.
    function _expectBadConfirmation() internal {
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
    }

    // ---------- event expectations ----------

    /// @dev `by` rather than `custodian` — the fixture already binds that name.
    function _expectCustodyBurnEvent(address by, address from, uint256 amount) internal {
        vm.expectEmit(true, true, false, true, address(token));
        emit CustodyBurn(by, from, amount);
    }

    function _expectDestinationAllowedSetEvent(address holder, address destination, bool allowed) internal {
        vm.expectEmit(true, true, false, true, address(token));
        emit DestinationAllowedSet(holder, destination, allowed);
    }

    /// @dev `by` rather than `admin` — the fixture already binds that name.
    function _expectAdminTransferEvent(address by, address from, address to, uint256 amount) internal {
        vm.expectEmit(true, true, true, true, address(token));
        emit AdminTransfer(by, from, to, amount);
    }

    function _expectTransferEvent(address from, address to, uint256 value) internal {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(from, to, value);
    }

    /// @dev Assert how many events the window opened by `vm.recordLogs()` saw.
    function _assertLogCount(uint256 expected, string memory reason) internal view {
        assertEq(vm.getRecordedLogs().length, expected, reason);
    }
}
