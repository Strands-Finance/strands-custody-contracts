// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "./Base.t.sol";

/// @notice Proves a `forge test --fork-url sepolia` run is what it claims: every suite's fixture is built on the beacon
///         and implementation deployed on Ethereum Sepolia, not on a fresh build that would pass regardless. Skipped on
///         any other chain, so CI, which forks nothing, skips it.
contract SepoliaForkTest is BaseTest {
    /// @dev `bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1)`: where a `BeaconProxy` records its beacon.
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    function test_OnASepoliaFork_EverySuiteRunsAgainstTheDeployedBeacon() public {
        if (block.chainid != SEPOLIA) vm.skip(true, "run with --fork-url sepolia");

        assertEq(address(beacon), SEPOLIA_BEACON, "the fixture's beacon is the one deployed on Sepolia");
        assertEq(
            address(implementation), beacon.implementation(), "and its implementation is the one that beacon names"
        );
        assertEq(beaconOwner, beacon.owner(), "and its owner is that beacon's owner");
        assertEq(
            address(uint160(uint256(vm.load(address(token), BEACON_SLOT)))),
            SEPOLIA_BEACON,
            "the fixture's token is a proxy of the deployed beacon"
        );

        bytes memory creation = vm.parseJsonBytes(vm.readFile("abi/StrandsDACAP.json"), ".bytecode");
        address fromArtifact;
        assembly {
            fromArtifact := create(0, add(creation, 0x20), mload(creation))
        }
        assertEq(address(implementation).code, fromArtifact.code, "the deployed implementation is abi/'s code");
    }
}
