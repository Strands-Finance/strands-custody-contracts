// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { BaseTest } from "../Base.t.sol";
import { StrandsDACAP } from "../../src/StrandsDACAP.sol";
import { StrandsDACAPV2 } from "../mocks/StrandsDACAPV2.sol";
import { CheckBeacon } from "../../script/CheckBeacon.s.sol";
import { DeployBeacon } from "../../script/DeployBeacon.s.sol";

/// @notice The post-deploy check. It is what stands between a beacon on chain and the backend being pointed at it, so
///         what is pinned is both halves: it passes exactly what `DeployBeacon.s.sol` deploys, and it refuses each
///         way a beacon address could be wrong — the wrong owner, an address that is no beacon, or a beacon naming
///         code other than `abi/StrandsDACAP.json`'s.
/// @dev    `check` is called directly rather than through `run`, so no test sets environment variables that a parallel
///         test could read.
contract CheckBeaconScriptTest is BaseTest {
    CheckBeacon internal script;

    address internal deployer;
    StrandsDACAP internal deployedImplementation;
    UpgradeableBeacon internal deployedBeacon;

    function setUp() public override {
        super.setUp();
        script = new CheckBeacon();

        uint256 deployerKey;
        (deployer, deployerKey) = makeAddrAndKey("beaconDeployer");
        (deployedImplementation, deployedBeacon) = new DeployBeacon().deploy(deployerKey, block.chainid);
    }

    function test_Check_PassesWhatDeployBeaconDeploys() public {
        script.check(deployedBeacon, deployer);
    }

    function test_Check_RefusesABeaconOwnedBySomeoneElse() public {
        vm.expectRevert(bytes("the beacon is not owned by the deploying key"));
        script.check(deployedBeacon, alice);
    }

    function test_Check_RefusesAnAddressWithNoCode() public {
        vm.expectRevert(bytes("BEACON_ADDRESS has no code on this chain"));
        script.check(UpgradeableBeacon(makeAddr("nothing")), deployer);
    }

    /// @dev The likeliest slip: pasting the implementation's address, or a token's, where the beacon's belongs.
    function test_Check_RefusesAnAddressThatIsNotABeacon() public {
        vm.expectRevert(bytes("BEACON_ADDRESS does not answer implementation(): it is not a beacon"));
        script.check(UpgradeableBeacon(address(deployedImplementation)), deployer);

        vm.expectRevert(bytes("BEACON_ADDRESS does not answer implementation(): it is not a beacon"));
        script.check(UpgradeableBeacon(address(token)), deployer);
    }

    /// @dev A beacon whose implementation is not the code the backend's bindings were generated from — here, after an
    ///      upgrade to the test-only V2.
    function test_Check_RefusesAnImplementationThatIsNotTheArtifact() public {
        address v2 = address(new StrandsDACAPV2());
        vm.prank(deployer);
        deployedBeacon.upgradeTo(v2);

        vm.expectRevert(bytes("the implementation's code is not abi/StrandsDACAP.json's"));
        script.check(deployedBeacon, deployer);
    }
}
