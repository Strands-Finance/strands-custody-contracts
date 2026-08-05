// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../../Base.t.sol";
import { StrandsCustodyToken } from "../../../src/StrandsCustodyToken.sol";

/// @title  Shared fixture for the `guardMint` suites
/// @notice `guardMint` is one three-line function, so its tests are split by the CLAIM each file makes rather
///         than by entrypoint. One file per claim:
///
///         - `Authority.t.sol`     MINTER_ROLE and nobody else may call it, checked per call
///         - `Estimate.t.sol`      the estimate must equal the supply
///         - `ZeroValues.t.sol`    a zero estimate and a zero amount are ordinary values, not sentinels
///         - `StaleEstimate.t.sol` anything that moves supply between the read and the call voids the estimate
///         - `Sequence.t.sol`      through any interleaving of mints and burns, the estimate IS the supply
///         - `Boundaries.t.sol`    the zero recipient and the top of the uint256 range
///         - `Decimals.t.sol`      none of the above depends on `decimals()`
///
///         Everything here extends `Base.t.sol`, so the starting state is the same 18-dp, alice-funded fixture
///         every other suite under `test/` uses.
abstract contract GuardMintBase is BaseTest {
    /// @dev Expect the next call to be refused by the guard. A named helper for the same reason `Base.t.sol`
    ///      has `_expectNotMinter`: the expectation appears in nearly every test here, and spelling out
    ///      `abi.encodeWithSelector` each time buries which two numbers actually disagreed.
    function _expectSupplyMismatch(uint256 actual, uint256 estimate) internal {
        vm.expectRevert(abi.encodeWithSelector(StrandsCustodyToken.SupplyMismatch.selector, actual, estimate));
    }

    /// @dev A token at an arbitrary magnitude, wired like the fixture's. Metadata is deliberately generic —
    ///      these suites are about arithmetic, and `Metadata.t.sol` owns naming. The role ids are keccak
    ///      constants, so `Base.t.sol`'s cached MINTER_ROLE / CUSTODIAN_ROLE apply to any instance.
    ///      Used well beyond `Decimals.t.sol`: any test needing a supply of zero, or room to reach the uint256
    ///      ceiling, needs a token the fixture has not already funded.
    function _deployWithDecimals(uint8 decimals_) internal returns (StrandsCustodyToken t) {
        t = new StrandsCustodyToken(admin, decimals_, "Strands Custody Fixture", "scFIX");
        vm.startPrank(admin);
        t.grantRole(MINTER_ROLE, minter);
        t.grantRole(CUSTODIAN_ROLE, custodian);
        vm.stopPrank();
    }
}
