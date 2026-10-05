// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { StrandsDACAP } from "../src/StrandsDACAP.sol";
import { ITransferAllowlist } from "../src/interfaces/ITransferAllowlist.sol";

/// @title  Shared test fixture
/// @notice Deploys the implementation and its beacon once, then the token as a
///         `BeaconProxy` — the only shape a token is ever deployed in. The
///         deploy seats `admin` as admin and minter; the fixture then hands
///         MINTER_ROLE to `minter` and funds `alice` with `INITIAL_MINT`. Every suite under `test/` extends this so
///         the starting state is identical across files, and so every suite runs
///         THROUGH the proxy without saying so.
///
///         On a fork of Ethereum Sepolia (`forge test --fork-url sepolia`) the implementation and beacon are NOT
///         deployed: the fixture takes the ones already deployed there (`SEPOLIA_BEACON`, recorded in DEPLOYMENTS.md),
///         and every token is a proxy of that beacon. So the same suites, unchanged, run against the code that is on
///         Sepolia rather than a fresh build of `src/`.
/// @dev    The transfer allowlist starts EMPTY and `setUp` opens nothing. That
///         is what makes the mint and burn suites double as the proof that
///         issuance and redemption are exempt: they run start to finish against
///         a list with no entries in it. The suites that need a destination open
///         say so in their own `setUp` override.
abstract contract BaseTest is Test {
    StrandsDACAP internal token;

    /// @dev The code every proxy delegates to, and the beacon that names it. One of each, however many
    ///      tokens a suite deploys.
    StrandsDACAP internal implementation;
    UpgradeableBeacon internal beacon;

    /// @dev Owns the beacon and nothing else: no role on any token. The one address that can upgrade. On a Sepolia fork,
    ///      whoever owns the deployed beacon there.
    address internal beaconOwner = makeAddr("beaconOwner");

    uint256 internal constant SEPOLIA = 11_155_111;

    /// @dev The beacon deployed on Ethereum Sepolia; see DEPLOYMENTS.md.
    address internal constant SEPOLIA_BEACON = 0x47A6aDF49f9D2dF03d1b8e2319A79A0dD47E8Df7;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    /// @dev What `setUp` seeds `alice` with. Suites assert against this rather
    ///      than a bare `1_000 ether` so the coupling to the fixture is visible.
    uint256 internal constant INITIAL_MINT = 1_000 ether;

    /// @dev The metadata `setUp` deploys with, in the exact shape the backend
    ///      composes: "Strands.DACAP.<custodian>.<ASSET>", used for BOTH name
    ///      and symbol. ETH because the fixture is 18-decimal; `Metadata.t.sol`
    ///      is where the strings themselves are the subject.
    string internal constant NAME = "Strands.DACAP.BitGo.ETH";
    string internal constant SYMBOL = "Strands.DACAP.BitGo.ETH";

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
        if (block.chainid == SEPOLIA) {
            beacon = UpgradeableBeacon(SEPOLIA_BEACON);
            implementation = StrandsDACAP(beacon.implementation());
            beaconOwner = beacon.owner();
        } else {
            implementation = new StrandsDACAP();
            beacon = new UpgradeableBeacon(address(implementation), beaconOwner);
        }

        // Read before the first deploy, which uses them to hand MINTER_ROLE on. The implementation answers for
        // every proxy: both are constants in its code.
        DEFAULT_ADMIN_ROLE = implementation.DEFAULT_ADMIN_ROLE();
        MINTER_ROLE = implementation.MINTER_ROLE();

        // `admin` deploys, so `admin` is the ONLY admin — `AdminLifecycle.t.sol`'s "last admin" assertions depend
        // on that being exactly true — and `minter` the only minter.
        token = _deploy(18, NAME, SYMBOL);

        vm.prank(minter);
        token.mint(alice, INITIAL_MINT);
    }

    // ---------- fixtures ----------

    /// @dev A token exactly as production deploys one: a `BeaconProxy` created by `deployer`, whose constructor
    ///      runs `initializeToken` in the same transaction. `deployer` comes out holding DEFAULT_ADMIN_ROLE AND
    ///      MINTER_ROLE, and nobody else holds anything. The encoding is done before the prank, so the prank
    ///      lands on the creation itself.
    function _deployAs(address deployer, uint8 decimals_, string memory name_, string memory symbol_)
        internal
        returns (StrandsDACAP t)
    {
        bytes memory init = abi.encodeCall(StrandsDACAP.initializeToken, (decimals_, name_, symbol_));
        vm.prank(deployer);
        t = StrandsDACAP(address(new BeaconProxy(address(beacon), init)));
    }

    /// @dev A token wired like the fixture's: deployed by `admin`, which then hands MINTER_ROLE to `minter` and
    ///      gives up its own — the ordinary grant-then-renounce hand-off, after the deploy. Governance and
    ///      operations end up on separate addresses, which is the standing state the role suites assume.
    function _deploy(uint8 decimals_, string memory name_, string memory symbol_) internal returns (StrandsDACAP t) {
        t = _deployAs(admin, decimals_, name_, symbol_);
        vm.startPrank(admin);
        t.grantRole(MINTER_ROLE, minter);
        t.renounceRole(MINTER_ROLE, admin);
        vm.stopPrank();
    }

    /// @dev A token at an arbitrary magnitude, wired like the fixture's. Metadata is deliberately generic —
    ///      the suites that use this are about arithmetic, and `Metadata.t.sol` owns naming.
    function _deployWithDecimals(uint8 decimals_) internal returns (StrandsDACAP t) {
        t = _deploy(decimals_, "Strands.DACAP.Fixture", "Strands.DACAP.Fixture");
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

    /// @dev Expect `initializeToken` on a token that already ran it (or on the locked implementation) to be refused.
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
