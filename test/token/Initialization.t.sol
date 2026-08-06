// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StrandsCustodyToken } from "../../src/StrandsCustodyToken.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice Deployment is two transactions — `constructor` then `initialize` — and this suite owns the gap
///         between them. Three properties carry it:
///
///         1. The constructor seats the DEPLOYER as admin and grants no operating role, so the window is
///            INERT (nothing mints, nothing burns) and RECOVERABLE (the deployer can still initialize).
///         2. `initialize` is admin-only, which is what makes it un-front-runnable. `initializer` alone would
///            let a stranger seat themselves as the token's minter between the two transactions — and with
///            one operating role, that is the whole of its mint AND burn authority.
///         3. `initialize` runs exactly once, which is what stops an admin silently re-seating a different
///            minter under a call named "initialize".
///
/// @dev    The fixture's `token` is already initialized, so most tests here deploy their own via
///         `_deployUninitialized()`. This test contract is the deployer of those, and therefore their admin.
contract InitializationTest is BaseTest {
    // ---------- what the constructor leaves behind ----------

    /// @dev The admin goes to `msg.sender` — NOT to a constructor argument, which is the change that makes
    ///      `initialize` safe to leave external. Asserting the deployer holds it and the eventual admin does
    ///      not is what distinguishes this from the old four-argument constructor.
    function test_Constructor_GrantsAdminToTheDeployerAndNothingElse() public {
        StrandsCustodyToken fresh = _deployUninitialized();

        assertTrue(fresh.hasRole(DEFAULT_ADMIN_ROLE, address(this)), "the deployer is the bootstrap admin");
        assertFalse(fresh.hasRole(DEFAULT_ADMIN_ROLE, admin), "the eventual admin arrives only via initialize");
        assertFalse(fresh.hasRole(MINTER_ROLE, address(this)), "the deployer must not arrive as a minter");
        assertEq(fresh.totalSupply(), 0, "a fresh token has no supply");
    }

    /// @dev The metadata is still the constructor's business, and still immutable. Pinned here because the
    ///      constructor lost a parameter and a mis-ordered argument list would compile.
    function test_Constructor_StillSetsMetadata() public {
        StrandsCustodyToken fresh = new StrandsCustodyToken(6, "Strands Custody USDC (BitGo)", "scUSDC");

        assertEq(fresh.decimals(), 6);
        assertEq(fresh.name(), "Strands Custody USDC (BitGo)");
        assertEq(fresh.symbol(), "scUSDC");
    }

    /// @dev The safe-failure claim, asserted rather than argued: a deploy whose second transaction never
    ///      landed can move no supply, for anyone, through any entrypoint. Every actor is tried — including
    ///      the deployer, who holds admin and might be assumed to inherit the operating role with it.
    function test_UninitializedToken_IsInert() public {
        StrandsCustodyToken fresh = _deployUninitialized();

        address[4] memory parties = [address(this), admin, minter, alice];
        for (uint256 i = 0; i < parties.length; i++) {
            vm.startPrank(parties[i]);

            _expectMissingRole(parties[i], MINTER_ROLE);
            fresh.mint(alice, 1 ether);

            _expectMissingRole(parties[i], MINTER_ROLE);
            fresh.guardMint(alice, 1 ether, 0);

            _expectMissingRole(parties[i], MINTER_ROLE);
            fresh.guardBurn(alice, 1 ether, 0);

            _expectMissingRole(parties[i], MINTER_ROLE);
            fresh.adminBurn(alice, 1 ether);

            _expectMissingRole(parties[i], MINTER_ROLE);
            fresh.burn(1 ether);

            _expectMissingRole(parties[i], MINTER_ROLE);
            fresh.burnFrom(alice, 1 ether);

            vm.stopPrank();
        }

        assertEq(fresh.totalSupply(), 0, "an uninitialized token issues nothing");
    }

    /// @dev Inert is not bricked. The deployer still holds admin, so the deploy is recoverable by finishing
    ///      it — no redeploy, no orphaned contract.
    function test_UninitializedToken_IsStillRecoverableByTheDeployer() public {
        StrandsCustodyToken fresh = _deployUninitialized();

        fresh.initialize(admin, minter);

        vm.prank(minter);
        fresh.mint(alice, 1 ether);
        assertEq(fresh.balanceOf(alice), 1 ether, "finishing the deploy is all the recovery needed");
    }

    // ---------- what initialize seats ----------

    function test_Initialize_SeatsBothRoles() public {
        StrandsCustodyToken fresh = _deployUninitialized();

        fresh.initialize(admin, minter);

        assertTrue(fresh.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(fresh.hasRole(MINTER_ROLE, minter));
    }

    /// @dev Each role goes to the address NAMED for it. Two distinct addresses, so a swapped argument pair
    ///      fails here rather than in whichever suite happens to exercise the wrong power first — and this is
    ///      the assertion that keeps governance and operations separable at all, since an `initialize` that
    ///      handed both to one argument would look identical from `hasRole(DEFAULT_ADMIN_ROLE, admin)` alone.
    function test_Initialize_DoesNotCrossWireTheRoles() public {
        StrandsCustodyToken fresh = _deployUninitialized();

        fresh.initialize(admin, minter);

        assertFalse(fresh.hasRole(MINTER_ROLE, admin), "the admin is not a minter");
        assertFalse(fresh.hasRole(DEFAULT_ADMIN_ROLE, minter), "the operating role does not carry admin");
    }

    function test_Initialize_EmitsInitialized() public {
        StrandsCustodyToken fresh = _deployUninitialized();

        vm.expectEmit(false, false, false, true, address(fresh));
        emit Initialized(1);

        fresh.initialize(admin, minter);
    }

    /// @dev Hand off, do not accumulate. A deployer that kept admin would be standing privilege nobody
    ///      declared — exactly the thing an auditor reading `initialize`'s arguments would not expect.
    function test_Initialize_RevokesTheDeployersAdminWhenAdminIsSomeoneElse() public {
        StrandsCustodyToken fresh = _deployUninitialized();

        fresh.initialize(admin, minter);

        assertFalse(fresh.hasRole(DEFAULT_ADMIN_ROLE, address(this)), "the deployer's bootstrap admin is spent");

        _expectNotAdmin(address(this));
        fresh.grantRole(MINTER_ROLE, carol);
        assertFalse(fresh.hasRole(MINTER_ROLE, carol), "and the revocation is effective immediately");
    }

    /// @dev The backend's actual shape: one mint-authority EOA is deployer, admin and minter. The revoke must
    ///      be SKIPPED there, not performed-and-undone — a token whose only admin revoked itself would have a
    ///      frozen role graph from birth.
    function test_Initialize_KeepsTheDeployersAdminWhenItIsTheAdmin() public {
        StrandsCustodyToken fresh = _deployUninitialized();

        fresh.initialize(address(this), address(this));

        assertTrue(fresh.hasRole(DEFAULT_ADMIN_ROLE, address(this)), "self-handoff must not strip the admin");
        assertTrue(fresh.hasRole(MINTER_ROLE, address(this)));

        fresh.grantRole(MINTER_ROLE, carol);
        assertTrue(fresh.hasRole(MINTER_ROLE, carol), "the role graph is still live");
    }

    /// @dev The whole point, end to end: the seated role must actually WORK, in both directions. `hasRole`
    ///      reading true proves the mapping was written, not that any entrypoint accepts the holder.
    function test_Initialize_LeavesTheTokenMintableAndBurnableEndToEnd() public {
        StrandsCustodyToken fresh = _deployUninitialized();
        fresh.initialize(admin, minter);

        vm.startPrank(minter);
        fresh.guardMint(alice, 100 ether, 0);
        fresh.guardBurn(alice, 40 ether, 100 ether);
        fresh.adminBurn(alice, 10 ether);
        vm.stopPrank();

        assertEq(fresh.balanceOf(alice), 50 ether);
        assertEq(fresh.totalSupply(), 50 ether, "the minter reaches every power initialize gave it");
    }

    // ---------- who may initialize ----------

    /// @dev The front-running case, written as the scenario rather than as a bare role assertion. A CREATE
    ///      deploy is visible the moment it lands; if `initializer` were the only guard, the first stranger to
    ///      call would own the token's mint and burn authority outright.
    function test_Initialize_CannotBeFrontRunByAStranger() public {
        StrandsCustodyToken fresh = _deployUninitialized();
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        _expectMissingRole(attacker, DEFAULT_ADMIN_ROLE);
        fresh.initialize(attacker, attacker);

        assertFalse(fresh.hasRole(MINTER_ROLE, attacker), "no self-seating");
        assertFalse(fresh.hasRole(DEFAULT_ADMIN_ROLE, attacker));

        // ...and the legitimate deployer's initialize still works afterwards: a refused attempt must not
        // consume the one shot.
        fresh.initialize(admin, minter);
        assertTrue(fresh.hasRole(MINTER_ROLE, minter), "a rejected attempt must not burn the initializer");
    }

    /// @dev No address is special. Every caller but the deployer is refused, at every argument shape.
    function testFuzz_ArbitraryNonDeployer_CannotInitialize(address caller) public {
        vm.assume(caller != address(this));
        StrandsCustodyToken fresh = _deployUninitialized();

        vm.prank(caller);
        _expectMissingRole(caller, DEFAULT_ADMIN_ROLE);
        fresh.initialize(admin, minter);

        assertFalse(fresh.hasRole(MINTER_ROLE, minter), "nothing was seated");
    }

    /// @dev The recovery path for a deploy from a key that is being retired: admin can be rotated BEFORE
    ///      initialize, and the successor inherits the right to finish the deploy.
    function test_Initialize_MayBeCompletedByARotatedAdmin() public {
        StrandsCustodyToken fresh = _deployUninitialized();

        fresh.grantRole(DEFAULT_ADMIN_ROLE, carol);
        fresh.renounceRole(DEFAULT_ADMIN_ROLE, address(this));

        vm.prank(carol);
        fresh.initialize(admin, minter);

        assertTrue(fresh.hasRole(MINTER_ROLE, minter), "the successor can finish what the deployer started");
        assertFalse(fresh.hasRole(DEFAULT_ADMIN_ROLE, carol), "and hands admin on in the same call");
    }

    // ---------- exactly once ----------

    function test_Initialize_RevertsOnSecondCall() public {
        StrandsCustodyToken fresh = _deployUninitialized();
        fresh.initialize(admin, minter);

        vm.prank(admin);
        _expectAlreadyInitialized();
        fresh.initialize(admin, carol);

        assertFalse(fresh.hasRole(MINTER_ROLE, carol), "a refused re-initialize seats nothing");
        assertTrue(fresh.hasRole(MINTER_ROLE, minter), "and leaves the original wiring intact");
    }

    /// @dev The fixture's own token, re-initialized by its live admin. `onlyRole` passes here — `admin` really
    ///      does hold DEFAULT_ADMIN_ROLE — so this is the case where `initializer` is the ONLY thing standing
    ///      between an admin and a silent minter swap under a call named "initialize".
    function test_Initialize_CannotBeReplayedByTheLiveAdmin() public {
        vm.prank(admin);
        _expectAlreadyInitialized();
        token.initialize(admin, carol);

        assertFalse(token.hasRole(MINTER_ROLE, carol));
    }

    /// @dev And it does not become available again after an admin rotation — `initializer` is a property of
    ///      the CONTRACT, not of the caller. Kills the reading where each new admin gets a fresh shot.
    function test_Initialize_CannotBeReplayedAfterAdminHandoff() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        token.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);

        vm.prank(newAdmin);
        _expectAlreadyInitialized();
        token.initialize(newAdmin, carol);

        assertFalse(token.hasRole(MINTER_ROLE, carol), "a new admin inherits no fresh initializer");
    }

    /// @dev A non-admin calling an ALREADY-initialized token is refused by the role gate, not the initializer.
    ///      Both guards are live, and they fail for distinguishable reasons — which is what makes a revert
    ///      readable to whoever is debugging the deploy.
    function test_Initialize_NonAdminOnInitializedToken_FailsTheRoleGateFirst() public {
        vm.prank(alice);
        _expectMissingRole(alice, DEFAULT_ADMIN_ROLE);
        token.initialize(alice, alice);
    }

    // ---------- argument validation ----------

    function test_Initialize_RevertsOnZeroAdmin() public {
        StrandsCustodyToken fresh = _deployUninitialized();

        vm.expectRevert(bytes("admin=0"));
        fresh.initialize(address(0), minter);
    }

    function test_Initialize_RevertsOnZeroMinter() public {
        StrandsCustodyToken fresh = _deployUninitialized();

        vm.expectRevert(bytes("minter=0"));
        fresh.initialize(admin, address(0));
    }

    /// @dev A rejected initialize must not consume the one shot — otherwise a fat-fingered zero address
    ///      would permanently strand a freshly deployed token.
    function test_Initialize_RejectedForAZeroAddress_LeavesTheInitializerAvailable() public {
        StrandsCustodyToken fresh = _deployUninitialized();

        vm.expectRevert(bytes("minter=0"));
        fresh.initialize(admin, address(0));

        fresh.initialize(admin, minter);
        assertTrue(fresh.hasRole(MINTER_ROLE, minter), "the retry with a corrected argument goes through");
    }
}
