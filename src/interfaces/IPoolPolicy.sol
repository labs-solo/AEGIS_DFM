// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/**
 * @title IPoolPolicy
 * @notice Consolidated interface for all policy types in the Spot system
 * @dev Combines fee, tick scaling, and v-tier policies into a single interface
 */
interface IPoolPolicy {
    /**
     * @notice Policy types supported by the system
     */
    enum PolicyType {
        FEE, // Manages fee calculation and distribution
        TICK_SCALING, // Controls tick movement restrictions
        VTIER, // Validates fee tier and tick spacing combinations
        REINVESTMENT, // Manages fee reinvestment strategies
        ORACLE, // Added: Manages oracle behavior and thresholds
        INTEREST_FEE, // Added: Manages protocol interest fee settings
        REINVESTOR_AUTH // Added: Manages authorized reinvestor addresses

    }

    /**
     * @notice Returns the governance address of the Solo system
     * @return The governance address that controls the system
     */
    function getSoloGovernance() external view returns (address);

    /**
     * @notice Initializes all policies for a pool
     * @param poolId The ID of the pool
     * @param governance The governance address
     * @param implementations Array of policy implementations
     */
    function initializePolicies(PoolId poolId, address governance, address[] calldata implementations) external;

    /**
     * @notice Handles pool initialization
     * @param poolId The ID of the pool
     * @param key The pool key
     * @param sqrtPriceX96 The initial sqrt price
     * @param tick The initial tick
     * @param hook The hook address
     */
    function handlePoolInitialization(
        PoolId poolId,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick,
        address hook
    ) external;

    /**
     * @notice Returns the policy implementation for a specific policy type
     * @param poolId The ID of the pool
     * @param policyType The type of policy to retrieve
     * @return implementation The policy implementation address
     */
    function getPolicy(PoolId poolId, PolicyType policyType) external view returns (address implementation);

    /**
     * @notice Returns fee allocation percentages in PPM
     * @param poolId The ID of the pool
     * @return polShare Protocol-owned liquidity share
     * @return fullRangeShare Full range incentive share
     * @return lpShare Liquidity provider share
     */
    function getFeeAllocations(PoolId poolId)
        external
        view
        returns (uint256 polShare, uint256 fullRangeShare, uint256 lpShare);

    /**
     * @notice Calculates the minimum POL target based on dynamic fee and total liquidity
     * @param poolId The ID of the pool
     * @param totalLiquidity Current total pool liquidity
     * @param dynamicFeePpm Current dynamic fee in PPM
     * @return Minimum required protocol-owned liquidity amount
     */
    function getMinimumPOLTarget(PoolId poolId, uint256 totalLiquidity, uint256 dynamicFeePpm)
        external
        view
        returns (uint256);

    /**
     * @notice Returns the minimum trading fee allowed (in PPM)
     * @return Minimum fee in PPM
     */
    function getMinimumTradingFee() external view returns (uint256);

    /**
     * @notice Returns the threshold for claiming fees during swaps
     * @return Threshold as percentage of total liquidity
     */
    function getFeeClaimThreshold() external view returns (uint256);

    /**
     * @notice Gets the POL multiplier for a specific pool
     * @param poolId The ID of the pool
     * @return The pool-specific POL multiplier, or the default if not set
     */
    function getPoolPOLMultiplier(PoolId poolId) external view returns (uint256);

    /**
     * @notice Returns the default dynamic fee in PPM to use when initializing new pools
     * @return Default dynamic fee in PPM (e.g., 3000 for 0.3%)
     */
    function getDefaultDynamicFee() external view returns (uint256);

    /**
     * @notice Set all fee configuration parameters at once
     * @param polSharePpm Protocol-owned liquidity share in PPM
     * @param fullRangeSharePpm Full range incentive share in PPM
     * @param lpSharePpm LP share in PPM
     * @param minimumTradingFeePpm Minimum trading fee in PPM
     * @param feeClaimThresholdPpm Fee claim threshold in PPM
     * @param defaultPolMultiplier Default POL target multiplier
     */
    function setFeeConfig(
        uint256 polSharePpm,
        uint256 fullRangeSharePpm,
        uint256 lpSharePpm,
        uint256 minimumTradingFeePpm,
        uint256 feeClaimThresholdPpm,
        uint256 defaultPolMultiplier
    ) external;

    /**
     * @notice Sets the POL multiplier for a specific pool
     * @param poolId The ID of the pool
     * @param multiplier The new multiplier value
     */
    function setPoolPOLMultiplier(PoolId poolId, uint32 multiplier) external;

    /**
     * @notice Sets the default POL multiplier for new pools
     * @param multiplier The new default multiplier value
     */
    function setDefaultPOLMultiplier(uint32 multiplier) external;

    /**
     * @notice Sets the POL share percentage for a specific pool
     * @param poolId The pool ID
     * @param polSharePpm The POL share in PPM (parts per million)
     */
    function setPoolPOLShare(PoolId poolId, uint256 polSharePpm) external;

    /**
     * @notice Enables or disables the use of pool-specific POL share percentages
     * @param enabled Whether to enable pool-specific POL sharing
     */
    function setPoolSpecificPOLSharingEnabled(bool enabled) external;

    /**
     * @notice Gets the POL share percentage for a specific pool
     * @param poolId The pool ID to get the POL share for
     * @return The POL share in PPM (parts per million)
     */
    function getPoolPOLShare(PoolId poolId) external view returns (uint256);

