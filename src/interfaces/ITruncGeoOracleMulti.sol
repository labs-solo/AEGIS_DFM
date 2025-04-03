// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/**
 * @title ITruncGeoOracleMulti
 * @notice Interface for the TruncGeoOracleMulti contract that provides truncated geomean oracle data
 * for multiple pools with tick capping functionality
 */
interface ITruncGeoOracleMulti {
    /**
     * @notice Enables oracle functionality for a pool.
     * @param key The pool key.
     * @param initialMaxAbsTickMove The initial maximum tick movement.
     * @dev Must be called once per pool. Enforces full-range requirements.
     */
    function enableOracleForPool(PoolKey calldata key, int24 initialMaxAbsTickMove) external;

    /**
     * @notice Updates oracle observations for a pool.
     * @param key The pool key.
     * @dev Called by the hook (Spot.sol) during its callbacks.
     */
    function updateObservation(PoolKey calldata key) external;

    /**
     * @notice Checks if an oracle update is needed based on time thresholds
     * @param poolId The unique identifier for the pool
     * @return shouldUpdate Whether the oracle should be updated
     */
    function shouldUpdateOracle(PoolId poolId) external view returns (bool shouldUpdate);

    /**
     * @notice Gets the most recent observation for a pool
     * @param poolId The ID of the pool
     * @return timestamp The timestamp of the observation
     * @return tick The tick value at the observation
     * @return tickCumulative The cumulative tick value
     * @return secondsPerLiquidityCumulativeX128 The cumulative seconds per liquidity value
     */
    function getLastObservation(PoolId poolId) external view returns (
        uint32 timestamp,
        int24 tick,
        int48 tickCumulative,
        uint144 secondsPerLiquidityCumulativeX128
    );

    /**
     * @notice Updates the maximum tick movement for a pool.
     * @param poolId The pool identifier.
     * @param newMove The new maximum tick movement.
     */
    function updateMaxAbsTickMoveForPool(bytes32 poolId, int24 newMove) external;

    /**
     * @notice Observes oracle data for a pool.
     * @param key The pool key.
     * @param secondsAgos Array of time offsets.
     * @return tickCumulatives The tick cumulative values.
     * @return secondsPerLiquidityCumulativeX128s The seconds per liquidity cumulative values.
     */
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external view returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s);

    /**
     * @notice Increases the cardinality of the oracle observation array
     * @param key The pool key.
     * @param cardinalityNext The new cardinality to grow to.
     * @return cardinalityNextOld The previous cardinality.
     * @return cardinalityNextNew The new cardinality.
     */
    function increaseCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew);
} 