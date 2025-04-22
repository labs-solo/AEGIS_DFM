// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolCreationPolicy} from "./interfaces/IPoolCreationPolicy.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Errors} from "./errors/Errors.sol";

/**
 * @title DefaultPoolCreationPolicy
 * @notice Default implementation of IPoolCreationPolicy that allows only governance to create pools
 */
contract DefaultPoolCreationPolicy is IPoolCreationPolicy, Owned {
    /// @dev mapping of addresses allowed to create pools
    mapping(address => bool) public isPoolCreator;

    /**
     * @notice Constructor sets contract owner
     * @param _owner The initial owner with full admin rights
     */
    constructor(address _owner) Owned(_owner) {
        // Set owner as a default pool creator
        isPoolCreator[_owner] = true;
    }

    /**
     * @notice Add an address to the pool creator whitelist
     * @param creator The address to authorize
     */
    function addPoolCreator(address creator) external onlyOwner {
        isPoolCreator[creator] = true;
    }

    /**
     * @notice Remove an address from the pool creator whitelist
     * @param creator The address to remove
     */
    function removePoolCreator(address creator) external onlyOwner {
        isPoolCreator[creator] = false;
    }

    /**
     * @notice Checks if an address is allowed to create a pool
     * @param sender The address attempting to create the pool
     * @return True if sender is authorized, false otherwise
     */
    function canCreatePool(address sender, PoolKey calldata) external pure override returns (bool) {
        sender; // silence unused-param warning
        return true; // unrestricted
    }
}
