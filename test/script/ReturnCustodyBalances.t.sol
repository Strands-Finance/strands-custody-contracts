// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { StrandsDACAP } from "../../src/StrandsDACAP.sol";
import { CustodyBalanceMover } from "../../script/CustodyBalanceMover.sol";
import { MoveCustodyBalances } from "../../script/MoveCustodyBalances.s.sol";
import { ReturnCustodyBalances } from "../../script/ReturnCustodyBalances.s.sol";

/// @notice Replays both balance scripts' real plans against a replica of Production on Ethereum mainnet, built at the
///         real addresses: the beacon, the three tokens, the mint authority holding both roles, and the supply minted to
///         the holder. The move then the return must leave exactly the balances asked for, and each script must refuse
///         to run a second time.
/// @dev    Local only: nothing here reads the chain. Each contract is deployed at its mainnet address by etching its
///         creation code there and calling it, so the constructor runs in that address's storage, as
///         `StdCheats.deployCodeTo` does, without reading artifacts from disk.
contract ReturnCustodyBalancesTest is Test {
    address internal constant HOLDER = 0xE399Fce1F0E00aCE5c5dAeba9a5d14be889E98D1;
    address internal constant SPOT_VAULT = 0x2e7dF4fAf35a1599979C7E764444e112d936ec42;
    address internal constant MINT_AUTHORITY = 0x4b0898BcaEedC2FCC42c0a2135Ba2ecbdb994a0C;
    address internal constant PROD_BEACON = 0x91007eaD9F8AB14f6a6e66bCA393510E6fcad114;
    address internal constant BEACON_OWNER = 0x30F10Bc50fCd6CA6d8567A2Bd2685ED975487c3c;

    StrandsDACAP internal constant ETH = StrandsDACAP(0xd91E772978142075727379e631DDe96377Bc5476);
    StrandsDACAP internal constant USDC = StrandsDACAP(0x1eBb06ae854F186030a80BB7b3e73D5F22240fD6);
    StrandsDACAP internal constant USDT = StrandsDACAP(0xEE70394909906E9B5fe6D19D16b8c07058B06d74);

    uint256 internal constant ETH_SUPPLY = 10_000_001_000_000_000;
    uint256 internal constant USDC_SUPPLY = 2_901_100_000_000;
    uint256 internal constant USDT_SUPPLY = 1_601_005_000_000;

    function setUp() public {
        StrandsDACAP implementation = new StrandsDACAP();
        _deployAt(
            PROD_BEACON, bytes.concat(type(UpgradeableBeacon).creationCode, abi.encode(implementation, BEACON_OWNER))
        );
        _deployToken(ETH, 18, "Strands.DACAP.BitGo.ETH");
        _deployToken(USDC, 6, "Strands.DACAP.BitGo.USDC");
        _deployToken(USDT, 6, "Strands.DACAP.BitGo.USDT");

        vm.startPrank(MINT_AUTHORITY);
        ETH.mint(HOLDER, ETH_SUPPLY);
        USDC.mint(HOLDER, USDC_SUPPLY);
        USDT.mint(HOLDER, USDT_SUPPLY);
        vm.stopPrank();
    }

    /// @dev Deployed by the mint authority, as Production's were, so it comes out the token's admin and minter.
    function _deployToken(StrandsDACAP token, uint8 decimals, string memory name) internal {
        bytes memory init = abi.encodeCall(StrandsDACAP.initializeToken, (decimals, name, name));
        vm.prank(MINT_AUTHORITY);
        _deployAt(address(token), bytes.concat(type(BeaconProxy).creationCode, abi.encode(PROD_BEACON, init)));
    }

    /// @dev Runs `initCode` as a constructor at `where` and leaves the runtime code it returns there. A prank set before
    ///      this call is the constructor's `msg.sender`.
    function _deployAt(address where, bytes memory initCode) internal {
        vm.etch(where, initCode);
        (bool ok, bytes memory runtime) = where.call("");
        require(ok, "a constructor reverted");
        vm.etch(where, runtime);
    }

    function _run(CustodyBalanceMover script) internal {
        (CustodyBalanceMover.Move[] memory moves, address from, address to) = script.plan();
        script.move(moves, from, to, MINT_AUTHORITY, PROD_BEACON, block.chainid);
    }

    /// @dev The move, as broadcast on 2026-10-08: everything into the vault.
    function test_Move_LeavesEverythingInTheVault() public {
        _run(new MoveCustodyBalances());

        assertEq(ETH.balanceOf(HOLDER) + USDC.balanceOf(HOLDER) + USDT.balanceOf(HOLDER), 0, "the holder holds nothing");
        assertEq(ETH.balanceOf(SPOT_VAULT), ETH_SUPPLY);
        assertEq(USDC.balanceOf(SPOT_VAULT), USDC_SUPPLY);
        assertEq(USDT.balanceOf(SPOT_VAULT), USDT_SUPPLY);
    }

    /// @dev The balances Cameron asked for once the excess is back: holder 400,000 USDC and 600,000 USDT, vault
    ///      2,501,100 USDC and 1,001,005 USDT, and the ETH token untouched in the vault. Supply never moves.
    function test_MoveThenReturn_LeavesTheBalancesAskedFor() public {
        _run(new MoveCustodyBalances());
        _run(new ReturnCustodyBalances());

        assertEq(USDC.balanceOf(HOLDER), 400_000e6, "holder USDC");
        assertEq(USDT.balanceOf(HOLDER), 600_000e6, "holder USDT");
        assertEq(ETH.balanceOf(HOLDER), 0, "holder ETH");
        assertEq(USDC.balanceOf(SPOT_VAULT), 2_501_100e6, "vault USDC");
        assertEq(USDT.balanceOf(SPOT_VAULT), 1_001_005e6, "vault USDT");
        assertEq(ETH.balanceOf(SPOT_VAULT), ETH_SUPPLY, "vault ETH");
        assertEq(USDC.totalSupply(), USDC_SUPPLY, "USDC supply");
        assertEq(USDT.totalSupply(), USDT_SUPPLY, "USDT supply");
        assertEq(ETH.totalSupply(), ETH_SUPPLY, "ETH supply");
    }

    /// @dev The state mainnet is in now. The move is done, so running it again is refused.
    function test_Move_RefusesASecondRun() public {
        _run(new MoveCustodyBalances());
        MoveCustodyBalances script = new MoveCustodyBalances();
        (CustodyBalanceMover.Move[] memory moves, address from, address to) = script.plan();

        vm.expectRevert(
            bytes("the source holds 0 of Strands.DACAP.BitGo.ETH, not the 10000001000000000 this run expects")
        );
        script.move(moves, from, to, MINT_AUTHORITY, PROD_BEACON, block.chainid);
    }

    /// @dev A second return would send another 400,000 and 600,000 back. It is refused, and nothing moves.
    function test_Return_RefusesASecondRun() public {
        _run(new MoveCustodyBalances());
        _run(new ReturnCustodyBalances());
        ReturnCustodyBalances script = new ReturnCustodyBalances();
        (CustodyBalanceMover.Move[] memory moves, address from, address to) = script.plan();

        vm.expectRevert(
            bytes("the source holds 2501100000000 of Strands.DACAP.BitGo.USDC, not the 2901100000000 this run expects")
        );
        script.move(moves, from, to, MINT_AUTHORITY, PROD_BEACON, block.chainid);

        assertEq(USDC.balanceOf(HOLDER), 400_000e6);
        assertEq(USDT.balanceOf(HOLDER), 600_000e6);
    }
}
