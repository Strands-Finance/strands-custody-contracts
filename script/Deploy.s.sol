// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { StrandsDACAP } from "../src/StrandsDACAP.sol";

contract Deploy is Script {
    function run() external returns (StrandsDACAP token) {
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
        // The one operating role. Defaulted to the admin so a single-key deploy (the backend's shape: one
        // mint-authority EOA is admin and minter) needs no extra variables, while a production deploy points
        // it at its own multisig and keeps the admin key cold.
        address minter = vm.envOr("MINTER_ADDRESS", admin);

        vm.startBroadcast(pk);
        token = new StrandsDACAP(decimals_, name_, symbol_);
        // Same broadcast as the deploy: a token left uninitialized is inert, and the deployer key is the only
        // address that can finish it. Splitting these across runs turns a dropped second transaction into an
        // operator problem for no benefit.
        token.initialize(admin, minter);
        vm.stopBroadcast();

        console2.log("StrandsDACAP deployed at:", address(token));
        console2.log("Admin:", admin);
        console2.log("Minter:", minter);
        console2.log("Decimals:", decimals_);
        console2.log("Name:", name_);
        console2.log("Symbol:", symbol_);
        // Not seeded here on purpose: `initialize` hands DEFAULT_ADMIN_ROLE to ADMIN_ADDRESS and REVOKES the
        // deployer's in the same call, so a setDestinationAllowed inside this broadcast would revert for every
        // deploy except the single-key shape where admin == deployer. Minting still works — it consults no list
        // — so a deploy that stops here leaves a usable token that simply cannot transfer yet.
        console2.log("Transfer allowlist: EMPTY. No transfer will succeed until the admin calls");
        console2.log("  setDestinationAllowed(destination, true) for each permitted recipient.");
    }
}
