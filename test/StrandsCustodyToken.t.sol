// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { StrandsCustodyToken } from "../src/StrandsCustodyToken.sol";

contract StrandsCustodyTokenTest is Test {
    StrandsCustodyToken internal token;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
    address internal custodian = makeAddr("custodian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    event CustodyBurn(address indexed custodian, address indexed from, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        token = new StrandsCustodyToken(admin);

        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);
        token.grantRole(token.CUSTODIAN_ROLE(), custodian);
        vm.stopPrank();

        vm.prank(minter);
        token.mint(alice, 1_000 ether);
    }

    // ---------- metadata ----------
    function test_Metadata() public view {
        assertEq(token.name(), "Strands Custody Token");
        assertEq(token.symbol(), "SCT");
        assertEq(token.decimals(), 18);
    }

    // ---------- roles ----------
    function test_AdminHasDefaultAdminRole() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_Constructor_RevertsOnZeroAdmin() public {
        vm.expectRevert(bytes("admin=0"));
        new StrandsCustodyToken(address(0));
    }

    function test_AdminCanRevokeCustodian() public {
        bytes32 role = token.CUSTODIAN_ROLE();
        vm.prank(admin);
        token.revokeRole(role, custodian);
        assertFalse(token.hasRole(role, custodian));
    }

    // ---------- mint ----------
    function test_MinterCanMint() public {
        vm.prank(minter);
        token.mint(bob, 50 ether);
        assertEq(token.balanceOf(bob), 50 ether);
        assertEq(token.totalSupply(), 1_050 ether);
    }

    function test_NonMinter_CannotMint() public {
        bytes32 role = token.MINTER_ROLE();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role));
        token.mint(bob, 1);
    }

    // ---------- custodyBurn (core feature) ----------
    function test_Custodian_CanBurnFromAnyHolder_WithoutAllowance() public {
        assertEq(token.allowance(alice, custodian), 0, "precondition: no allowance");

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, address(0), 400 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit CustodyBurn(custodian, alice, 400 ether);

        vm.prank(custodian);
        token.custodyBurn(alice, 400 ether);

        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.totalSupply(), 600 ether);
    }

    function test_NonCustodian_CannotCustodyBurn() public {
        bytes32 role = token.CUSTODIAN_ROLE();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, bob, role));
        token.custodyBurn(alice, 1);
    }

    function test_CustodyBurn_RevertsOnInsufficientBalance() public {
        vm.prank(custodian);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1_000 ether, 1_001 ether)
        );
        token.custodyBurn(alice, 1_001 ether);
    }

    // ---------- standard burn paths still work ----------
    function test_Holder_CanBurnOwnBalance() public {
        vm.prank(alice);
        token.burn(100 ether);
        assertEq(token.balanceOf(alice), 900 ether);
        assertEq(token.totalSupply(), 900 ether);
    }

    function test_BurnFrom_RequiresAllowance() public {
        vm.prank(bob);
        vm.expectRevert();
        token.burnFrom(alice, 1);
    }

    function test_BurnFrom_WorksWithAllowance() public {
        vm.prank(alice);
        token.approve(bob, 200 ether);

        vm.prank(bob);
        token.burnFrom(alice, 200 ether);

        assertEq(token.balanceOf(alice), 800 ether);
        assertEq(token.allowance(alice, bob), 0);
    }

    // ---------- fuzz ----------
    function testFuzz_CustodyBurn_BurnsExactAmount(uint96 amount) public {
        amount = uint96(bound(amount, 0, 1_000 ether));
        vm.prank(custodian);
        token.custodyBurn(alice, amount);
        assertEq(token.balanceOf(alice), 1_000 ether - amount);
        assertEq(token.totalSupply(), 1_000 ether - amount);
    }
}
