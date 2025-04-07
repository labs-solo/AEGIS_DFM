// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IInterestRateModel} from "../../src/interfaces/IInterestRateModel.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

// Basic mock for IInterestRateModel
contract MockLinearInterestRateModel is IInterestRateModel {
    uint256 public constant PRECISION = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    // Mock values (can be changed via setters)
    uint256 public mockBorrowRatePerSecond = ((5 * PRECISION) / 100) / SECONDS_PER_YEAR; // 0.05 * PRECISION / (365 days); // 5% APR default
    uint256 public mockMaxUtilizationRate = (95 * PRECISION) / 100; // 0.95 * PRECISION; // 95% default

    function getBorrowRate(PoolId poolId, uint256 utilization)
        external
        view
        override
        returns (uint256 ratePerSecond)
    {
        poolId;
        utilization;
        return mockBorrowRatePerSecond;
    }

    function getUtilizationRate(
        PoolId poolId,
        uint256 totalBorrowed,
        uint256 totalSupplied
    ) external pure override returns (uint256 utilization) {
        poolId;
        if (totalSupplied == 0) return 0;
        utilization = (totalBorrowed * PRECISION) / totalSupplied;
    }

    function maxUtilizationRate() external view override returns (uint256) {
        return mockMaxUtilizationRate;
    }

    function getModelParameters() external view override returns (
        uint256 baseRate,
        uint256 kinkRate,
        uint256 kinkUtilization,
        uint256 maxRate,
        uint256 kinkMultiplier
    ) {
        // Return dummy values, not used in tests relying on mock
        return (0, 0, 0, 0, 0);
    }

    // --- Mock Setters ---
    function setMockBorrowRatePerSecond(uint256 _rate) external {
        mockBorrowRatePerSecond = _rate;
    }

    function setMockMaxUtilizationRate(uint256 _rate) external {
        mockMaxUtilizationRate = _rate;
    }
} 