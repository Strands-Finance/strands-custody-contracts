// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { BurnCustodyTokens } from "../../script/BurnCustodyTokens.s.sol";

/// @notice The burn script. What is pinned is that it burns exactly the amount from exactly the holder, and that every
///         refusal, the second run of the same command included, comes before anything is sent.
/// @dev    `burn` is called directly with the signer and chain, rather than through `mainnet()`, which forks.
contract BurnCustodyTokensTest is BaseTest {
    BurnCustodyTokens internal script;

    function setUp() public override {
        super.setUp();
        script = new BurnCustodyTokens();
    }

    function _burn(uint256 amount, uint256 expectedSupply, address signer) internal {
        script.burn(token, alice, amount, expectedSupply, signer, block.chainid);
    }

    function _assertNothingBurned() internal view {
        assertEq(token.balanceOf(alice), INITIAL_MINT, "the holder keeps its balance");
        assertEq(token.totalSupply(), INITIAL_MINT, "the supply is unchanged");
    }

    function test_Burn_TakesTheAmountFromTheHolderAndTheSupply() public {
        _expectBurnedEvent(minter, alice, 100 ether);
        _burn(100 ether, INITIAL_MINT, minter);

        assertEq(token.balanceOf(alice), INITIAL_MINT - 100 ether);
        assertEq(token.totalSupply(), INITIAL_MINT - 100 ether);
    }

    function test_Burn_CanTakeTheWholeBalance() public {
        _burn(INITIAL_MINT, INITIAL_MINT, minter);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }

    /// @dev The burn moved the supply off the value the command carries, so running it again is refused, not repeated.
    function test_Burn_RefusesASecondRunOfTheSameCommand() public {
        _burn(100 ether, INITIAL_MINT, minter);

        vm.expectRevert(
            bytes(
                "the supply of Strands.DACAP.BitGo.ETH is 900000000000000000000, not the expected 1000000000000000000000"
            )
        );
        _burn(100 ether, INITIAL_MINT, minter);

        assertEq(token.balanceOf(alice), INITIAL_MINT - 100 ether, "only the first run burned");
    }

    function test_Burn_RefusesAStaleSupply() public {
        vm.expectRevert(bytes("the supply of Strands.DACAP.BitGo.ETH is 1000000000000000000000, not the expected 999"));
        _burn(100 ether, 999, minter);

        _assertNothingBurned();
    }

    function test_Burn_RefusesMoreThanTheHolderHolds() public {
        vm.prank(minter);
        token.mint(bob, 1);

        vm.expectRevert(
            bytes(
                string.concat(
                    vm.toString(alice),
                    " holds 1000000000000000000000 of Strands.DACAP.BitGo.ETH, less than the 1000000000000000000001 to burn"
                )
            )
        );
        script.burn(token, alice, INITIAL_MINT + 1, INITIAL_MINT + 1, minter, block.chainid);

        assertEq(token.balanceOf(alice), INITIAL_MINT);
    }

    /// @dev The fixture's admin gave its minter seat away: admin alone can neither burn nor mint.
    function test_Burn_RefusesASignerThatIsNotMinter() public {
        vm.expectRevert(
            bytes(
                string.concat(
                    vm.toString(admin),
                    " does not hold MINTER_ROLE on Strands.DACAP.BitGo.ETH: pass the minter as --sender to simulate, or its key to broadcast"
                )
            )
        );
        _burn(100 ether, INITIAL_MINT, admin);

        _assertNothingBurned();
    }

    function test_Burn_RefusesAZeroAmount() public {
        vm.expectRevert(bytes("the amount is zero"));
        _burn(0, INITIAL_MINT, minter);

        _assertNothingBurned();
    }

    function test_Burn_RefusesTheWrongChain() public {
        uint256 other = block.chainid + 1;

        vm.expectRevert(
            bytes(
                string.concat(
                    "the RPC is chain ",
                    vm.toString(block.chainid),
                    ", not the expected ",
                    vm.toString(other),
                    ": nothing was sent"
                )
            )
        );
        script.burn(token, alice, 100 ether, INITIAL_MINT, minter, other);

        _assertNothingBurned();
    }
}
