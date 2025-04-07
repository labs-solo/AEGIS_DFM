// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { PoolId } from "v4-core/src/types/PoolId.sol";

/**
 * @title IInterestRateModel
 * @notice Interface for interest rate model implementations
 */
interface IInterestRateModel {
    /**
     * @notice Get the borrow interest rate per second
     * @param poolId The pool ID (allows for future pool-specific overrides)
     * @param utilization The current utilization rate (scaled by PRECISION)
     * @return ratePerSecond The borrow rate per second (scaled by PRECISION)
     */
    function getBorrowRate(
        PoolId poolId,
        uint256 utilization
    ) external view returns (uint256 ratePerSecond);

    /**
     * @notice Get the current utilization rate based on borrowed and supplied amounts
     * @param poolId The pool ID
     * @param totalBorrowed Total borrowed amount (in shares or equivalent value)
     * @param totalSupplied Total supplied amount (in shares or equivalent value)
     * @return utilization The utilization rate (scaled by PRECISION)
     */
    function getUtilizationRate(
        PoolId poolId,
        uint256 totalBorrowed,
        uint256 totalSupplied
    ) external pure returns (uint256 utilization);

    /**
     * @notice Get the maximum allowed utilization rate for a pool
     * @return The maximum utilization rate (scaled by PRECISION)
     */
    function maxUtilizationRate() external view returns (uint256);

    /**
     * @notice Get model parameters (for off-chain analysis or UI display)
     * @return baseRate Base interest rate at 0% utilization (per year, scaled by PRECISION)
     * @return kinkRate Interest rate at the kink utilization point (per year, scaled by PRECISION)
     * @return kinkUtilization The utilization point where slope increases (scaled by PRECISION)
     * @return maxRate Maximum interest rate (per year, scaled by PRECISION)
     * @return kinkMultiplier The multiplier applied to the slope after the kink (scaled by PRECISION)
     */
    function getModelParameters() external view returns (
        uint256 baseRate,
        uint256 kinkRate,
        uint256 kinkUtilization,
        uint256 maxRate,
        uint256 kinkMultiplier // Added for completeness
    );
} 