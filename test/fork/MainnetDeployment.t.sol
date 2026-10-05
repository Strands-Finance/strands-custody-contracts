// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EthereumMainnetForkTest } from "./EthereumMainnetFork.t.sol";
import { StrandsDACAP } from "../../src/StrandsDACAP.sol";
import { StrandsDACAPV2 } from "../mocks/StrandsDACAPV2.sol";
import { TransferBeaconOwnership } from "../../script/TransferBeaconOwnership.s.sol";

/// @notice On a fork of Ethereum mainnet (Derive V3), checks that the custody contracts come out correctly deployed,
///         initialized and permissioned. The beacon is deployed through `script/DeployBeacon.s.sol`, each token from
///         `abi/BeaconProxy.json`, and the hand-over through `script/TransferBeaconOwnership.s.sol`. The last test runs
///         all of it in production order and checks the arrangement mainnet ends up in.
/// @dev    Run with `ETH_MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/$ALCHEMY_KEY forge test --match-path
///         'test/fork/*' -vvv`, where the key comes from the backend (see "Fork test" in the README). Skipped otherwise.
contract MainnetDeploymentTest is EthereumMainnetForkTest {
    /// @dev A USDC token, named the way the README requires: "Strands.DACAP.<custodian>.<ASSET>", one string for both
    ///      name and symbol.
    uint8 internal constant USDC_DECIMALS = 6;
    string internal constant USDC_NAME = "Strands.DACAP.BitGo.USDC";
    uint256 internal constant USDC = 10 ** USDC_DECIMALS;

    // ---------- deployed ----------

    /// @dev The once-per-chain deploy: a beacon that names the implementation and is owned by whoever was chosen, in
    ///      front of an implementation that is code only and can never be made into a token.
    function test_DeployBeacon_NamesALockedImplementation_AndTheChosenOwner() public {
        assertEq(beacon.implementation(), address(implementation));
        assertEq(beacon.owner(), strandsBeaconOwner);
        assertEq(_initializedVersion(address(implementation)), type(uint64).max, "the implementation is locked");

        _expectAlreadyInitialized();
        vm.prank(stranger);
        implementation.initializeToken(USDC_DECIMALS, USDC_NAME, USDC_NAME);

        _expectMissingRole(stranger, DEFAULT_ADMIN_ROLE);
        vm.prank(stranger);
        implementation.initialize(stranger, stranger);

        assertEq(implementation.name(), "", "the implementation holds no metadata");
        assertFalse(
            implementation.hasRole(DEFAULT_ADMIN_ROLE, strandsBeaconOwner), "and no admin, not even its deployer"
        );
    }

    /// @dev One token as deployed: a proxy of the chain's beacon, its metadata fixed, and its deployer the only role
    ///      holder. It is inert until `initialize`.
    function test_DeployToken_FixesTheMetadata_AndSeatsOnlyTheDeployerAsAdmin() public {
        StrandsDACAP token = _deployToken(USDC_DECIMALS, USDC_NAME);

        assertEq(_beaconOf(address(token)), address(beacon), "the token follows the chain's beacon");
        assertEq(token.name(), USDC_NAME);
        assertEq(token.symbol(), USDC_NAME);
        assertEq(token.decimals(), USDC_DECIMALS);
        assertEq(token.totalSupply(), 0);
        assertEq(_initializedVersion(address(token)), 1, "initializeToken ran inside the deploy");
        assertFalse(token.initialized());
        assertEq(implementation.name(), "", "the token's state lives in the proxy, not the implementation");

        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, mintAuthority), "the deployer is admin");
        assertFalse(token.hasRole(MINTER_ROLE, mintAuthority), "nobody can mint yet");
        address[4] memory others = [holder, stranger, DERIVE_ADMIN, strandsBeaconOwner];
        for (uint256 i = 0; i < others.length; i++) {
            assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, others[i]));
            assertFalse(token.hasRole(MINTER_ROLE, others[i]));
        }

        // The metadata and the deployer's admin seat are set once. Nobody can re-run initializeToken, the deployer
        // included.
        address[2] memory callers = [mintAuthority, stranger];
        for (uint256 i = 0; i < callers.length; i++) {
            _expectAlreadyInitialized();
            vm.prank(callers[i]);
            token.initializeToken(18, "Strands.DACAP.Other", "Strands.DACAP.Other");
        }
        assertEq(token.name(), USDC_NAME);

        _expectMissingRole(mintAuthority, MINTER_ROLE);
        vm.prank(mintAuthority);
        token.mint(holder, 1);
    }

    // ---------- initialized ----------

    /// @dev `initialize` belongs to the deployer alone, seats exactly the roles it is given, and runs once.
    function test_Initialize_IsTheDeployersAlone_SeatsTheNamedRoles_AndRunsOnce() public {
        StrandsDACAP token = _deployToken(USDC_DECIMALS, USDC_NAME);

        // Nobody else can seat themselves between the deploy and `initialize`.
        address[3] memory others = [stranger, holder, DERIVE_ADMIN];
        for (uint256 i = 0; i < others.length; i++) {
            _expectMissingRole(others[i], DEFAULT_ADMIN_ROLE);
            vm.prank(others[i]);
            token.initialize(others[i], others[i]);
        }

        _initialize(token);
        assertTrue(token.initialized());
        assertEq(_initializedVersion(address(token)), 2);
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, mintAuthority));
        assertTrue(token.hasRole(MINTER_ROLE, mintAuthority));

        // Once only, even for the admin: it cannot re-seat a different minter under the same call.
        _expectAlreadyInitialized();
        vm.prank(mintAuthority);
        token.initialize(stranger, stranger);
        assertFalse(token.hasRole(MINTER_ROLE, stranger));
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, stranger));
    }

    // ---------- permissioned ----------

    /// @dev Once the roles are seated: only the minter changes supply, only the admin opens destinations and grants
    ///      roles, and a holder can send only where the admin has opened.
    function test_Permissions_OnlyTheMinterMovesSupply_OnlyTheAdminOpensDestinationsAndGrantsRoles() public {
        StrandsDACAP token = _deployToken(USDC_DECIMALS, USDC_NAME);
        _initialize(token);

        vm.prank(mintAuthority);
        token.mint(holder, 1_000 * USDC);
        uint256 supply = token.totalSupply();

        address[2] memory unprivileged = [holder, stranger];
        for (uint256 i = 0; i < unprivileged.length; i++) {
            address caller = unprivileged[i];
            vm.startPrank(caller);

            _expectMissingRole(caller, MINTER_ROLE);
            token.mint(caller, 1);
            _expectMissingRole(caller, MINTER_ROLE);
            token.guardMint(caller, 1, supply);
            _expectMissingRole(caller, MINTER_ROLE);
            token.adminBurn(holder, 1);
            _expectMissingRole(caller, MINTER_ROLE);
            token.guardBurn(holder, 1, supply);
            _expectMissingRole(caller, MINTER_ROLE);
            token.burn(1);

            _expectMissingRole(caller, DEFAULT_ADMIN_ROLE);
            token.setDestinationAllowed(caller, true);
            _expectMissingRole(caller, DEFAULT_ADMIN_ROLE);
            token.grantRole(MINTER_ROLE, caller);

            vm.stopPrank();
        }
        assertEq(token.totalSupply(), supply, "no refused call moved supply");

        // Transfers are default-deny: the holder can send only once the admin opens the destination.
        _expectDestinationNotAllowed(V3_ESCROW);
        vm.prank(holder);
        token.transfer(V3_ESCROW, 1 * USDC);

        vm.prank(mintAuthority);
        token.setDestinationAllowed(V3_ESCROW, true);
        vm.prank(holder);
        token.transfer(V3_ESCROW, 400 * USDC);
        assertEq(token.balanceOf(V3_ESCROW), 400 * USDC);

        // The minter redeems, guarded on the supply it read.
        vm.prank(mintAuthority);
        token.guardBurn(holder, 600 * USDC, 1_000 * USDC);
        assertEq(token.totalSupply(), 400 * USDC);
    }

    /// @dev Enrolment grants Derive DEFAULT_ADMIN_ROLE, and Strands renounces nothing. That gives Derive the role graph
    ///      and the allowlist, but not supply and not the code.
    function test_GrantingDeriveAdmin_GivesTheRoleGraphAndAllowlist_NotSupplyNorUpgrades() public {
        StrandsDACAP token = _deployToken(USDC_DECIMALS, USDC_NAME);
        _initialize(token);

        vm.prank(mintAuthority);
        token.grantRole(DEFAULT_ADMIN_ROLE, DERIVE_ADMIN);

        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, DERIVE_ADMIN));
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, mintAuthority), "Strands keeps its admin seat");
        assertTrue(token.hasRole(MINTER_ROLE, mintAuthority), "and stays minter");
        assertFalse(token.hasRole(MINTER_ROLE, DERIVE_ADMIN), "admin is not minter");

        vm.prank(DERIVE_ADMIN);
        token.setDestinationAllowed(V3_ESCROW, true);
        assertTrue(token.allowedDestination(V3_ESCROW), "Derive can open a destination");

        _expectMissingRole(DERIVE_ADMIN, MINTER_ROLE);
        vm.prank(DERIVE_ADMIN);
        token.mint(DERIVE_ADMIN, 1);

        address v2 = address(new StrandsDACAPV2());
        _expectNotBeaconOwner(DERIVE_ADMIN);
        vm.prank(DERIVE_ADMIN);
        beacon.upgradeTo(v2);
    }

    /// @dev Only the beacon's owner can upgrade; no token role can. `script/TransferBeaconOwnership.s.sol` moves that
    ///      power to Derive, and an upgrade then keeps every token's address, state and roles.
    function test_Beacon_OnlyItsOwnerUpgrades_AndTheHandOverScriptMovesThatToDerive() public {
        StrandsDACAP token = _deployToken(USDC_DECIMALS, USDC_NAME);
        _initialize(token);
        vm.prank(mintAuthority);
        token.mint(holder, 1_000 * USDC);
        address v2 = address(new StrandsDACAPV2());

        address[3] memory notOwners = [mintAuthority, DERIVE_ADMIN, stranger];
        for (uint256 i = 0; i < notOwners.length; i++) {
            _expectNotBeaconOwner(notOwners[i]);
            vm.prank(notOwners[i]);
            beacon.upgradeTo(v2);
        }

        new TransferBeaconOwnership().handOver(beacon, DERIVE_ADMIN, strandsBeaconOwnerKey);
        assertEq(beacon.owner(), DERIVE_ADMIN);
        assertEq(beacon.implementation(), address(implementation), "the hand-over changes no code");
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, DERIVE_ADMIN), "and grants no token role");

        _expectNotBeaconOwner(strandsBeaconOwner);
        vm.prank(strandsBeaconOwner);
        beacon.upgradeTo(v2);

        vm.prank(DERIVE_ADMIN);
        beacon.upgradeTo(v2);
        assertEq(StrandsDACAPV2(address(token)).version(), 2, "Derive's upgrade reaches the token");

        assertEq(_beaconOf(address(token)), address(beacon));
        assertEq(token.name(), USDC_NAME);
        assertEq(token.decimals(), USDC_DECIMALS);
        assertEq(token.balanceOf(holder), 1_000 * USDC);
        assertTrue(token.initialized());
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, mintAuthority));
        assertTrue(token.hasRole(MINTER_ROLE, mintAuthority));

        _expectMissingRole(stranger, MINTER_ROLE);
        vm.prank(stranger);
        token.mint(stranger, 1);
    }

    // ---------- end to end ----------

    /// @dev Everything above in production order on one token, ending in the arrangement mainnet is meant to have:
    ///      Derive owns the beacon and is admin on the token, while Strands keeps its admin seat and is the minter.
    function test_EndToEnd_DeployedInitializedAndPermissionedOnEthereumMainnet() public {
        // Once per chain: setUp ran DeployBeacon. Per token: deploy, seat the roles, open the destinations.
        StrandsDACAP token = _deployToken(USDC_DECIMALS, USDC_NAME);
        _initialize(token);
        vm.startPrank(mintAuthority);
        token.setDestinationAllowed(V3_ESCROW, true);
        token.setDestinationAllowed(holder, true);
        token.guardMint(holder, 5_000 * USDC, 0);
        vm.stopPrank();

        // The holder deposits into Derive.
        vm.prank(holder);
        token.transfer(V3_ESCROW, 5_000 * USDC);

        // Hand-overs: the token's admin role, then the beacon. Derive then upgrades.
        vm.prank(mintAuthority);
        token.grantRole(DEFAULT_ADMIN_ROLE, DERIVE_ADMIN);
        new TransferBeaconOwnership().handOver(beacon, DERIVE_ADMIN, strandsBeaconOwnerKey);
        address v2 = address(new StrandsDACAPV2());
        vm.prank(DERIVE_ADMIN);
        beacon.upgradeTo(v2);

        assertEq(beacon.owner(), DERIVE_ADMIN, "Derive owns the beacon");
        assertEq(StrandsDACAPV2(address(token)).version(), 2);
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, DERIVE_ADMIN), "Derive is admin");
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, mintAuthority), "Strands keeps its admin seat");
        assertTrue(token.hasRole(MINTER_ROLE, mintAuthority), "Strands is minter");
        assertFalse(token.hasRole(MINTER_ROLE, DERIVE_ADMIN), "Derive is not");
        assertEq(token.balanceOf(V3_ESCROW), 5_000 * USDC);

        // The token still works under that arrangement: a withdrawal comes back, Strands redeems it, and a stranger
        // still cannot mint.
        vm.prank(V3_ESCROW);
        token.transfer(holder, 2_000 * USDC);
        vm.prank(mintAuthority);
        token.guardBurn(holder, 2_000 * USDC, 5_000 * USDC);
        assertEq(token.totalSupply(), 3_000 * USDC);

        _expectMissingRole(stranger, MINTER_ROLE);
        vm.prank(stranger);
        token.mint(stranger, 1);
    }
}
