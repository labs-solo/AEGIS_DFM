// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title IPoolPolicyManager
/// @notice Consolidated interface for all policy types in the Spot system
/// @dev Combines fee, tick scaling, v-tier, and various other policies into a single interface
interface IPoolPolicyManager {
    /// @notice Policy types supported by the system
    enum PolicyType {
        FEE, // Manages fee calculation and distribution
        TICK_SCALING, // Controls tick movement restrictions
        VTIER, // Validates fee tier and tick spacing combinations
        REINVESTMENT, // Manages fee reinvestment strategies
        ORACLE, // Manages oracle behavior and thresholds
        INTEREST_FEE, // Manages protocol interest fee settings
        REINVESTOR_AUTH // Manages authorized reinvestor addresses

    }

    /// === Events ===

    /// @notice Emitted when fee configuration is changed
    /// @param polSharePpm Protocol-owned liquidity share in PPM
    /// @param minimumTradingFeePpm Minimum trading fee in PPM
    event FeeConfigChanged(uint256 polSharePpm, uint256 minimumTradingFeePpm);

    /// @notice Emitted when a policy is set for a pool
    /// @param poolId The ID of the pool
    /// @param policyType The type of policy being set
    /// @param implementation The address of the implementation (or address-encoded parameter)
    /// @param setter The address that set the policy
    event PolicySet(
        PoolId indexed poolId, PolicyType indexed policyType, address implementation, address indexed setter
    );

    /// @notice Emitted when a pool is initialized
    /// @param poolId The ID of the pool
    /// @param hook The hook address
    /// @param initialTick The initial tick
    event PoolInitialized(PoolId indexed poolId, address hook, int24 initialTick);

    /// @notice Emitted when a pool's POL share is changed
    /// @param poolId The ID of the pool
    /// @param polSharePpm The new POL share in PPM
    event PoolPOLShareChanged(PoolId indexed poolId, uint256 polSharePpm);

    /// @notice Emitted when pool-specific POL sharing is enabled or disabled
    /// @param enabled Whether pool-specific POL sharing is enabled
    event PoolSpecificPOLSharingEnabled(bool enabled);

    /// @notice Emitted when the POL share is set
    /// @param oldShare The old POL share
    /// @param newShare The new POL share
    event POLShareSet(uint256 oldShare, uint256 newShare);

    /// @notice Emitted when the full range share is set
    /// @param oldShare The old full range share
    /// @param newShare The new full range share
    event FullRangeShareSet(uint256 oldShare, uint256 newShare);

    /// @notice Emitted when the daily budget is set
    /// @param newBudget The new daily budget
    event DailyBudgetSet(uint32 newBudget);

    /// @notice Emitted when base fee parameters are set
    /// @param poolId The ID of the pool
    /// @param stepPpm The step size in PPM
    /// @param updateIntervalSecs The update interval in seconds
    event BaseFeeParamsSet(PoolId indexed poolId, uint32 stepPpm, uint32 updateIntervalSecs);

    /// @notice Emitted when a manual fee is set for a pool
    /// @param poolId The ID of the pool
    /// @param manualFee The manual fee in PPM
    event ManualFeeSet(PoolId indexed poolId, uint24 manualFee);

    /// === Fee Configuration Functions ===

    /// @notice Sets the POL share percentage for a specific pool
    /// @param poolId The pool ID
    /// @param polSharePpm The POL share in PPM (parts per million)
    function setPoolPOLShare(PoolId poolId, uint256 polSharePpm) external;

    /// @notice Enables or disables the use of pool-specific POL share percentages
    /// @param enabled Whether to enable pool-specific POL sharing
    function setPoolSpecificPOLSharingEnabled(bool enabled) external;

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
    function getSurgeDecayPeriodSeconds(PoolId poolId) external view returns (uint256);

    /// @notice Returns the daily budget for CAP events in PPM for the given pool
    /// @param poolId The pool ID
    /// @return Daily budget in PPM
    function getDailyBudgetPpm(PoolId poolId) external view returns (uint32);

