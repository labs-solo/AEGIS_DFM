// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

/**
 * @title PrecisionConstants
 * @notice Centralized library for precision-related constants used throughout the protocol
 * @dev This ensures consistency in scaling factors across all contracts
 */
library PrecisionConstants {
    /**
     * @notice Standard high-precision scaling factor (10^18)
     * @dev Used for interest rates, LTV ratios, and other high-precision calculations
     */
    uint256 internal constant PRECISION = 1e18;

    /**
     * @notice Parts-per-million scaling factor (10^6)
     * @dev Used for fee percentages, allocation shares, and other percentage-based calculations
     */
    uint256 internal constant PPM_SCALE = 1e6;

    /**
     * @notice 100% represented in PPM (1,000,000)
     * @dev Can be used for percentage calculations or validations
     */
    uint256 internal constant ONE_HUNDRED_PERCENT_PPM = 1e6;
}
