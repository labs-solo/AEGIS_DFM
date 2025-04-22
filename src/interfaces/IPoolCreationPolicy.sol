// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/**
 * @title IPoolCreationPolicy
 * @notice Interface for policy that controls who can create pools and with what parameters
 */
interface IPoolCreationPolicy {
    /**
     * @notice Determines if the sender is allowed to create a pool with the given key
     * @param sender The address attempting to create the pool
     * @param key The pool key for the pool being created
     * @return Boolean indicating if pool creation is allowed
     */
    function canCreatePool(address sender, PoolKey calldata key) external view returns (bool);
}
