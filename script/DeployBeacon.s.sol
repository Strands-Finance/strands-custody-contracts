// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/Script.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { StrandsDACAP } from "../src/StrandsDACAP.sol";
import { Networks } from "./Networks.sol";

/// @notice The once-per-chain deploy: the StrandsDACAP implementation and the beacon that names it. Every token
///         on the chain is a `BeaconProxy` pointing at this beacon, so its address is what the backend is
///         configured with (`DERIVE_CUSTODY_DACAP_BEACON`) and what `Deploy.s.sol` takes as `BEACON_ADDRESS`.
///
///         The command names the chain; the script holds its RPC and chain id (see `Networks`):
///
///             forge script script/DeployBeacon.s.sol --sig "sepolia()" --broadcast
///
///         `DEPLOYER_PRIVATE_KEY` and `ALCHEMY_KEY` come from the environment, the same two on every chain.
contract DeployBeacon is Networks {
    function sepolia() external returns (StrandsDACAP implementation, UpgradeableBeacon beacon) {
        return _deployOn(_sepolia());
    }

    function mainnet() external returns (StrandsDACAP implementation, UpgradeableBeacon beacon) {
        return _deployOn(_mainnet());
    }

    function localFork() external returns (StrandsDACAP implementation, UpgradeableBeacon beacon) {
        return _deployOn(_localFork());
    }

    /// @dev The deploying key owns the beacon: the one address that can point it at new code, and so replace the
    ///      logic of EVERY token at once. It keeps that power until it hands the beacon to Derive with
    ///      `TransferBeaconOwnership.s.sol`, which is a separate, later step.
    ///
    ///      `chainId` is the chain the deploy is meant for, and the deploy is refused before anything is signed unless
    ///      the RPC is on it. Forge's own `--chain` does not stop a broadcast to an RPC on another chain, so this is
    ///      what keeps an RPC on the wrong chain from receiving the deploy.
    ///
    ///      Separate from the entrypoints so tests pass arguments rather than environment variables, which every test
    ///      running in parallel would share.
    function deploy(uint256 pk, uint256 chainId)
        public
        returns (StrandsDACAP implementation, UpgradeableBeacon beacon)
    {
        require(
            block.chainid == chainId,
            string.concat(
                "the RPC is chain ",
                vm.toString(block.chainid),
                ", not the expected ",
                vm.toString(chainId),
                ": nothing was sent"
            )
        );
        address owner = vm.addr(pk);

        vm.startBroadcast(pk);
        implementation = new StrandsDACAP();
        beacon = new UpgradeableBeacon(address(implementation), owner);
        vm.stopBroadcast();

        console2.log("StrandsDACAP implementation:", address(implementation));
        console2.log("UpgradeableBeacon:", address(beacon));
        console2.log("Beacon owner (the deploying key):", owner);
    }

    function _deployOn(Network memory network) private returns (StrandsDACAP implementation, UpgradeableBeacon beacon) {
        _use(network);
        return deploy(vm.envUint("DEPLOYER_PRIVATE_KEY"), network.chainId);
    }
}
