// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { BaseTest } from "../Base.t.sol";
import { StrandsDACAPV2 } from "../mocks/StrandsDACAPV2.sol";
import { TransferBeaconOwnership } from "../../script/TransferBeaconOwnership.s.sol";

/// @notice The script that hands the beacon to Derive. The transfer is one-step and cannot be undone, so what is
///         pinned here is what it does on success (upgrade power moves, and nothing else does) and the three
///         cases it must refuse before signing.
/// @dev    The fixture's beacon owner has no private key, so `setUp` passes the beacon to one that does: the
///         script signs with a key, exactly as an operator runs it. `handOver` is called directly rather than
///         through `run`, so no test sets environment variables that a parallel test could read.
contract TransferBeaconOwnershipTest is BaseTest {
    TransferBeaconOwnership internal script;

    address internal keyedOwner;
    uint256 internal keyedOwnerKey;
    address internal derive = makeAddr("derive");

    function setUp() public override {
        super.setUp();
        script = new TransferBeaconOwnership();
        (keyedOwner, keyedOwnerKey) = makeAddrAndKey("keyedBeaconOwner");

        vm.prank(beaconOwner);
        beacon.transferOwnership(keyedOwner);
    }

    /// @dev The whole point of the handover: upgrade power leaves the old key and arrives at the new owner, who can
    ///      then upgrade every token at the same address with its state intact.
    function test_HandOver_MovesUpgradePowerToTheNewOwner() public {
        script.handOver(beacon, derive, keyedOwnerKey);

        assertEq(beacon.owner(), derive);

        address v2 = address(new StrandsDACAPV2());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keyedOwner));
        vm.prank(keyedOwner);
        beacon.upgradeTo(v2);

        vm.prank(derive);
        beacon.upgradeTo(v2);
        assertEq(StrandsDACAPV2(address(token)).version(), 2, "the new owner's upgrade reaches the token");
        assertEq(token.balanceOf(alice), INITIAL_MINT, "at the same address, with its balances");
    }

    /// @dev Ownership is the only thing that moves. The code every token runs, and every token's roles and
    ///      balances, are exactly what they were.
    function test_HandOver_ChangesNothingButTheOwner() public {
        script.handOver(beacon, derive, keyedOwnerKey);

        assertEq(beacon.implementation(), address(implementation), "the code is unchanged");
        assertTrue(token.hasRole(DEFAULT_ADMIN_ROLE, admin), "token roles are unchanged");
        assertTrue(token.hasRole(MINTER_ROLE, minter));
        assertFalse(token.hasRole(DEFAULT_ADMIN_ROLE, derive), "the beacon carries no token role");
        assertEq(token.totalSupply(), INITIAL_MINT, "and no supply moved");
    }

    function test_HandOver_RefusesAKeyThatIsNotTheOwner() public {
        (, uint256 strangerKey) = makeAddrAndKey("stranger");

        vm.expectRevert(bytes("BEACON_OWNER_PRIVATE_KEY is not the beacon's owner"));
        script.handOver(beacon, derive, strangerKey);

        assertEq(beacon.owner(), keyedOwner);
    }

    /// @dev Ownable would reject a zero owner too, but only after a send. Refusing first keeps a missing
    ///      environment variable from costing a transaction.
    function test_HandOver_RefusesTheZeroAddress() public {
        vm.expectRevert(bytes("NEW_BEACON_OWNER is zero"));
        script.handOver(beacon, address(0), keyedOwnerKey);

        assertEq(beacon.owner(), keyedOwner);
    }

    /// @dev Ownable would accept this as a no-op that still emits OwnershipTransferred, which reads like a
    ///      handover that never happened.
    function test_HandOver_RefusesTheCurrentOwner() public {
        vm.expectRevert(bytes("NEW_BEACON_OWNER already owns the beacon"));
        script.handOver(beacon, keyedOwner, keyedOwnerKey);

        assertEq(beacon.owner(), keyedOwner);
    }
}
