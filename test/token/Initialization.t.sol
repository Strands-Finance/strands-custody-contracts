// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { StrandsDACAP } from "../../src/StrandsDACAP.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice A token is initialized once, inside its own deploy: the `BeaconProxy` constructor runs `initializeToken`,
///         which fixes the metadata and seats the DEPLOYER as both DEFAULT_ADMIN_ROLE and MINTER_ROLE. There is no
///         second transaction, so there is no window between "deployed" and "usable" for anyone to step into. Three
///         properties carry it:
///
///         1. The deploy seats the deployer, and nobody else, in both roles. The token is live the moment the deploy
///            returns.
///         2. `initializeToken` cannot run again on a deployed token, for anyone. A replay that got through would hand
///            its caller both roles, or rename the token.
///         3. Moving a role elsewhere is the ordinary grant-then-renounce, and leaves exactly the named holders.
///
/// @dev    The fixture's `token` has already had MINTER_ROLE handed from `admin` to `minter`, so the tests about the
///         deploy itself use `_deployAs`, which stops at the deploy.
contract InitializationTest is BaseTest {
    address internal deployer = makeAddr("deployer");

    // ---------- what the deploy leaves behind ----------

    /// @dev Both roles go to `msg.sender` of the proxy's creation — the deployer — and to no argument.
    function test_Deploy_SeatsTheDeployerAsAdminAndMinter() public {
        StrandsDACAP fresh = _deployAs(deployer, 18, NAME, SYMBOL);

        assertTrue(fresh.hasRole(DEFAULT_ADMIN_ROLE, deployer), "the deployer is admin");
        assertTrue(fresh.hasRole(MINTER_ROLE, deployer), "and minter");
    }

    /// @dev And to nobody else: not the account running the test, not the fixture's role holders, not a holder, not
    ///      the beacon or its owner. A role that leaked to any of them would be standing privilege nobody declared.
    function test_Deploy_SeatsNobodyElse() public {
        StrandsDACAP fresh = _deployAs(deployer, 18, NAME, SYMBOL);

        address[6] memory others = [address(this), admin, minter, alice, beaconOwner, address(beacon)];
        for (uint256 i = 0; i < others.length; i++) {
            assertFalse(fresh.hasRole(DEFAULT_ADMIN_ROLE, others[i]), "no one else is admin");
            assertFalse(fresh.hasRole(MINTER_ROLE, others[i]), "no one else is minter");
        }
        assertEq(fresh.totalSupply(), 0, "a fresh token has no supply");
    }

    /// @dev The metadata is the deploy's business, and has no setter afterwards. Pinned here because a mis-ordered
    ///      `initializeToken` argument list would compile.
    function test_Deploy_SetsMetadata() public {
        StrandsDACAP fresh = _deployAs(deployer, 6, "Strands.DACAP.BitGo.USDC", "Strands.DACAP.BitGo.USDC");

        assertEq(fresh.decimals(), 6);
        assertEq(fresh.name(), "Strands.DACAP.BitGo.USDC");
        assertEq(fresh.symbol(), "Strands.DACAP.BitGo.USDC");
    }

    /// @dev Exactly one initializer runs, at version 1. A second one — the old `initialize`, or anything a later
    ///      change slips in — would show up here as a second `Initialized` event.
    function test_Deploy_RunsExactlyOneInitializer() public {
        vm.recordLogs();
        StrandsDACAP fresh = _deployAs(deployer, 18, NAME, SYMBOL);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 count;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(fresh) && logs[i].topics[0] == Initialized.selector) {
                assertEq(abi.decode(logs[i].data, (uint64)), 1, "the one initializer is version 1");
                count++;
            }
        }
        assertEq(count, 1, "the deploy runs exactly one initializer");
    }

    /// @dev Live from the deploy, with no second transaction: the deployer mints, burns and opens a destination at
    ///      once. This is the backend's shape, where one mint-authority key is deployer, admin and minter.
    function test_Deploy_TokenIsLiveImmediately() public {
        StrandsDACAP fresh = _deployAs(deployer, 18, NAME, SYMBOL);

        vm.startPrank(deployer);
        fresh.guardMint(alice, 100 ether, 0);
        fresh.guardBurn(alice, 40 ether, 100 ether);
        fresh.setDestinationAllowed(bob, true);
        vm.stopPrank();

        vm.prank(alice);
        fresh.transfer(bob, 10 ether);

        assertEq(fresh.balanceOf(alice), 50 ether);
        assertEq(fresh.balanceOf(bob), 10 ether);
        assertEq(fresh.totalSupply(), 60 ether, "the deployer reaches every power the deploy gave it");
    }

    // ---------- the deploy cannot be replayed ----------

    /// @dev `initializeToken` does what a constructor would, but unlike a constructor it is an external function, and
    ///      it grants both roles to its caller. "Only the deployer is seated" and "the metadata has no setter"
    ///      therefore rest on its `initializer` guard rather than on the language. Tried on a fresh token and on the
    ///      fixture's, by the deployer, the seated admin and a stranger.
    function test_InitializeToken_CannotBeReplayedOnADeployedToken() public {
        StrandsDACAP fresh = _deployAs(deployer, 18, NAME, SYMBOL);
        address attacker = makeAddr("attacker");

        address[4] memory callers = [deployer, admin, minter, attacker];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            _expectAlreadyInitialized();
            fresh.initializeToken(6, "Strands.DACAP.Replayed", "Strands.DACAP.Replayed");

            vm.prank(callers[i]);
            _expectAlreadyInitialized();
            token.initializeToken(6, "Strands.DACAP.Replayed", "Strands.DACAP.Replayed");
        }

        assertEq(fresh.name(), NAME, "a refused replay renames nothing");
        assertEq(fresh.decimals(), 18, "nor changes decimals");
        assertEq(token.name(), NAME);
        assertEq(token.decimals(), 18);
        assertFalse(fresh.hasRole(DEFAULT_ADMIN_ROLE, attacker), "and seats no admin");
        assertFalse(fresh.hasRole(MINTER_ROLE, attacker), "and no minter");
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, attacker));
        assertFalse(token.hasRole(MINTER_ROLE, attacker));
    }

    /// @dev No address is special: every caller is refused, and none is seated. The deployer is excluded only because
    ///      it already holds both roles, which would make the closing assertions meaningless; the test above covers
    ///      its refusal.
    function testFuzz_InitializeToken_IsRefusedForAnyCaller(address caller) public {
        vm.assume(caller != deployer);
        StrandsDACAP fresh = _deployAs(deployer, 18, NAME, SYMBOL);

        vm.prank(caller);
        _expectAlreadyInitialized();
        fresh.initializeToken(6, "Strands.DACAP.Replayed", "Strands.DACAP.Replayed");

        assertFalse(fresh.hasRole(DEFAULT_ADMIN_ROLE, caller), "no caller is seated as admin by a replay");
        assertFalse(fresh.hasRole(MINTER_ROLE, caller), "nor as minter");
    }

    // ---------- handing the roles on ----------

    /// @dev Moving the roles off the deploying key is ordinary AccessControl, by that key: grant to the new holders,
    ///      then renounce its own. Afterwards the role graph is exactly the named holders, and the deployer can do
    ///      nothing — no residual privilege for an auditor to chase.
    function test_HandOff_GrantThenRenounce_LeavesExactlyTheNamedHolders() public {
        StrandsDACAP fresh = _deployAs(deployer, 18, NAME, SYMBOL);

        vm.startPrank(deployer);
        fresh.grantRole(DEFAULT_ADMIN_ROLE, admin);
        fresh.grantRole(MINTER_ROLE, minter);
        fresh.renounceRole(MINTER_ROLE, deployer);
        fresh.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        vm.stopPrank();

        assertTrue(fresh.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(fresh.hasRole(MINTER_ROLE, minter));
        assertFalse(fresh.hasRole(MINTER_ROLE, admin), "the admin is not a minter");
        assertFalse(fresh.hasRole(DEFAULT_ADMIN_ROLE, minter), "the operating role does not carry admin");
        assertFalse(fresh.hasRole(DEFAULT_ADMIN_ROLE, deployer), "the deployer's admin is spent");
        assertFalse(fresh.hasRole(MINTER_ROLE, deployer), "and its minter");

        vm.prank(deployer);
        _expectNotMinter(deployer);
        fresh.mint(alice, 1);

        vm.prank(minter);
        fresh.mint(alice, 1);
        assertEq(fresh.balanceOf(alice), 1, "the new minter works");
    }
}
