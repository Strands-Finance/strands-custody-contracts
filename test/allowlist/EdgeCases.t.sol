// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice Corners the guard must still cover: self-transfers, zero-value
///         transfers, and the zero address as a destination. Two of these are
///         deliberate deviations from how a plain ERC20 behaves, pinned here so
///         they read as decisions rather than accidents.
contract EdgeCasesTest is BaseTest {
    function test_SelfTransfer_RevertsWhenNotAllowlisted() public {
        vm.prank(alice);
        _expectNotAllowed(alice, alice);
        token.transfer(alice, 1 ether);
    }

    function test_SelfTransfer_SucceedsWhenAllowlisted() public {
        _allow(alice, alice);

        vm.prank(alice);
        token.transfer(alice, 1 ether);
        assertEq(token.balanceOf(alice), INITIAL_MINT, "self-transfer must be balance-neutral");
    }

    /// @dev ERC20 requires zero-value transfers to behave like any other transfer.
    ///      The allowlist deliberately blocks them too; pin that so the deviation
    ///      from the spec is a decision and not an accident.
    function test_ZeroValueTransfer_RevertsWhenNotAllowlisted() public {
        vm.prank(alice);
        _expectNotAllowed(alice, bob);
        token.transfer(bob, 0);
    }

    function test_TransferToZeroAddress_StillRevertsWithErc20Error() public {
        _allow(alice, address(0)); // must not open a burn-by-transfer path

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);

        assertEq(token.totalSupply(), INITIAL_MINT, "supply must be untouched");
    }
}
