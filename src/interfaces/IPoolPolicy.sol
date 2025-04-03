// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

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
        FEE,           // Manages fee calculation and distribution
        TICK_SCALING,  // Controls tick movement restrictions
        VTIER,         // Validates fee tier and tick spacing combinations
        REINVESTMENT   // Manages fee reinvestment strategies
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
    function handlePoolInitialization(PoolId poolId, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick, address hook) external;

    /**
     * @notice Returns the policy implementation for a specific policy type
     * @param poolId The ID of the pool
     * @param policyType The type of policy to retrieve
     * @return The policy implementation address
     */
    function getPolicy(PoolId poolId, PolicyType policyType) external view returns (address);

    /**
     * @notice Returns fee allocation percentages in PPM
     * @param poolId The ID of the pool
     * @return polShare Protocol-owned liquidity share
     * @return fullRangeShare Full range incentive share
     * @return lpShare Liquidity provider share
     */
    function getFeeAllocations(PoolId poolId) external view returns (uint256 polShare, uint256 fullRangeShare, uint256 lpShare);
    
    /**
     * @notice Calculates the minimum POL target based on dynamic fee and total liquidity
     * @param poolId The ID of the pool
     * @param totalLiquidity Current total pool liquidity
     * @param dynamicFeePpm Current dynamic fee in PPM
     * @return Minimum required protocol-owned liquidity amount
     */
    function getMinimumPOLTarget(PoolId poolId, uint256 totalLiquidity, uint256 dynamicFeePpm) external view returns (uint256);
    
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
} 