// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StrandsDACAP } from "../../src/StrandsDACAP.sol";

/// @notice A stand-in for "some later version of the token", used only to prove a beacon upgrade keeps state.
///         It adds one function and no storage, which is all the proof needs.
contract StrandsDACAPV2 is StrandsDACAP {
    function version() external pure returns (uint256) {
        return 2;
    }
}
