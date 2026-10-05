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
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        // The one address that can point the beacon at new code, and so replace the logic of EVERY token at
        // once. Required rather than defaulted to the deployer: it is the most powerful key in the system and
        // should be chosen, not inherited.
        address owner = vm.envAddress("BEACON_OWNER");

        vm.startBroadcast(pk);
        implementation = new StrandsDACAP();
        beacon = new UpgradeableBeacon(address(implementation), owner);
        vm.stopBroadcast();

        console2.log("StrandsDACAP implementation:", address(implementation));
        console2.log("UpgradeableBeacon:", address(beacon));
        console2.log("Beacon owner:", owner);
    }
}
