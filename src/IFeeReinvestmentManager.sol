// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolPolicy} from "./IPoolPolicy.sol";

/**
 * @title IFeeReinvestmentManager
 * @notice Interface for the Fee Reinvestment Manager component
 */
interface IFeeReinvestmentManager {
    /**
     * @notice Emitted when fees are reinvested
     * @param poolId The pool ID
     * @param fee0 Amount of token0 fees
     * @param fee1 Amount of token1 fees
     * @param investable0 Amount of token0 reinvested
     * @param investable1 Amount of token1 reinvested
     */
    event FeesReinvested(PoolId indexed poolId, uint256 fee0, uint256 fee1, uint256 investable0, uint256 investable1);
    
    /**
     * @notice Checks if a pool has pending fees above a threshold
     * @param poolId The pool ID
     * @param minFeeThreshold Minimum threshold to consider meaningful
     * @return hasMeaningfulFees True if there are meaningful pending fees
     */
    function hasPendingFees(PoolId poolId, uint256 minFeeThreshold) external view returns (bool hasMeaningfulFees);
    
    /**
     * @notice Checks if reinvestment should be performed based on the current mode and conditions
     * @param poolId The pool ID
     * @param swapValue Used for threshold calculations
     * @return shouldPerformReinvestment Whether reinvestment should be performed
     */
    function shouldReinvest(PoolId poolId, uint256 swapValue) external view returns (bool shouldPerformReinvestment);
    
    /**
     * @notice Processes reinvestment if needed based on current reinvestment mode
     * @param poolId The pool ID
     * @param swapValue Used for threshold calculations
     * @return reinvested Whether fees were successfully reinvested
     */
    function processReinvestmentIfNeeded(PoolId poolId, uint256 swapValue) external returns (bool reinvested);
    
    /**
     * @notice Reinvests accumulated fees for a specific pool
     * @param poolId The pool ID to reinvest fees for
     * @return amount0 The amount of token0 fees reinvested
     * @return amount1 The amount of token1 fees reinvested
     */
    function reinvestFees(PoolId poolId) external returns (uint256 amount0, uint256 amount1);
    
    /**
     * @notice Get the amount of pending fees for token0 for a pool
     * @param poolId The pool ID
     * @return The amount of pending token0 fees
     */
    function pendingFees0(PoolId poolId) external view returns (uint256);
    
    /**
     * @notice Get the amount of pending fees for token1 for a pool
     * @param poolId The pool ID
     * @return The amount of pending token1 fees
     */
    function pendingFees1(PoolId poolId) external view returns (uint256);
}
