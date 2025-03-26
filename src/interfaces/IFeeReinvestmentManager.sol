// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolPolicy} from "./IPoolPolicy.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/**
 * @title IFeeReinvestmentManager
 * @notice Interface for the optimized Fee Reinvestment Manager component
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
     * @notice Emitted when fees are extracted
     * @param poolId The pool ID
     * @param fee0 Amount of token0 fees
     * @param fee1 Amount of token1 fees
     * @param caller Address that triggered the extraction
     */
    event FeesExtracted(PoolId indexed poolId, uint256 fee0, uint256 fee1, address indexed caller);
    
    /**
     * @notice Emitted when fees are queued for processing
     * @param poolId The pool ID
     * @param fee0 Amount of token0 fees
     * @param fee1 Amount of token1 fees
     */
    event FeesQueuedForProcessing(PoolId indexed poolId, uint256 fee0, uint256 fee1);
    
    /**
     * @notice Operation types for different reinvestment contexts
     */
    enum OperationType { 
        SWAP, 
        DEPOSIT, 
        WITHDRAWAL 
    }
    
    /**
     * @notice Comprehensive fee extraction handler for FullRange.sol
     * @dev This function handles all fee extraction logic to keep FullRange.sol lean
     * 
     * @param poolId The pool ID
     * @param key The pool key
     * @param feesAccrued The total fees accrued during the operation
     * @return extractDelta The balance delta representing fees to extract
     */
    function handleFeeExtraction(
        PoolId poolId,
        PoolKey calldata key,
        BalanceDelta feesAccrued
    ) external returns (BalanceDelta extractDelta);
    
    /**
     * @notice Permissionless function to process queued fees
     * @param poolId The pool ID
     * @return reinvested Whether fees were successfully reinvested
     */
    function processQueuedFees(PoolId poolId) external returns (bool reinvested);
    
    /**
     * @notice Permissionless function to collect and process accumulated fees
     * @param poolId The pool ID to collect fees for
     * @return extracted Whether fees were successfully extracted and processed
     */
    function collectAccumulatedFees(PoolId poolId) external returns (bool extracted);
    
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
     * @param value Value used for threshold calculations
     * @return reinvested Whether fees were successfully reinvested
     * @return autoCompounded Whether auto-compounding was performed
     */
    function processReinvestmentIfNeeded(
        PoolId poolId,
        uint256 value
    ) external returns (bool reinvested, bool autoCompounded);
    
    /**
     * @notice Processes reinvestment if needed based on operation type
     * @param poolId The pool ID
     * @param opType The operation type (SWAP, DEPOSIT, WITHDRAWAL)
     * @return reinvested Whether fees were successfully reinvested
     * @return autoCompounded Whether auto-compounding was performed
     */
    function processReinvestmentIfNeeded(
        PoolId poolId,
        OperationType opType
    ) external returns (bool reinvested, bool autoCompounded);
    
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
    
    /**
     * @notice Get the cumulative fee multiplier for a pool
     * @param poolId The pool ID
     * @return The cumulative fee multiplier
     */
    function cumulativeFeeMultiplier(PoolId poolId) external view returns (uint256);
    
    /**
     * @notice Get the POL share percentage for a specific pool
     * @param poolId The pool ID to get the POL share for
     * @return The POL share in PPM (parts per million)
     */
    function getPolSharePpm(PoolId poolId) external view returns (uint256);

    /**
     * @notice Get information about leftover tokens from previous reinvestments
     * @param poolId The pool ID
     * @return leftover0 Leftover token0 amount
     * @return leftover1 Leftover token1 amount
     */
    function getLeftoverTokens(PoolId poolId) external view returns (uint256 leftover0, uint256 leftover1);
} 