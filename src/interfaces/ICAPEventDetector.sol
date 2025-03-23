// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/**
 * @title ICAPEventDetector
 * @notice Interface for detecting CAP events in price movement
 * 
 * A CAP event is an extreme price volatility event that may require
 * fee adjustments to protect liquidity providers.
 */
interface ICAPEventDetector {
    /**
     * @notice Detects if a CAP event has occurred for a given pool
     * @param poolId The ID of the pool to check
     * @return Whether a CAP event has been detected
     */
    function detectCAPEvent(PoolId poolId) external view returns (bool);
} 