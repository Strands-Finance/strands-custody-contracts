// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { StrandsCustodyToken } from "../src/StrandsCustodyToken.sol";
import { StrandsAllowlistBatch } from "../src/StrandsAllowlistBatch.sol";

/// @title  Edge array literals for `setPairs` / `areAllowed`
/// @notice Split out of `BaseTest` so the invariant handler — which drives the
///         token directly rather than through the fixture — builds its batch
///         arguments the same way every other suite does.
abstract contract EdgeBuilder {
    function _edges(address h, address d) internal pure returns (StrandsAllowlistBatch.Edge[] memory e) {
        e = new StrandsAllowlistBatch.Edge[](1);
        e[0] = StrandsAllowlistBatch.Edge(h, d);
    }

    function _edges(address h1, address d1, address h2, address d2)
        internal
        pure
        returns (StrandsAllowlistBatch.Edge[] memory e)
    {
        e = new StrandsAllowlistBatch.Edge[](2);
        e[0] = StrandsAllowlistBatch.Edge(h1, d1);
        e[1] = StrandsAllowlistBatch.Edge(h2, d2);
    }
}

/// @title  Shared test fixture
/// @notice Deploys the token, wires MINTER_ROLE / CUSTODIAN_ROLE and funds
///         `alice` with `INITIAL_MINT`. Every suite under `test/` extends this
///         so the starting state is identical across files.
/// @dev    The allowlist starts EMPTY, which makes every inherited test double
///         as a regression test for the default-deny behavior.
abstract contract BaseTest is Test, EdgeBuilder {
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
    // under test — `allowlist/SetDestination.t.sol`, `batch/BatchLink.t.sol`,
    // `batch/Idempotency.t.sol` — keep calling the entrypoints directly, so what
    // is being asserted about stays visible at the call site.

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
        token.setPairs(_edges(a, b), true);
    }

    /// @dev Close both directions between `a` and `b`.
    function _unlink(address a, address b) internal {
        vm.prank(admin);
        token.setPairs(_edges(a, b), false);
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

    function _expectTransferEvent(address from, address to, uint256 value) internal {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(from, to, value);
    }

    /// @dev Assert how many events the window opened by `vm.recordLogs()` saw.
    function _assertLogCount(uint256 expected, string memory reason) internal view {
        assertEq(vm.getRecordedLogs().length, expected, reason);
    }
}
