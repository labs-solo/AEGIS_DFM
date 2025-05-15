// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

// TODO: make interface complete

/**
 * @title ISpot
 * @notice Minimal interface for the Spot hook contract
 * @dev Contains only essential functions for the core hook functionality
 */
interface ISpot is IHooks {
    /**
     * @notice Emitted when an oracle is initialized for a pool
     * @param poolId The ID of the pool
     * @param initialTick The initial tick when the oracle was initialized
     * @param maxAbsTickMove The maximum absolute tick movement allowed
     */
    event OracleInitialized(PoolId indexed poolId, int24 initialTick, int24 maxAbsTickMove);

    /**
     * @notice Emitted when oracle initialization fails
     * @param poolId The ID of the pool
     * @param reason The reason for the failure
     */
    event OracleInitializationFailed(PoolId indexed poolId, bytes reason);

    /**
     * @notice Emitted when policy initialization fails
     * @param poolId The ID of the pool
     * @param reason The reason for the failure
     */
    event PolicyInitializationFailed(PoolId indexed poolId, string reason);

    /**
     * @notice Emitted when a fee is collected by the hook when reinvestment is NOT paused
     * @param id The pool ID
     * @param sender The address that triggered the fee collection
     * @param feeAmount0 The amount of token0 collected as fee
     * @param feeAmount1 The amount of token1 collected as fee
     */
    event HookFee(PoolId indexed id, address indexed sender, uint128 feeAmount0, uint128 feeAmount1);

    event HookFeeReinvested(PoolId indexed id, address indexed sender, uint128 feeAmount0, uint128 feeAmount1);

    event ReinvestmentPausedChanged(bool paused);

    /**
     * @notice Pauses or unpauses reinvestment of hook fees
     * @dev Can only be called by the policy manager owner
     * @param paused True to pause reinvestment, false to enable it
     */
    function setReinvestmentPaused(bool paused) external;
}
