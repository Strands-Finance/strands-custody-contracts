// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { MintCustodyTokens } from "../../script/MintCustodyTokens.s.sol";

/// @notice The mint script. What is pinned is that it mints exactly the amount to exactly the recipient, and that every
///         refusal, the second run of the same command included, comes before anything is sent.
/// @dev    `mint` is called directly with the signer and chain, rather than through `mainnet()`, which forks.
contract MintCustodyTokensTest is BaseTest {
    MintCustodyTokens internal script;

    function setUp() public override {
        super.setUp();
        script = new MintCustodyTokens();
    }

    function _mint(address to, uint256 amount, uint256 expectedSupply, address signer) internal {
        script.mint(token, to, amount, expectedSupply, signer, block.chainid);
    }

    function _assertNothingMinted() internal view {
        assertEq(token.balanceOf(bob), 0, "the recipient received nothing");
        assertEq(token.totalSupply(), INITIAL_MINT, "the supply is unchanged");
    }

    function test_Mint_GivesTheAmountToTheRecipientAndTheSupply() public {
        _mint(bob, 100 ether, INITIAL_MINT, minter);

        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.balanceOf(alice), INITIAL_MINT, "nobody else's balance moves");
        assertEq(token.totalSupply(), INITIAL_MINT + 100 ether);
    }

    /// @dev The mint moved the supply off the value the command carries, so running it again is refused, not repeated.
    function test_Mint_RefusesASecondRunOfTheSameCommand() public {
        _mint(bob, 100 ether, INITIAL_MINT, minter);

        vm.expectRevert(
            bytes(
                "the supply of Strands.DACAP.BitGo.ETH is 1100000000000000000000, not the expected 1000000000000000000000"
            )
        );
        _mint(bob, 100 ether, INITIAL_MINT, minter);

        assertEq(token.balanceOf(bob), 100 ether, "only the first run minted");
    }

    function test_Mint_RefusesAStaleSupply() public {
        vm.expectRevert(bytes("the supply of Strands.DACAP.BitGo.ETH is 1000000000000000000000, not the expected 999"));
        _mint(bob, 100 ether, 999, minter);

        _assertNothingMinted();
    }

    function test_Mint_RefusesTheZeroRecipient() public {
        vm.expectRevert(bytes("the recipient is zero"));
        _mint(address(0), 100 ether, INITIAL_MINT, minter);

        _assertNothingMinted();
    }

    /// @dev The fixture's admin gave its minter seat away: admin alone can neither burn nor mint.
    function test_Mint_RefusesASignerThatIsNotMinter() public {
        vm.expectRevert(
            bytes(
                string.concat(
                    vm.toString(admin),
                    " does not hold MINTER_ROLE on Strands.DACAP.BitGo.ETH: pass the minter as --sender to simulate, or its key to broadcast"
                )
            )
        );
        _mint(bob, 100 ether, INITIAL_MINT, admin);

        _assertNothingMinted();
    }

    function test_Mint_RefusesAZeroAmount() public {
        vm.expectRevert(bytes("the amount is zero"));
        _mint(bob, 0, INITIAL_MINT, minter);

        _assertNothingMinted();
    }

    function test_Mint_RefusesTheWrongChain() public {
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
        script.mint(token, bob, 100 ether, INITIAL_MINT, minter, other);

        _assertNothingMinted();
    }
}
