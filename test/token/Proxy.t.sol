// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { BaseTest } from "../Base.t.sol";
import { StrandsDACAP } from "../../src/StrandsDACAP.sol";
import { StrandsDACAPV2 } from "../mocks/StrandsDACAPV2.sol";

/// @notice What the proxy adds. Every other suite already runs through a `BeaconProxy` (the fixture deploys
///         one), so the token's own behaviour is covered there; this file is only about the three things that
///         exist BECAUSE there is a proxy: a locked implementation, per-proxy state, and the upgrade.
contract ProxyTest is BaseTest {
    /// @dev The implementation is code, not a token. If it could be initialized, someone could seat themselves
    ///      on it and make it look like one.
    function test_Implementation_CannotBeInitialized() public {
        _expectAlreadyInitialized();
        implementation.initializeToken(18, NAME, SYMBOL);

        // Nobody holds a role on the implementation, so `initialize` is refused at its role check.
        _expectNotAdmin(address(this));
        implementation.initialize(admin, minter);

        assertEq(implementation.name(), "", "the implementation holds no metadata");
        assertFalse(implementation.hasRole(DEFAULT_ADMIN_ROLE, address(this)), "and no admin");
    }

    /// @dev One implementation, one beacon, two tokens — and nothing shared between them. Decimals is the
    ///      sharp one: as an immutable it would have read the same on every proxy.
    function test_ProxiesOffOneBeacon_KeepSeparateState() public {
        StrandsDACAP usdc = _deploy(6, "Strands.DACAP.BitGo.USDC", "Strands.DACAP.BitGo.USDC");
        usdc.initialize(admin, minter);

        assertEq(usdc.decimals(), 6);
        assertEq(token.decimals(), 18);
        assertEq(usdc.name(), "Strands.DACAP.BitGo.USDC");
        assertEq(token.name(), NAME);

        vm.prank(minter);
        usdc.mint(bob, 5);
        vm.prank(admin);
        usdc.setDestinationAllowed(carol, true);

        assertEq(usdc.totalSupply(), 5);
        assertEq(token.totalSupply(), INITIAL_MINT, "a mint on one token must not reach the other");
        assertEq(token.balanceOf(bob), 0);
        assertFalse(token.allowedDestination(carol), "nor must an allowlist entry");
    }

    /// @dev The reason the proxy exists: new logic at the SAME address, with every balance, role and allowlist
    ///      entry still in place — no burn, no re-mint, nothing for a holder or an integration to do.
    function test_BeaconUpgrade_KeepsStateAndAddress() public {
        StrandsDACAP other = _deploy(6, "Strands.DACAP.BitGo.USDC", "Strands.DACAP.BitGo.USDC");
        other.initialize(admin, minter);
        _allow(bob);

        address v2 = address(new StrandsDACAPV2());
        vm.prank(beaconOwner);
        beacon.upgradeTo(v2);

        // The new logic answers at the old address, on every proxy at once.
        assertEq(StrandsDACAPV2(address(token)).version(), 2);
        assertEq(StrandsDACAPV2(address(other)).version(), 2);

        assertEq(token.balanceOf(alice), INITIAL_MINT);
        assertEq(token.totalSupply(), INITIAL_MINT);
        assertEq(token.name(), NAME);
        assertEq(token.decimals(), 18);
        assertEq(other.decimals(), 6);
        assertTrue(token.initialized());
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(token.hasRole(MINTER_ROLE, minter));
        assertTrue(token.allowedDestination(bob));

        // And it still works as a token: the supply guard reads the supply that was there before.
        vm.prank(minter);
        token.guardMint(alice, 1, INITIAL_MINT);
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(bob), 1);
    }

    /// @dev Upgrade authority is the beacon's owner and nobody else. In particular NOT a token's admin — the
    ///      backend grants DEFAULT_ADMIN_ROLE onward, and that grant carries no power over the code. Handing over
    ///      the beacon is its own explicit step (`script/TransferBeaconOwnership.s.sol`), even when, as with Derive,
    ///      the same party ends up holding both.
    function test_OnlyTheBeaconOwnerCanUpgrade() public {
        address v2 = address(new StrandsDACAPV2());

        address[3] memory strangers = [admin, minter, alice];
        for (uint256 i = 0; i < strangers.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, strangers[i]));
            vm.prank(strangers[i]);
            beacon.upgradeTo(v2);
        }

        assertEq(beacon.implementation(), address(implementation));
    }
}
