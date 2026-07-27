// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { StrandsCustodyToken } from "../src/StrandsCustodyToken.sol";
import { StrandsAllowlistBatch } from "../src/StrandsAllowlistBatch.sol";

/// @title  Shared test fixture
/// @notice Deploys the token, wires MINTER_ROLE / CUSTODIAN_ROLE and funds
///         `alice` with 1_000 ether. Every suite under `test/` extends this so
///         the starting state is identical across files.
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

    event CustodyBurn(address indexed custodian, address indexed from, uint256 amount);
    event DestinationAllowedSet(address indexed holder, address indexed destination, bool allowed);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public virtual {
        token = new StrandsCustodyToken(admin, 18);

        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        token.grantRole(token.CUSTODIAN_ROLE(), custodian);
        vm.stopPrank();

        vm.prank(minter);
        token.mint(alice, 1_000 ether);
    }

    // ---------- helpers ----------

    /// @dev Open a single directed edge as the admin.
    function _allow(address holder, address destination) internal {
        vm.prank(admin);
        token.setDestinationAllowed(holder, destination, true);
    }

    /// @dev Expect the next call to be rejected by the destination allowlist.
    function _expectNotAllowed(address holder, address destination) internal {
        vm.expectRevert(
            abi.encodeWithSelector(StrandsCustodyToken.TransferDestinationNotAllowed.selector, holder, destination)
        );
    }

    /// @dev Expect the next call to be rejected for lacking DEFAULT_ADMIN_ROLE.
    function _expectNotAdmin(address caller) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, bytes32(0))
        );
    }

    // ---------- array literals for the batch entrypoints ----------

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

    function _addrs(address a) internal pure returns (address[] memory x) {
        x = new address[](1);
        x[0] = a;
    }

    function _addrs(address a, address b) internal pure returns (address[] memory x) {
        x = new address[](2);
        x[0] = a;
        x[1] = b;
    }

    function _bools(bool a, bool b) internal pure returns (bool[] memory x) {
        x = new bool[](2);
        x[0] = a;
        x[1] = b;
    }
}
