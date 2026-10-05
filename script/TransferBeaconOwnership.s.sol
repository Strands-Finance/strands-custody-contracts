// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @notice Hands a chain's beacon to a new owner, and with it the power to replace the code of EVERY token on the
///         chain. Written for the handover to Derive.
/// @dev    `UpgradeableBeacon` uses OpenZeppelin's one-step `Ownable`: the transfer takes effect in the same
///         transaction and nothing on-chain can undo it. A wrong `NEW_BEACON_OWNER` hands upgrade control of every
///         token to whoever holds that address's key, or to nobody. Confirm the address with its owner on a second
///         channel and simulate on a fork first; see "Hand the beacon to Derive" in the README.
///
///         Signs with a private key, like the deploy scripts. A beacon owned by a multisig cannot use this: send
///         `transferOwnership(newOwner)` from the multisig itself.
contract TransferBeaconOwnership is Script {
    function run() external {
        handOver(
            UpgradeableBeacon(vm.envAddress("BEACON_ADDRESS")),
            vm.envAddress("NEW_BEACON_OWNER"),
            vm.envUint("BEACON_OWNER_PRIVATE_KEY")
        );
    }

    /// @dev Separate from `run` so tests pass arguments rather than environment variables, which every test running
    ///      in parallel would share.
    function handOver(UpgradeableBeacon beacon, address newOwner, uint256 ownerKey) public {
        address currentOwner = beacon.owner();

        // All three are refused before anything is signed. Ownable would reject the first two itself, but only after
        // a send, and the third it would accept as a no-op transfer that still emits OwnershipTransferred.
        require(vm.addr(ownerKey) == currentOwner, "BEACON_OWNER_PRIVATE_KEY is not the beacon's owner");
        require(newOwner != address(0), "NEW_BEACON_OWNER is zero");
        require(newOwner != currentOwner, "NEW_BEACON_OWNER already owns the beacon");

        console2.log("Beacon:", address(beacon));
        console2.log("Implementation:", beacon.implementation());
        console2.log("Current owner:", currentOwner);
        console2.log("New owner:", newOwner);
        console2.log("New owner is a contract (e.g. a Safe):", newOwner.code.length != 0);

        vm.startBroadcast(ownerKey);
        beacon.transferOwnership(newOwner);
        vm.stopBroadcast();

        require(beacon.owner() == newOwner, "ownership did not move");
        console2.log("Beacon owner is now:", beacon.owner());
    }
}
