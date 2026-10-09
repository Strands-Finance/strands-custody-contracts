// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StrandsDACAP } from "../src/StrandsDACAP.sol";
import { CustodyTokenScript } from "./CustodyTokenScript.sol";

/// @notice Burns `amount` of one custody token from `from`. `expectedSupply` is the token's `totalSupply()` now: the
///         run is refused unless the chain agrees, and the burn changes it, so the same command run twice is refused.
///
///             forge script script/BurnCustodyTokens.s.sol --sig "mainnet(address,address,uint256,uint256)" \
///               <token> <from> <amount> <expected supply> --sender <minter>
///
///         See `CustodyTokenScript` for amounts, simulating and sending.
contract BurnCustodyTokens is CustodyTokenScript {
    function mainnet(StrandsDACAP token, address from, uint256 amount, uint256 expectedSupply) external {
        Network memory network = _mainnet();
        _use(network);
        burn(token, from, amount, expectedSupply, msg.sender, network.chainId);
    }

    function localFork(StrandsDACAP token, address from, uint256 amount, uint256 expectedSupply) external {
        Network memory network = _localFork();
        _use(network);
        burn(token, from, amount, expectedSupply, msg.sender, network.chainId);
    }

    /// @dev Separate from the entrypoints so tests pass the signer and chain rather than forking one.
    function burn(
        StrandsDACAP token,
        address from,
        uint256 amount,
        uint256 expectedSupply,
        address signer,
        uint256 chainId
    ) public {
        _requireChain(chainId);
        _requireMinter(token, signer);
        _requireSupply(token, expectedSupply);
        _burn(token, from, amount, expectedSupply, signer);
    }
}
