// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { MoveCustodyTokens } from "../../script/MoveCustodyTokens.s.sol";

/// @notice The move script: a burn from the source, then a mint to the recipient. What is pinned is that exactly the
///         amount moves with supply unchanged, that a recipient on no allowlist still receives it, and that every
///         refusal, the second run of the same command included, comes before anything is sent.
/// @dev    `move` is called directly with the signer and chain, rather than through `mainnet()`, which forks.
contract MoveCustodyTokensTest is BaseTest {
    MoveCustodyTokens internal script;

    function setUp() public override {
        super.setUp();
        script = new MoveCustodyTokens();
    }

    function _move(address to, uint256 amount, uint256 expectedFromBalance, address signer) internal {
        script.move(token, alice, to, amount, expectedFromBalance, signer, block.chainid);
    }

    function _assertNothingMoved() internal view {
        assertEq(token.balanceOf(alice), INITIAL_MINT, "the source keeps its balance");
        assertEq(token.balanceOf(bob), 0, "the recipient received nothing");
        assertEq(token.totalSupply(), INITIAL_MINT, "the supply is unchanged");
    }

    /// @dev `bob` is on no allowlist: a mint does not consult it, so a move reaches an address a transfer could not.
    function test_Move_MovesTheAmountWithSupplyUnchanged() public {
        _expectBurnedEvent(minter, alice, 100 ether);
        _move(bob, 100 ether, INITIAL_MINT, minter);

        assertEq(token.balanceOf(alice), INITIAL_MINT - 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.totalSupply(), INITIAL_MINT, "a burn and a mint of the same amount leave supply where it was");
    }

    /// @dev The recipient's own balance is added to, not replaced.
    function test_Move_AddsToWhatTheRecipientHolds() public {
        vm.prank(minter);
        token.mint(bob, 7);

        _move(bob, 100 ether, INITIAL_MINT, minter);

        assertEq(token.balanceOf(bob), 7 + 100 ether);
        assertEq(token.totalSupply(), INITIAL_MINT + 7);
    }

    /// @dev The move changed the source's balance off the value the command carries, so running it again is refused.
    ///      Supply alone could not catch this: a move leaves it unchanged.
    function test_Move_RefusesASecondRunOfTheSameCommand() public {
        _move(bob, 100 ether, INITIAL_MINT, minter);

        vm.expectRevert(
            bytes(
                string.concat(
                    vm.toString(alice),
                    " holds 900000000000000000000 of Strands.DACAP.BitGo.ETH, not the expected 1000000000000000000000"
                )
            )
        );
        _move(bob, 100 ether, INITIAL_MINT, minter);

        assertEq(token.balanceOf(bob), 100 ether, "only the first run moved");
    }

    function test_Move_RefusesMoreThanTheSourceHolds() public {
        vm.expectRevert(
            bytes(
                string.concat(
                    vm.toString(alice),
                    " holds 1000000000000000000000 of Strands.DACAP.BitGo.ETH, less than the 1000000000000000000001 to burn"
                )
            )
        );
        _move(bob, INITIAL_MINT + 1, INITIAL_MINT, minter);

        _assertNothingMoved();
    }

    function test_Move_RefusesTheSourceAsTheRecipient() public {
        vm.expectRevert(bytes("the recipient is the source"));
        _move(alice, 100 ether, INITIAL_MINT, minter);

        _assertNothingMoved();
    }

    function test_Move_RefusesTheZeroRecipient() public {
        vm.expectRevert(bytes("the recipient is zero"));
        _move(address(0), 100 ether, INITIAL_MINT, minter);

        _assertNothingMoved();
    }

    /// @dev The fixture's admin gave its minter seat away: admin alone can neither burn nor mint.
    function test_Move_RefusesASignerThatIsNotMinter() public {
        vm.expectRevert(
            bytes(
                string.concat(
                    vm.toString(admin),
                    " does not hold MINTER_ROLE on Strands.DACAP.BitGo.ETH: pass the minter as --sender to simulate, or its key to broadcast"
                )
            )
        );
        _move(bob, 100 ether, INITIAL_MINT, admin);

        _assertNothingMoved();
    }

    function test_Move_RefusesTheWrongChain() public {
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
        script.move(token, alice, bob, 100 ether, INITIAL_MINT, minter, other);

        _assertNothingMoved();
    }
}
