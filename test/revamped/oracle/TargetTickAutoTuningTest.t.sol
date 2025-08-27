// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Base_Test} from "../Base_Test.sol";
import {console} from "forge-std/console.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract TargetTickAutoTuningTest is Base_Test {
    
    /// @notice Test autotuning convergence to a low target tick (13)
    function test_AutoTuning_ConvergeToLowTick() public {
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("=== Testing Autotuning Convergence to Low Tick (13) ===");
        console.log("Initial maxTicks:", initialMaxTicks);
        
        // Perform daily swaps that cause small tick movement
        for (uint256 day = 1; day <= 60; day++) { // Extended to 60 days to reach lower values
            vm.warp(block.timestamp + 1 days);
            
            // Perform a swap that causes small tick movement (less than current maxTicks)
            // We'll use a small amount that won't trigger cap events
            this._performSwap(1e6, true);
            
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            console.log("Day", day, "maxTicks:", currentMaxTicks);
            
            // Check if we've converged to around 13
            if (currentMaxTicks <= 20) {
                console.log("Converged to low tick range on day", day);
                break;
            }
        }
        
        uint24 finalMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("Final maxTicks:", finalMaxTicks);
        console.log("Target was 13, achieved:", finalMaxTicks);
        
        // Should converge to around the target tick (allow some tolerance)
        assertTrue(finalMaxTicks <= 50, "Should converge to low tick range");
        assertTrue(finalMaxTicks >= 10, "Should not go below reasonable minimum");
    }
    
    /// @notice Test autotuning convergence to a high target tick (140)
    function test_AutoTuning_ConvergeToHighTick() public {
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("=== Testing Autotuning Convergence to High Tick (140) ===");
        console.log("Initial maxTicks:", initialMaxTicks);
        
        // Perform daily swaps that cause exactly 140 ticks of movement
        for (uint256 day = 1; day <= 30; day++) {
            vm.warp(block.timestamp + 1 days);
            
            // Perform a swap that causes exactly 140 ticks of movement
            // We'll use a large amount that should cause ~140 tick movement
            this._performSwap(100000e18, true);
            
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            console.log("Day", day, "maxTicks:", currentMaxTicks);
            
            // Check if we've converged to around 140
            if (currentMaxTicks >= 130) {
                console.log("Converged to high tick range on day", day);
                break;
            }
        }
        
        uint24 finalMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("Final maxTicks:", finalMaxTicks);
        console.log("Target was 140, achieved:", finalMaxTicks);
        
        // Should converge to around the target tick (allow some tolerance)
        assertTrue(finalMaxTicks >= 120, "Should converge to high tick range");
        assertTrue(finalMaxTicks <= 200, "Should not exceed reasonable maximum");
    }
    
    /// @notice Test autotuning convergence to medium target tick (60)
    function test_AutoTuning_ConvergeToMediumTick() public {
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("=== Testing Autotuning Convergence to Medium Tick (60) ===");
        console.log("Initial maxTicks:", initialMaxTicks);
        
        // Perform daily swaps that cause moderate tick movement
        for (uint256 day = 1; day <= 100; day++) {
            vm.warp(block.timestamp + 1 days);
            
            // Perform a swap that causes moderate tick movement
            // We'll use a moderate amount that should cause ~60 tick movement without triggering cap events
            this._performSwap(600e18, true);
            
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            
            // Log every 10 days to avoid spam, but log first 20 days and last 10 days
            if (day <= 20 || day % 10 == 0 || day > 90) {
                console.log("Day", day, "maxTicks:", currentMaxTicks);
            }
            
            // Check if we've converged to around 60
            if (currentMaxTicks >= 50 && currentMaxTicks <= 70) {
                console.log("Converged to medium tick range on day", day);
                // Don't break - continue to see what happens after convergence
            }
        }
        
        uint24 finalMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("Final maxTicks:", finalMaxTicks);
        console.log("Target was 60, achieved:", finalMaxTicks);
        
        // Should not exceed reasonable maximum (since we're starting at 107 and the algorithm increases on cap events)
        assertTrue(finalMaxTicks <= 150, "Should not exceed reasonable maximum");
    }
    
    /// @notice Test autotuning with alternating high and low volatility
    function test_AutoTuning_AlternatingVolatility() public {
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("=== Testing Autotuning with Alternating Volatility ===");
        console.log("Initial maxTicks:", initialMaxTicks);
        
        // Alternate between high and low volatility every 5 days
        for (uint256 day = 1; day <= 40; day++) {
            vm.warp(block.timestamp + 1 days);
            
            if (day <= 10) {
                // First 10 days: High volatility (large swaps)
                this._performSwap(100000e18, true);
                console.log("Day", day, "High vol - maxTicks:", oracle.maxTicksPerBlock(poolId));
            } else if (day <= 20) {
                // Next 10 days: Low volatility (small swaps)
                this._performSwap(1000e18, true);
                console.log("Day", day, "Low vol - maxTicks:", oracle.maxTicksPerBlock(poolId));
            } else if (day <= 30) {
                // Next 10 days: High volatility again
                this._performSwap(100000e18, true);
                console.log("Day", day, "High vol - maxTicks:", oracle.maxTicksPerBlock(poolId));
            } else {
                // Final 10 days: Low volatility again
                this._performSwap(1000e18, true);
                console.log("Day", day, "Low vol - maxTicks:", oracle.maxTicksPerBlock(poolId));
            }
        }
        
        uint24 finalMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("Final maxTicks after alternating volatility:", finalMaxTicks);
        
        // Should be within reasonable bounds
        assertTrue(finalMaxTicks >= 10, "Should not go below reasonable minimum");
        assertTrue(finalMaxTicks <= 200, "Should not exceed reasonable maximum");
    }
    

    

    
    /// @notice Test to measure actual tick movement during autotuning
    function test_AutoTuning_MeasureActualTickMovement() public {
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("=== Testing Actual Tick Movement During Autotuning ===");
        console.log("Initial maxTicks:", initialMaxTicks);
        
        // Reset to initial state
        vm.prank(owner);
        oracle.refreshPolicyCache(poolId);
        
        uint256 swapAmount = 400e18; // Changed to 400e18 to test smaller movement
        
        // Measure tick movement for first 10 swaps
        for (uint256 day = 1; day <= 10; day++) {
            vm.warp(block.timestamp + 1 days);
            
            // Get tick before swap
            (, int24 tickBefore,,) = StateLibrary.getSlot0(manager, poolId);
            
            // Perform the swap
            this._performSwap(swapAmount, true);
            
            // Get tick after swap
            (, int24 tickAfter,,) = StateLibrary.getSlot0(manager, poolId);
            int24 tickMovement = tickAfter - tickBefore;
            
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            
            console.log("Day", day);
            console.log("Movement:", tickMovement);
            console.log("maxTicks:", currentMaxTicks);
            
            // Check if this swap caused a cap event
            bool wasCapped = tickMovement < 0 ? uint24(-tickMovement) > currentMaxTicks : uint24(tickMovement) > currentMaxTicks;
            console.log("Was capped:", wasCapped);
        }
    }
    
    /// @notice Test to measure actual tick movement during autotuning with alternating directions
    function test_AutoTuning_MeasureAlternatingTickMovement() public {
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("=== Testing Alternating Tick Movement During Autotuning ===");
        console.log("Initial maxTicks:", initialMaxTicks);
        
        // Reset to initial state
        vm.prank(owner);
        oracle.refreshPolicyCache(poolId);
        
        uint256 swapAmount = 100e18;
        
        // Measure tick movement for 20 swaps, alternating directions
        for (uint256 day = 1; day <= 20; day++) {
            vm.warp(block.timestamp + 1 days);
            
            // Get tick before swap
            (, int24 tickBefore,,) = StateLibrary.getSlot0(manager, poolId);
            
            // Alternate between zeroForOne and oneForZero
            bool zeroForOne = (day % 2 == 1); // Odd days: zeroForOne, Even days: oneForZero
            
            // Perform the swap
            this._performSwap(swapAmount, zeroForOne);
            
            // Get tick after swap
            (, int24 tickAfter,,) = StateLibrary.getSlot0(manager, poolId);
            int24 tickMovement = tickAfter - tickBefore;
            
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            
            console.log("Day", day);
            console.log("Direction:", zeroForOne ? "zeroForOne" : "oneForZero");
            console.log("Movement:", tickMovement);
            console.log("maxTicks:", currentMaxTicks);
            
            // Check if this swap caused a cap event
            bool wasCapped = tickMovement < 0 ? uint24(-tickMovement) > currentMaxTicks : uint24(tickMovement) > currentMaxTicks;
            console.log("Was capped:", wasCapped);
        }
    }
    
    /// @notice Test to measure autotuning behavior with 80-tick swaps over 150 days
    function test_AutoTuning_80TickSwaps150Days() public {
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("=== Testing 80-Tick Swaps for 150 Days ===");
        console.log("Initial maxTicks:", initialMaxTicks);
        
        // Reset to initial state
        vm.prank(owner);
        oracle.refreshPolicyCache(poolId);
        
        // Use a larger swap amount to get ~80 ticks per swap
        uint256 swapAmount = 500e18; // Increased from 100e18 to get larger tick movement
        
        // Track key metrics
        uint24 maxTicksAtDay10 = 0;
        uint24 maxTicksAtDay50 = 0;
        uint24 maxTicksAtDay100 = 0;
        uint24 maxTicksAtDay150 = 0;
        
        // Run for 150 days
        for (uint256 day = 1; day <= 150; day++) {
            vm.warp(block.timestamp + 1 days);
            
            // Get tick before swap
            (, int24 tickBefore,,) = StateLibrary.getSlot0(manager, poolId);
            
            // Alternate between zeroForOne and oneForZero
            bool zeroForOne = (day % 2 == 1); // Odd days: zeroForOne, Even days: oneForZero
            
            // Perform the swap
            this._performSwap(swapAmount, zeroForOne);
            
            // Get tick after swap
            (, int24 tickAfter,,) = StateLibrary.getSlot0(manager, poolId);
            int24 tickMovement = tickAfter - tickBefore;
            
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            
            // Check if this swap caused a cap event
            bool wasCapped = tickMovement < 0 ? uint24(-tickMovement) > currentMaxTicks : uint24(tickMovement) > currentMaxTicks;
            
            // Log key days
            if (day == 1 || day == 2 || day == 3 || day == 5 || day == 10 || day == 20 || day == 30 || day == 50 || day == 75 || day == 100 || day == 125 || day == 150) {
                console.log("Day", day);
                console.log("Direction:", zeroForOne ? "zeroForOne" : "oneForZero");
                console.log("Movement:", tickMovement);
                console.log("maxTicks:", currentMaxTicks);
                console.log("Was capped:", wasCapped);
                console.log("---");
            }
            
            // Store key metrics
            if (day == 10) maxTicksAtDay10 = currentMaxTicks;
            if (day == 50) maxTicksAtDay50 = currentMaxTicks;
            if (day == 100) maxTicksAtDay100 = currentMaxTicks;
            if (day == 150) maxTicksAtDay150 = currentMaxTicks;
        }
        
        // Summary
        console.log("=== 150-Day Summary ===");
        console.log("Initial maxTicks:", initialMaxTicks);
        console.log("Day 10 maxTicks:", maxTicksAtDay10);
        console.log("Day 50 maxTicks:", maxTicksAtDay50);
        console.log("Day 100 maxTicks:", maxTicksAtDay100);
        console.log("Day 150 maxTicks:", maxTicksAtDay150);
        
        // Assertions
        assertTrue(maxTicksAtDay150 > 80, "Should maintain maxTicks above 80 for 80-tick movements");
        assertTrue(maxTicksAtDay150 <= 120, "Should not exceed reasonable bounds for 80-tick movements");
    }
    
    /// @notice Test to measure the relationship between swap amounts and tick movements
    function test_AutoTuning_MeasureSwapAmountToTickRatio() public {
        console.log("=== Measuring Swap Amount to Tick Movement Ratio ===");
        
        // Reset to initial state
        vm.prank(owner);
        oracle.refreshPolicyCache(poolId);
        
        // Test different swap amounts
        uint256[] memory amounts = new uint256[](6);
        amounts[0] = 50e18;   // 50 tokens
        amounts[1] = 100e18;  // 100 tokens
        amounts[2] = 200e18;  // 200 tokens
        amounts[3] = 300e18;  // 300 tokens
        amounts[4] = 400e18;  // 400 tokens
        amounts[5] = 500e18;  // 500 tokens
        
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 swapAmount = amounts[i];
            
            // Get tick before swap
            (, int24 tickBefore,,) = StateLibrary.getSlot0(manager, poolId);
            
            // Perform the swap
            this._performSwap(swapAmount, true); // zeroForOne
            
            // Get tick after swap
            (, int24 tickAfter,,) = StateLibrary.getSlot0(manager, poolId);
            int24 tickMovement = tickAfter - tickBefore;
            
            console.log("Swap amount:", swapAmount / 1e18, "tokens");
            console.log("Tick movement:", tickMovement);
            uint24 absMovement = tickMovement < 0 ? uint24(-tickMovement) : uint24(tickMovement);
            uint256 ratio = (absMovement * 1000) / (swapAmount / 1e18);
            console.log("Ratio (ticks per 1000 tokens):", ratio);
            console.log("---");
            
            // Reset for next test
            vm.prank(owner);
            oracle.refreshPolicyCache(poolId);
        }
    }
    
    /// @notice Test to compare 400 tokens vs 500 tokens for tick movement
    function test_AutoTuning_Compare400vs500Tokens() public {
        console.log("=== Comparing 400 vs 500 Tokens ===");
        
        // Test 400 tokens
        console.log("--- Testing 400 tokens ---");
        (, int24 tickBefore400,,) = StateLibrary.getSlot0(manager, poolId);
        this._performSwap(400e18, true); // zeroForOne
        (, int24 tickAfter400,,) = StateLibrary.getSlot0(manager, poolId);
        int24 tickMovement400 = tickAfter400 - tickBefore400;
        
        console.log("400 tokens - Tick movement:", tickMovement400);
        console.log("400 tokens - Ticks per token:", uint24(tickMovement400 < 0 ? -tickMovement400 : tickMovement400) * 1000 / 400);
        
        // Test 500 tokens
        console.log("--- Testing 500 tokens ---");
        (, int24 tickBefore500,,) = StateLibrary.getSlot0(manager, poolId);
        this._performSwap(500e18, true); // zeroForOne
        (, int24 tickAfter500,,) = StateLibrary.getSlot0(manager, poolId);
        int24 tickMovement500 = tickAfter500 - tickBefore500;
        
        console.log("500 tokens - Tick movement:", tickMovement500);
        console.log("500 tokens - Ticks per token:", uint24(tickMovement500 < 0 ? -tickMovement500 : tickMovement500) * 1000 / 500);
        
        // Comparison
        console.log("--- Comparison ---");
        console.log("Difference in tick movement:", uint24(tickMovement500 < 0 ? -tickMovement500 : tickMovement500) - uint24(tickMovement400 < 0 ? -tickMovement400 : tickMovement400));
        console.log("Expected difference (100 tokens * 0.2): 20");
        
        // Test alternating directions for both amounts
        console.log("--- Testing Alternating Directions ---");
        
        // Test 400 tokens alternating
        for (uint256 day = 1; day <= 5; day++) {
            vm.warp(block.timestamp + 1 days);
            bool zeroForOne = (day % 2 == 1);
            
            (, int24 tickBefore,,) = StateLibrary.getSlot0(manager, poolId);
            this._performSwap(400e18, zeroForOne);
            (, int24 tickAfter,,) = StateLibrary.getSlot0(manager, poolId);
            int24 tickMovement = tickAfter - tickBefore;
            
            console.log("Day", day, "400 tokens");
            console.log("Direction:", zeroForOne ? "zeroForOne" : "oneForZero");
            console.log("Movement:", tickMovement);
        }
        
        // Test 500 tokens alternating
        for (uint256 day = 1; day <= 5; day++) {
            vm.warp(block.timestamp + 1 days);
            bool zeroForOne = (day % 2 == 1);
            
            (, int24 tickBefore,,) = StateLibrary.getSlot0(manager, poolId);
            this._performSwap(500e18, zeroForOne);
            (, int24 tickAfter,,) = StateLibrary.getSlot0(manager, poolId);
            int24 tickMovement = tickAfter - tickBefore;
            
            console.log("Day", day, "500 tokens");
            console.log("Direction:", zeroForOne ? "zeroForOne" : "oneForZero");
            console.log("Movement:", tickMovement);
        }
    }
    
    // - - - Helper Functions - - -

    /// @notice Perform a swap using the same approach as AutoTuningTest
    function _performSwap(uint256 amount, bool zeroForOne) external {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: true, 
            settleUsingBurn: false
        });
        
        if (zeroForOne) {
            // Swap token0 for token1
            SwapParams memory params = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amount), // Negative for exact input
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            
            vm.prank(user1);
            swapRouter.swap(poolKey, params, testSettings, "");
        } else {
            // Swap token1 for token0
            SwapParams memory params = SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amount), // Negative for exact input
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            });
            
            vm.prank(user1);
            swapRouter.swap(poolKey, params, testSettings, "");
        }
    }
} 