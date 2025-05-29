// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title IPoolPolicyManager
/// @notice Consolidated interface for all policy types in the Spot system
/// @dev Combines fee, tick scaling, v-tier, and various other policies into a single interface
interface IPoolPolicyManager {
    /// === Events ===

    /// @notice Emitted when a pool's POL share is changed
    /// @param poolId The ID of the pool
    /// @param polSharePpm The new POL share in PPM
    event PoolPOLShareChanged(PoolId indexed poolId, uint256 polSharePpm);

    /// @notice Emitted when the daily budget is set
    /// @param newBudget The new daily budget
    event DailyBudgetSet(uint32 newBudget);

    /// @notice Emitted when a pool-specific daily budget is set
    /// @param poolId The pool ID
    /// @param newBudget The new daily budget
    event PoolDailyBudgetSet(PoolId indexed poolId, uint32 newBudget);

    /// @notice Emitted when base fee parameters are set
    /// @param poolId The ID of the pool
    /// @param stepPpm The step size in PPM
    /// @param updateIntervalSecs The update interval in seconds
    event BaseFeeParamsSet(PoolId indexed poolId, uint32 stepPpm, uint32 updateIntervalSecs);

    /// @notice Emitted when a manual fee is set for a pool
    /// @param poolId The ID of the pool
    /// @param manualFee The manual fee in PPM
    event ManualFeeSet(PoolId indexed poolId, uint24 manualFee);

    /// @notice Emitted when the minimum base fee is set for a pool
    /// @param poolId The ID of the pool
    /// @param minBaseFeePpm The new minimum base fee in PPM
    event MinBaseFeeSet(PoolId indexed poolId, uint24 minBaseFeePpm);

    /// @notice Emitted when the maximum base fee is set for a pool
    /// @param poolId The ID of the pool
    /// @param maxBaseFeePpm The new maximum base fee in PPM
    event MaxBaseFeeSet(PoolId indexed poolId, uint24 maxBaseFeePpm);

    /// @notice Emitted when the cap budget decay window is set for a pool
    /// @param poolId The ID of the pool
    /// @param decayWindow The new decay window in seconds
    event CapBudgetDecayWindowSet(PoolId indexed poolId, uint32 decayWindow);

    /// @notice Emitted when the surge decay period is set for a pool
    /// @param poolId The ID of the pool
    /// @param decayPeriod The new decay period in seconds
    event SurgeDecayPeriodSet(PoolId indexed poolId, uint32 decayPeriod);

    /// @notice Emitted when the surge fee multiplier is set for a pool
    /// @param poolId The ID of the pool
    /// @param multiplier The new multiplier in PPM
    event SurgeFeeMultiplierSet(PoolId indexed poolId, uint24 multiplier);

    /// @notice Emitted when the global decay window is set
    /// @param decayWindow The new decay window in seconds
    event GlobalDecayWindowSet(uint32 decayWindow);

    /// @notice Emitted when the base fee factor is set for a pool
    /// @param poolId The pool ID
    /// @param factor The new base fee factor
    event BaseFeeFactorSet(PoolId indexed poolId, uint32 factor);

    /// === Fee Configuration Functions ===

    /// @notice Sets the POL share percentage for a specific pool
    /// @param poolId The pool ID
    /// @param polSharePpm The POL share in PPM (parts per million)
    function setPoolPOLShare(PoolId poolId, uint256 polSharePpm) external;

    /// @notice Gets the POL share percentage for a specific pool
    /// @param poolId The pool ID to get the POL share for
    /// @return The POL share in PPM (parts per million)
    function getPoolPOLShare(PoolId poolId) external view returns (uint256);

    /// === Manual Fee Functions ===

    /// @notice Gets the manual fee for a pool, if set
    /// @param poolId The pool ID to get the manual fee for
    /// @return manualFee The manual fee in PPM, 0 if not set
    /// @return isSet Whether a manual fee is set for this pool
    function getManualFee(PoolId poolId) external view returns (uint24 manualFee, bool isSet);

    /// @notice Sets a manual fee for a pool, overriding the dynamic fee calculation
    /// @param poolId The pool ID
    /// @param manualFee The manual fee in PPM
    function setManualFee(PoolId poolId, uint24 manualFee) external;

    /// @notice Clears a manual fee for a pool, reverting to dynamic fee calculation
    /// @param poolId The pool ID
    function clearManualFee(PoolId poolId) external;

    /// === Dynamic Fee Configuration Functions ===

    /// @notice Returns the surge decay period in seconds for the given pool
    /// @param poolId The pool ID
    /// @return Surge decay period in seconds
    function getSurgeDecayPeriodSeconds(PoolId poolId) external view returns (uint32);

