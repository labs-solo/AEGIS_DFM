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
        NONE,
        SWAP, 
        DEPOSIT, 
        WITHDRAWAL 
    }
    
    /**
     * @notice Comprehensive fee extraction handler for Spot.sol
     * @dev This function handles all fee extraction logic to keep Spot.sol lean
     * 
     * @param poolId The pool ID
     * @param feesAccrued The total fees accrued during the operation
     * @return extractDelta The balance delta representing fees to extract
     */
    function handleFeeExtraction(
        PoolId poolId,
        BalanceDelta feesAccrued
    ) external returns (BalanceDelta extractDelta);
    
    /**
     * @notice Permissionless function to process queued fees
     * @param poolId The pool ID
     * @return reinvested Whether fees were successfully reinvested
     */
    function processQueuedFees(PoolId poolId) external returns (bool reinvested);
    
    /**
     * @notice Checks if reinvestment should be performed based on the current mode and conditions
     * @param poolId The pool ID
     * @return shouldPerformReinvestment Whether reinvestment should be performed
     */
    function shouldReinvest(PoolId poolId) external view returns (bool shouldPerformReinvestment);
    
    /**
     * @notice Unified function to collect fees, reset leftovers, and return amounts
     * @dev This replaces collectAccumulatedFees, processReinvestmentIfNeeded, and reinvestFees
     * 
     * @param poolId The pool ID to collect fees for
     * @param opType The operation type (for event emission)
     * @return success Whether collection was successful
     * @return amount0 Amount of token0 collected and reset from leftovers
     * @return amount1 Amount of token1 collected and reset from leftovers
     */
    function collectFees(
        PoolId poolId,
        OperationType opType
    ) external returns (
        bool success,
        uint256 amount0,
        uint256 amount1
    );
    
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

    /**
     * @notice Triggers the processing and reinvestment of accrued protocol interest fees.
     * @param poolId The pool ID for which to process interest fees.
     * @return success Boolean indicating if processing was successful (or if there were fees to process).
     */
    function triggerInterestFeeProcessing(PoolId poolId) external returns (bool success);
} 