// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { PoolId } from "v4-core/src/types/PoolId.sol";

/**
 * @title IInterestRateModel
 * @notice Interface for interest rate model implementations
 * @dev Placeholder for Phase 2 implementation
 */
interface IInterestRateModel {
    /**
     * @notice Get the borrow interest rate per second
     * @param poolId The pool ID
     * @param utilization The current utilization rate (scaled by 1e18)
     * @return ratePerSecond The borrow rate per second (scaled by 1e18)
     */
    function getBorrowRate(
        PoolId poolId,
        uint256 utilization
    ) external view returns (uint256 ratePerSecond);
    
    /**
     * @notice Get the current utilization rate
     * @param poolId The pool ID
     * @param totalBorrowed Total borrowed amount
     * @param totalSupplied Total supplied amount
     * @return utilization The utilization rate (scaled by 1e18)
     */
    function getUtilizationRate(
        PoolId poolId,
        uint256 totalBorrowed,
        uint256 totalSupplied
    ) external pure returns (uint256 utilization);
} 