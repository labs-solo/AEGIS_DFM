// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import {Base_Test} from "../Base_Test.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Errors} from "../../../src/errors/Errors.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import "forge-std/console.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract TickSpacingAutoTuningTest is Base_Test {
    using PoolIdLibrary for PoolKey;
    using PoolIdLibrary for PoolId;

    // Different tick spacings to test
    int24[] public tickSpacings;
    PoolKey[] public poolKeys;
    PoolId[] public poolIds;

    function setUp() public override {
        super.setUp();
        
        // Initialize tick spacings array with common values
        // Note: Base_Test already creates a pool with tick spacing 60, so we avoid that
        tickSpacings = new int24[](5);
        tickSpacings[0] = 1;    // Should give 100 ppm (clamped)
        tickSpacings[1] = 10;   // Should give 500 ppm
        tickSpacings[2] = 30;   // Should give 1500 ppm
        tickSpacings[3] = 200;  // Should give 10000 ppm (clamped)
        tickSpacings[4] = 500;  // Should give 10000 ppm (clamped)

        // Create pools for each tick spacing using the same currency pair but different tick spacings
        // Uniswap V4 allows this with the dynamic fee flag
        poolKeys = new PoolKey[](tickSpacings.length);
        poolIds = new PoolId[](tickSpacings.length);

        for (uint i = 0; i < tickSpacings.length; i++) {
            poolKeys[i] = PoolKey({
                currency0: currency0,
                currency1: currency1,
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, // Dynamic fee sentinel allows different tick spacings
                tickSpacing: tickSpacings[i],
                hooks: IHooks(address(spot))
            });

            // Initialize the pool
            manager.initialize(poolKeys[i], Constants.SQRT_PRICE_1_1);
            poolIds[i] = poolKeys[i].toId();
        }
    }

    /// @notice Test that different tick spacings result in different fee calculations
    function test_DifferentTickSpacings_ProduceDifferentFees() public {
        console.log("=== Testing Different Tick Spacings Produce Different Fees ===");
        
        for (uint i = 0; i < tickSpacings.length; i++) {
            // Get the calculated fee parameters for this tick spacing
            uint24 minBaseFee = policyManager.getMinBaseFee(poolIds[i]);
            uint24 maxBaseFee = policyManager.getMaxBaseFee(poolIds[i]);
            uint24 defaultMaxTicks = policyManager.getDefaultMaxTicksPerBlock(poolIds[i]);
            uint32 baseFeeFactor = policyManager.getBaseFeeFactor(poolIds[i]);
            
            // Get dynamic fee state
            (uint256 baseFee, uint256 surgeFee) = feeManager.getFeeState(poolIds[i]);
            
            console.log("Tick Spacing:", uint24(tickSpacings[i]));
            console.log("  Min Base Fee (ppm):", minBaseFee);
            console.log("  Max Base Fee (ppm):", maxBaseFee);
            console.log("  Default Max Ticks:", defaultMaxTicks);
            console.log("  Base Fee Factor:", baseFeeFactor);
            console.log("  Current Base Fee (ppm):", baseFee);
            console.log("  Current Surge Fee (ppm):", surgeFee);
            console.log("");
            
            // Verify the expected fee calculation: feePpm = clamp(tickSpacing * 50, 100, 10_000)
            uint24 expectedNormalFee;
            if (tickSpacings[i] <= 0) {
                expectedNormalFee = 100;
            } else {
                uint256 calculatedFee = uint256(uint24(tickSpacings[i])) * 50;
                if (calculatedFee < 100) calculatedFee = 100;
                if (calculatedFee > 10_000) calculatedFee = 10_000;
                expectedNormalFee = uint24(calculatedFee);
            }
            
            // The starting max ticks should be: normalFeePpm / baseFeeFactor
            uint24 expectedStartingMaxTicks = uint24(expectedNormalFee / baseFeeFactor);
            if (expectedStartingMaxTicks == 0) expectedStartingMaxTicks = 1;
            
            assertEq(defaultMaxTicks, expectedStartingMaxTicks, 
                "Default max ticks mismatch for tick spacing");
        }
        
        // Verify that different tick spacings produce different default max ticks
        for (uint i = 1; i < tickSpacings.length; i++) {
            uint24 prevDefaultMaxTicks = policyManager.getDefaultMaxTicksPerBlock(poolIds[i-1]);
            uint24 currDefaultMaxTicks = policyManager.getDefaultMaxTicksPerBlock(poolIds[i]);
            
            // For increasing tick spacings, we should generally get different max ticks
            // (unless clamped at boundaries)
            if (tickSpacings[i-1] < 200 && tickSpacings[i] <= 200) {
                assertTrue(currDefaultMaxTicks != prevDefaultMaxTicks || 
                          (tickSpacings[i-1] >= 200 && tickSpacings[i] >= 200),
                    "Different tick spacings should produce different default max ticks");
            }
        }
    }



    /// @notice Test fee calculations during swaps for different tick spacings
    function test_SwapFees_DifferentTickSpacings() public {
        console.log("=== Testing Swap Fees with Different Tick Spacings ===");
        
        for (uint i = 0; i < poolIds.length; i++) {
            console.log("--- Pool", i, "TickSpacing:", uint24(tickSpacings[i]));
            console.log("---");
            
            // Get initial fee state
            (uint256 initialBaseFee, uint256 initialSurgeFee) = feeManager.getFeeState(poolIds[i]);
            uint256 initialTotalFee = initialBaseFee + initialSurgeFee;
            
            console.log("Initial Base Fee:", initialBaseFee);
            console.log("Initial Surge Fee:", initialSurgeFee);
            console.log("Initial Total Fee:", initialTotalFee);
            
            // Perform a swap to trigger fee calculation
            this._performSwapOnPool(poolKeys[i], 1e18, true);
            
            // Get fee state after swap
            (uint256 afterBaseFee, uint256 afterSurgeFee) = feeManager.getFeeState(poolIds[i]);
            uint256 afterTotalFee = afterBaseFee + afterSurgeFee;
            
            console.log("After Base Fee:", afterBaseFee);
            console.log("After Surge Fee:", afterSurgeFee);
            console.log("After Total Fee:", afterTotalFee);
            
            // Verify fees are reasonable
            assertTrue(afterTotalFee >= 10, "Total fee should be at least 10 ppm"); // 0.001%
            assertTrue(afterTotalFee <= 100_000, "Total fee should not exceed 100_000 ppm"); // 10%
        }
    }



    /// @notice Test that tick spacing affects initial oracle configuration
    function test_TickSpacing_AffectsInitialOracleConfig() public {
        console.log("=== Testing Tick Spacing Effects on Initial Oracle Configuration ===");
        
        for (uint i = 0; i < poolIds.length; i++) {
            uint24 maxTicksPerBlock = oracle.maxTicksPerBlock(poolIds[i]);
            uint24 minCap = policyManager.getMinCap(poolIds[i]);
            uint24 maxCap = policyManager.getMaxCap(poolIds[i]);
            uint24 defaultMaxTicks = policyManager.getDefaultMaxTicksPerBlock(poolIds[i]);
            uint32 baseFeeFactor = policyManager.getBaseFeeFactor(poolIds[i]);
            
            console.log("TickSpacing:", uint24(tickSpacings[i]));
            console.log("  MaxTicksPerBlock:", maxTicksPerBlock);
            console.log("  MinCap:", minCap);
            console.log("  MaxCap:", maxCap);
            console.log("  DefaultMaxTicks:", defaultMaxTicks);
            console.log("  BaseFeeFactor:", baseFeeFactor);
            
            // Verify maxTicksPerBlock is within caps
            assertTrue(maxTicksPerBlock >= minCap, "MaxTicksPerBlock should be >= minCap");
            assertTrue(maxTicksPerBlock <= maxCap, "MaxTicksPerBlock should be <= maxCap");
            
            // Verify relationship between tick spacing and default max ticks
            // Higher tick spacing should generally result in higher default max ticks
            // (except when clamped at boundaries)
            if (i > 0 && tickSpacings[i-1] < 200 && tickSpacings[i] <= 200) {
                uint24 prevDefaultMaxTicks = policyManager.getDefaultMaxTicksPerBlock(poolIds[i-1]);
                assertTrue(defaultMaxTicks >= prevDefaultMaxTicks, 
                    "Higher tick spacing should generally result in higher default max ticks");
            }
        }
    }

    /// @notice Test fee bounds initialization for different tick spacings
    function test_FeeBounds_DifferentTickSpacings() public {
        console.log("=== Testing Fee Bounds for Different Tick Spacings ===");
        
        for (uint i = 0; i < poolIds.length; i++) {
            uint24 minBaseFee = policyManager.getMinBaseFee(poolIds[i]);
            uint24 maxBaseFee = policyManager.getMaxBaseFee(poolIds[i]);
            
            console.log("TickSpacing:", uint24(tickSpacings[i]));
            console.log("  MinBaseFee:", minBaseFee);
            console.log("  MaxBaseFee:", maxBaseFee);
            
            // All pools should have the same fee bounds (10 ppm min, 30000 ppm max)
            // as set in PoolPolicyManager.initializeBaseFeeBounds
            assertEq(minBaseFee, 10, "Min base fee should be 10 ppm for all tick spacings");
            assertEq(maxBaseFee, 30_000, "Max base fee should be 30_000 ppm for all tick spacings");
            
            // Verify bounds are reasonable
            assertTrue(minBaseFee < maxBaseFee, "Min base fee should be less than max base fee");
        }
    }

    // - - - Helper Functions - - -

    /// @notice Perform a swap on a specific pool
    function _performSwapOnPool(PoolKey memory key, uint256 amount, bool zeroForOne) external {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: true, 
            settleUsingBurn: false
        });
        
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount), // Negative for exact input
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        
        vm.prank(user1);
        swapRouter.swap(key, params, testSettings, "");
    }

    /// @notice Get pool information for debugging
    function _getPoolInfo(uint256 poolIndex) external view returns (
        int24 tickSpacing,
        uint24 maxTicksPerBlock,
        uint24 minCap,
        uint24 maxCap,
        uint24 defaultMaxTicks,
        uint32 baseFeeFactor,
        uint256 baseFee,
        uint256 surgeFee
    ) {
        require(poolIndex < poolIds.length, "Invalid pool index");
        
        tickSpacing = tickSpacings[poolIndex];
        maxTicksPerBlock = oracle.maxTicksPerBlock(poolIds[poolIndex]);
        minCap = policyManager.getMinCap(poolIds[poolIndex]);
        maxCap = policyManager.getMaxCap(poolIds[poolIndex]);
        defaultMaxTicks = policyManager.getDefaultMaxTicksPerBlock(poolIds[poolIndex]);
        baseFeeFactor = policyManager.getBaseFeeFactor(poolIds[poolIndex]);
        (baseFee, surgeFee) = feeManager.getFeeState(poolIds[poolIndex]);
    }
} 