// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { StrandsCustodyToken } from "../src/StrandsCustodyToken.sol";

/// @title  Shared test fixture
/// @notice Deploys the token, wires MINTER_ROLE / CUSTODIAN_ROLE and funds
///         `alice` with `INITIAL_MINT`. Every suite under `test/` extends this
///         so the starting state is identical across files.
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

    /// @dev The metadata `setUp` deploys with, in the exact shape the backend
    ///      composes: "Strands Custody <asset> (<custodian>)" / "sc<ASSET>".
    ///      ETH because the fixture is 18-decimal; `Metadata.t.sol` is where the
    ///      strings themselves are the subject.
    string internal constant NAME = "Strands Custody ETH (BitGo)";
    string internal constant SYMBOL = "scETH";

    /// @dev Role ids, read from the token in `setUp` so the CONTRACT stays the
    ///      source of truth. Cached because a `token.X_ROLE()` call placed after
    ///      a `vm.prank` / `vm.expectRevert` would consume the cheatcode before
    ///      the call under test runs — every auth suite used to hoist this by
    ///      hand, one line at a time.
    bytes32 internal DEFAULT_ADMIN_ROLE;
    bytes32 internal MINTER_ROLE;
    bytes32 internal CUSTODIAN_ROLE;

    event CustodyBurn(address indexed custodian, address indexed from, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public virtual {
        token = new StrandsCustodyToken(admin, 18, NAME, SYMBOL);

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

    // ---------- revert expectations ----------

    /// @dev Expect the next call to be rejected for lacking `role`.
    function _expectMissingRole(address caller, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role));
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

    function _expectTransferEvent(address from, address to, uint256 value) internal {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(from, to, value);
    }
}
