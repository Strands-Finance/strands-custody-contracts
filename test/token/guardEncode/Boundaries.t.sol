// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { stdError } from "forge-std/StdError.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { GuardEncodeBase } from "./GuardEncodeBase.t.sol";
import { StrandsDACAP } from "../../../src/StrandsDACAP.sol";

/// @notice The edges of `guardEncode`'s inputs: the zero recipient, and the top of the uint256 range.
/// @dev    Both are about what the guard must NOT absorb. `guardEncode` calls `_mint` directly rather than through
///         `mint` (see its @dev note), so ERC20's own failures are reached by a different route, and they have
///         to surface as themselves rather than as a SupplyMismatch that would misdiagnose the cause.
contract GuardEncodeBoundariesTest is GuardEncodeBase {
    function test_GuardEncode_ToTheZeroAddress_Reverts() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.guardEncode(address(0), 50 ether, INITIAL_MINT);

        assertEq(token.totalSupply(), INITIAL_MINT);
    }

    /// @dev At the ceiling the guard still gates — a zero-amount mint with the right estimate goes through — and
    ///      still does not mask arithmetic: the overflow surfaces as ERC20's own panic.
    function test_GuardEncode_AtMaxSupply_GatesAndLetsOverflowPanic() public {
        StrandsDACAP t = _deployWithDecimals(18);

        vm.prank(operator);
        t.guardEncode(bob, type(uint256).max, 0);
        assertEq(t.totalSupply(), type(uint256).max, "precondition: supply is at the ceiling");

        vm.prank(operator);
        t.guardEncode(bob, 0, type(uint256).max); // a matching estimate still passes at the extreme

        vm.prank(operator);
        vm.expectRevert(stdError.arithmeticError);
        t.guardEncode(bob, 1, type(uint256).max);

        assertEq(t.totalSupply(), type(uint256).max, "an overflowing mint must leave supply where it was");
    }
}
