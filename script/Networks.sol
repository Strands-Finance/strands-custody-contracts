// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";

/// @notice The chains the beacon is deployed to, and how each is reached. A script takes its chain from the entrypoint
///         the command names (`--sig "sepolia()"`), so the chain is chosen there and nowhere else: there is no `run()` to
///         fall back on, and no `--rpc-url` or environment variable can point the script at a different chain.
/// @dev    The RPCs are the backend's Alchemy endpoints, built the way `AlchemyUrlProvider.cs` builds them:
///         `https://<prefix>.g.alchemy.com/v2/<key>`. Only the key comes from the environment, as `ALCHEMY_KEY`. This
///         repo is public, so the key is never written here, and the URL is never logged.
abstract contract Networks is Script {
    struct Network {
        /// @dev The entrypoint that selects it, which is also how forge names a script's broadcast record:
        ///      `broadcast/<script>/<chain id>/<entrypoint>-latest.json`.
        string entrypoint;
        string name;
        uint256 chainId;
        string rpcUrl;
    }

    function _sepolia() internal view returns (Network memory) {
        return Network("sepolia", "Ethereum Sepolia", 11_155_111, _alchemy("eth-sepolia"));
    }

    function _mainnet() internal view returns (Network memory) {
        return Network("mainnet", "Ethereum mainnet", 1, _alchemy("eth-mainnet"));
    }

    /// @dev A rehearsal on an anvil fork started with `--chain-id 31337 --port 8546`. The chain id keeps anything signed
    ///      there invalid on a real chain.
    function _localFork() internal pure returns (Network memory) {
        return Network("localFork", "local anvil fork", 31_337, "http://127.0.0.1:8546");
    }

    /// @dev Points the script at `network`: every call and every broadcast after this goes to its RPC.
    function _use(Network memory network) internal {
        vm.createSelectFork(network.rpcUrl);
        console2.log("Network:", network.name);
        console2.log("Chain:", block.chainid);
    }

    function _alchemy(string memory prefix) private view returns (string memory) {
        return string.concat("https://", prefix, ".g.alchemy.com/v2/", vm.envString("ALCHEMY_KEY"));
    }
}
