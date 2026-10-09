// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/Script.sol";
import { StrandsDACAP } from "../src/StrandsDACAP.sol";
import { Networks } from "./Networks.sol";

/// @notice What `BurnCustodyTokens`, `MintCustodyTokens` and `MoveCustodyTokens` share: the checks made before anything
///         is signed, the guarded burn and mint, and the balance printout. Each script takes its token, addresses and
///         amount on the command line, one token per run, so an operation is a command rather than a new script:
///
///             forge script script/BurnCustodyTokens.s.sol --sig "mainnet(address,address,uint256,uint256)" \
///               <token> <from> <amount> <expected supply> --sender <minter>
///
///         Amounts are in base units: `$(cast parse-units 400000 6)` is 400,000 of a 6-decimal token. Without
///         `--broadcast` a run only simulates: it prints every balance before and after, and sends nothing. To send, add
///         `--broadcast --slow` and give the minter's key (`--private-key`, `--account` or `--ledger`) in place of
///         `--sender`.
/// @dev    The signer is whoever forge runs the script as (`--sender`, or the one key given), so the same scripts serve
///         any environment's mint authority. Each run also takes a value that it checks before anything is signed and
///         that the run itself changes, so the same command run twice is refused rather than repeated.
abstract contract CustodyTokenScript is Networks {
    /// @dev `bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1)`: where a `BeaconProxy` records its beacon.
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    /// @dev Refuses before anything is signed unless the RPC is on `chainId`. Forge's own `--chain` does not stop a
    ///      broadcast to an RPC on another chain.
    function _requireChain(uint256 chainId) internal view {
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
    }

    /// @dev Logs the token and refuses one the signer cannot burn or mint. A wrong token address is refused here too: no
    ///      other contract seats the mint authority as its minter.
    function _requireMinter(StrandsDACAP token, address signer) internal view {
        require(address(token).code.length != 0, string.concat(vm.toString(address(token)), " has no code"));
        console2.log(token.name(), address(token));
        console2.log("  beacon:", address(uint160(uint256(vm.load(address(token), BEACON_SLOT)))));
        console2.log("  signer:", signer);
        console2.log("  supply:", _amount(token.totalSupply(), token.decimals()));
        require(
            token.hasRole(token.MINTER_ROLE(), signer),
            string.concat(
                vm.toString(signer),
                " does not hold MINTER_ROLE on ",
                token.name(),
                ": pass the minter as --sender to simulate, or its key to broadcast"
            )
        );
    }

    function _requireSupply(StrandsDACAP token, uint256 expectedSupply) internal view {
        uint256 supply = token.totalSupply();
        require(
            supply == expectedSupply,
            string.concat(
                "the supply of ",
                token.name(),
                " is ",
                vm.toString(supply),
                ", not the expected ",
                vm.toString(expectedSupply)
            )
        );
    }

    /// @dev `guardBurn(from, amount, supply)`, then checks that exactly `amount` left `from` and the supply.
    function _burn(StrandsDACAP token, address from, uint256 amount, uint256 supply, address signer) internal {
        require(amount != 0, "the amount is zero");
        uint256 held = token.balanceOf(from);
        require(
            held >= amount,
            string.concat(
                vm.toString(from),
                " holds ",
                vm.toString(held),
                " of ",
                token.name(),
                ", less than the ",
                vm.toString(amount),
                " to burn"
            )
        );

        vm.startBroadcast(signer);
        token.guardBurn(from, amount, supply);
        vm.stopBroadcast();

        require(token.balanceOf(from) == held - amount, "the burn did not take exactly the amount from the holder");
        require(token.totalSupply() == supply - amount, "the burn did not take exactly the amount from the supply");
        uint8 decimals = token.decimals();
        console2.log(string.concat("burned ", _amount(amount, decimals), " from ", vm.toString(from)));
        _logChange(from, held, held - amount, decimals);
        _logChange(address(0), supply, supply - amount, decimals);
    }

    /// @dev `guardMint(to, amount, supply)`, then checks that exactly `amount` reached `to` and the supply.
    function _mint(StrandsDACAP token, address to, uint256 amount, uint256 supply, address signer) internal {
        require(amount != 0, "the amount is zero");
        require(to != address(0), "the recipient is zero");
        uint256 held = token.balanceOf(to);

        vm.startBroadcast(signer);
        token.guardMint(to, amount, supply);
        vm.stopBroadcast();

        require(token.balanceOf(to) == held + amount, "the mint did not give exactly the amount to the recipient");
        require(token.totalSupply() == supply + amount, "the mint did not add exactly the amount to the supply");
        uint8 decimals = token.decimals();
        console2.log(string.concat("minted ", _amount(amount, decimals), " to ", vm.toString(to)));
        _logChange(to, held, held + amount, decimals);
        _logChange(address(0), supply, supply + amount, decimals);
    }

    /// @dev One balance's before and after. The zero address stands for the supply.
    function _logChange(address who, uint256 before, uint256 afterwards, uint8 decimals) internal view {
        console2.log(
            string.concat(
                who == address(0) ? "  supply" : string.concat("  ", vm.toString(who)),
                ": ",
                _amount(before, decimals),
                " -> ",
                _amount(afterwards, decimals)
            )
        );
    }

    /// @dev `<units> (<base units>)`, e.g. `0.010000001 (10000001000000000)` for 18 decimals.
    function _amount(uint256 baseUnits, uint8 decimals) internal view returns (string memory) {
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
}
