// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsCustodyToken } from "../../src/StrandsCustodyToken.sol";

/// @notice ERC20 metadata: name, symbol, and deploy-time configurable decimals.
contract MetadataTest is BaseTest {
    function test_Metadata() public view {
        assertEq(token.name(), "Strands Custody Token");
        assertEq(token.symbol(), "SCT");
        assertEq(token.decimals(), 18);
    }

    function test_Decimals_AreSetByConstructor() public {
        assertEq(new StrandsCustodyToken(admin, 6).decimals(), 6, "usdc");
        assertEq(new StrandsCustodyToken(admin, 8).decimals(), 8, "btc");
        assertEq(new StrandsCustodyToken(admin, 18).decimals(), 18, "eth");
    }
}
