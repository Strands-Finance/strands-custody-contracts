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
        // The operating roles. Defaulted to the admin so a single-key deploy (the backend's shape: one
        // mint-authority EOA is admin, minter and custodian) needs no extra variables, while a production
        // deploy points each at its own multisig.
        address minter = vm.envOr("MINTER_ADDRESS", admin);
        address custodian = vm.envOr("CUSTODIAN_ADDRESS", admin);

        vm.startBroadcast(pk);
        token = new StrandsCustodyToken(decimals_, name_, symbol_);
        // Same broadcast as the deploy: a token left uninitialized is inert, and the deployer key is the only
        // address that can finish it. Splitting these across runs turns a dropped second transaction into an
        // operator problem for no benefit.
        token.initialize(admin, minter, custodian);
        vm.stopBroadcast();

        console2.log("StrandsCustodyToken deployed at:", address(token));
        console2.log("Admin:", admin);
        console2.log("Minter:", minter);
        console2.log("Custodian:", custodian);
        console2.log("Decimals:", decimals_);
        console2.log("Name:", name_);
        console2.log("Symbol:", symbol_);
    }
}
