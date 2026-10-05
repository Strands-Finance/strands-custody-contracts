// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StrandsDACAP } from "../../src/StrandsDACAP.sol";
import { BaseTest } from "../Base.t.sol";

/// @notice Where a token's state lives in its proxy's storage. The layout is fixed by the first production deploy: from
///         then on every proxy holds state at these slots, and a later implementation behind the beacon reads them
///         where this one wrote them. Reordering, retyping or removing a field silently reinterprets every token's
///         storage, and neither `forge build` nor the beacon's `upgradeTo` checks anything.
///
///         A LATER IMPLEMENTATION MUST KEEP EVERY TEST HERE PASSING. It may only APPEND fields to `DACAPStorage`.
///
/// @dev    Read with `vm.load` on the proxy, so what is pinned is the storage itself, not the getters over it. The
///         namespace roots are recomputed from their ERC-7201 ids rather than copied, and the token's own root is also
///         compared with the literal in `src/StrandsDACAP.sol`, so a typo in either is caught.
contract StorageLayoutTest is BaseTest {
    /// @dev `DACAP_STORAGE_LOCATION` in `src/StrandsDACAP.sol`. Private there, so restated here.
    bytes32 internal constant DACAP_STORAGE_LOCATION =
        0x94b7310252f3826cce10f0dba840c935d992f0d817174335cd814aafabd92d00;

    /// @dev How many low slots must stay empty. Generous: a sequential variable anywhere in the inheritance chain lands
    ///      in the first few.
    uint256 internal constant SEQUENTIAL_SLOTS_CHECKED = 64;

    /// @dev `keccak256(abi.encode(uint256(keccak256(id)) - 1)) & ~bytes32(uint256(0xff))`, the ERC-7201 formula.
    function _erc7201(string memory id) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(id))) - 1)) & ~bytes32(uint256(0xff));
    }

    function _mappingSlot(address key, bytes32 root) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, root));
    }

    function _load(StrandsDACAP t, bytes32 slot) internal view returns (uint256) {
        return uint256(vm.load(address(t), slot));
    }

    // ---------- the token's own namespace ----------

    /// @dev The root is the ERC-7201 slot of `strands.storage.StrandsDACAP`, and its first field is `decimals`, alone in
    ///      the slot.
    function test_DACAPStorage_IsAtItsERC7201Root_WithDecimalsFirst() public {
        assertEq(_erc7201("strands.storage.StrandsDACAP"), DACAP_STORAGE_LOCATION, "the root is the ERC-7201 slot");

        StrandsDACAP usdc = _deploy(6, "Strands.DACAP.BitGo.USDC", "Strands.DACAP.BitGo.USDC");
        assertEq(_load(usdc, DACAP_STORAGE_LOCATION), 6, "decimals, and nothing else, at the root");
        assertEq(_load(token, DACAP_STORAGE_LOCATION), 18);
    }

    /// @dev The second field is the allowlist: `allowedDestination[d]` at `keccak256(d, root + 1)`.
    function test_DACAPStorage_AllowedDestinationIsTheSecondField() public {
        bytes32 bobSlot = _mappingSlot(bob, bytes32(uint256(DACAP_STORAGE_LOCATION) + 1));
        assertEq(_load(token, bobSlot), 0, "closed");

        _allow(bob);
        assertEq(_load(token, bobSlot), 1, "open");

        _disallow(bob);
        assertEq(_load(token, bobSlot), 0, "closed again");
        assertEq(_load(token, bytes32(uint256(DACAP_STORAGE_LOCATION) + 1)), 0, "a mapping's own slot holds nothing");
    }

    // ---------- OpenZeppelin's namespaces ----------

    /// @dev Balances, supply, roles and the initializer version sit in OpenZeppelin's own ERC-7201 namespaces, which
    ///      the token inherits and does not control. Pinned so that changing an OpenZeppelin base, or the pinned
    ///      submodule, cannot move them unnoticed.
    function test_InheritedState_IsInOpenZeppelinsNamespaces() public view {
        bytes32 erc20 = _erc7201("openzeppelin.storage.ERC20");
        assertEq(_load(token, _mappingSlot(alice, erc20)), INITIAL_MINT, "ERC20Storage._balances is field 0");
        assertEq(_load(token, bytes32(uint256(erc20) + 2)), INITIAL_MINT, "ERC20Storage._totalSupply is field 2");

        bytes32 roles = _erc7201("openzeppelin.storage.AccessControl");
        assertEq(_load(token, _mappingSlot(admin, keccak256(abi.encode(DEFAULT_ADMIN_ROLE, roles)))), 1, "admin seat");
        assertEq(_load(token, _mappingSlot(minter, keccak256(abi.encode(MINTER_ROLE, roles)))), 1, "minter seat");

        assertEq(_load(token, _erc7201("openzeppelin.storage.Initializable")), 1, "initializer version 1");
    }

    // ---------- nothing outside a namespace ----------

    /// @dev Every piece of state is namespaced, so the sequential slots from 0 up stay empty however the token is
    ///      used. A sequential variable is where an inheritance change would shift storage under a deployed token.
    function test_NoSequentialStorage_AfterAFullLifecycle() public {
        _allow(bob);
        vm.prank(alice);
        token.transfer(bob, 10);
        vm.prank(alice);
        token.approve(carol, 5);

        vm.startPrank(minter);
        token.guardMint(carol, 7, INITIAL_MINT);
        token.adminBurn(bob, 4);
        token.guardBurn(carol, 3, INITIAL_MINT + 3);
        vm.stopPrank();

        vm.startPrank(admin);
        token.grantRole(MINTER_ROLE, carol);
        token.revokeRole(MINTER_ROLE, carol);
        vm.stopPrank();

        for (uint256 slot = 0; slot < SEQUENTIAL_SLOTS_CHECKED; slot++) {
            assertEq(_load(token, bytes32(slot)), 0, string.concat("sequential slot ", vm.toString(slot), " written"));
        }
    }
}
