// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/Script.sol";
import { StrandsDACAP } from "../src/StrandsDACAP.sol";
import { CustodyTokenScript } from "./CustodyTokenScript.sol";

/// @notice Moves `amount` of one custody token from `from` to `to`: the burn of `BurnCustodyTokens`, then the mint of
///         `MintCustodyTokens`, so supply ends where it started and the backend, which mints
///         `custodian balance - totalSupply()`, mints nothing back. `expectedFromBalance` is what `from` holds now: the
///         run is refused unless the chain agrees, and the move changes it, so the same command run twice is refused.
///
///             forge script script/MoveCustodyTokens.s.sol --sig "mainnet(address,address,address,uint256,uint256)" \
///               <token> <from> <to> <amount> <expected from balance> --sender <minter>
///
///         See `CustodyTokenScript` for amounts, simulating and sending.
/// @dev    Two transactions: the burn, then the mint against the supply the burn left, so a mint landing between the
///         two makes ours revert rather than double the supply. The run prints a recovery `cast send` for a burn that
///         lands without its mint.
contract MoveCustodyTokens is CustodyTokenScript {
    function mainnet(StrandsDACAP token, address from, address to, uint256 amount, uint256 expectedFromBalance)
        external
    {
        Network memory network = _mainnet();
        _use(network);
        move(token, from, to, amount, expectedFromBalance, msg.sender, network.chainId);
    }

    function localFork(StrandsDACAP token, address from, address to, uint256 amount, uint256 expectedFromBalance)
        external
    {
        Network memory network = _localFork();
        _use(network);
        move(token, from, to, amount, expectedFromBalance, msg.sender, network.chainId);
    }

    /// @dev Separate from the entrypoints so tests pass the signer and chain rather than forking one.
    function move(
        StrandsDACAP token,
        address from,
        address to,
        uint256 amount,
        uint256 expectedFromBalance,
        address signer,
        uint256 chainId
    ) public {
        _requireChain(chainId);
        require(to != address(0), "the recipient is zero");
        require(to != from, "the recipient is the source");
        _requireMinter(token, signer);
        uint256 held = token.balanceOf(from);
        require(
            held == expectedFromBalance,
            string.concat(
                vm.toString(from),
                " holds ",
                vm.toString(held),
                " of ",
                token.name(),
                ", not the expected ",
                vm.toString(expectedFromBalance)
            )
        );

        uint256 supply = token.totalSupply();
        _burn(token, from, amount, supply, signer);
        console2.log("if the burn above lands and the mint below does not, finish it with:");
        console2.log(
            string.concat(
                "  cast send ",
                vm.toString(address(token)),
                ' "guardMint(address,uint256,uint256)" ',
                vm.toString(to),
                " ",
                vm.toString(amount),
                " ",
                vm.toString(supply - amount)
            )
        );
        _mint(token, to, amount, supply - amount, signer);
    }
}
