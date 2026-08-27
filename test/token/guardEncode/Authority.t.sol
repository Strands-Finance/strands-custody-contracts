// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { GuardEncodeBase } from "./GuardEncodeBase.t.sol";

/// @notice Who may call `guardEncode`: OPERATOR_ROLE and nobody else, checked per call.
/// @dev    The guard is a correctness check on a caller who is already trusted to issue supply — it is not an
///         authorization mechanism, and must never be mistaken for one. So the gate in front of it is stated
///         here in full rather than as the single negative case it used to be.
///
///         `admin` is the sharp principal. It holds DEFAULT_ADMIN_ROLE, which ADMINISTERS OPERATOR_ROLE but does
///         not confer it — an admin who could mint would make "the operator key is separate" untrue without any
///         grant appearing on chain. That separation is what `Roles.t.sol` establishes for the role graph and
///         this pins for this entrypoint.
///
///         `Roles.t.sol` owns the role graph itself (who may grant, role admins, event emission). This file
///         only asks what each standing means at `guardEncode`'s door.
contract GuardEncodeAuthorityTest is GuardEncodeBase {
    function test_NonOperator_CannotGuardEncode() public {
        vm.prank(alice);
        _expectNotOperator(alice);
        token.guardEncode(bob, 1, INITIAL_MINT);
    }

    /// @dev Every unprivileged principal in the fixture, each with a CORRECT estimate so the only possible
    ///      reason for refusal is the role. A holder, the recipient, a bystander and the admin are all equally
    ///      outside.
    function test_EveryPrincipalWithoutOperatorRole_IsRefused() public {
        address[4] memory outsiders = [alice, bob, carol, admin];

        for (uint256 i = 0; i < outsiders.length; i++) {
            assertFalse(token.hasRole(OPERATOR_ROLE, outsiders[i]), "precondition: this principal is not a operator");

            vm.prank(outsiders[i]);
            _expectNotOperator(outsiders[i]);
            token.guardEncode(bob, 50 ether, INITIAL_MINT);
        }

        assertEq(token.totalSupply(), INITIAL_MINT, "no refused call may issue supply");
        assertEq(token.balanceOf(bob), 0, "nor credit the recipient it named");
    }

    /// @dev The general form: no address is special. `operator` is excluded as the one address for which the call
    ///      legitimately succeeds. A correct estimate is passed for the same reason as above — the guard must
    ///      not be what stops these callers.
    function testFuzz_ArbitraryCaller_CannotGuardEncode(address caller) public {
        vm.assume(caller != operator);

        vm.prank(caller);
        _expectNotOperator(caller);
        token.guardEncode(bob, 50 ether, INITIAL_MINT);

        assertEq(token.totalSupply(), INITIAL_MINT, "an unauthorized call must not change supply");
    }

    /// @dev The gate runs BEFORE the guard, and the ordering is observable. An unauthorized caller passing a
    ///      wrong estimate is told they are unauthorized — not that their estimate was wrong — so the revert
    ///      data leaks no supply reading to someone with no standing to ask. `SupplyMismatch` carries the
    ///      chain's actual supply; it must be reachable only by a caller already entitled to that answer.
    function test_TheRoleGateRunsBeforeTheGuard() public {
        // The control: holding the role, a wrong estimate is diagnosed as a wrong estimate.
        vm.prank(operator);
        _expectSupplyMismatch(INITIAL_MINT, 1);
        token.guardEncode(bob, 50 ether, 1);

        // The same wrong estimate from an outsider never reaches the comparison.
        vm.prank(alice);
        _expectNotOperator(alice);
        token.guardEncode(bob, 50 ether, 1);
    }

    /// @dev Authorization is read per call, not cached at deploy: a grant is effective in the very next call.
    ///      Mirrors `Roles.t.sol`'s `test_NewlyGrantedOperator_CanMintImmediately` for the guarded entrypoint,
    ///      and doubles as the positive control that OPERATOR_ROLE — not the `operator` address the fixture happens
    ///      to use — is what the gate actually tests.
    function test_NewlyGrantedOperator_CanGuardEncodeImmediately() public {
        vm.prank(carol);
        _expectNotOperator(carol);
        token.guardEncode(carol, 1 ether, INITIAL_MINT);

        vm.prank(admin);
        token.grantRole(OPERATOR_ROLE, carol);

        vm.prank(carol);
        token.guardEncode(carol, 1 ether, INITIAL_MINT);
        assertEq(token.balanceOf(carol), 1 ether, "a grant is effective in the very next call");
    }

    /// @dev And the reverse, which is the one that matters during an incident: revoking a compromised operator
    ///      closes the guarded entrypoint immediately, with no in-flight estimate still honoured.
    function test_RevokedOperator_LosesGuardEncodeImmediately() public {
        vm.prank(admin);
        token.revokeRole(OPERATOR_ROLE, operator);

        vm.prank(operator);
        _expectNotOperator(operator);
        token.guardEncode(bob, 1 ether, INITIAL_MINT);

        assertEq(token.totalSupply(), INITIAL_MINT, "a revoked operator cannot issue, correct estimate or not");
    }

    /// @dev The self-service path. `renounceRole` is the one AccessControl write that needs no admin, so a
    ///      operator can stand itself down — and must then be as outside as anyone else.
    function test_RenouncedOperator_LosesGuardEncodeImmediately() public {
        vm.prank(operator);
        token.renounceRole(OPERATOR_ROLE, operator);
        assertFalse(token.hasRole(OPERATOR_ROLE, operator));

        vm.prank(operator);
        _expectNotOperator(operator);
        token.guardEncode(bob, 1 ether, INITIAL_MINT);

        assertEq(token.totalSupply(), INITIAL_MINT);
    }
}
