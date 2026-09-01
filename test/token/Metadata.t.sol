// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsDACAP } from "../../src/StrandsDACAP.sol";

/// @notice ERC20 metadata: name, symbol and decimals, all three fixed at deploy time.
///
/// @dev    None of the three has a setter, so every assertion here is about a value that becomes PERMANENT the
///         moment the constructor returns. A token deployed with the wrong name cannot be corrected — only
///         redeployed and re-minted into. That is why the empty-string reverts exist and are pinned here.
contract MetadataTest is BaseTest {
    function test_Metadata() public view {
        assertEq(token.name(), NAME);
        assertEq(token.symbol(), SYMBOL);
        assertEq(token.decimals(), 18);
    }

    function test_Decimals_AreSetByConstructor() public {
        assertEq(new StrandsDACAP(6, NAME, SYMBOL).decimals(), 6, "usdc");
        assertEq(new StrandsDACAP(8, NAME, SYMBOL).decimals(), 8, "btc");
        assertEq(new StrandsDACAP(18, NAME, SYMBOL).decimals(), 18, "eth");
    }

    /// @dev Two tokens, different metadata — the one shape that fails if the strings ever regress to being
    ///      hardcoded in the constructor. Asserting a single token's name against a constant cannot tell a
    ///      constructor argument apart from a literal that happens to match.
    function test_NameAndSymbol_AreSetByConstructor() public {
        StrandsDACAP usdc = new StrandsDACAP(6, "Strands.DACAP.BitGo.USDC", "Strands.DACAP.BitGo.USDC");
        StrandsDACAP weth = new StrandsDACAP(18, "Strands.DACAP.Anchorage.WETH", "Strands.DACAP.Anchorage.WETH");

        assertEq(usdc.name(), "Strands.DACAP.BitGo.USDC");
        assertEq(usdc.symbol(), "Strands.DACAP.BitGo.USDC");
        assertEq(weth.name(), "Strands.DACAP.Anchorage.WETH");
        assertEq(weth.symbol(), "Strands.DACAP.Anchorage.WETH");
    }

    function test_Constructor_RevertsOnEmptyName() public {
        vm.expectRevert(bytes("name=0"));
        new StrandsDACAP(18, "", SYMBOL);
    }

    function test_Constructor_RevertsOnEmptySymbol() public {
        vm.expectRevert(bytes("symbol=0"));
        new StrandsDACAP(18, NAME, "");
    }
}
