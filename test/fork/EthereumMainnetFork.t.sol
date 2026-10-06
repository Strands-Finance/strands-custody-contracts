// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test, console2 } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { StrandsDACAP } from "../../src/StrandsDACAP.sol";
import { ITransferAllowlist } from "../../src/interfaces/ITransferAllowlist.sol";
import { DeployBeacon } from "../../script/DeployBeacon.s.sol";

/// @title  Ethereum mainnet fork fixture
/// @notice Deploys the custody contracts on a fork of ETHEREUM mainnet (chain 1), the way they will be deployed there,
///         so that suites built on it can check that they come out correctly deployed, initialized and permissioned.
///         It tests the contracts alone. How the backend drives them belongs to the backend's own tests.
///
///         DERIVE V2 AND V3 ARE ON DIFFERENT CHAINS.
///         - Derive V2 runs on Derive Chain, an OP-stack L2: mainnet is chain 957, testnet is chain 901. The testnet
///           beacon in DEPLOYMENTS.md is V2.
///         - Derive V3 settles on Ethereum mainnet, chain 1. This suite forks Ethereum mainnet, so it covers V3.
///
///         Derive has published no V3 L1 addresses, so Derive's admin and V3's escrow are stand-ins (`DERIVE_ADMIN`,
///         `V3_ESCROW`). Swap in the real addresses once Derive names them.
/// @dev    Opt-in and local only; CI never runs it. Without `ETH_MAINNET_RPC_URL`, every suite built on this skips in
///         `setUp`. Point it at the backend's Ethereum mainnet Alchemy URL (see "Fork test" in the README). The key
///         lives in the backend, and this repo is public, so the key never goes in here. The fork is taken at the
///         RPC's latest block. Nothing here depends on mainnet state that a pin would freeze, because every contract
///         is deployed fresh.
abstract contract EthereumMainnetForkTest is Test {
    uint256 internal constant ETHEREUM_MAINNET = 1;

    /// @dev `bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1)`: where a `BeaconProxy` records its beacon.
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    /// @dev OpenZeppelin's ERC-7201 slot for `Initializable`, whose low 8 bytes hold the initialized version.
    bytes32 internal constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    /// @dev Stand-in for Derive V3's L1 escrow, where a holder's tokens go when they deposit into Derive. REPLACE IT with
    ///      the real address once Derive publishes it.
    address internal constant V3_ESCROW = address(uint160(uint256(keccak256("strands.fork.stand-in.DeriveV3Escrow"))));

    /// @dev Stand-in for Derive's L1 address, which receives each token's DEFAULT_ADMIN_ROLE and then the beacon. REPLACE
    ///      IT once Derive names it.
    address internal constant DERIVE_ADMIN = address(uint160(uint256(keccak256("strands.fork.stand-in.DeriveAdmin"))));

    /// @dev The Strands key that deploys each token. The deploy seats that one key as the token's admin and its minter,
    ///      which is also the production arrangement.
    address internal mintAuthority = makeAddr("mintAuthority");

    /// @dev A user's wallet, where their tokens are minted.
    address internal holder = makeAddr("holder");

    address internal stranger = makeAddr("stranger");

    /// @dev Deploys the beacon with a Strands key, which owns it and then hands it to Derive (the path in
    ///      DEPLOYMENTS.md). Keyed, because both scripts sign.
    address internal strandsBeaconOwner;
    uint256 internal strandsBeaconOwnerKey;

    StrandsDACAP internal implementation;
    UpgradeableBeacon internal beacon;

    bytes32 internal DEFAULT_ADMIN_ROLE;
    bytes32 internal MINTER_ROLE;

    function setUp() public virtual {
        string memory rpc = vm.envOr("ETH_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "set ETH_MAINNET_RPC_URL to run the Ethereum mainnet fork suite");

        vm.createSelectFork(rpc);
        assertEq(block.chainid, ETHEREUM_MAINNET, "ETH_MAINNET_RPC_URL must be an Ethereum mainnet RPC");
        console2.log("Ethereum mainnet fork at block", block.number);
        vm.label(V3_ESCROW, "V3_ESCROW (stand-in)");
        vm.label(DERIVE_ADMIN, "DERIVE_ADMIN (stand-in)");

        // The once-per-chain deploy, through the script an operator will run on mainnet.
        (strandsBeaconOwner, strandsBeaconOwnerKey) = makeAddrAndKey("strandsBeaconOwner");
        (implementation, beacon) = new DeployBeacon().deploy(strandsBeaconOwnerKey, ETHEREUM_MAINNET);

        DEFAULT_ADMIN_ROLE = implementation.DEFAULT_ADMIN_ROLE();
        MINTER_ROLE = implementation.MINTER_ROLE();
    }

    // ---------- deploy ----------

    /// @dev One token: a `BeaconProxy` whose constructor runs `initializeToken`, deployed by the mint authority, which
    ///      comes out as its admin and minter. There is nothing more to initialize. Built from `abi/BeaconProxy.json`,
    ///      the proxy bytecode this repo exports for per-token deploys, so the artifact itself is what gets proven. Name
    ///      and symbol are the same string, as the README requires.
    function _deployToken(uint8 decimals_, string memory name_) internal returns (StrandsDACAP token) {
        bytes memory init = abi.encodeCall(StrandsDACAP.initializeToken, (decimals_, name_, name_));
        bytes memory initCode = bytes.concat(
            vm.parseJsonBytes(vm.readFile("abi/BeaconProxy.json"), ".bytecode"), abi.encode(address(beacon), init)
        );

        address deployed;
        vm.prank(mintAuthority);
        assembly {
            deployed := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(deployed != address(0), "the proxy deploy reverted");
        token = StrandsDACAP(deployed);
    }

    // ---------- storage reads ----------

    function _beaconOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, BEACON_SLOT))));
    }

    function _initializedVersion(address target) internal view returns (uint64) {
        return uint64(uint256(vm.load(target, INITIALIZABLE_SLOT)));
    }

    // ---------- revert expectations ----------

    function _expectMissingRole(address caller, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, role));
    }

    function _expectNotBeaconOwner(address caller) internal {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    }

    function _expectAlreadyInitialized() internal {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
    }

    function _expectDestinationNotAllowed(address destination) internal {
        vm.expectRevert(abi.encodeWithSelector(ITransferAllowlist.TransferDestinationNotAllowed.selector, destination));
    }
}
