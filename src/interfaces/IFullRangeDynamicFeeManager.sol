// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/**
 * @title IFullRangeDynamicFeeManager
 * @notice Interface for the Dynamic Fee Manager component with integrated oracle functionality
 */
interface IFullRangeDynamicFeeManager {
    /**
     * @notice Emitted when dynamic fee is updated (base fee or significant event)
     * @param poolId The pool ID
     * @param oldFeePpm Previous base fee (in PPM)
     * @param newFeePpm New base fee (in PPM)
     * @param capEventOccurred Whether a CAP event occurred during this update cycle
     */
    event DynamicFeeUpdated(PoolId indexed poolId, uint256 oldFeePpm, uint256 newFeePpm, bool capEventOccurred);

    /**
     * @notice Emitted when surge fee state changes (starts, ends, or value updates)
     * @param poolId The pool ID
     * @param surgeFee New surge fee (in PPM) - can be full initial surge or decayed value
     * @param capEventOccurred True if the surge started/reset due to a new cap event, false if surge is ending/decaying
     */
    event SurgeFeeUpdated(PoolId indexed poolId, uint256 surgeFee, bool capEventOccurred);

    /**
     * @notice Emitted when recorded oracle data is updated for a pool
     * @param poolId The pool ID
     * @param oldTick The previously recorded tick
     * @param newTick The newly recorded tick (potentially capped)
     * @param tickCapped Whether the tick change was capped in this update
     */
    event OracleUpdated(PoolId indexed poolId, int24 oldTick, int24 newTick, bool tickCapped);

    /**
     * @notice Initialize fee data for a newly created pool
     * @param poolId The ID of the pool
     */
    function initializeFeeData(PoolId poolId) external;

    /**
     * @notice Initialize oracle data for a newly created pool
     * @param poolId The ID of the pool
     * @param initialTick The initial tick of the pool
     */
    function initializeOracleData(PoolId poolId, int24 initialTick) external;

    /**
     * @notice Updates the dynamic fee if needed based on time interval and CAP events
     * @param poolId The pool ID to update fee for
     * @param key The pool key for the pool
     * @return newBase The current base fee in PPM
     * @return newSurge The current surge fee in PPM
     * @return didUpdate Whether the base fee calculation logic ran in this call
     */
    function updateDynamicFeeIfNeeded(PoolId poolId, PoolKey calldata key)
        external
        returns (uint256 newBase, uint256 newSurge, bool didUpdate);

    /**
     * @notice External function to trigger fee updates with rate limiting
     * @param poolId The pool ID to update fees for
     * @param key The pool key for the pool
     */
    function triggerFeeUpdate(PoolId poolId, PoolKey calldata key) external;

    /**
     * @notice Handle fee update and related event emissions
     * @param poolId The pool ID to update fee for
     */
    function handleFeeUpdate(PoolId poolId) external;

    /**
     * @notice Gets current fee values for a pool
     * @param poolId The pool ID to query
     * @return baseFee The current base fee in PPM
     * @return surgeFeeValue The current surge fee in PPM
     */
    function getCurrentFees(PoolId poolId) external view returns (uint256 baseFee, uint256 surgeFeeValue);

    /**
     * @notice Update oracle data (not supported in reverse‐auth model)
     * @param poolId The pool ID to update
     * @param tick The current tick value
     */
    function updateOracle(PoolId poolId, int24 tick) external;

    /**
     * @notice Check if a CAP event is active for the pool
     * @param poolId The pool ID to query
     * @return True if a CAP event is active, false otherwise
     */
    function isCAPEventActive(PoolId poolId) external view returns (bool);

    /**
     * @notice Get the current dynamic fee for a pool (base + surge)
     * @param poolId The pool ID to query
     * @return The total dynamic fee in PPM
     */
    function getCurrentDynamicFee(PoolId poolId) external view returns (uint256);
}