    /// @notice Gets the default/global/fallback daily budget for CAP events
    /// @return The default daily budget in PPM
    function getDefaultDailyBudgetPpm() external view returns (uint32);

    /// @notice Returns the daily budget for CAP events in PPM for the given pool
    /// @param poolId The pool ID
    /// @return Daily budget in PPM
    function getDailyBudgetPpm(PoolId poolId) external view returns (uint32);

    /// @notice Returns the budget decay window in seconds for the given pool
    /// @param poolId The pool ID
    /// @return Budget decay window in seconds
    function getCapBudgetDecayWindow(PoolId poolId) external view returns (uint32);

    /// @notice Returns the minimum base fee in PPM for the given pool
    /// @param poolId The pool ID
    /// @return Minimum base fee in PPM
    function getMinBaseFee(PoolId poolId) external view returns (uint24);

    /// @notice Returns the maximum base fee in PPM for the given pool
    /// @param poolId The pool ID
    /// @return Maximum base fee in PPM
    function getMaxBaseFee(PoolId poolId) external view returns (uint24);

    /// @notice Returns the surge fee multiplier in PPM for the given pool
    /// @param poolId The pool ID
    /// @return Surge fee multiplier in PPM
    function getSurgeFeeMultiplierPpm(PoolId poolId) external view returns (uint24);

    /// @notice Returns the default maximum ticks per block for a pool
    /// @param poolId The pool ID
    /// @return Default maximum ticks per block
    function getDefaultMaxTicksPerBlock(PoolId poolId) external view returns (uint24);

    /// @notice Returns the base fee step size in PPM for the given pool
    /// @param poolId The pool ID
    /// @return Base fee step size in PPM
    function getBaseFeeStepPpm(PoolId poolId) external view returns (uint32);

    /// @notice Returns the base fee update interval in seconds for the given pool
    /// @param poolId The pool ID
    /// @return Base fee update interval in seconds
    function getBaseFeeUpdateIntervalSeconds(PoolId poolId) external view returns (uint32);

    /// @notice Gets the base fee factor for converting oracle ticks to fee PPM
    /// @param poolId The pool ID
    function getBaseFeeFactor(PoolId poolId) external view returns (uint32);

    /// === Dynamic Fee Setter Functions ===

    /// @notice Sets the cap budget decay window for a pool
    /// @param poolId The pool ID
    /// @param decayWindow The decay window in seconds
    function setCapBudgetDecayWindow(PoolId poolId, uint32 decayWindow) external;

    /// @notice Sets the minimum base fee for a pool
    /// @param poolId The pool ID
    /// @param minBaseFee The minimum base fee in PPM
    function setMinBaseFee(PoolId poolId, uint24 minBaseFee) external;

    /// @notice Sets the maximum base fee for a pool
    /// @param poolId The pool ID
    /// @param maxBaseFee The maximum base fee in PPM
    function setMaxBaseFee(PoolId poolId, uint24 maxBaseFee) external;

    /// @notice Sets the surge decay period in seconds for a pool
    /// @param poolId The pool ID
    /// @param surgeDecaySeconds The surge decay period in seconds
    function setSurgeDecayPeriodSeconds(PoolId poolId, uint32 surgeDecaySeconds) external;

    /// @notice Sets the surge fee multiplier for a pool
    /// @param poolId The pool ID
    /// @param multiplier The surge fee multiplier in PPM
    function setSurgeFeeMultiplierPpm(PoolId poolId, uint24 multiplier) external;

    /// @notice Sets base fee parameters for a pool
    /// @param poolId The pool ID
    /// @param stepPpm The step size in PPM
    /// @param updateIntervalSecs The update interval in seconds
    function setBaseFeeParams(PoolId poolId, uint32 stepPpm, uint32 updateIntervalSecs) external;

    /// @notice Sets the daily budget in PPM
    /// @param ppm The daily budget in PPM
    function setDailyBudgetPpm(uint32 ppm) external;

    /// @notice Sets the daily budget for CAP events for a specific pool
    /// @param poolId The pool ID
    /// @param newBudget The new daily budget in PPM (0 means use default)
    function setPoolDailyBudgetPpm(PoolId poolId, uint32 newBudget) external;

    /// @notice Sets the decay window in seconds
    /// @param secs The decay window in seconds
    function setDecayWindow(uint32 secs) external;

    /// @notice Sets the base fee factor for a specific pool
    /// @param poolId The pool ID
    /// @param factor The new base fee factor (1 tick = X PPM)
    function setBaseFeeFactor(PoolId poolId, uint32 factor) external;
}
