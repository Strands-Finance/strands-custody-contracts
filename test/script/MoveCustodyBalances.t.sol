// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import { BaseTest } from "../Base.t.sol";
import { StrandsDACAP } from "../../src/StrandsDACAP.sol";
import { MoveCustodyBalances } from "../../script/MoveCustodyBalances.s.sol";

/// @notice The one-time move of a holder's custody tokens into Derive v3's SpotVault. What is pinned is that every
///         balance lands in the vault with supply unchanged and nothing else touched, and that every refusal comes
///         before the first send, so a run that refuses leaves every token as it was.
/// @dev    `move` is called directly with fixture tokens, rather than through `mainnet()` and its constants. Three tokens,
///         as on mainnet, deployed by `mintAuthority` so it holds both roles, as the backend's key does.
contract MoveCustodyBalancesTest is BaseTest {
    MoveCustodyBalances internal script;

    address internal mintAuthority = makeAddr("mintAuthority");
    address internal holder = makeAddr("holder");
    address internal vault = makeAddr("spotVault");

    StrandsDACAP internal eth;
    StrandsDACAP internal usdc;
    StrandsDACAP internal usdt;

    uint256 internal constant ETH_AMOUNT = 10_000_001_000_000_000;
    uint256 internal constant USDC_AMOUNT = 2_901_100_000_000;
    uint256 internal constant USDT_AMOUNT = 1_601_005_000_000;

    function setUp() public override {
        super.setUp();
        script = new MoveCustodyBalances();
        vm.etch(vault, hex"00");

        eth = _deployAs(mintAuthority, 18, "Strands.DACAP.BitGo.ETH", "Strands.DACAP.BitGo.ETH");
        usdc = _deployAs(mintAuthority, 6, "Strands.DACAP.BitGo.USDC", "Strands.DACAP.BitGo.USDC");
        usdt = _deployAs(mintAuthority, 6, "Strands.DACAP.BitGo.USDT", "Strands.DACAP.BitGo.USDT");

        vm.startPrank(mintAuthority);
        eth.mint(holder, ETH_AMOUNT);
        usdc.mint(holder, USDC_AMOUNT);
        usdt.mint(holder, USDT_AMOUNT);
        vm.stopPrank();
    }

    function _moves() internal view returns (MoveCustodyBalances.Move[] memory moves) {
        moves = new MoveCustodyBalances.Move[](3);
        moves[0] = MoveCustodyBalances.Move(eth, ETH_AMOUNT);
        moves[1] = MoveCustodyBalances.Move(usdc, USDC_AMOUNT);
        moves[2] = MoveCustodyBalances.Move(usdt, USDT_AMOUNT);
    }

    function _move(MoveCustodyBalances.Move[] memory moves) internal {
        script.move(moves, holder, vault, mintAuthority, address(beacon), block.chainid);
    }

    /// @dev What every refusal must leave behind: the holder still holds everything and the vault nothing.
    function _assertNothingMoved() internal view {
        assertEq(eth.balanceOf(holder), ETH_AMOUNT, "the holder keeps its ETH token");
        assertEq(usdc.balanceOf(holder), USDC_AMOUNT, "the holder keeps its USDC token");
        assertEq(usdt.balanceOf(holder), USDT_AMOUNT, "the holder keeps its USDT token");
        assertEq(eth.balanceOf(vault) + usdc.balanceOf(vault) + usdt.balanceOf(vault), 0, "the vault received nothing");
    }

    // ---------- the move ----------

    function test_Move_TakesEveryBalanceFromTheHolderToTheVault_WithSupplyUnchanged() public {
        _move(_moves());

        assertEq(eth.balanceOf(holder), 0);
        assertEq(usdc.balanceOf(holder), 0);
        assertEq(usdt.balanceOf(holder), 0);
        assertEq(eth.balanceOf(vault), ETH_AMOUNT);
        assertEq(usdc.balanceOf(vault), USDC_AMOUNT);
        assertEq(usdt.balanceOf(vault), USDT_AMOUNT);
        assertEq(eth.totalSupply(), ETH_AMOUNT, "a burn and a mint of the same amount leave supply where it was");
        assertEq(usdc.totalSupply(), USDC_AMOUNT);
        assertEq(usdt.totalSupply(), USDT_AMOUNT);
    }

    /// @dev The guarded estimates are the supply read at run time, not the holder's balance. With other holders and a
    ///      vault that already holds the token, the two differ, and the move must still land and touch only the holder.
    function test_Move_LeavesEveryOtherBalanceAlone() public {
        vm.startPrank(mintAuthority);
        usdc.mint(vault, 7);
        usdc.mint(bob, 11);
        vm.stopPrank();

        _move(_moves());

        assertEq(usdc.balanceOf(vault), 7 + USDC_AMOUNT, "the vault's own balance is kept");
        assertEq(usdc.balanceOf(bob), 11, "another holder is untouched");
        assertEq(usdc.totalSupply(), 18 + USDC_AMOUNT);
    }

    /// @dev Each burn is the mint authority's, from the holder, so a reconciler watching `Burned` sees exactly this move.
    function test_Move_EmitsBurnedFromTheHolder() public {
        vm.expectEmit(true, true, false, true, address(eth));
        emit Burned(mintAuthority, holder, ETH_AMOUNT);
        vm.expectEmit(true, true, false, true, address(usdc));
        emit Burned(mintAuthority, holder, USDC_AMOUNT);
        vm.expectEmit(true, true, false, true, address(usdt));
        emit Burned(mintAuthority, holder, USDT_AMOUNT);

        _move(_moves());
    }

    // ---------- refusals, all before the first send ----------

    /// @dev Admin alone can neither burn nor mint. The refused token is last, so the refusal also proves that nothing
    ///      was sent for the two before it.
    function test_Move_RefusesASignerThatIsAdminButNotMinter() public {
        vm.prank(mintAuthority);
        usdt.renounceRole(MINTER_ROLE, mintAuthority);

        vm.expectRevert(bytes("the signer does not hold MINTER_ROLE on Strands.DACAP.BitGo.USDT"));
        _move(_moves());

        _assertNothingMoved();
    }

    function test_Move_RefusesASignerWithNoRole() public {
        vm.expectRevert(bytes("the signer does not hold MINTER_ROLE on Strands.DACAP.BitGo.ETH"));
        script.move(_moves(), holder, vault, makeAddr("stranger"), address(beacon), block.chainid);

        _assertNothingMoved();
    }

    /// @dev The amounts are pinned to what the console showed, so a balance that moved since is refused, not followed.
    function test_Move_RefusesAHolderBalanceThatIsNotThePinnedAmount() public {
        MoveCustodyBalances.Move[] memory moves = _moves();
        moves[2].amount = USDT_AMOUNT + 1;

        vm.expectRevert(
            bytes("the holder holds 1601005000000 of Strands.DACAP.BitGo.USDT, not the 1601005000001 this run moves")
        );
        _move(moves);

        _assertNothingMoved();
    }

    function test_Move_RefusesATokenOfAnotherBeacon() public {
        UpgradeableBeacon other = new UpgradeableBeacon(address(implementation), beaconOwner);

        vm.expectRevert(bytes(string.concat(vm.toString(address(eth)), " is not a token of the expected beacon")));
        script.move(_moves(), holder, vault, mintAuthority, address(other), block.chainid);

        _assertNothingMoved();
    }

    function test_Move_RefusesTheZeroDestination() public {
        vm.expectRevert(bytes("the destination is zero"));
        script.move(_moves(), holder, address(0), mintAuthority, address(beacon), block.chainid);

        _assertNothingMoved();
    }

    function test_Move_RefusesTheHolderAsTheDestination() public {
        vm.expectRevert(bytes("the destination is the holder"));
        script.move(_moves(), holder, holder, mintAuthority, address(beacon), block.chainid);

        _assertNothingMoved();
    }

    /// @dev The vault is a contract, so a destination with no code is a mistyped address.
    function test_Move_RefusesADestinationWithNoCode() public {
        vm.expectRevert(bytes("the destination has no code, so it is not the vault"));
        script.move(_moves(), holder, makeAddr("wallet"), mintAuthority, address(beacon), block.chainid);

        _assertNothingMoved();
    }

    function test_Move_RefusesTheWrongChain() public {
        uint256 other = block.chainid + 1;

        vm.expectRevert(
            bytes(
                string.concat(
                    "the RPC is chain ",
                    vm.toString(block.chainid),
                    ", not the expected ",
                    vm.toString(other),
                    ": nothing was sent"
                )
            )
        );
        script.move(_moves(), holder, vault, mintAuthority, address(beacon), other);

        _assertNothingMoved();
    }
}
