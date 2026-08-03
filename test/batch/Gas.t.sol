// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "../Base.t.sol";
import { StrandsAllowlistBatch } from "../../src/StrandsAllowlistBatch.sol";

/// @notice Measures batching rather than asserting it.
///
///         An important caveat this suite makes explicit: `forge` measures
///         EXECUTION gas inside one transaction, so it cannot see the saving
///         that actually motivates batching — the 21,000 gas intrinsic cost
///         charged once per transaction, plus one signature and one nonce each.
///         In-EVM the two paths are near-identical by design: `_setIfChanged`
///         reads the slot first, but that read warms the slot the write then
///         uses, so a cold SLOAD (2,100) + warm SSTORE (20,000) costs the same
///         22,100 as a bare cold SSTORE.
///
///         So: this suite proves batching is execution-neutral, and derives the
///         real saving arithmetically from the transaction count.
contract GasTest is BaseTest {
    uint256 internal constant N = 20;
    uint256 internal constant TX_BASE_GAS = 21_000;

    /// @dev N user ↔ subaccount pairs, i.e. 2N directed edges once linked.
    function _makePairs(uint160 seed) internal pure returns (StrandsAllowlistBatch.Edge[] memory e) {
        e = new StrandsAllowlistBatch.Edge[](N);
        for (uint160 i = 0; i < N; ++i) {
            e[i] = StrandsAllowlistBatch.Edge(address(seed + i), address(seed + 1000 + i));
        }
    }

    function test_Batched_IsExecutionNeutralVersusIndividualCalls() public {
        StrandsAllowlistBatch.Edge[] memory individual = _makePairs(0x10000);
        StrandsAllowlistBatch.Edge[] memory batched = _makePairs(0x20000);

        vm.startPrank(admin);

        // the un-batched equivalent of one `setPairs`: 2 single writes per pair
        uint256 before = gasleft();
        for (uint256 i = 0; i < N; ++i) {
            token.setDestinationAllowed(individual[i].holder, individual[i].destination, true);
            token.setDestinationAllowed(individual[i].destination, individual[i].holder, true);
        }
        uint256 individualGas = before - gasleft();

        before = gasleft();
        token.setPairs(batched, true);
        uint256 batchedGas = before - gasleft();

        vm.stopPrank();

        emit log_named_uint("execution gas, 2N individual calls", individualGas);
        emit log_named_uint("execution gas, 1 batched call    ", batchedGas);
        emit log_named_uint("tx base gas saved (21k * (2N-1)) ", TX_BASE_GAS * (2 * N - 1));
        emit log_named_uint("signatures saved                 ", 2 * N - 1);

        // Execution cost must stay in the same ballpark — the skip-read is paid
        // for by the warmed slot. A large regression here means _setIfChanged
        // started costing real gas.
        assertLt(batchedGas, (individualGas * 110) / 100, "batching must not cost >10% more execution gas");

        // Every edge actually landed, in both directions.
        for (uint256 i = 0; i < N; ++i) {
            assertTrue(token.isLinked(batched[i].holder, batched[i].destination));
        }
    }

    /// @dev The skip path should be dramatically cheaper than re-writing, which
    ///      is what makes re-running a manifest safe to do routinely.
    function test_ReRunningAppliedBatch_IsMuchCheaper() public {
        StrandsAllowlistBatch.Edge[] memory pairs = _makePairs(0x30000);

        vm.startPrank(admin);
        uint256 before = gasleft();
        token.setPairs(pairs, true);
        uint256 firstRun = before - gasleft();

        before = gasleft();
        token.setPairs(pairs, true); // every edge skipped
        uint256 secondRun = before - gasleft();
        vm.stopPrank();

        emit log_named_uint("first run (writes)  ", firstRun);
        emit log_named_uint("second run (skips)  ", secondRun);

        assertLt(secondRun, firstRun / 5, "a fully-applied re-run should cost a fraction of the first");
    }
}
