// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CustodyBalanceMover } from "./CustodyBalanceMover.sol";

/// @notice One-time correction to `MoveCustodyBalances.s.sol`, which moved too much into Derive v3's SpotVault: sends
///         400,000 of the USDC token and 600,000 of the USDT token back from the vault to the holder. The ETH token stays
///         where it is.
///
///             forge script script/ReturnCustodyBalances.s.sol --sig "mainnet()"
///             forge script script/ReturnCustodyBalances.s.sol --sig "mainnet()" --broadcast --slow --private-key <key>
///
///         It runs only against the state the move left, the vault holding the whole supply of both, and leaves:
///
///         | Token | Holder  | SpotVault |
///         |-------|---------|-----------|
///         | USDC  | 400,000 | 2,501,100 |
///         | USDT  | 600,000 | 1,001,005 |
contract ReturnCustodyBalances is CustodyBalanceMover {
    function plan() public pure override returns (Move[] memory moves, address from, address to) {
        moves = new Move[](2);
        moves[0] = Move(USDC_TOKEN, 400_000_000_000, 2_501_100_000_000, 400_000_000_000);
        moves[1] = Move(USDT_TOKEN, 600_000_000_000, 1_001_005_000_000, 600_000_000_000);
        return (moves, SPOT_VAULT, HOLDER);
    }
}