    /**
     * @notice Returns the tick scaling factor used to convert dynamic fee to max tick change
     * @return Tick scaling factor (default 1000)
     */
    function getTickScalingFactor() external view returns (int24);

    /**
     * @notice Updates a supported tick spacing
     * @param tickSpacing The tick spacing value to update
     * @param isSupported Whether the tick spacing should be supported
     */
    function updateSupportedTickSpacing(uint24 tickSpacing, bool isSupported) external;

    /**
     * @notice Batch updates supported tick spacings
     * @param tickSpacings Array of tick spacing values to update
     * @param allowed Array of boolean values indicating if the corresponding tick spacing is supported
     */
    function batchUpdateAllowedTickSpacings(uint24[] calldata tickSpacings, bool[] calldata allowed) external;

    /**
     * @notice Checks if a tick spacing is supported
     * @param tickSpacing The tick spacing to check
     * @return True if the tick spacing is supported
     */
    function isTickSpacingSupported(uint24 tickSpacing) external view returns (bool);

    /**
     * @notice Determines if the fee and tickSpacing combination is valid
     * @param fee The fee tier (e.g., dynamic fee flag 0x800000)
     * @param tickSpacing The tick spacing for the pool
     * @return Boolean indicating if the vtier is valid
     */
    function isValidVtier(uint24 fee, int24 tickSpacing) external view returns (bool);

    /**
     * @notice Returns the protocol fee percentage for interest earned on borrowed funds.
     * @param poolId The ID of the pool (allows for future pool-specific overrides).
     * @return feePercentage Protocol fee percentage (scaled by PRECISION, e.g., 0.1e18 for 10%).
     */
    function getProtocolFeePercentage(PoolId poolId) external view returns (uint256 feePercentage);

    /**
     * @notice Returns the designated fee collector address (optional, might not be needed if fees go to POL).
     * @return The address authorized to potentially collect protocol fees (or address(0) if unused).
     */
    function getFeeCollector() external view returns (address);

    // ----------------------------------------------------------------
    // Dynamic Fee Feedback Policy Getters
    // ----------------------------------------------------------------

    /**
     * @notice Returns the policy‐defined surge decay period (in seconds) for the given pool.
     */
    function getSurgeDecayPeriodSeconds(PoolId poolId) external view returns (uint256);

    /**
     * @notice Returns the target number of CAP events per day (equilibrium) for the given pool.
     */
    function getTargetCapsPerDay(PoolId poolId) external view returns (uint32);

    /**
     * @notice Returns the daily budget for CAP events (in parts per million) for the given pool.
     */
    function getDailyBudgetPpm(PoolId pid) external view returns (uint32);

    /**
     * @notice Returns the budget decay window (in seconds) for the given pool.
     */
    function getCapBudgetDecayWindow(PoolId pid) external view returns (uint32);

    /**
     * @notice Returns the scaling factor used for CAP frequency math for the given pool.
     */
    function getFreqScaling(PoolId pid) external view returns (uint256);

    /**
     * @notice Returns the minimum base fee (in PPM) for the given pool.
     */
    function getMinBaseFee(PoolId poolId) external view returns (uint256);

    /**
     * @notice Returns the maximum base fee (in PPM) for the given pool.
     */
    function getMaxBaseFee(PoolId poolId) external view returns (uint256);

    /**
     * @notice DEPRECATED - Returns 0. Kept for backward compatibility.
     * @param poolId Pool ID to query.
     * @return Base fee update interval in seconds.
     */
    function getBaseFeeUpdateIntervalSeconds(PoolId poolId) external view returns (uint32);

    /**
     * @notice DEPRECATED - Returns 0. Kept for backward compatibility.
     * @param poolId Pool ID to query.
     * @return Maximum step size in PPM.
     */
    function getMaxStepPpm(PoolId poolId) external view returns (uint32);

    /**
     * @notice DEPRECATED - Returns 0. Kept for backward compatibility.
     * @param poolId Pool ID to query.
     * @return Base fee step size in PPM.
     */
    function getBaseFeeStepPpm(PoolId poolId) external view returns (uint32);

    /*──────── NEW knobs ─────────────────────────────────────────────*/
    /// surge = base * surgeFeeMultiplierPpm / 1e6  (e.g. 1_000_000 ppm = 100 %)
    function getSurgeFeeMultiplierPpm(PoolId poolId) external view returns (uint24);

    /// linear fade‑out period for surge fee
    function getSurgeDecaySeconds(PoolId poolId) external view returns (uint32);

    /// @notice Checks if a currency is supported for adding to a concentrated LP position
    /// @param currency The currency to check
    /// @return True if the currency can be added to a concentrated LP position, false otherwise
    function isSupportedCurrency(Currency currency) external view returns (bool);

    /**
     * @notice Helper to get both budget and window values in a single call, saving gas
     * @param id The PoolId to query
     * @return budgetPerDay Daily budget in PPM
     * @return decayWindow Decay window in seconds
     */
    function getBudgetAndWindow(PoolId id) external view returns (uint32 budgetPerDay, uint32 decayWindow);

    /*──────── NEW: default starting cap ─────────*/
    /// @notice Initial `maxTicksPerBlock` the oracle should use for a pool.
    function getDefaultMaxTicksPerBlock(PoolId id) external view returns (uint24);

    /* ────── test / governance helpers REMOVED FROM INTERFACE ────── */
    // function setFreqScaling(PoolId pid, uint32 scalingPpm) external;
    function setBaseFeeParams(PoolId pid, uint32 stepPpm, uint32 updateIntervalSecs) external;
}
