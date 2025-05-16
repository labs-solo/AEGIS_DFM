// SPDX-License-Identifier: MIT
// minimal subset used by tests
pragma solidity >=0.5.0;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/**
 * @title ITruncGeoOracleMulti
 * @notice Interface for the TruncGeoOracleMulti contract that provides truncated geomean oracle data
 * for multiple pools with tick capping functionality
 */
interface ITruncGeoOracleMulti {
    /**
     * @notice Enable the oracle for a pool
     * @param key The pool key
     */
    function enableOracleForPool(bytes calldata key) external;

    /**
     * @notice Updates oracle observations for a pool.
     * @param key The pool key.
     * @dev Called by the hook (Spot.sol) during its callbacks.
     */
    function updateObservation(bytes calldata key) external;

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
    function getLastObservation(PoolId poolId)
        external
        view
        returns (uint32 timestamp, int24 tick, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128);

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
    /// @notice Returns cumulative tick and seconds-per-liquidity for each `secondsAgo`.
    /// @dev Typed to mirror Uniswap V3 so off-the-shelf TWAP helpers "just work".
    function observe(bytes calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    /**
     * @notice Increases the cardinality of the oracle observation array
     * @param key The pool key.
     * @param cardinalityNext The new cardinality to grow to.
     * @return cardinalityNextOld The previous cardinality.
     * @return cardinalityNextNew The new cardinality.
     */
    function increaseCardinalityNext(bytes calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew);

    /// ------------------------------------------------------------------
    ///  Immutable hook address accessor
    /// ------------------------------------------------------------------
    /**
     * @notice Returns the address of the hook that is authorized to use this oracle
     * @return The hook address
     */
    function getHookAddress() external view returns (address);

    /**
     * @notice Query the latest observation for a given pool.
     */
    function getLatestObservation(PoolId poolId) external view returns (int24 tick, uint32 timestamp);

    /// @return true if a pool has been enabled and at least one observation exists
    function isOracleEnabled(PoolId pid) external view returns (bool);

    /**
     * @notice Returns the current maximum ticks per block allowed for a pool.
     * @param poolId The ID of the pool.
     * @return The maximum ticks per block.
     */
    function getMaxTicksPerBlock(bytes32 poolId) external view returns (uint24);

    // NB: we intentionally **do not** expose the whole `states` mapping
    // to keep storage layout private – tests should rely on the helper.

    /* ------------------------------------------------------- */
    /*  Ring buffer logic                                      */
}
