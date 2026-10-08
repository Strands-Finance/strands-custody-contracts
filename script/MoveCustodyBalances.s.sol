// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/Script.sol";
import { StrandsDACAP } from "../src/StrandsDACAP.sol";
import { Networks } from "./Networks.sol";

/// @notice One-time move on Ethereum mainnet (Production, Derive v3): takes one holder's balance of each of their three
///         custody tokens into Derive v3's SpotVault, by burning it from the holder and minting the same amount to the
///         vault. Supply is unchanged, so the backend, which mints `custodian balance - totalSupply()`, mints nothing
///         back.
///
///         Without `--broadcast` it only simulates: every call runs against a local fork of the chain, the balances are
///         printed before and after, and nothing is sent. No key is needed for that.
///
///             forge script script/MoveCustodyBalances.s.sol --sig "mainnet()"
///             forge script script/MoveCustodyBalances.s.sol --sig "mainnet()" --broadcast --slow --private-key <key>
///
///         The key is Production's mint authority (`MINT_AUTHORITY`), given only on the broadcast (`--private-key`,
///         `--account` or `--ledger`). Forge refuses to send if it is any other key's.
/// @dev    Sends six transactions, two per token, one token at a time: `guardBurn` from the holder, then `guardMint` to
///         the vault, each against the supply read just before. A mint landing between the two makes ours revert
///         rather than double the supply. The run prints a recovery `cast send` for each token, for a burn that lands
///         without its mint.
contract MoveCustodyBalances is Networks {
    struct Move {
        StrandsDACAP token;
        /// @dev The exact amount the holder must hold, in base units. The run refuses anything else.
        uint256 amount;
    }

    /// @dev `bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1)`: where a `BeaconProxy` records its beacon.
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    address internal constant HOLDER = 0xE399Fce1F0E00aCE5c5dAeba9a5d14be889E98D1;
    /// @dev Derive v3's SpotVault, the escrow `OnchainActionManager.deposit` pulls collateral into.
    address internal constant SPOT_VAULT = 0x2e7dF4fAf35a1599979C7E764444e112d936ec42;
    /// @dev Production's mint authority: deployed all three tokens and holds DEFAULT_ADMIN_ROLE and MINTER_ROLE on each.
    address internal constant MINT_AUTHORITY = 0x4b0898BcaEedC2FCC42c0a2135Ba2ecbdb994a0C;
    /// @dev Production's beacon on Ethereum mainnet. RC's is a different one.
    address internal constant PROD_BEACON = 0x91007eaD9F8AB14f6a6e66bCA393510E6fcad114;

    // Each amount is the token's whole supply, all of it held by HOLDER, as read on 2026-10-08 at block 26,150,554.
    StrandsDACAP internal constant ETH_TOKEN = StrandsDACAP(0xd91E772978142075727379e631DDe96377Bc5476);
    uint256 internal constant ETH_AMOUNT = 10_000_001_000_000_000; // 0.010000001, 18 decimals
    StrandsDACAP internal constant USDC_TOKEN = StrandsDACAP(0x1eBb06ae854F186030a80BB7b3e73D5F22240fD6);
    uint256 internal constant USDC_AMOUNT = 2_901_100_000_000; // 2,901,100, 6 decimals
    StrandsDACAP internal constant USDT_TOKEN = StrandsDACAP(0xEE70394909906E9B5fe6D19D16b8c07058B06d74);
    uint256 internal constant USDT_AMOUNT = 1_601_005_000_000; // 1,601,005, 6 decimals

    function mainnet() external {
        _moveOn(_mainnet());
    }

    /// @dev A rehearsal on an anvil fork of Ethereum mainnet, impersonating the mint authority:
    ///      `cast rpc anvil_impersonateAccount <MINT_AUTHORITY> --rpc-url http://127.0.0.1:8546`, then
    ///      `--sig "localFork()" --broadcast --unlocked --sender <MINT_AUTHORITY>`.
    function localFork() external {
        _moveOn(_localFork());
    }

    /// @dev Every check, for every token, runs before the first send, so a refusal sends nothing.
    ///
    ///      Separate from the entrypoints so tests pass arguments rather than the mainnet constants.
    function move(Move[] memory moves, address from, address to, address signer, address beacon, uint256 chainId)
        public
    {
        require(
            block.chainid == chainId,
            string.concat(
                "the RPC is chain ",
                vm.toString(block.chainid),
                ", not the expected ",
                vm.toString(chainId),
                ": nothing was sent"
            )
        );
        require(moves.length != 0, "no tokens to move");
        require(to != address(0), "the destination is zero");
        require(to != from, "the destination is the holder");
        require(to.code.length != 0, "the destination has no code, so it is not the vault");

        console2.log("Holder:", from);
        console2.log("Destination:", to);
        console2.log("Signer:", signer);

        uint256[] memory supplies = new uint256[](moves.length);
        uint256[] memory toBefore = new uint256[](moves.length);
        console2.log("");
        console2.log("---------- before ----------");
        for (uint256 i = 0; i < moves.length; i++) {
            (supplies[i], toBefore[i]) = _check(moves[i], from, to, signer, beacon);
        }

        console2.log("");
        console2.log("---------- moving ----------");
        for (uint256 i = 0; i < moves.length; i++) {
            StrandsDACAP token = moves[i].token;
            uint256 amount = moves[i].amount;
            uint256 supply = supplies[i];
            console2.log(token.name(), "- if the burn lands and the mint does not, finish it with:");
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

            vm.startBroadcast(signer);
            token.guardBurn(from, amount, supply);
            token.guardMint(to, amount, supply - amount);
            vm.stopBroadcast();
        }

        console2.log("");
        console2.log("---------- after ----------");
        for (uint256 i = 0; i < moves.length; i++) {
            StrandsDACAP token = moves[i].token;
            _log(token, from, to);
            require(token.balanceOf(from) == 0, "the holder still holds tokens");
            require(token.balanceOf(to) == toBefore[i] + moves[i].amount, "the destination did not gain the amount");
            require(token.totalSupply() == supplies[i], "the supply changed");
        }
        console2.log("");
        console2.log("Every balance moved and every supply is unchanged.");
    }

    /// @dev Refuses a token this run cannot or should not move, and logs it as it stands. Returns its supply and the
    ///      destination's balance, which the moves and the final checks are measured against.
    function _check(Move memory m, address from, address to, address signer, address beacon)
        private
        view
        returns (uint256 supply, uint256 toBalance)
    {
        StrandsDACAP token = m.token;
        require(address(token).code.length != 0, string.concat(vm.toString(address(token)), " has no code"));
        require(
            address(uint160(uint256(vm.load(address(token), BEACON_SLOT)))) == beacon,
            string.concat(vm.toString(address(token)), " is not a token of the expected beacon")
        );

        _log(token, from, to);
        bool isAdmin = token.hasRole(token.DEFAULT_ADMIN_ROLE(), signer);
        bool isMinter = token.hasRole(token.MINTER_ROLE(), signer);
        console2.log("  signer is admin:", isAdmin);
        console2.log("  signer is minter:", isMinter);

        require(isMinter, string.concat("the signer does not hold MINTER_ROLE on ", token.name()));
        require(
            token.balanceOf(from) == m.amount,
            string.concat(
                "the holder holds ",
                vm.toString(token.balanceOf(from)),
                " of ",
                token.name(),
                ", not the ",
                vm.toString(m.amount),
                " this run moves"
            )
        );

        return (token.totalSupply(), token.balanceOf(to));
    }

    function _log(StrandsDACAP token, address from, address to) private view {
        uint8 decimals = token.decimals();
        console2.log(token.name(), address(token));
        console2.log("  total supply:", _amount(token.totalSupply(), decimals));
        console2.log("  holder:      ", _amount(token.balanceOf(from), decimals));
        console2.log("  destination: ", _amount(token.balanceOf(to), decimals));
    }

    /// @dev `<units> (<base units>)`, e.g. `0.010000001 (10000001000000000)` for 18 decimals.
    function _amount(uint256 baseUnits, uint8 decimals) private view returns (string memory) {
        uint256 scale = uint256(10) ** decimals;
        string memory units = vm.toString(baseUnits / scale);
        uint256 fraction = baseUnits % scale;
        if (fraction != 0) {
            bytes memory digits = bytes(vm.toString(fraction + scale)); // a leading 1 keeps the fraction's zeros
            uint256 end = digits.length;
            while (digits[end - 1] == "0") end--;
            bytes memory kept = new bytes(end - 1);
            for (uint256 i = 1; i < end; i++) {
                kept[i - 1] = digits[i];
            }
            units = string.concat(units, ".", string(kept));
        }
        return string.concat(units, " (", vm.toString(baseUnits), ")");
    }

    function _moveOn(Network memory network) private {
        _use(network);
        Move[] memory moves = new Move[](3);
        moves[0] = Move(ETH_TOKEN, ETH_AMOUNT);
        moves[1] = Move(USDC_TOKEN, USDC_AMOUNT);
        moves[2] = Move(USDT_TOKEN, USDT_AMOUNT);
        move(moves, HOLDER, SPOT_VAULT, MINT_AUTHORITY, PROD_BEACON, network.chainId);
    }
}
