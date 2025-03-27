// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FullRange} from "../../src/FullRange.sol";

/**
 * @title PoolCreationHelper
 * @notice Helper functions for creating pools in tests using hook callbacks
 */
library PoolCreationHelper {
    /**
     * @notice Creates a new pool using the FullRange hook via Uniswap's PoolManager
     * @param manager The Uniswap V4 PoolManager
     * @param fullRangeHook The FullRange hook contract
     * @param token0 The address of token0
     * @param token1 The address of token1
     * @param tickSpacing The tick spacing for the pool
     * @param sqrtPriceX96 The initial sqrt price
     * @return poolId The ID of the created pool
     */
    function createPoolWithHook(
        IPoolManager manager,
        FullRange fullRangeHook,
        address token0,
        address token1,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) internal returns (PoolId) {
        // Use dynamic fee (0x800000)
        uint24 fee = 0x800000;
        
        // Create pool key with hook address
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(fullRangeHook))
        });
        
        // Initialize pool via PoolManager (will trigger hook callbacks)
        manager.initialize(key, sqrtPriceX96);
        
        // Return the pool ID
        return PoolIdLibrary.toId(key);
    }
    
    /**
     * @notice Checks if pool parameters are valid before attempting to create a pool
     * @param fullRangeHook The FullRange hook contract
     * @param sender The address attempting to create the pool
     * @param token0 The address of token0
     * @param token1 The address of token1
     * @param tickSpacing The tick spacing for the pool
     * @return isValid Whether the parameters are valid
     * @return errorMessage A human-readable error message if invalid
     */
    function validatePoolCreation(
        FullRange fullRangeHook,
        address sender,
        address token0,
        address token1,
        int24 tickSpacing
    ) internal view returns (bool isValid, string memory errorMessage) {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0x800000, // Dynamic fee
            tickSpacing: tickSpacing,
            hooks: IHooks(address(fullRangeHook))
        });
        
        return fullRangeHook.validatePoolParameters(sender, key);
    }
} 