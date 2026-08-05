// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../../Base.t.sol";

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
///
/// @dev    This contract holds nothing of its own. `_expectSupplyMismatch` and `_deployWithDecimals` both moved
///         up into `Base.t.sol` when `guardBurn` arrived and needed the identical pair — one helper per claim,
///         not one per entrypoint. The type is kept so the suites below still name a common parent, and so a
///         helper that turns out to be guardMint-specific has somewhere to land.
abstract contract GuardMintBase is BaseTest { }
