// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/Script.sol";
import { StrandsDACAP } from "../src/StrandsDACAP.sol";
import { Networks } from "./Networks.sol";

/// @notice Moves custody-token balances between two addresses on Ethereum mainnet (Production, Derive v3): each amount is
///         burned from one and minted to the other, so supply is unchanged and the backend, which mints
///         `custodian balance - totalSupply()`, mints nothing back. A script names what it moves in `plan()`.
///
///         Without `--broadcast` it only simulates: every call runs against a local fork of the chain, the balances are
///         printed before and after, and nothing is sent. No key is needed for that.
///
///             forge script script/<Script>.s.sol --sig "mainnet()"
///             forge script script/<Script>.s.sol --sig "mainnet()" --broadcast --slow --private-key <key>
///
///         The key is Production's mint authority (`MINT_AUTHORITY`), given only on the broadcast (`--private-key`,
///         `--account` or `--ledger`). Forge refuses to send if it is any other key's.
/// @dev    Sends two transactions per token, one token at a time: `guardBurn` from the source, then `guardMint` to the
///         destination, each against the supply read just before. A mint landing between the two makes ours revert
///         rather than double the supply. The run prints a recovery `cast send` for each token, for a burn that lands
///         without its mint.
abstract contract CustodyBalanceMover is Networks {
    struct Move {
        StrandsDACAP token;
        /// @dev Burned from the source and minted to the destination, in base units.
        uint256 amount;
        /// @dev What the source and the destination must hold once the move is done. Together with `amount` they pin
        ///      both balances before it too, so a run against any other state is refused before anything is sent.
        uint256 fromAfter;
        uint256 toAfter;
    }

    /// @dev `bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1)`: where a `BeaconProxy` records its beacon.
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    /// @dev The holder's wallet, which the tokens were minted to.
    address internal constant HOLDER = 0xE399Fce1F0E00aCE5c5dAeba9a5d14be889E98D1;
    /// @dev Derive v3's SpotVault, the escrow `OnchainActionManager.deposit` pulls collateral into.
    address internal constant SPOT_VAULT = 0x2e7dF4fAf35a1599979C7E764444e112d936ec42;
    /// @dev Production's mint authority: deployed all three tokens and holds DEFAULT_ADMIN_ROLE and MINTER_ROLE on each.
    address internal constant MINT_AUTHORITY = 0x4b0898BcaEedC2FCC42c0a2135Ba2ecbdb994a0C;
    /// @dev Production's beacon on Ethereum mainnet. RC's is a different one.
    address internal constant PROD_BEACON = 0x91007eaD9F8AB14f6a6e66bCA393510E6fcad114;

    // Each supply is the whole of what was minted, all of it to HOLDER, as read on 2026-10-08 at block 26,150,554. The
    // moves only shift it between HOLDER and SPOT_VAULT.
    StrandsDACAP internal constant ETH_TOKEN = StrandsDACAP(0xd91E772978142075727379e631DDe96377Bc5476);
    uint256 internal constant ETH_SUPPLY = 10_000_001_000_000_000; // 0.010000001, 18 decimals
    StrandsDACAP internal constant USDC_TOKEN = StrandsDACAP(0x1eBb06ae854F186030a80BB7b3e73D5F22240fD6);
    uint256 internal constant USDC_SUPPLY = 2_901_100_000_000; // 2,901,100, 6 decimals
    StrandsDACAP internal constant USDT_TOKEN = StrandsDACAP(0xEE70394909906E9B5fe6D19D16b8c07058B06d74);
    uint256 internal constant USDT_SUPPLY = 1_601_005_000_000; // 1,601,005, 6 decimals

    function mainnet() external {
        _run(_mainnet());
    }

    /// @dev A rehearsal on an anvil fork of Ethereum mainnet, impersonating the mint authority:
    ///      `cast rpc anvil_impersonateAccount <MINT_AUTHORITY> --rpc-url http://127.0.0.1:8546`, then
    ///      `--sig "localFork()" --broadcast --unlocked --sender <MINT_AUTHORITY>`.
    function localFork() external {
        _run(_localFork());
    }

    /// @dev What this script moves, and between which two addresses. Public so a test can replay it.
    function plan() public pure virtual returns (Move[] memory moves, address from, address to);

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
        require(to != from, "the destination is the source");

        console2.log("From:", from);
        console2.log("To:", to);
        console2.log("Signer:", signer);

        uint256[] memory supplies = new uint256[](moves.length);
        console2.log("");
        console2.log("---------- before ----------");
        for (uint256 i = 0; i < moves.length; i++) {
            supplies[i] = _check(moves[i], from, to, signer, beacon);
        }

        console2.log("");
        console2.log("---------- moving ----------");
        for (uint256 i = 0; i < moves.length; i++) {
            StrandsDACAP token = moves[i].token;
            uint256 amount = moves[i].amount;
            uint256 supply = supplies[i];
            console2.log(token.name(), _amount(amount, token.decimals()));
            console2.log("  if the burn lands and the mint does not, finish it with:");
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
            require(token.balanceOf(from) == moves[i].fromAfter, "the source does not hold what was planned");
            require(token.balanceOf(to) == moves[i].toAfter, "the destination does not hold what was planned");
            require(token.totalSupply() == supplies[i], "the supply changed");
        }
        console2.log("");
        console2.log("Every balance is as planned and every supply is unchanged.");
    }

    /// @dev Refuses a token this run cannot or should not move, and logs it as it stands. Returns its supply, which the
    ///      guarded calls and the final checks are measured against.
    function _check(Move memory m, address from, address to, address signer, address beacon)
        private
        view
        returns (uint256 supply)
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
        _requirePlannedBalances(m, from, to);

        return token.totalSupply();
    }

    /// @dev The source must hold exactly `fromAfter + amount`, and the destination must end at exactly `toAfter`.
    function _requirePlannedBalances(Move memory m, address from, address to) private view {
        StrandsDACAP token = m.token;
        uint256 fromBefore = token.balanceOf(from);
        require(
            fromBefore == m.fromAfter + m.amount,
            string.concat(
                "the source holds ",
                vm.toString(fromBefore),
                " of ",
                token.name(),
                ", not the ",
                vm.toString(m.fromAfter + m.amount),
                " this run expects"
            )
        );
        uint256 toBefore = token.balanceOf(to);
        require(
            toBefore + m.amount == m.toAfter,
            string.concat(
                "the destination holds ",
                vm.toString(toBefore),
                " of ",
                token.name(),
                ", so it would end at ",
                vm.toString(toBefore + m.amount),
                ", not the planned ",
                vm.toString(m.toAfter)
            )
        );
    }

    function _log(StrandsDACAP token, address from, address to) private view {
        uint8 decimals = token.decimals();
        console2.log(token.name(), address(token));
        console2.log("  total supply:", _amount(token.totalSupply(), decimals));
        console2.log("  from:        ", _amount(token.balanceOf(from), decimals));
        console2.log("  to:          ", _amount(token.balanceOf(to), decimals));
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

    function _run(Network memory network) private {
        _use(network);
        (Move[] memory moves, address from, address to) = plan();
        move(moves, from, to, MINT_AUTHORITY, PROD_BEACON, network.chainId);
    }
}
