// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { StrandsDACAP } from "../src/StrandsDACAP.sol";

/// @notice Deploys ONE token: a `BeaconProxy` in front of the implementation the chain's beacon names.
///         The beacon itself is deployed once per chain by `DeployBeacon.s.sol`.
contract Deploy is Script {
    function run() external returns (StrandsDACAP token) {
        // The chain's UpgradeableBeacon. Required: there is no sensible default for which code a token runs.
        address beacon = vm.envAddress("BEACON_ADDRESS");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        // Native decimals of the custodied asset (e.g. USDC=6, BTC=8, ETH=18). REQUIRED, and taken exactly as given:
        // a token's decimals are permanent, and every mint is in base units of them. Both ways this used to go wrong
        // were silent — an unset or empty variable deployed 18, and a value past 255 wrapped modulo 256 (262 deployed
        // a 6-decimal token). Each is now refused here, before anything is broadcast.
        uint256 rawDecimals = vm.envUint("DECIMALS");
        require(rawDecimals <= type(uint8).max, "DECIMALS must fit in a uint8 (0-255)");
        uint8 decimals_ = uint8(rawDecimals);
        // Both composed as "Strands.DACAP.<custodian>.<ASSET>" — custodian and asset only, no holder. The symbol
        // is the same string as the name rather than a short form: these labels identify a custodial claim, not a
        // tradeable ticker, and one unambiguous string beats a terse one nothing resolves back to.
        // Defaulted rather than required: `initializeToken` rejects empty metadata, so a missing variable would
        // otherwise waste a deploy. SET THEM — the default deploys a token indistinguishable from the rest.
        string memory name_ = vm.envOr("TOKEN_NAME", string("Strands.DACAP"));
        string memory symbol_ = vm.envOr("TOKEN_SYMBOL", string("Strands.DACAP"));

        vm.startBroadcast(pk);
        // `initializeToken` travels as the proxy constructor's data, so the metadata is fixed and the deployer
        // seated as admin AND minter in the deploy transaction itself: the token is live when this returns, with
        // no second transaction to send. A proxy created with empty data could be claimed by whoever called
        // `initializeToken` first. Deployed straight from the broadcasting key, never through a factory, which
        // would receive both roles instead.
        bytes memory init = abi.encodeCall(StrandsDACAP.initializeToken, (decimals_, name_, symbol_));
        token = StrandsDACAP(address(new BeaconProxy(beacon, init)));
        vm.stopBroadcast();

        address deployer = vm.addr(pk);
        console2.log("StrandsDACAP (BeaconProxy) deployed at:", address(token));
        console2.log("Beacon:", beacon);
        console2.log("Admin and minter (the deployer):", deployer);
        console2.log("Decimals:", decimals_);
        console2.log("Name:", name_);
        console2.log("Symbol:", symbol_);
        // Both roles sit on the deploying key. Moving one elsewhere (a cold admin, a minter multisig) is a separate,
        // deliberate step by that key: grantRole to the new holder, then renounceRole its own. Not done here, so
        // this script stays exactly what the backend does.
        console2.log("To hand a role on: grantRole(role, newHolder), then renounceRole(role, deployer).");
        console2.log("Transfer allowlist: EMPTY. No transfer will succeed until the admin calls");
        console2.log("  setDestinationAllowed(destination, true) for each permitted recipient.");
    }
}
