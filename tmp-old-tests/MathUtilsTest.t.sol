// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/*
 * This test file has been moved to old-tests and commented out.
 * It is kept for reference but is no longer used in the project.
 * The new testing approach uses LocalUniswapV4TestBase.t.sol for local deployments.
 */

/*

import {Test} from "forge-std/Test.sol";
import {MathUtils} from "../src/libraries/MathUtils.sol";
import {MathErrors} from "../src/libraries/MathErrors.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Errors} from "../src/errors/Errors.sol";

/**
 * @title MathUtilsHarness
 * @notice Exposes internal functions of MathUtils for testing
 */
library MathUtilsHarness {
    // Existing functions

    // New functions for improved fee reinvestment calculation
    function calculateReinvestableFees(
        uint256 fee0,
        uint256 fee1,
        uint256 reserve0,
        uint256 reserve1,
        uint8 options
    ) internal pure returns (
        uint256 investable0,
        uint256 investable1,
        uint8 limitingToken
    ) {
        return MathUtils.calculateReinvestableFees(fee0, fee1, reserve0, reserve1, options);
    }

    // New functions for dynamic fee calculation
    function calculateDynamicFee(
        uint256 currentFeePpm,
        bool capEventOccurred,
        int256 eventDeviation,
        uint256 targetEventRate,
        uint16 maxIncreasePct,
        uint16 maxDecreasePct,
        MathUtils.FeeBounds memory bounds
    ) internal pure returns (
        uint256 newFeePpm,
        bool surgeEnabled,
        MathUtils.FeeAdjustmentType adjustmentType
    ) {
        return MathUtils.calculateDynamicFee(
            currentFeePpm,
            capEventOccurred,
            eventDeviation,
            targetEventRate,
            maxIncreasePct,
            maxDecreasePct,
            bounds
        );
    }

    function calculateSurgeFee(
        uint256 baseFeePpm,
        uint256 surgeMultiplierPpm,
        uint256 decayFactor
    ) internal pure returns (uint256 surgeFee) {
        return MathUtils.calculateSurgeFee(baseFeePpm, surgeMultiplierPpm, decayFactor);
    }

    function calculateDecayFactor(
        uint256 secondsElapsed,
        uint256 totalDuration
    ) internal pure returns (uint256 decayFactor) {
        return MathUtils.calculateDecayFactor(secondsElapsed, totalDuration);
    }
}

/**
 * @title MathUtilsTest
 * @notice Comprehensive test suite for MathUtils library
 * @dev Tests all functionality with standard, edge, and fuzz cases
 */
