// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { StrandsDACAP } from "../src/StrandsDACAP.sol";

/// @notice The once-per-chain deploy: the StrandsDACAP implementation and the beacon that names it. Every token
///         on the chain is a `BeaconProxy` pointing at this beacon, so its address is what the backend is
///         configured with (`DERIVE_CUSTODY_DACAP_BEACON`) and what `Deploy.s.sol` takes as `BEACON_ADDRESS`.
contract DeployBeacon is Script {
    function run() external returns (StrandsDACAP implementation, UpgradeableBeacon beacon) {
        return deploy(vm.envUint("DEPLOYER_PRIVATE_KEY"));
    }

    /// @dev The deploying key owns the beacon: the one address that can point it at new code, and so replace the
    ///      logic of EVERY token at once. It keeps that power until it hands the beacon to Derive with
    ///      `TransferBeaconOwnership.s.sol`, which is a separate, later step.
    ///
    ///      Separate from `run` so tests pass the key as an argument rather than an environment variable, which
    ///      every test running in parallel would share.
    function deploy(uint256 pk) public returns (StrandsDACAP implementation, UpgradeableBeacon beacon) {
        address owner = vm.addr(pk);

        vm.startBroadcast(pk);
        implementation = new StrandsDACAP();
        beacon = new UpgradeableBeacon(address(implementation), owner);
        vm.stopBroadcast();

        console2.log("StrandsDACAP implementation:", address(implementation));
        console2.log("UpgradeableBeacon:", address(beacon));
        console2.log("Beacon owner (the deploying key):", owner);
    }
}
