// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { BaseTest } from "../Base.t.sol";
import { StrandsDACAP } from "../../src/StrandsDACAP.sol";
import { DeployBeacon } from "../../script/DeployBeacon.s.sol";

/// @notice The once-per-chain deploy: the implementation and the beacon every token on the chain points at. What is
///         pinned is what an operator gets back: a beacon naming that implementation and owned by the deploying key,
///         in front of an implementation that is locked and is the very code the backend's bindings were generated
///         from.
/// @dev    `deploy` is called directly rather than through `run`, so no test sets environment variables. `run` reads
///         `DEPLOYER_PRIVATE_KEY`, which `Deploy.t.sol` also sets, and forge runs test contracts in parallel. The
///         fixture's own beacon is not involved; every test deploys a fresh pair through the script.
contract DeployBeaconScriptTest is BaseTest {
    /// @dev OpenZeppelin's ERC-7201 slot for `Initializable`, whose low 8 bytes hold the initialized version.
    bytes32 internal constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    DeployBeacon internal script;
    address internal deployer;
    uint256 internal deployerKey;

    function setUp() public override {
        super.setUp();
        script = new DeployBeacon();
        (deployer, deployerKey) = makeAddrAndKey("beaconDeployer");
    }

    // ---------- the beacon ----------

    /// @dev The deploying key owns the beacon, and so alone can upgrade it, until it hands it to Derive with
    ///      `TransferBeaconOwnership.s.sol`.
    function test_Deploy_TheBeaconNamesTheImplementation_AndTheDeployingKeyOwnsIt() public {
        (StrandsDACAP impl, UpgradeableBeacon deployed) = script.deploy(deployerKey, block.chainid);

        assertEq(deployed.implementation(), address(impl), "the beacon names the implementation it was deployed with");
        assertEq(deployed.owner(), deployer, "the deploying key owns the beacon");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        deployed.upgradeTo(address(implementation));
    }

    /// @dev The deploy names the chain it is meant for, and an RPC on any other chain is refused before anything is
    ///      signed: here, a mainnet RPC where Sepolia was meant. Forge's `--chain` flag does not catch this.
    function test_Deploy_RefusesAnRpcOnAnotherChain_BeforeSendingAnything() public {
        vm.chainId(1);
        uint64 nonceBefore = vm.getNonce(deployer);

        vm.expectRevert(bytes("the RPC is chain 1, not the expected 11155111: nothing was sent"));
        script.deploy(deployerKey, 11155111);

        assertEq(vm.getNonce(deployer), nonceBefore, "nothing was sent");
    }

    // ---------- the implementation ----------

    /// @dev Code, not a token: nobody can initialize it, so it holds no metadata and no roles, not even the deploying
    ///      key's, which also owns the beacon.
    function test_Deploy_TheImplementationIsLocked() public {
        (StrandsDACAP impl,) = script.deploy(deployerKey, block.chainid);

        assertEq(uint64(uint256(vm.load(address(impl), INITIALIZABLE_SLOT))), type(uint64).max, "initializers disabled");

        address[2] memory callers = [deployer, alice];
        for (uint256 i = 0; i < callers.length; i++) {
            _expectAlreadyInitialized();
            vm.prank(callers[i]);
            impl.initializeToken(6, "Strands.DACAP.BitGo.USDC", "Strands.DACAP.BitGo.USDC");
        }

        assertEq(impl.name(), "", "no metadata");
        assertEq(impl.decimals(), 0);
        assertFalse(impl.hasRole(DEFAULT_ADMIN_ROLE, deployer), "no admin");
        assertFalse(impl.hasRole(MINTER_ROLE, deployer), "no minter");
    }

    /// @dev The implementation the script deploys runs exactly the code in `abi/StrandsDACAP.json`, the artifact the
    ///      backend generates its bindings from. CI already checks that artifact against `src/`; this ties the script's
    ///      deploy to it too, so the code on chain is the code the backend was built to call.
    function test_Deploy_TheImplementationIsTheCodeTheBackendWasGeneratedFrom() public {
        (StrandsDACAP impl,) = script.deploy(deployerKey, block.chainid);

        bytes memory creation = vm.parseJsonBytes(vm.readFile("abi/StrandsDACAP.json"), ".bytecode");
        address fromArtifact;
        assembly {
            fromArtifact := create(0, add(creation, 0x20), mload(creation))
        }
        require(fromArtifact != address(0), "the artifact's creation code reverted");

        assertEq(address(impl).code, fromArtifact.code, "the deployed implementation is the artifact's code");
    }
}
