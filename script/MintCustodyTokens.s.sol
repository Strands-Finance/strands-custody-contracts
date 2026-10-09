// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StrandsDACAP } from "../src/StrandsDACAP.sol";
import { CustodyTokenScript } from "./CustodyTokenScript.sol";

/// @notice Mints `amount` of one custody token to `to`. `expectedSupply` is the token's `totalSupply()` now: the run is
///         refused unless the chain agrees, and the mint changes it, so the same command run twice is refused.
///
///             forge script script/MintCustodyTokens.s.sol --sig "mainnet(address,address,uint256,uint256)" \
///               <token> <to> <amount> <expected supply> --sender <minter>
///
///         See `CustodyTokenScript` for amounts, simulating and sending.
contract MintCustodyTokens is CustodyTokenScript {
    function mainnet(StrandsDACAP token, address to, uint256 amount, uint256 expectedSupply) external {
        Network memory network = _mainnet();
        _use(network);
        mint(token, to, amount, expectedSupply, msg.sender, network.chainId);
    }

    function localFork(StrandsDACAP token, address to, uint256 amount, uint256 expectedSupply) external {
        Network memory network = _localFork();
        _use(network);
        mint(token, to, amount, expectedSupply, msg.sender, network.chainId);
    }

    /// @dev Separate from the entrypoints so tests pass the signer and chain rather than forking one.
    function mint(
        StrandsDACAP token,
        address to,
        uint256 amount,
        uint256 expectedSupply,
        address signer,
        uint256 chainId
    ) public {
        _requireChain(chainId);
        _requireMinter(token, signer);
        _requireSupply(token, expectedSupply);
        _mint(token, to, amount, expectedSupply, signer);
    }
}
