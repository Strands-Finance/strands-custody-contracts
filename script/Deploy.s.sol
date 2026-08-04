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
        // Composed as "Strands Custody <asset> (<custodian>)" / "sc<ASSET>" — asset and custodian only, no holder.
        // Defaulted rather than required: the constructor rejects empty metadata, so a missing variable would
        // otherwise waste a deploy, and the fallback is the exact pair every token carried before this contract
        // took name/symbol as arguments. SET THEM — the default deploys a token indistinguishable from the rest.
        string memory name_ = vm.envOr("TOKEN_NAME", string("Strands Custody Token"));
        string memory symbol_ = vm.envOr("TOKEN_SYMBOL", string("SCT"));

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
