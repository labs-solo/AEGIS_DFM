// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolPolicy} from "src/interfaces/IPoolPolicy.sol";
import {Errors} from "src/errors/Errors.sol";

library EventTools {
    // Get the cheatcode address from forge-std
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // Maximum PPM value (100%)
    uint256 public constant MAX_PPM = 1_000_000;

    event PolicySet(
        PoolId indexed poolId, IPoolPolicy.PolicyType indexed policyType, address implementation, address indexed setter
    );

    /**
     * @notice Expect a PolicySet event unconditionally
     * @param pid The pool ID
     * @param ptype The policy type
     * @param impl The implementation address
     * @param setter The address setting the policy
     */
    function expectPolicySet(
        Test /* t */,
        PoolId pid,
        IPoolPolicy.PolicyType ptype,
        address impl,
        address setter
    ) internal {
        vm.expectEmit(true, true, true, true);
        emit PolicySet(pid, ptype, impl, setter);
    }

    /**
     * @notice Conditionally expect a PolicySet event based on a condition
     * @param willEmit Whether the event should be expected
     * @param pid The pool ID
     * @param ptype The policy type
     * @param impl The implementation address
     * @param setter The address setting the policy
     */
    function expectPolicySetIf(
        Test /* t */,
        bool willEmit,
        PoolId pid,
        IPoolPolicy.PolicyType ptype,
        address impl,
        address setter
    ) internal {
        if (willEmit) {
            vm.expectEmit(true, true, true, true);
            emit PolicySet(pid, ptype, impl, setter);
        }
    }

    /**
     * @notice Conditionally expect any event based on a condition
     * @param willEmit Whether the event should be expected
     * @param checkTopic1 Whether to check the first topic
     * @param checkTopic2 Whether to check the second topic
     * @param checkTopic3 Whether to check the third topic
     * @param checkData Whether to check the data
     */
    function expectEmitIf(
        Test /* t */,
        bool willEmit,
        bool checkTopic1,
        bool checkTopic2,
        bool checkTopic3,
        bool checkData
    ) internal {
        if (willEmit) {
            vm.expectEmit(checkTopic1, checkTopic2, checkTopic3, checkData);
        }
    }

    function expectReinvestorDenied(address /* who */) internal {
        vm.expectRevert(abi.encodeWithSelector(Errors.Unauthorized.selector));
    }
}
