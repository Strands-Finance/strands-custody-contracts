// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsDACAP } from "../../src/StrandsDACAP.sol";
import { Deploy } from "../../script/Deploy.s.sol";

/// @notice The per-token deploy script, run end to end through `run()` — the function an operator invokes — so what is
///         pinned is how it reads its environment. A token's decimals are permanent: there is no setter, and every
///         mint is in base units of whatever `decimals()` says. So the script must take DECIMALS exactly as given or
///         refuse to deploy; it must never fill in a value nobody gave it, or wrap one it cannot hold.
/// @dev    Every case is in ONE test, run in sequence. `vm.setEnv` is process-wide, so cases split across tests (which
///         forge runs in parallel) could read each other's DECIMALS. No other test reads these variables.
contract DeployScriptTest is BaseTest {
    Deploy internal script;
    address internal deployer;
    uint256 internal deployerKey;

    function setUp() public override {
        super.setUp();
        script = new Deploy();
        (deployer, deployerKey) = makeAddrAndKey("tokenDeployer");
    }

    function test_Decimals_AreTakenExactlyAsGiven_OrTheDeployIsRefused() public {
        vm.setEnv("BEACON_ADDRESS", vm.toString(address(beacon)));
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(deployerKey));
        vm.setEnv("TOKEN_NAME", "Strands.DACAP.BitGo.USDC");
        vm.setEnv("TOKEN_SYMBOL", "Strands.DACAP.BitGo.USDC");

        // The custodied asset's own decimals deploy exactly as given, and the deployer comes out able to mint.
        _assertDeploysWith("6", 6); // USDC
        _assertDeploysWith("8", 8); // BTC
        _assertDeploysWith("18", 18); // ETH
        _assertDeploysWith("255", 255); // the largest value a uint8 holds

        // A value a uint8 cannot hold is refused, not wrapped modulo 256: 256 would deploy a 0-decimal token, and a
        // typo of 262 a token that looks exactly like USDC.
        _assertRefused("256");
        _assertRefused("262");

        // A missing value is refused, not defaulted. `DECIMALS=$ASSET_DECIMALS` with the shell variable unset arrives
        // as an empty string, and an 18-decimal USDC claim is as permanent as any other mistake here.
        _assertRefused("");
    }

    function _assertDeploysWith(string memory raw, uint8 expected) private {
        vm.setEnv("DECIMALS", raw);
        StrandsDACAP token_ = script.run();

        assertEq(token_.decimals(), expected, string.concat("DECIMALS=", raw, " deployed the wrong decimals"));
        assertTrue(token_.hasRole(MINTER_ROLE, deployer), "the deployer can mint");
    }

    /// @dev Refused BEFORE anything is broadcast: the deployer's nonce does not move, so a refusal costs nothing.
    function _assertRefused(string memory raw) private {
        vm.setEnv("DECIMALS", raw);
        uint64 nonceBefore = vm.getNonce(deployer);

        try script.run() returns (StrandsDACAP token_) {
            fail(
                string.concat(
                    "DECIMALS=\"",
                    raw,
                    "\" was not refused: it deployed a token with decimals ",
                    vm.toString(token_.decimals())
                )
            );
        } catch { }

        assertEq(vm.getNonce(deployer), nonceBefore, "a refused deploy sent nothing");
    }
}
