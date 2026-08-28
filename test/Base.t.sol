// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { StrandsDACAP } from "../src/StrandsDACAP.sol";
import { ITransferAllowlist } from "../src/interfaces/ITransferAllowlist.sol";

/// @title  Shared test fixture
/// @notice Deploys the token, seats DEFAULT_ADMIN_ROLE / MINTER_ROLE through
///         `initialize` and funds `alice` with `INITIAL_MINT`. Every suite under
///         `test/` extends this so the starting state is identical across files.
/// @dev    The transfer allowlist starts EMPTY and `setUp` opens nothing. That
///         is what makes the mint and burn suites double as the proof that
///         issuance and redemption are exempt: they run start to finish against
///         a list with no entries in it. The suites that need a destination open
///         say so in their own `setUp` override.
abstract contract BaseTest is Test {
    StrandsDACAP internal token;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
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

    event Burned(address indexed burnedBy, address indexed from, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Initialized(uint64 version);

    function setUp() public virtual {
        // This test contract is the deployer, so the constructor seats IT as DEFAULT_ADMIN_ROLE — which is
        // what lets it call `initialize` and hand the role on to `admin` in the same step. No `vm.prank`
        // wrapper: pranking the deploy would seat a different admin than the one that initializes.
        token = new StrandsDACAP(18, NAME, SYMBOL);

        DEFAULT_ADMIN_ROLE = token.DEFAULT_ADMIN_ROLE();
        MINTER_ROLE = token.MINTER_ROLE();

        // Hands DEFAULT_ADMIN_ROLE to `admin` and revokes this contract's, so `admin` is the ONLY holder —
        // `AdminLifecycle.t.sol`'s "last admin" assertions depend on that being exactly true.
        token.initialize(admin, minter);

        vm.prank(minter);
        token.mint(alice, INITIAL_MINT);
    }

    // ---------- fixtures ----------

    /// @dev A token at an arbitrary magnitude, wired like the fixture's. Metadata is deliberately generic —
    ///      the suites that use this are about arithmetic, and `Metadata.t.sol` owns naming. The role ids are
    ///      keccak constants, so the cached MINTER_ROLE applies to any instance.
    function _deployWithDecimals(uint8 decimals_) internal returns (StrandsDACAP t) {
        t = new StrandsDACAP(decimals_, "Strands Custody Fixture", "scFIX");
        t.initialize(admin, minter);
    }

    /// @dev A deployed but DELIBERATELY UNINITIALIZED token — no minter, and this test contract still holding
    ///      DEFAULT_ADMIN_ROLE. The state a deploy leaves behind before its second transaction.
    function _deployUninitialized() internal returns (StrandsDACAP t) {
        t = new StrandsDACAP(18, NAME, SYMBOL);
    }

    // ---------- allowlist arrangement (admin-pranked) ----------

    /// @dev Open one destination. One argument, not two — the list is keyed by
    ///      destination alone, so there is no holder to name and no direction to
    ///      choose.
    function _allow(address destination) internal {
        vm.prank(admin);
        token.setDestinationAllowed(destination, true);
    }

    /// @dev Close one destination.
    function _disallow(address destination) internal {
        vm.prank(admin);
        token.setDestinationAllowed(destination, false);
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

    /// @dev Expect the next call to be rejected by the destination allowlist.
    ///      The error is declared on `ITransferAllowlist`, so it is NOT
    ///      reachable as `StrandsDACAP.TransferDestinationNotAllowed` —
    ///      an inherited error is not a member of the deriving type. Hiding that
    ///      qualification here is the same move `_expectMissingRole` makes for
    ///      `IAccessControl.AccessControlUnauthorizedAccount`.
    function _expectDestinationNotAllowed(address destination) internal {
        vm.expectRevert(abi.encodeWithSelector(ITransferAllowlist.TransferDestinationNotAllowed.selector, destination));
    }

    /// @dev Expect `renounceRole` to be rejected for a confirmation argument that
    ///      is not the caller. The one AccessControl error no role gate reaches.
    function _expectBadConfirmation() internal {
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
    }

    /// @dev Expect a second `initialize` (or one on an already-initialized token) to be refused.
    function _expectAlreadyInitialized() internal {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
    }

    /// @dev Expect a guarded call to refuse `estimated` against the chain's `actual`.
    function _expectSupplyMismatch(uint256 actual, uint256 estimated) internal {
        vm.expectRevert(abi.encodeWithSelector(StrandsDACAP.SupplyMismatch.selector, actual, estimated));
    }

    // ---------- event expectations ----------

    /// @dev `by` rather than `minter` — the fixture already binds that name, and the burner is only ever the
    ///      fixture's minter by convention, not by anything the event itself requires.
    function _expectBurnedEvent(address by, address from, uint256 amount) internal {
        vm.expectEmit(true, true, false, true, address(token));
        emit Burned(by, from, amount);
    }

    function _expectTransferEvent(address from, address to, uint256 value) internal {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(from, to, value);
    }
}
