// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ICAPEventDetector} from "./ICAPEventDetector.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/**
 * @title IFullRangeDynamicFeeManager
 * @notice Interface for the Dynamic Fee Manager component with integrated oracle functionality
 */
interface IFullRangeDynamicFeeManager {
    /**
     * @notice Emitted when dynamic fee is updated
     * @param pid The pool ID hash
     * @param oldFeePpm Previous fee (in PPM)
     * @param newFeePpm New fee (in PPM)
     * @param capEventOccurred Whether a CAP event occurred
     */
    event DynamicFeeUpdated(bytes32 indexed pid, uint256 oldFeePpm, uint256 newFeePpm, bool capEventOccurred);
    
    /**
     * @notice Emitted when a pool's surge mode changes
     * @param pid The pool ID hash
     * @param surgeEnabled Whether surge mode is enabled
     */
    event SurgeModeChanged(bytes32 indexed pid, bool surgeEnabled);
    
    /**
     * @notice Emitted when surge fee is updated
     * @param poolId The pool ID
     * @param newSurgeFeePpm New surge fee (in PPM)
     * @param capEventActive Whether CAP event is active
     */
    event SurgeFeeUpdated(PoolId poolId, uint256 newSurgeFeePpm, bool capEventActive);
    
    /**
     * @notice Emitted when CAP event state changes
     * @param pid The pool ID hash
     * @param isActive Whether CAP event is currently active
     */
    event CAPEventStateChanged(bytes32 indexed pid, bool isActive);

    /**
     * @notice Emitted when oracle data is updated
     * @param pid The pool ID hash
     * @param tick The current tick value
     * @param timestamp The timestamp of the update
     */
    event OracleUpdated(bytes32 indexed pid, int24 tick, uint32 timestamp);
    
    /**
     * @notice Initialize fee and oracle data for a newly created pool
     * @param poolId The ID of the pool
     */
    function initializeFeeData(PoolId poolId) external;
    
    /**
     * @notice Updates the dynamic fee if needed based on time interval and CAP events
     * @param poolId The pool ID to update fee for
     * @param key The pool key for the pool
     * @return baseFee The current base fee in PPM
     * @return surgeFeeValue The current surge fee in PPM
     * @return wasUpdated Whether fee was updated in this call
     */
    function updateDynamicFeeIfNeeded(
        PoolId poolId,
        PoolKey calldata key
    ) external returns (
        uint256 baseFee,
        uint256 surgeFeeValue,
        bool wasUpdated
    );
    
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
    function getCurrentFees(PoolId poolId) external view returns (
        uint256 baseFee,
        uint256 surgeFeeValue
    );

    /**
     * @notice Update oracle data for a pool
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
     * @notice Gets the CAP event detector
     * @return The CAP event detector address
     */
    function getCAPEventDetector() external view returns (ICAPEventDetector);
} 