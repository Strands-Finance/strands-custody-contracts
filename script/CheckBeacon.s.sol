// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/Script.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { StrandsDACAP } from "../src/StrandsDACAP.sol";
import { Networks } from "./Networks.sol";

/// @notice Checks a beacon that `DeployBeacon.s.sol` has deployed, before the backend is pointed at it. Run it straight
///         after the deploy, naming the same chain, and it finds the beacon itself:
///
///             forge script script/CheckBeacon.s.sol --sig "sepolia()"
///
///         It checks that:
///         - the beacon is OpenZeppelin's `UpgradeableBeacon`, owned by the deploying key;
///         - the implementation it names is locked, and is exactly the code in `abi/StrandsDACAP.json` that the
///           backend's bindings were generated from;
///         - a token deployed against it from `abi/BeaconProxy.json`, as the backend deploys one, comes out live with
///           only its deployer seated.
///         The first check that fails reverts the run and says what failed.
/// @dev    SENDS NOTHING, even with `--broadcast`: it never calls `vm.startBroadcast`, so the token it deploys and mints
///         exists only in forge's local simulation of the chain. It reads `DEPLOYER_PRIVATE_KEY` only to know which owner
///         to expect, and signs nothing with it.
contract CheckBeacon is Networks {
    /// @dev `bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1)`: where a `BeaconProxy` records its beacon.
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    /// @dev OpenZeppelin's ERC-7201 slot for `Initializable`, whose low 8 bytes hold the initialized version.
    bytes32 internal constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    uint8 internal constant DECIMALS = 6;
    string internal constant NAME = "Strands.DACAP.BitGo.USDC";
    address internal constant HOLDER = address(uint160(uint256(keccak256("strands.check-beacon.holder"))));
    /// @dev Stands in for the backend's mint authority, which deploys each token. A fixed address because forge refuses
    ///      `address(this)` in a script: a script contract's address is not stable.
    address internal constant TOKEN_DEPLOYER =
        address(uint160(uint256(keccak256("strands.check-beacon.token-deployer"))));

    function sepolia() external {
        _checkOn(_sepolia());
    }

    function mainnet() external {
        _checkOn(_mainnet());
    }

    function localFork() external {
        _checkOn(_localFork());
    }

    /// @dev Separate from the entrypoints so tests pass arguments rather than environment variables, which every test
    ///      running in parallel would share.
    function check(UpgradeableBeacon beacon, address expectedOwner) public {
        console2.log("Beacon:", address(beacon));

        // ---------- the beacon ----------

        // Checked first: a call to an address with no code fails in a way `try` cannot catch.
        require(address(beacon).code.length != 0, "BEACON_ADDRESS has no code on this chain");
        StrandsDACAP implementation;
        try beacon.implementation() returns (address named) {
            implementation = StrandsDACAP(named);
        } catch {
            revert("BEACON_ADDRESS does not answer implementation(): it is not a beacon");
        }
        require(address(implementation).code.length != 0, "the beacon names an implementation with no code");
        // UpgradeableBeacon has no immutables, so one built here from the same source has the same runtime code.
        address reference_ = address(new UpgradeableBeacon(address(implementation), TOKEN_DEPLOYER));
        require(
            keccak256(address(beacon).code) == keccak256(reference_.code),
            "the beacon's code is not OpenZeppelin's UpgradeableBeacon"
        );
        require(beacon.owner() == expectedOwner, "the beacon is not owned by the deploying key");
        console2.log("Beacon owner:", expectedOwner);

        // ---------- the implementation ----------

        console2.log("Implementation:", address(implementation));
        console2.log("Implementation code hash:");
        console2.logBytes32(keccak256(address(implementation).code));
        require(
            keccak256(address(implementation).code)
                == keccak256(_create(_artifactBytecode("abi/StrandsDACAP.json")).code),
            "the implementation's code is not abi/StrandsDACAP.json's"
        );
        require(
            uint64(uint256(vm.load(address(implementation), INITIALIZABLE_SLOT))) == type(uint64).max,
            "the implementation is not locked"
        );
        try implementation.initializeToken(DECIMALS, NAME, NAME) {
            revert("the implementation can be initialized");
        } catch { }

        // ---------- a token against it ----------

        bytes32 adminRole = implementation.DEFAULT_ADMIN_ROLE();
        bytes32 minterRole = implementation.MINTER_ROLE();
        bytes memory init = abi.encodeCall(StrandsDACAP.initializeToken, (DECIMALS, NAME, NAME));
        vm.startPrank(TOKEN_DEPLOYER);
        StrandsDACAP token = StrandsDACAP(
            _create(bytes.concat(_artifactBytecode("abi/BeaconProxy.json"), abi.encode(address(beacon), init)))
        );

        require(
            address(uint160(uint256(vm.load(address(token), BEACON_SLOT)))) == address(beacon),
            "a token does not follow the beacon"
        );
        require(
            keccak256(bytes(token.name())) == keccak256(bytes(NAME)) && token.decimals() == DECIMALS,
            "a token's metadata did not take"
        );
        require(
            token.hasRole(adminRole, TOKEN_DEPLOYER) && token.hasRole(minterRole, TOKEN_DEPLOYER),
            "a token's deployer is not its admin and minter"
        );
        require(
            !token.hasRole(adminRole, expectedOwner) && !token.hasRole(minterRole, expectedOwner),
            "the beacon's owner holds a role on a token"
        );
        token.guardMint(HOLDER, 1, 0);
        require(token.balanceOf(HOLDER) == 1, "a token cannot mint");
        vm.stopPrank();
        try token.initializeToken(18, "Strands.DACAP.Other", "Strands.DACAP.Other") {
            revert("a token can be initialized twice");
        } catch { }

        console2.log("All checks passed. Nothing was sent.");
    }

    /// @dev The beacon is the one `DeployBeacon.s.sol` last broadcast through the same entrypoint, read from its record
    ///      `broadcast/DeployBeacon.s.sol/<chain id>/<entrypoint>-latest.json`, unless `BEACON_ADDRESS` names another. A
    ///      dry run writes its record under `dry-run/`, so it never stands in for a deploy.
    function _checkOn(Network memory network) private {
        _use(network);
        address beacon = vm.envOr("BEACON_ADDRESS", address(0));
        if (beacon == address(0)) {
            beacon = _lastBroadcastBeacon(network);
            console2.log("Beacon from DeployBeacon's last broadcast (set BEACON_ADDRESS to check another)");
        }
        check(UpgradeableBeacon(beacon), vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY")));
    }

    function _lastBroadcastBeacon(Network memory network) private view returns (address) {
        string memory path = string.concat(
            "broadcast/DeployBeacon.s.sol/", vm.toString(network.chainId), "/", network.entrypoint, "-latest.json"
        );
        require(vm.exists(path), string.concat("no DeployBeacon broadcast at ", path, "; set BEACON_ADDRESS"));
        string memory json = vm.readFile(path);
        for (uint256 i = 0;; i++) {
            string memory key = string.concat(".transactions[", vm.toString(i), "]");
            require(vm.keyExistsJson(json, key), "DeployBeacon's last broadcast deployed no UpgradeableBeacon");
            if (
                keccak256(bytes(vm.parseJsonString(json, string.concat(key, ".contractName"))))
                    == keccak256("UpgradeableBeacon")
            ) {
                return vm.parseJsonAddress(json, string.concat(key, ".contractAddress"));
            }
        }
    }

    function _artifactBytecode(string memory path) private view returns (bytes memory) {
        return vm.parseJsonBytes(vm.readFile(path), ".bytecode");
    }

    function _create(bytes memory initCode) private returns (address created) {
        assembly {
            created := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(created != address(0), "a contract created from an abi/ artifact reverted");
    }
}
