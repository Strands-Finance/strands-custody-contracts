// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { StrandsCustodyToken } from "../src/StrandsCustodyToken.sol";

contract Deploy is Script {
    function run() external returns (StrandsCustodyToken token) {
        address admin = vm.envAddress("ADMIN_ADDRESS");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        // Native decimals of the custodied asset (e.g. USDC=6, BTC=8, ETH=18). Defaults to 18.
        uint8 decimals_ = uint8(vm.envOr("DECIMALS", uint256(18)));
        // Required, deliberately WITHOUT an `envOr` default unlike DECIMALS: the name and symbol are immutable once
        // deployed, and a token that silently ships with a generic label is exactly what this is here to prevent.
        // Composed as "Strands Custody <asset> (<custodian>)" / "sc<ASSET>" — asset and custodian only, no holder.
        string memory name_ = vm.envString("TOKEN_NAME");
        string memory symbol_ = vm.envString("TOKEN_SYMBOL");

        vm.startBroadcast(pk);
        token = new StrandsCustodyToken(admin, decimals_, name_, symbol_);
        vm.stopBroadcast();

        console2.log("StrandsCustodyToken deployed at:", address(token));
        console2.log("Admin:", admin);
        console2.log("Decimals:", decimals_);
        console2.log("Name:", name_);
        console2.log("Symbol:", symbol_);
    }
}
