// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { CustodyBalanceMover } from "./CustodyBalanceMover.sol";

/// @notice One-time move, broadcast on 2026-10-08 (blocks 26,150,618-623): the holder's whole balance of each of its
///         three custody tokens into Derive v3's SpotVault. `ReturnCustodyBalances.s.sol` sends part of it back.
///
///             forge script script/MoveCustodyBalances.s.sol --sig "mainnet()"
///
///         It is pinned to the state it ran against, so it now refuses: the holder holds none of what it moves.
contract MoveCustodyBalances is CustodyBalanceMover {
    function plan() public pure override returns (Move[] memory moves, address from, address to) {
        moves = new Move[](3);
        moves[0] = Move(ETH_TOKEN, ETH_SUPPLY, 0, ETH_SUPPLY);
        moves[1] = Move(USDC_TOKEN, USDC_SUPPLY, 0, USDC_SUPPLY);
        moves[2] = Move(USDT_TOKEN, USDT_SUPPLY, 0, USDT_SUPPLY);
        return (moves, HOLDER, SPOT_VAULT);
    }
}
