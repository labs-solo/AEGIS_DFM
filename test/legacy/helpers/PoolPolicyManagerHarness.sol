// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {PoolPolicyManager} from "src/PoolPolicyManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @dev Harness: wrapper around the real contract, exposing unrestricted setters.
contract PoolPolicyManagerHarness {
    PoolPolicyManager public immutable target;

    constructor(PoolPolicyManager _target) {
        target = _target;
    }

    function setDailyBudgetPpm(uint32 ppm) external {
        target.setDailyBudgetPpm(ppm);
    }

    function setDecayWindow(uint32 secs) external {
        target.setDecayWindow(secs);
    }

    function getDailyBudgetPpm(PoolId pid) external view returns (uint32) {
        return target.getDailyBudgetPpm(pid);
    }

    function getCapBudgetDecayWindow(PoolId pid) external view returns (uint32) {
        return target.getCapBudgetDecayWindow(pid);
    }
}