    /// @notice Returns the budget decay window in seconds for the given pool
    /// @param poolId The pool ID
    /// @return Budget decay window in seconds
    function getCapBudgetDecayWindow(PoolId poolId) external view returns (uint32);

    /// @notice Returns the scaling factor used for CAP frequency calculations
    /// @param poolId The pool ID
    /// @return Frequency scaling factor
    function getFreqScaling(PoolId poolId) external view returns (uint256);

    /// @notice Returns the minimum base fee in PPM for the given pool
    /// @param poolId The pool ID
    /// @return Minimum base fee in PPM
    function getMinBaseFee(PoolId poolId) external view returns (uint256);

    /// @notice Returns the maximum base fee in PPM for the given pool
    /// @param poolId The pool ID
    /// @return Maximum base fee in PPM
    function getMaxBaseFee(PoolId poolId) external view returns (uint256);

    /// @notice Returns the surge fee multiplier in PPM for the given pool
    /// @param poolId The pool ID
    /// @return Surge fee multiplier in PPM
    function getSurgeFeeMultiplierPpm(PoolId poolId) external view returns (uint24);

    /// @notice Returns the surge decay seconds for the given pool
    /// @param poolId The pool ID
    /// @return Surge decay in seconds
    function getSurgeDecaySeconds(PoolId poolId) external view returns (uint32);

    /// @notice Returns the default maximum ticks per block for a pool
    /// @param poolId The pool ID
    /// @return Default maximum ticks per block
    function getDefaultMaxTicksPerBlock(PoolId poolId) external view returns (uint24);

    /// @notice Helper to get both budget and window values in a single call
    /// @param poolId The pool ID
    /// @return budgetPerDay Daily budget in PPM
    /// @return decayWindow Decay window in seconds
    function getBudgetAndWindow(PoolId poolId) external view returns (uint32 budgetPerDay, uint32 decayWindow);

    /// @notice Returns the base fee step size in PPM for the given pool
    /// @param poolId The pool ID
    /// @return Base fee step size in PPM
    function getBaseFeeStepPpm(PoolId poolId) external view returns (uint32);

    /// @notice Returns the base fee update interval in seconds for the given pool
    /// @param poolId The pool ID
    /// @return Base fee update interval in seconds
    function getBaseFeeUpdateIntervalSeconds(PoolId poolId) external view returns (uint32);

    /// @notice Legacy alias for getBaseFeeStepPpm
    /// @param poolId The pool ID
    /// @return Maximum step size in PPM
    function getMaxStepPpm(PoolId poolId) external view returns (uint32);

    /// === Dynamic Fee Setter Functions ===

    /// @notice Sets the target caps per day for a pool
    /// @param poolId The pool ID
    /// @param targetCapsPerDay The target caps per day
    function setTargetCapsPerDay(PoolId poolId, uint256 targetCapsPerDay) external;

    /// @notice Sets the cap budget decay window for a pool
    /// @param poolId The pool ID
    /// @param decayWindow The decay window in seconds
    function setCapBudgetDecayWindow(PoolId poolId, uint256 decayWindow) external;

    /// @notice Sets the frequency scaling factor for a pool
    /// @param poolId The pool ID
    /// @param freqScaling The frequency scaling factor
    function setFreqScaling(PoolId poolId, uint256 freqScaling) external;

    /// @notice Sets the minimum base fee for a pool
    /// @param poolId The pool ID
    /// @param minBaseFee The minimum base fee in PPM
    function setMinBaseFee(PoolId poolId, uint256 minBaseFee) external;

    /// @notice Sets the maximum base fee for a pool
    /// @param poolId The pool ID
    /// @param maxBaseFee The maximum base fee in PPM
    function setMaxBaseFee(PoolId poolId, uint256 maxBaseFee) external;

    /// @notice Sets the surge decay period in seconds for a pool
    /// @param poolId The pool ID
    /// @param surgeDecaySeconds The surge decay period in seconds
    function setSurgeDecayPeriodSeconds(PoolId poolId, uint256 surgeDecaySeconds) external;

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

    /// @notice Sets the decay window in seconds
    /// @param secs The decay window in seconds
    function setDecayWindow(uint32 secs) external;
}