contract MathUtilsTest is Test {
    // Test struct for organizing deposit test cases
    struct DepositTestCase {
        uint128 totalShares;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 reserve0;
        uint256 reserve1;
        uint256 expectedActual0;
        uint256 expectedActual1;
        uint256 expectedShares;
        uint256 expectedLocked;
        bool shouldRevert;
        bytes4 revertError;
    }
    
    // Test cases for deposit calculations
    DepositTestCase[] depositTestCases;
    
    // Test struct for withdraw test cases
    struct WithdrawTestCase {
        uint128 totalShares;
        uint256 sharesToBurn;
        uint256 reserve0;
        uint256 reserve1;
        uint256 expectedAmount0;
        uint256 expectedAmount1;
        bool shouldRevert;
        bytes4 revertError;
    }
    
    // Test cases for withdrawal calculations
    WithdrawTestCase[] withdrawTestCases;
    
    // Test struct for fee distribution test cases
    struct FeeDistributionTestCase {
        uint256 amount0;
        uint256 amount1;
        uint256 polSharePpm;
        uint256 fullRangeSharePpm;
        uint256 lpSharePpm;
        uint256 expectedPol0;
        uint256 expectedPol1;
        uint256 expectedFullRange0;
        uint256 expectedFullRange1;
        uint256 expectedLp0;
        uint256 expectedLp1;
        bool shouldRevert;
        bytes4 revertError;
    }
    
    // Test cases for fee distribution
    FeeDistributionTestCase[] feeDistributionTestCases;
    
    function setUp() public {
        // Initialize deposit test cases
        _initializeDepositTestCases();
        
        // Initialize withdrawal test cases
        _initializeWithdrawTestCases();
        
        // Initialize fee distribution test cases
        _initializeFeeDistributionTestCases();
    }
    
    function _initializeDepositTestCases() internal {
        // Case 1: First deposit (happy path)
        depositTestCases.push(DepositTestCase({
            totalShares: 0,
            amount0Desired: 1000,
            amount1Desired: 1000,
            reserve0: 0,
            reserve1: 0,
            expectedActual0: 1000,
            expectedActual1: 1000,
            expectedShares: 1000 - MathUtils.MINIMUM_LIQUIDITY(),
            expectedLocked: MathUtils.MINIMUM_LIQUIDITY(),
            shouldRevert: false,
            revertError: bytes4(0)
        }));
        
        // Case 2: Subsequent deposit (equal proportions)
        depositTestCases.push(DepositTestCase({
            totalShares: 1000,
            amount0Desired: 100,
            amount1Desired: 100,
            reserve0: 1000,
            reserve1: 1000,
            expectedActual0: 100,
            expectedActual1: 100,
            expectedShares: 100,
            expectedLocked: 0,
            shouldRevert: false,
            revertError: bytes4(0)
        }));
        
        // Case 3: Zero amounts
        depositTestCases.push(DepositTestCase({
            totalShares: 1000,
            amount0Desired: 0,
            amount1Desired: 0,
            reserve0: 1000,
            reserve1: 1000,
            expectedActual0: 0,
            expectedActual1: 0,
            expectedShares: 0,
            expectedLocked: 0,
            shouldRevert: true,
            revertError: Errors.ValidationZeroAmount.selector
        }));
        
        // Case 4: First deposit with zero token0
        depositTestCases.push(DepositTestCase({
            totalShares: 0,
            amount0Desired: 0,
            amount1Desired: 1000,
            reserve0: 0,
            reserve1: 0,
            expectedActual0: 0,
            expectedActual1: 0,
            expectedShares: 0,
            expectedLocked: 0,
            shouldRevert: true,
            revertError: MathErrors.ZeroAmount.selector
        }));
        
        // Case 5: Deposit with zero reserve0
        depositTestCases.push(DepositTestCase({
            totalShares: 1000,
            amount0Desired: 100,
            amount1Desired: 100,
            reserve0: 0,
            reserve1: 1000,
            expectedActual0: 0,
            expectedActual1: 0,
            expectedShares: 0,
            expectedLocked: 0,
            shouldRevert: true,
            revertError: Errors.LiquidityInsufficientAmount.selector
        }));
        
        // Case 6: Amount too large for first deposit
        depositTestCases.push(DepositTestCase({
            totalShares: 0,
            amount0Desired: uint256(type(uint128).max) + 1,
            amount1Desired: 1000,
            reserve0: 0,
            reserve1: 0,
            expectedActual0: 0,
            expectedActual1: 0,
            expectedShares: 0,
            expectedLocked: 0,
            shouldRevert: true,
            revertError: Errors.MathAmountTooLarge.selector
        }));
        
        // Case 7: Uneven deposit (limited by token0)
        depositTestCases.push(DepositTestCase({
            totalShares: 1000,
            amount0Desired: 100,
            amount1Desired: 300,
            reserve0: 1000,
            reserve1: 2000,
            expectedActual0: 100,
            expectedActual1: 200,
            expectedShares: 100,
            expectedLocked: 0,
            shouldRevert: false,
            revertError: bytes4(0)
        }));
        
        // Case 8: High precision deposit
        depositTestCases.push(DepositTestCase({
            totalShares: 1000,
            amount0Desired: 1,
            amount1Desired: 2,
            reserve0: 1000,
            reserve1: 2000,
            expectedActual0: 1,
            expectedActual1: 2,
            expectedShares: 1,
            expectedLocked: 0,
            shouldRevert: false,
            revertError: bytes4(0)
        }));
    }
    
    function _initializeWithdrawTestCases() internal {
        // Case 1: Full withdrawal
        withdrawTestCases.push(WithdrawTestCase({
            totalShares: 1000,
            sharesToBurn: 1000,
            reserve0: 1000,
            reserve1: 2000,
            expectedAmount0: 1000,
            expectedAmount1: 2000,
            shouldRevert: false,
            revertError: bytes4(0)
        }));
        
        // Case 2: Partial withdrawal
        withdrawTestCases.push(WithdrawTestCase({
            totalShares: 1000,
            sharesToBurn: 500,
            reserve0: 1000,
            reserve1: 2000,
            expectedAmount0: 500,
            expectedAmount1: 1000,
            shouldRevert: false,
            revertError: bytes4(0)
        }));
        
        // Case 3: Zero shares
        withdrawTestCases.push(WithdrawTestCase({
            totalShares: 1000,
            sharesToBurn: 0,
            reserve0: 1000,
            reserve1: 2000,
            expectedAmount0: 0,
            expectedAmount1: 0,
            shouldRevert: false,
            revertError: bytes4(0)
        }));
        
        // Case 4: Attempt to burn more than total shares
        withdrawTestCases.push(WithdrawTestCase({
            totalShares: 1000,
            sharesToBurn: 1500,
            reserve0: 1000,
            reserve1: 2000,
            expectedAmount0: 1000,
            expectedAmount1: 2000,
            shouldRevert: false,
            revertError: bytes4(0)
        }));
        
        // Case 5: Handle rounding (when small shares would result in 0 tokens)
        withdrawTestCases.push(WithdrawTestCase({
            totalShares: 10000,
            sharesToBurn: 1,
            reserve0: 500,
            reserve1: 300,
            expectedAmount0: 1, // Would be 0 mathematically but adjusted to 1
            expectedAmount1: 1, // Would be 0 mathematically but adjusted to 1
            shouldRevert: false,
            revertError: bytes4(0)
        }));
    }
    
    function _initializeFeeDistributionTestCases() internal {
        // Case 1: Standard distribution (exact division)
        feeDistributionTestCases.push(FeeDistributionTestCase({
            amount0: 1000000,
            amount1: 2000000,
            polSharePpm: 200000, // 20%
            fullRangeSharePpm: 300000, // 30%
            lpSharePpm: 500000, // 50%
            expectedPol0: 200000,
            expectedPol1: 400000,
            expectedFullRange0: 300000,
            expectedFullRange1: 600000,
            expectedLp0: 500000,
            expectedLp1: 1000000,
            shouldRevert: false,
            revertError: bytes4(0)
        }));
        
        // Case 2: Rounding error handling
        feeDistributionTestCases.push(FeeDistributionTestCase({
            amount0: 1000,
            amount1: 2000,
            polSharePpm: 333333, // 1/3
            fullRangeSharePpm: 333333, // 1/3
            lpSharePpm: 333334, // 1/3 + rounding
            expectedPol0: 333,
            expectedPol1: 666,
            expectedFullRange0: 333,
            expectedFullRange1: 666,
            expectedLp0: 334, // Includes rounding error
            expectedLp1: 668, // Includes rounding error
            shouldRevert: false,
            revertError: bytes4(0)
        }));
        
        // Case 3: Invalid shares (doesn't sum to 100%)
        feeDistributionTestCases.push(FeeDistributionTestCase({
            amount0: 1000,
            amount1: 2000,
            polSharePpm: 400000,
            fullRangeSharePpm: 400000,
            lpSharePpm: 300000, // Only 90% in total
            expectedPol0: 0,
            expectedPol1: 0,
            expectedFullRange0: 0,
            expectedFullRange1: 0,
            expectedLp0: 0,
            expectedLp1: 0,
            shouldRevert: true,
            revertError: Errors.FeeAllocationSumError.selector
        }));
        
        // Case 4: Zero fees
        feeDistributionTestCases.push(FeeDistributionTestCase({
            amount0: 0,
            amount1: 0,
            polSharePpm: 200000,
            fullRangeSharePpm: 300000,
            lpSharePpm: 500000,
            expectedPol0: 0,
            expectedPol1: 0,
            expectedFullRange0: 0,
            expectedFullRange1: 0,
            expectedLp0: 0,
            expectedLp1: 0,
            shouldRevert: false,
            revertError: bytes4(0)
        }));
    }
    
    //----------------------------------------
    // Core Math Function Tests
    //----------------------------------------
    
    function testSqrt() public {
        assertEq(MathUtils.sqrt(0), 0, "sqrt(0) should be 0");
        assertEq(MathUtils.sqrt(1), 1, "sqrt(1) should be 1");
        assertEq(MathUtils.sqrt(4), 2, "sqrt(4) should be 2");
        assertEq(MathUtils.sqrt(9), 3, "sqrt(9) should be 3");
        assertEq(MathUtils.sqrt(16), 4, "sqrt(16) should be 4");
        assertEq(MathUtils.sqrt(10000), 100, "sqrt(10000) should be 100");
        
        // Large numbers
        assertEq(MathUtils.sqrt(10**18), 10**9, "sqrt(10^18) should be 10^9");
        
        // Non-perfect squares
        assertEq(MathUtils.sqrt(2), 1, "sqrt(2) should round down to 1");
        assertEq(MathUtils.sqrt(99), 9, "sqrt(99) should round down to 9");
        assertEq(MathUtils.sqrt(101), 10, "sqrt(101) should round down to 10");
    }
    
    function testAbsDiff() public {
        assertEq(MathUtils.absDiff(0, 0), 0, "absDiff(0, 0) should be 0");
        assertEq(MathUtils.absDiff(10, 5), 5, "absDiff(10, 5) should be 5");
        assertEq(MathUtils.absDiff(5, 10), 5, "absDiff(5, 10) should be 5");
        assertEq(MathUtils.absDiff(-5, 5), 10, "absDiff(-5, 5) should be 10");
        assertEq(MathUtils.absDiff(5, -5), 10, "absDiff(5, -5) should be 10");
        assertEq(MathUtils.absDiff(-10, -5), 5, "absDiff(-10, -5) should be 5");
        assertEq(MathUtils.absDiff(-5, -10), 5, "absDiff(-5, -10) should be 5");
    }
    
    function testGeometricMean() public {
        // Basic cases
        assertEq(MathUtils.calculateGeometricMean(0, 100), 0, "GM with 0 should be 0");
        assertEq(MathUtils.calculateGeometricMean(100, 0), 0, "GM with 0 should be 0");
        assertEq(MathUtils.calculateGeometricMean(100, 100), 100, "GM of same values should be the value");
        assertEq(MathUtils.calculateGeometricMean(4, 9), 6, "GM of 4 and 9 should be 6");
        
        // Large numbers (potential overflow case)
        uint256 large1 = 2**128;
        uint256 large2 = 2**128;
        assertEq(MathUtils.calculateGeometricMean(large1, large2), large1, "GM of 2^128 and 2^128 should be 2^128");
    }
    
    function testMinMax() public {
        // Min tests
        assertEq(MathUtils.min(5, 10), 5, "min(5, 10) should be 5");
        assertEq(MathUtils.min(10, 5), 5, "min(10, 5) should be 5");
        assertEq(MathUtils.min(5, 5), 5, "min(5, 5) should be 5");
        
        // Max tests
        assertEq(MathUtils.max(5, 10), 10, "max(5, 10) should be 10");
        assertEq(MathUtils.max(10, 5), 10, "max(10, 5) should be 10");
        assertEq(MathUtils.max(5, 5), 5, "max(5, 5) should be 5");
    }
    
    //----------------------------------------
    // Deposit Tests
    //----------------------------------------
    
    function testDepositCalculations() public {
        for (uint i = 0; i < depositTestCases.length; i++) {
            DepositTestCase memory tc = depositTestCases[i];
            
            if (tc.shouldRevert) {
                vm.expectRevert(tc.revertError);
                MathUtils.computeDepositAmountsAndShares(
                    tc.totalShares,
                    tc.amount0Desired,
                    tc.amount1Desired,
                    tc.reserve0,
                    tc.reserve1
                );
            } else {
                (uint256 actual0, uint256 actual1, uint256 shares, uint256 locked) = 
                    MathUtils.computeDepositAmountsAndShares(
                        tc.totalShares,
                        tc.amount0Desired,
                        tc.amount1Desired,
                        tc.reserve0,
                        tc.reserve1
                    );
                
                assertEq(actual0, tc.expectedActual0, string(abi.encodePacked("actual0 mismatch for case ", vm.toString(i))));
                assertEq(actual1, tc.expectedActual1, string(abi.encodePacked("actual1 mismatch for case ", vm.toString(i))));
                assertEq(shares, tc.expectedShares, string(abi.encodePacked("shares mismatch for case ", vm.toString(i))));
                assertEq(locked, tc.expectedLocked, string(abi.encodePacked("locked shares mismatch for case ", vm.toString(i))));
            }
        }
    }
    
    function testHighPrecisionDeposit() public {
        // Test with high precision for small amounts
        uint128 totalShares = 1000000;
        uint256 amount0Desired = 1;
        uint256 amount1Desired = 1;
        uint256 reserve0 = 10000000;
        uint256 reserve1 = 10000000;
        
        // Standard precision
        (uint256 actual0, uint256 actual1, uint256 shares, ) = 
            MathUtils.computeDepositAmountsAndShares(
                totalShares,
                amount0Desired,
                amount1Desired,
                reserve0,
                reserve1
            );
        
        // High precision
        (uint256 actual0HP, uint256 actual1HP, uint256 sharesHP, ) = 
            MathUtils.computeDepositAmountsAndSharesWithPrecision(
                totalShares,
                amount0Desired,
                amount1Desired,
                reserve0,
                reserve1
            );
        
        // High precision should give more accurate results for small amounts
        assertGe(sharesHP, shares, "High precision should provide at least as many shares");
    }
    
    //----------------------------------------
    // Withdrawal Tests
    //----------------------------------------
    
    function testWithdrawalCalculations() public {
        for (uint i = 0; i < withdrawTestCases.length; i++) {
            WithdrawTestCase memory tc = withdrawTestCases[i];
            
            if (tc.shouldRevert) {
                vm.expectRevert(tc.revertError);
                MathUtils.computeWithdrawAmounts(
                    tc.totalShares,
                    tc.sharesToBurn,
                    tc.reserve0,
                    tc.reserve1
                );
            } else {
                (uint256 amount0Out, uint256 amount1Out) = 
                    MathUtils.computeWithdrawAmounts(
                        tc.totalShares,
                        tc.sharesToBurn,
                        tc.reserve0,
                        tc.reserve1
                    );
                
                assertEq(amount0Out, tc.expectedAmount0, string(abi.encodePacked("amount0Out mismatch for case ", vm.toString(i))));
                assertEq(amount1Out, tc.expectedAmount1, string(abi.encodePacked("amount1Out mismatch for case ", vm.toString(i))));
            }
        }
    }
    
    //----------------------------------------
    // Fee Distribution Tests
    //----------------------------------------
    
    function testFeeDistribution() public {
        for (uint i = 0; i < feeDistributionTestCases.length; i++) {
            FeeDistributionTestCase memory tc = feeDistributionTestCases[i];
            
            if (tc.shouldRevert) {
                vm.expectRevert(tc.revertError);
                MathUtils.distributeFees(
                    tc.amount0,
                    tc.amount1,
                    tc.polSharePpm,
                    tc.fullRangeSharePpm,
                    tc.lpSharePpm
                );
            } else {
                (
                    uint256 pol0,
                    uint256 pol1,
                    uint256 fullRange0,
                    uint256 fullRange1,
                    uint256 lp0,
                    uint256 lp1
                ) = MathUtils.distributeFees(
                    tc.amount0,
                    tc.amount1,
                    tc.polSharePpm,
                    tc.fullRangeSharePpm,
                    tc.lpSharePpm
                );
                
                assertEq(pol0, tc.expectedPol0, string(abi.encodePacked("pol0 mismatch for case ", vm.toString(i))));
                assertEq(pol1, tc.expectedPol1, string(abi.encodePacked("pol1 mismatch for case ", vm.toString(i))));
                assertEq(fullRange0, tc.expectedFullRange0, string(abi.encodePacked("fullRange0 mismatch for case ", vm.toString(i))));
                assertEq(fullRange1, tc.expectedFullRange1, string(abi.encodePacked("fullRange1 mismatch for case ", vm.toString(i))));
                assertEq(lp0, tc.expectedLp0, string(abi.encodePacked("lp0 mismatch for case ", vm.toString(i))));
                assertEq(lp1, tc.expectedLp1, string(abi.encodePacked("lp1 mismatch for case ", vm.toString(i))));
                
                // Check that all tokens are accounted for (rounding errors handled correctly)
                assertEq(pol0 + fullRange0 + lp0, tc.amount0, "Total token0 allocation should equal original amount");
                assertEq(pol1 + fullRange1 + lp1, tc.amount1, "Total token1 allocation should equal original amount");
            }
        }
    }
    
    //----------------------------------------
    // Reinvestable Fees Tests
    //----------------------------------------
    
    function testReinvestableFees() public {
        // Case 1: New pool (no reserves)
        (uint256 investable0, uint256 investable1) = MathUtils.calculateReinvestableFees(
            1000,
            2000,
            0,
            0
        );
        assertEq(investable0, 1000, "With no reserves, all token0 fees should be investable");
        assertEq(investable1, 2000, "With no reserves, all token1 fees should be investable");
        
        // Case 2: Limited by token0
        (investable0, investable1) = MathUtils.calculateReinvestableFees(
            1000,
            3000,
            10000,
            20000
        );
        assertEq(investable0, 1000, "All token0 fees should be investable");
        assertEq(investable1, 2000, "Token1 should be limited to maintain ratio");
        
        // Case 3: Limited by token1
        (investable0, investable1) = MathUtils.calculateReinvestableFees(
            3000,
            1000,
            10000,
            20000
        );
        assertEq(investable0, 500, "Token0 should be limited to maintain ratio");
        assertEq(investable1, 1000, "All token1 fees should be investable");
        
        // Case 4: Zero fees
        (investable0, investable1) = MathUtils.calculateReinvestableFees(
            0,
            0,
            10000,
            20000
        );
        assertEq(investable0, 0, "Zero token0 should result in zero investable");
        assertEq(investable1, 0, "Zero token1 should result in zero investable");
    }
    
    //----------------------------------------
    // Dynamic Fee Tests
    //----------------------------------------
    
    function testDynamicFee() public {
        // Case 1: Increase fee (CAP event)
        uint256 newFee = MathUtils.calculateDynamicFee(
            5000, // 0.5% fee
            true, // CAP event
            int256(2000), // 0.2% deviation
            5000, // 0.5% max increase
            1000, // 0.1% max decrease
            1000, // 0.1% min fee
            10000 // 1% max fee
        );
        assertEq(newFee, 7000, "Fee should increase by the deviation amount");
        
        // Case 2: Cap at maximum fee
        newFee = MathUtils.calculateDynamicFee(
            8000, // 0.8% fee
            true, // CAP event
            int256(5000), // 0.5% deviation
            5000, // 0.5% max increase
            1000, // 0.1% max decrease
            1000, // 0.1% min fee
            10000 // 1% max fee
        );
        assertEq(newFee, 10000, "Fee should be capped at the maximum");
        
        // Case 3: Decrease fee (no CAP event)
        newFee = MathUtils.calculateDynamicFee(
            5000, // 0.5% fee
            false, // No CAP event
            int256(-2000), // Negative deviation
            5000, // 0.5% max increase
            1000, // 0.1% max decrease
            1000, // 0.1% min fee
            10000 // 1% max fee
        );
        assertEq(newFee, 4000, "Fee should decrease when no CAP event");
        
        // Case 4: Floor at minimum fee
        newFee = MathUtils.calculateDynamicFee(
            1500, // 0.15% fee
            false, // No CAP event
            int256(-2000), // Negative deviation
            5000, // 0.5% max increase
            1000, // 0.1% max decrease
            1000, // 0.1% min fee
            10000 // 1% max fee
        );
        assertEq(newFee, 1000, "Fee should be floored at the minimum");
    }
    
    //----------------------------------------
    // Surge Fee Tests
    //----------------------------------------
    
    function testSurgeFee() public {
        // Case 1: Standard surge calculation
        uint256 surgeFee = MathUtils.calculateSurgeFee(1000, 2000000); // 0.1% fee, 2x multiplier
        assertEq(surgeFee, 2000, "Surge fee should be 2x the base fee");
        
        // Case 2: Zero base fee
        surgeFee = MathUtils.calculateSurgeFee(0, 2000000);
        assertEq(surgeFee, 0, "Zero base fee should result in zero surge fee");
        
        // Case 3: Decay factor calculation
        uint256 decayFactor = MathUtils.calculateSurgeDecayFactor(
            600, // 600 seconds elapsed
            3600 // 1 hour (3600 seconds) duration
        );
        assertEq(decayFactor, MathUtils.PRECISION() * 5 / 6, "Decay factor should be 5/6 after 1/6 of the duration");
        
        // Case 4: Full decay
        decayFactor = MathUtils.calculateSurgeDecayFactor(3600, 3600);
        assertEq(decayFactor, 0, "Decay factor should be 0 after full duration");
    }
    
    //----------------------------------------
    // Fuzzing Tests
    //----------------------------------------
    
    function testFuzz_CalculateGeometricShares(uint128 amount0, uint128 amount1) public {
        vm.assume(amount0 > 0 && amount1 > 0);
        
        uint256 shares = MathUtils.calculateGeometricShares(amount0, amount1);
        
        // Properties that must hold:
        // 1. If amounts are equal, shares = amount
        if (amount0 == amount1) {
            assertEq(shares, amount0, "Equal inputs should produce equal output");
        }
        
        // 2. Shares should be <= the minimum of amount0 and amount1
        uint256 minAmount = amount0 < amount1 ? amount0 : amount1;
        assertTrue(shares <= minAmount, "Shares should not exceed min amount");
        
        // 3. Shares should be >= sqrt(amount0 * amount1) minus rounding error
        uint256 exactSqrt;
        if (amount0 > type(uint256).max / amount1) {
            exactSqrt = MathUtils.sqrt((amount0 / 1e9) * (amount1 / 1e9)) * 1e9;
        } else {
            exactSqrt = MathUtils.sqrt(uint256(amount0) * uint256(amount1));
        }
        
        // Allow small rounding error for large numbers
        uint256 tolerance = exactSqrt / 1000; // 0.1% tolerance
        // Due to integer division, calculated shares can be slightly less than exact
        assertTrue(
            shares <= exactSqrt && shares >= exactSqrt - tolerance,
            "Shares should approximately equal sqrt(amount0 * amount1)"
        );
    }
    
    function testFuzz_DepositWithdrawRoundTrip(
        uint128 totalShares,
        uint128 reserve0,
        uint128 reserve1,
        uint128 amount0,
        uint128 amount1
    ) public {
        // Require non-zero values for a meaningful test
        vm.assume(totalShares > 0 && reserve0 > 0 && reserve1 > 0);
        vm.assume(amount0 > 0 && amount1 > 0);
        
        // Perform deposit
        (uint256 actual0, uint256 actual1, uint256 newShares, ) = 
            MathUtils.computeDepositAmounts(
                totalShares,
                amount0,
                amount1,
                reserve0,
                reserve1,
                false
            );
        
        // Skip test if deposit resulted in 0 shares (e.g., due to rounding)
        if (newShares == 0) return;
        
        // Update state for withdrawal
        uint128 newTotalShares = totalShares + uint128(newShares);
        uint256 newReserve0 = reserve0 + actual0;
        uint256 newReserve1 = reserve1 + actual1;
        
        // Perform full withdrawal
        (uint256 withdrawn0, uint256 withdrawn1) = 
            MathUtils.computeWithdrawAmounts(
                newTotalShares,
                newShares,
                newReserve0,
                newReserve1,
                false
            );
        
        // Check roundtrip property: withdrawal should approximately return what was deposited
        // Allow small rounding errors in integer math
        uint256 tolerance0 = actual0 / 1000; // 0.1% tolerance
        uint256 tolerance1 = actual1 / 1000; // 0.1% tolerance
        
        assertTrue(
            withdrawn0 >= actual0 - tolerance0 && withdrawn0 <= actual0 + tolerance0,
            "withdrawn0 should approximately match actual0"
        );
        assertTrue(
            withdrawn1 >= actual1 - tolerance1 && withdrawn1 <= actual1 + tolerance1,
            "withdrawn1 should approximately match actual1"
        );
    }
    
    //----------------------------------------
    // Gas Benchmarking
    //----------------------------------------
    
    function testBenchmark_CalculateGeometricShares() public {
        uint256 a = 1000;
        uint256 b = 2000;
        
        uint256 gasBefore = gasleft();
        MathUtils.calculateGeometricShares(a, b);
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used for calculateGeometricShares:", gasUsed);
    }
    
    function testBenchmark_ComputeDepositAmounts() public {
        uint128 totalShares = 1000;
        uint256 amount0Desired = 100;
        uint256 amount1Desired = 100;
        uint256 reserve0 = 1000;
        uint256 reserve1 = 1000;
        
        uint256 gasBefore = gasleft();
        MathUtils.computeDepositAmountsAndShares(
            totalShares,
            amount0Desired,
            amount1Desired,
            reserve0,
            reserve1
        );
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used for computeDepositAmountsAndShares:", gasUsed);
    }
    
    function testBenchmark_ComputeWithdrawAmounts() public {
        uint128 totalShares = 1000;
        uint256 sharesToBurn = 100;
        uint256 reserve0 = 1000;
        uint256 reserve1 = 1000;
        
        uint256 gasBefore = gasleft();
        MathUtils.computeWithdrawAmounts(
            totalShares,
            sharesToBurn,
            reserve0,
            reserve1
        );
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used for computeWithdrawAmounts:", gasUsed);
    }
    
    function testBenchmark_DistributeFees() public {
        uint256 amount0 = 1000;
        uint256 amount1 = 2000;
        uint256 polSharePpm = 200000;
        uint256 fullRangeSharePpm = 300000;
        uint256 lpSharePpm = 500000;
        
        uint256 gasBefore = gasleft();
        MathUtils.distributeFees(
            amount0,
            amount1,
            polSharePpm,
            fullRangeSharePpm,
            lpSharePpm
        );
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used for distributeFees:", gasUsed);
    }

    function testCalculateReinvestableFees_Advanced() public {
        // Test with fast path exits
        (uint256 investable0, uint256 investable1, uint8 limitingToken) = 
            MathUtilsHarness.calculateReinvestableFees(0, 0, 1000, 1000, 0x3);
        assertEq(investable0, 0);
        assertEq(investable1, 0);
        assertEq(limitingToken, 0);
        
        // Test with no reserves
        (investable0, investable1, limitingToken) = 
            MathUtilsHarness.calculateReinvestableFees(100, 200, 0, 1000, 0x3);
        assertEq(investable0, 100);
        assertEq(investable1, 200);
        assertEq(limitingToken, 0);
        
        // Test with single-token fees (token0 only)
        (investable0, investable1, limitingToken) = 
            MathUtilsHarness.calculateReinvestableFees(100, 0, 1000, 1000, 0x3);
        assertEq(investable0, 100);
        assertEq(investable1, 0);
        assertEq(limitingToken, 1);
        
        // Test with single-token fees (token1 only)
        (investable0, investable1, limitingToken) = 
            MathUtilsHarness.calculateReinvestableFees(0, 100, 1000, 1000, 0x3);
        assertEq(investable0, 0);
        assertEq(investable1, 100);
        assertEq(limitingToken, 0);
        
        // Test with token0 as limiting token
        (investable0, investable1, limitingToken) = 
            MathUtilsHarness.calculateReinvestableFees(100, 300, 1000, 1000, 0x3);
        assertEq(investable0, 100);
        assertEq(investable1, 100); // Amount calculated to maintain ratio
        assertEq(limitingToken, 0);
        
        // Test with token1 as limiting token
        (investable0, investable1, limitingToken) = 
            MathUtilsHarness.calculateReinvestableFees(300, 100, 1000, 1000, 0x3);
        assertEq(investable0, 100); // Amount calculated to maintain ratio
        assertEq(investable1, 100);
        assertEq(limitingToken, 1);
        
        // Test with different reserve ratios
        (investable0, investable1, limitingToken) = 
            MathUtilsHarness.calculateReinvestableFees(300, 100, 3000, 1000, 0x3);
        assertEq(investable0, 300);
        assertEq(investable1, 100);
        assertEq(limitingToken, 1);
        
        // Test with high precision
        (investable0, investable1, limitingToken) = 
            MathUtilsHarness.calculateReinvestableFees(100, 300, 1000, 1000, 0x1);
        assertEq(investable0, 100);
        assertEq(investable1, 100);
        assertEq(limitingToken, 0);
        
        // Test with minimum output guarantee
        (investable0, investable1, limitingToken) = 
            MathUtilsHarness.calculateReinvestableFees(1, 1000, 1, 1000, 0x2);
        assertEq(investable0, 1);
        assertEq(investable1, 1);
        assertEq(limitingToken, 0);
    }

    function testCalculateDynamicFee_CAPEvent() public {
        // Setup test parameters
        uint256 currentFee = 3000; // 0.3%
        bool capEvent = true;
        int256 deviation = 500; // Significant positive deviation
        uint256 targetRate = 1000;
        uint16 maxIncreasePct = 10; // 10% increase
        uint16 maxDecreasePct = 5;  // 5% decrease
        
        // Create bounds structure
        MathUtils.FeeBounds memory bounds = MathUtils.FeeBounds({
            minFeePpm: 100,     // 0.01%
            maxFeePpm: 100000   // 10%
        });
        
        // Call the function
        (uint256 newFee, bool surgeEnabled, MathUtils.FeeAdjustmentType adjType) = 
            MathUtilsHarness.calculateDynamicFee(
                currentFee, 
                capEvent, 
                deviation, 
                targetRate, 
                maxIncreasePct, 
                maxDecreasePct, 
                bounds
            );
        
        // Verify expected results
        assertEq(newFee, 3300); // 3000 + (3000 * 10% = 300)
        assertTrue(surgeEnabled);
        assertEq(uint8(adjType), uint8(MathUtils.FeeAdjustmentType.SIGNIFICANT_INCREASE));
    }

    function testCalculateDynamicFee_ModerateDeviation() public {
        // Setup test parameters
        uint256 currentFee = 3000; // 0.3%
        bool capEvent = true;
        int256 deviation = 50; // Small positive deviation
        uint256 targetRate = 1000;
        uint16 maxIncreasePct = 10; // 10% increase
        uint16 maxDecreasePct = 5;  // 5% decrease
        
        // Create bounds structure
        MathUtils.FeeBounds memory bounds = MathUtils.FeeBounds({
            minFeePpm: 100,     // 0.01%
            maxFeePpm: 100000   // 10%
        });
        
        // Call the function
        (uint256 newFee, bool surgeEnabled, MathUtils.FeeAdjustmentType adjType) = 
            MathUtilsHarness.calculateDynamicFee(
                currentFee, 
                capEvent, 
                deviation, 
                targetRate, 
                maxIncreasePct, 
                maxDecreasePct, 
                bounds
            );
        
        // Verify expected results
        assertEq(newFee, 3100); // 3000 + (3000 * 10% / 3 = 100)
        assertTrue(surgeEnabled);
        assertEq(uint8(adjType), uint8(MathUtils.FeeAdjustmentType.MODERATE_INCREASE));
    }

    function testCalculateDynamicFee_NoCAPEvent() public {
        // Setup test parameters
        uint256 currentFee = 3000; // 0.3%
        bool capEvent = false;
        int256 deviation = 0; // No deviation
        uint256 targetRate = 1000;
        uint16 maxIncreasePct = 10; // 10% increase
        uint16 maxDecreasePct = 5;  // 5% decrease
        
        // Create bounds structure
        MathUtils.FeeBounds memory bounds = MathUtils.FeeBounds({
            minFeePpm: 100,     // 0.01%
            maxFeePpm: 100000   // 10%
        });
        
        // Call the function
        (uint256 newFee, bool surgeEnabled, MathUtils.FeeAdjustmentType adjType) = 
            MathUtilsHarness.calculateDynamicFee(
                currentFee, 
                capEvent, 
                deviation, 
                targetRate, 
                maxIncreasePct, 
                maxDecreasePct, 
                bounds
            );
        
        // Verify expected results
        assertEq(newFee, 2850); // 3000 - (3000 * 5% = 150)
        assertFalse(surgeEnabled);
        assertEq(uint8(adjType), uint8(MathUtils.FeeAdjustmentType.GRADUAL_DECREASE));
    }

    function testCalculateDynamicFee_BoundsEnforcement() public {
        // Setup test parameters for minimum bound enforcement
        uint256 currentFee = 150; // 0.015%
        bool capEvent = false;
        int256 deviation = 0;
        uint256 targetRate = 1000;
        uint16 maxIncreasePct = 10;
        uint16 maxDecreasePct = 50; // Large decrease to hit minimum
        
        // Create bounds structure
        MathUtils.FeeBounds memory bounds = MathUtils.FeeBounds({
            minFeePpm: 100,     // 0.01% minimum
            maxFeePpm: 100000   // 10% maximum
        });
        
        // Call the function to test minimum enforcement
        (uint256 newFee, bool surgeEnabled, MathUtils.FeeAdjustmentType adjType) = 
            MathUtilsHarness.calculateDynamicFee(
                currentFee, 
                capEvent, 
                deviation, 
                targetRate, 
                maxIncreasePct, 
                maxDecreasePct, 
                bounds
            );
        
        // Verify minimum enforcement
        assertEq(newFee, 100); // Min fee enforced
        assertFalse(surgeEnabled);
        assertEq(uint8(adjType), uint8(MathUtils.FeeAdjustmentType.MINIMUM_ENFORCED));
        
        // Setup test parameters for maximum bound enforcement
        currentFee = 95000; // 9.5%
        capEvent = true;
        deviation = 1000; // Large deviation to trigger full increase
        
        // Call the function to test maximum enforcement
        (newFee, surgeEnabled, adjType) = 
            MathUtilsHarness.calculateDynamicFee(
                currentFee, 
                capEvent, 
                deviation, 
                targetRate, 
                maxIncreasePct, 
                maxDecreasePct, 
                bounds
            );
        
        // Verify maximum enforcement
        assertEq(newFee, 100000); // Max fee enforced
        assertTrue(surgeEnabled);
        assertEq(uint8(adjType), uint8(MathUtils.FeeAdjustmentType.MAXIMUM_ENFORCED));
    }

    function testCalculateSurgeFee_WithDecay() public {
        uint256 baseFee = 3000; // 0.3%
        uint256 multiplier = 2000000; // 2x
        
        // Test with no decay
        uint256 decayFactor = MathUtils.PRECISION; // Full multiplier
        uint256 surgeFee = MathUtilsHarness.calculateSurgeFee(
            baseFee, 
            multiplier, 
            decayFactor
        );
        assertEq(surgeFee, 6000); // 0.3% * 2 = 0.6% = 6000 PPM
        
        // Test with 50% decay
        decayFactor = MathUtils.PRECISION / 2;
        surgeFee = MathUtilsHarness.calculateSurgeFee(
            baseFee, 
            multiplier, 
            decayFactor
        );
        assertEq(surgeFee, 4500); // Base 3000 + (3000 * 50% = 1500) = 4500
        
        // Test with full decay
        decayFactor = 0;
        surgeFee = MathUtilsHarness.calculateSurgeFee(
            baseFee, 
            multiplier, 
            decayFactor
        );
        assertEq(surgeFee, 3000); // Returns to base fee
        
        // Test with multiplier = 1x (no surge)
        multiplier = 1000000; // 1x
        surgeFee = MathUtilsHarness.calculateSurgeFee(
            baseFee, 
            multiplier, 
            MathUtils.PRECISION
        );
        assertEq(surgeFee, 3000); // No change
    }

    function testCalculateDecayFactor() public {
        // Test no elapsed time
        uint256 factor = MathUtilsHarness.calculateDecayFactor(0, 86400);
        assertEq(factor, MathUtils.PRECISION); // 0% elapsed = no decay
        
        // Test 25% elapsed time
        factor = MathUtilsHarness.calculateDecayFactor(21600, 86400);
        assertEq(factor, MathUtils.PRECISION * 3 / 4); // 25% elapsed = 25% decay
        
        // Test 50% elapsed time
        factor = MathUtilsHarness.calculateDecayFactor(43200, 86400);
        assertEq(factor, MathUtils.PRECISION / 2); // 50% elapsed = 50% decay
        
        // Test 75% elapsed time
        factor = MathUtilsHarness.calculateDecayFactor(64800, 86400);
        assertEq(factor, MathUtils.PRECISION / 4); // 75% elapsed = 75% decay
        
        // Test full elapsed time
        factor = MathUtilsHarness.calculateDecayFactor(86400, 86400);
        assertEq(factor, 0); // 100% elapsed = full decay
        
        // Test beyond elapsed time
        factor = MathUtilsHarness.calculateDecayFactor(100000, 86400);
        assertEq(factor, 0); // Beyond duration = full decay
    }
} 
*/
