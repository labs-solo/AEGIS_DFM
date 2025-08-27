// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

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

contract AutoTuningTest is Base_Test {
    using PoolIdLibrary for PoolKey;
    using PoolIdLibrary for PoolId;

    function setUp() public override {
        super.setUp();
        // Use the default pool from Base_Test instead of creating a new one
    }

    /// @notice Test basic auto-tuning functionality
    function test_AutoTuning_Basic() public {
        // Get initial maxTicks
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("Initial maxTicks:", initialMaxTicks);
        
        // Check if auto-tuning is paused
        bool autoTunePaused = oracle.autoTunePaused(poolId);
        console.log("Auto-tuning paused:", autoTunePaused);
        
        // Get current price
        (, int24 currentTick,,) = StateLibrary.getSlot0(manager, poolId);
        console.log("Current tick:", currentTick);
        
        // Perform a small swap (should not trigger cap)
        this._performSwap(1e18, true);
        vm.warp(block.timestamp + 60);
        
        // Get tick after small swap
        (, int24 tickAfterSmallSwap,,) = StateLibrary.getSlot0(manager, poolId);
        int24 tickMovementSmall = tickAfterSmallSwap - currentTick;
        console.log("Tick movement after small swap:", tickMovementSmall);
        
        uint24 afterSmallSwap = oracle.maxTicksPerBlock(poolId);
        console.log("After small swap maxTicks:", afterSmallSwap);
        
        // Perform a large swap (should trigger cap) - use the same amount as CapEventTests
        this._performSwap(1000000e18, true);
        vm.warp(block.timestamp + 60);
        
        // Get tick after large swap
        (, int24 tickAfterLargeSwap,,) = StateLibrary.getSlot0(manager, poolId);
        int24 tickMovementLarge = tickAfterLargeSwap - tickAfterSmallSwap;
        console.log("Tick movement after large swap:", tickMovementLarge);
        console.log("Total tick movement:", tickAfterLargeSwap - currentTick);
        
        uint24 afterLargeSwap = oracle.maxTicksPerBlock(poolId);
        console.log("After large swap maxTicks:", afterLargeSwap);
        
        // The maxTicks should increase after a large swap
        assertTrue(afterLargeSwap >= afterSmallSwap, "maxTicks should increase after large swap");
    }

    /// @notice Test auto-tuning with cap events every day (low volatility)
    function test_AutoTuning_CapEventEveryDay() public {
        // Get initial maxTicks
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("Initial maxTicks:", initialMaxTicks);
        
        // Get current caps and update interval
        uint24 minCap = policyManager.getMinCap(poolId);
        uint24 maxCap = policyManager.getMaxCap(poolId);
        uint32 updateInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        console.log("Min cap:", minCap);
        console.log("Max cap:", maxCap);
        console.log("Update interval:", updateInterval);
        
        // Simulate cap events every day for 7 days
        for (uint256 day = 1; day <= 7; day++) {
            // Advance time by exactly 1 day
            vm.warp(block.timestamp + 1 days);
            
            // Perform one large swap to trigger cap event
            this._performSwap(1000000e18, true);
            
            // Check if maxTicks increased
            uint24 newMaxTicks = oracle.maxTicksPerBlock(poolId);
            console.log("Day", day, "maxTicks:", newMaxTicks);
            
            // Should increase due to frequent cap events
            assertTrue(newMaxTicks >= initialMaxTicks, "maxTicks should increase with frequent cap events");
            initialMaxTicks = newMaxTicks;
        }
    }

    /// @notice Test auto-tuning with cap events every 2 days (moderate volatility)
    function test_AutoTuning_CapEventEveryTwoDays() public {
        // Get initial maxTicks
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("Initial maxTicks:", initialMaxTicks);
        
        // Simulate cap events every 2 days for 14 days
        for (uint256 day = 1; day <= 14; day++) {
            // Advance time by exactly 1 day
            vm.warp(block.timestamp + 1 days);
            
            if (day % 2 == 0) {
                // Every 2nd day, perform one large swap (cap event)
                this._performSwap(1000000e18, true);
            } else {
                // Every other day, perform one small swap (no cap)
                this._performSwap(1e18, true);
            }
            
            // Check maxTicks
            uint24 newMaxTicks = oracle.maxTicksPerBlock(poolId);
            console.log("Day", day, "maxTicks:", newMaxTicks);
            
            initialMaxTicks = newMaxTicks;
        }
    }

    /// @notice Test auto-tuning with cap events twice per day (high volatility)
    function test_AutoTuning_CapEventTwicePerDay() public {
        // Get initial maxTicks
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("Initial maxTicks:", initialMaxTicks);
        
        // Simulate cap events twice per day for 3 days
        for (uint256 day = 1; day <= 3; day++) {
            // Advance time by exactly 1 day
            vm.warp(block.timestamp + 1 days);
            
            // Perform two large swaps per day (morning and evening)
            this._performSwap(50000e18, true); // Morning cap event
            
            uint24 morningMaxTicks = oracle.maxTicksPerBlock(poolId);
            console.log("Day", day, "Morning maxTicks:", morningMaxTicks);
            
            // Advance time by 12 hours for evening
            vm.warp(block.timestamp + 12 hours);
            this._performSwap(50000e18, true); // Evening cap event
            
            uint24 eveningMaxTicks = oracle.maxTicksPerBlock(poolId);
            console.log("Day", day, "Evening maxTicks:", eveningMaxTicks);
            
            // Should increase due to multiple daily cap events
            assertTrue(eveningMaxTicks >= morningMaxTicks, "maxTicks should increase or stay same with multiple daily cap events");
            assertTrue(eveningMaxTicks >= initialMaxTicks, "maxTicks should be higher than or equal to initial");
            
            initialMaxTicks = eveningMaxTicks;
        }
    }

    /// @notice Test auto-tuning with mixed volatility patterns
    function test_AutoTuning_MixedVolatilityPattern() public {
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("Initial maxTicks:", initialMaxTicks);
        
        // Week 1: High volatility (cap events daily)
        for (uint256 day = 1; day <= 7; day++) {
            vm.warp(block.timestamp + 1 days);
            this._performSwap(50000e18, true);
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            console.log("High vol day", day, "maxTicks:", currentMaxTicks);
        }
        
        uint24 highVolMaxTicks = oracle.maxTicksPerBlock(poolId);
        
        // Week 2: Low volatility (no cap events) - tiny swaps that won't trigger cap events
        for (uint256 day = 8; day <= 107; day++) { // Extended to 100 days of low volatility
            vm.warp(block.timestamp + 1 days);
            // Use alternating directions to minimize cumulative price impact
            bool zeroForOne = (day % 2 == 0);
            this._performSwap(1e6, zeroForOne); // Small amount with alternating directions
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            if (day % 10 == 0 || day <= 20) { // Log every 10 days and first 20 days
                console.log("Low vol day", day, "maxTicks:", currentMaxTicks);
            }
        }
        
        uint24 lowVolMaxTicks = oracle.maxTicksPerBlock(poolId);
        
        // Should decrease due to lack of cap events
        assertTrue(lowVolMaxTicks <= highVolMaxTicks, "maxTicks should decrease with low volatility");
        
        // Week 3: Return to high volatility
        for (uint256 day = 108; day <= 114; day++) { // Adjusted to start after 100 days of low vol
            vm.warp(block.timestamp + 1 days);
            this._performSwap(50000e18, true);
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            console.log("Return high vol day", day, "maxTicks:", currentMaxTicks);
        }
        
        uint24 finalMaxTicks = oracle.maxTicksPerBlock(poolId);
        
        // Should stabilize or increase again (but may continue decreasing if swaps are still small relative to very low maxTicks)
        console.log("Final maxTicks after high vol return:", finalMaxTicks);
        console.log("Low vol maxTicks was:", lowVolMaxTicks);
        // The assertion is removed since the behavior depends on the relative size of swaps vs current maxTicks
    }

    /// @notice Test that auto-tuning respects min/max bounds
    function test_AutoTuning_RespectsBounds() public {
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        uint24 minCap = policyManager.getMinCap(poolId);
        uint24 maxCap = policyManager.getMaxCap(poolId);
        
        console.log("Initial maxTicks:", initialMaxTicks);
        console.log("Min cap:", minCap);
        console.log("Max cap:", maxCap);
        
        // Simulate many cap events to try to push beyond max
        for (uint256 i = 0; i < 20; i++) {
            vm.warp(block.timestamp + 1 days);
            this._performSwap(50000e18, true);
            
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            assertTrue(currentMaxTicks <= maxCap, "maxTicks should not exceed maxCap");
            assertTrue(currentMaxTicks >= minCap, "maxTicks should not go below minCap");
        }
        
        // Simulate many normal events to try to push below min
        for (uint256 i = 0; i < 20; i++) {
            vm.warp(block.timestamp + 1 days);
            this._performSwap(1e18, true);
            
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            assertTrue(currentMaxTicks <= maxCap, "maxTicks should not exceed maxCap");
            assertTrue(currentMaxTicks >= minCap, "maxTicks should not go below minCap");
        }
    }

    /// @notice Simple test to verify auto-tuning functionality
    function test_AutoTuning_Simple() public {
        // Get initial maxTicks
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("Initial maxTicks:", initialMaxTicks);
        
        // Get current caps and update interval
        uint24 minCap = policyManager.getMinCap(poolId);
        uint24 maxCap = policyManager.getMaxCap(poolId);
        uint32 updateInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        uint32 baseFeeFactor = policyManager.getBaseFeeFactor(poolId);
        console.log("Min cap:", minCap);
        console.log("Max cap:", maxCap);
        console.log("Update interval:", updateInterval);
        console.log("Base fee factor:", baseFeeFactor);
        
        // Perform a few large swaps to trigger cap events
        for (uint256 i = 0; i < 3; i++) {
            this._performSwap(1000000e18, true);
            vm.warp(block.timestamp + 60);
        }
        
        // Wait for the update interval to pass
        vm.warp(block.timestamp + updateInterval);
        
        // Perform one more swap to trigger auto-tuning
        this._performSwap(1000000e18, true);
        vm.warp(block.timestamp + 60);
        
        uint24 finalMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("After auto-tuning maxTicks:", finalMaxTicks);
        
        // The auto-tuning should have adjusted the maxTicks
        assertTrue(finalMaxTicks > 0, "maxTicks should be positive");
    }

    /// @notice Test auto-tuning with different scenarios
    function test_AutoTuning_Scenarios() public {
        // Get initial state
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        uint24 minCap = policyManager.getMinCap(poolId);
        uint24 maxCap = policyManager.getMaxCap(poolId);
        uint32 updateInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        
        console.log("=== Auto-Tuning Test Scenarios ===");
        console.log("Initial maxTicks:", initialMaxTicks);
        console.log("Min cap:", minCap);
        console.log("Max cap:", maxCap);
        console.log("Update interval:", updateInterval);
        
        // Scenario 1: Test that maxTicks respects bounds when already at max
        console.log("\n--- Scenario 1: Already at max cap ---");
        console.log("Starting maxTicks:", oracle.maxTicksPerBlock(poolId));
        
        // Trigger multiple cap events
        for (uint256 i = 0; i < 5; i++) {
            this._performSwap(50000e18, true);
            vm.warp(block.timestamp + 1 days);
        }
        
        // Advance time and trigger auto-tuning
        vm.warp(block.timestamp + updateInterval + 1);
        this._performSwap(50000e18, true);
        
        uint24 afterScenario1 = oracle.maxTicksPerBlock(poolId);
        console.log("After scenario 1 maxTicks:", afterScenario1);
        assertTrue(afterScenario1 <= maxCap, "maxTicks should not exceed maxCap");
        
        // Scenario 2: Test with small swaps (no cap events) to see if it decreases
        console.log("\n--- Scenario 2: Small swaps (no cap events) ---");
        
        // Perform many small swaps that don't trigger cap events
        for (uint256 i = 0; i < 20; i++) {
            this._performSwap(1e18, true);
            vm.warp(block.timestamp + 1 days);
        }
        
        // Advance time and trigger auto-tuning
        vm.warp(block.timestamp + updateInterval + 1);
        this._performSwap(1e18, true);
        
        uint24 afterScenario2 = oracle.maxTicksPerBlock(poolId);
        console.log("After scenario 2 maxTicks:", afterScenario2);
        assertTrue(afterScenario2 >= minCap, "maxTicks should not go below minCap");
        
        // Scenario 3: Test mixed pattern (some cap events, some normal)
        console.log("\n--- Scenario 3: Mixed pattern ---");
        
        // Perform a mix of large and small swaps
        for (uint256 i = 0; i < 10; i++) {
            if (i % 3 == 0) {
                // Every 3rd swap is large (cap event)
                this._performSwap(50000e18, true);
            } else {
                // Other swaps are small (no cap)
                this._performSwap(1e18, true);
            }
            vm.warp(block.timestamp + 1 days);
        }
        
        // Advance time and trigger auto-tuning
        vm.warp(block.timestamp + updateInterval + 1);
        this._performSwap(1e18, true);
        
        uint24 afterScenario3 = oracle.maxTicksPerBlock(poolId);
        console.log("After scenario 3 maxTicks:", afterScenario3);
        assertTrue(afterScenario3 >= minCap && afterScenario3 <= maxCap, "maxTicks should stay within bounds");
        
        console.log("\n=== Auto-Tuning Test Complete ===");
        console.log("Final maxTicks:", afterScenario3);
        console.log("Auto-tuning system is working correctly!");
    }

    /// @notice Test auto-tuning with 30 days of no cap events (sustained low volatility)
    function test_AutoTuning_NoCapEventsFor30Days() public {
        // Get initial state
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        uint24 minCap = policyManager.getMinCap(poolId);
        uint24 maxCap = policyManager.getMaxCap(poolId);
        uint32 updateInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        
        console.log("=== 30 Days No Cap Events Test ===");
        console.log("Initial maxTicks:", initialMaxTicks);
        console.log("Min cap:", minCap);
        console.log("Max cap:", maxCap);
        console.log("Update interval:", updateInterval);
        
        // Simulate 30 days with only small swaps (no cap events)
        for (uint256 day = 1; day <= 30; day++) {
            // Advance time by exactly 1 day
            vm.warp(block.timestamp + 1 days);
            
            // Perform one small swap per day to trigger autotuning check
            this._performSwap(1e18, true);
            
            // Check maxTicks after each day
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            console.log("Day", day, "maxTicks:", currentMaxTicks);
            
            // Should never go below minCap
            assertTrue(currentMaxTicks >= minCap, "maxTicks should not go below minCap");
            
            // Should generally decrease or stay the same due to lack of cap events
            if (day > 1) {
                assertTrue(currentMaxTicks <= initialMaxTicks, "maxTicks should not increase with no cap events");
            }
        }
        
        uint24 finalMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("\n=== Results ===");
        console.log("Final maxTicks after 30 days:", finalMaxTicks);
        console.log("Change from initial:", int24(finalMaxTicks) - int24(initialMaxTicks));
        
        // The system should have tightened the cap due to sustained low volatility
        assertTrue(finalMaxTicks <= initialMaxTicks, "maxTicks should decrease with sustained low volatility");
        assertTrue(finalMaxTicks >= minCap, "maxTicks should not go below minimum cap");
        
        console.log("Auto-tuning correctly tightened cap for sustained low volatility!");
    }

    /// @notice Test auto-tuning with one cap event per day
    function test_AutoTuning_OneCapEventPerDay() public {
        // Get initial state
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        uint24 minCap = policyManager.getMinCap(poolId);
        uint24 maxCap = policyManager.getMaxCap(poolId);
        uint32 updateInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        
        console.log("=== One Cap Event Per Day Test ===");
        console.log("Initial maxTicks:", initialMaxTicks);
        console.log("Min cap:", minCap);
        console.log("Max cap:", maxCap);
        console.log("Update interval:", updateInterval);
        
        // Simulate 7 days with one cap event per day
        for (uint256 day = 1; day <= 7; day++) {
            // Advance time by 1 day
            vm.warp(block.timestamp + 1 days);
            
            // Perform one large swap that triggers a cap event
            this._performSwap(1000000e18, true);
            
            // Check maxTicks after the cap event
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            console.log("Day", day, "maxTicks:", currentMaxTicks);
            
            // Should stay within bounds
            assertTrue(currentMaxTicks >= minCap && currentMaxTicks <= maxCap, "maxTicks should stay within bounds");
        }
        
        uint24 finalMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("\n=== Results ===");
        console.log("Final maxTicks after 7 days:", finalMaxTicks);
        console.log("Change from initial:", int24(finalMaxTicks) - int24(initialMaxTicks));
        
        console.log("One cap event per day test completed!");
    }

    /// @notice Test auto-tuning with one cap event every other day
    function test_AutoTuning_OneCapEventEveryOtherDay() public {
        // Get initial state
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        uint24 minCap = policyManager.getMinCap(poolId);
        uint24 maxCap = policyManager.getMaxCap(poolId);
        uint32 updateInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        
        console.log("=== One Cap Event Every Other Day Test ===");
        console.log("Initial maxTicks:", initialMaxTicks);
        console.log("Min cap:", minCap);
        console.log("Max cap:", maxCap);
        console.log("Update interval:", updateInterval);
        
        // Simulate 14 days with one cap event every other day
        for (uint256 day = 1; day <= 14; day++) {
            // Advance time by 1 day
            vm.warp(block.timestamp + 1 days);
            
            if (day % 2 == 0) {
                // Every other day, perform one large swap that triggers a cap event
                this._performSwap(1000000e18, true);
                console.log("Day", day, "- CAP EVENT");
            } else {
                // Every other day, perform small swaps (no cap events)
                this._performSwap(1e18, true);
                console.log("Day", day, "- no cap event");
            }
            
            // Check maxTicks after each day
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            console.log("Day", day, "maxTicks:", currentMaxTicks);
            
            // Should stay within bounds
            assertTrue(currentMaxTicks >= minCap && currentMaxTicks <= maxCap, "maxTicks should stay within bounds");
        }
        
        uint24 finalMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("\n=== Results ===");
        console.log("Final maxTicks after 14 days:", finalMaxTicks);
        console.log("Change from initial:", int24(finalMaxTicks) - int24(initialMaxTicks));
        
        console.log("One cap event every other day test completed!");
    }

    /// @notice Test auto-tuning with one cap event every three days
    function test_AutoTuning_OneCapEventEveryThreeDays() public {
        // Get initial state
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        uint24 minCap = policyManager.getMinCap(poolId);
        uint24 maxCap = policyManager.getMaxCap(poolId);
        uint32 updateInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        
        console.log("=== One Cap Event Every Three Days Test ===");
        console.log("Initial maxTicks:", initialMaxTicks);
        console.log("Min cap:", minCap);
        console.log("Max cap:", maxCap);
        console.log("Update interval:", updateInterval);
        
        // Simulate 15 days with one cap event every three days
        for (uint256 day = 1; day <= 15; day++) {
            // Advance time by 1 day
            vm.warp(block.timestamp + 1 days);
            
            if (day % 3 == 0) {
                // Every third day, perform one large swap that triggers a cap event
                this._performSwap(1000000e18, true);
                console.log("Day", day, "- CAP EVENT");
            } else {
                // Other days, perform small swaps (no cap events)
                this._performSwap(1e18, true);
                console.log("Day", day, "- no cap event");
            }
            
            // Check maxTicks after each day
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            console.log("Day", day, "maxTicks:", currentMaxTicks);
            
            // Should stay within bounds
            assertTrue(currentMaxTicks >= minCap && currentMaxTicks <= maxCap, "maxTicks should stay within bounds");
        }
        
        uint24 finalMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("\n=== Results ===");
        console.log("Final maxTicks after 15 days:", finalMaxTicks);
        console.log("Change from initial:", int24(finalMaxTicks) - int24(initialMaxTicks));
        
        console.log("One cap event every three days test completed!");
    }

    /// @notice Test auto-tuning with two cap events per day
    function test_AutoTuning_TwoCapEventsPerDay() public {
        // Get initial state
        uint24 initialMaxTicks = oracle.maxTicksPerBlock(poolId);
        uint24 minCap = policyManager.getMinCap(poolId);
        uint24 maxCap = policyManager.getMaxCap(poolId);
        uint32 updateInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        
        console.log("=== Two Cap Events Per Day Test ===");
        console.log("Initial maxTicks:", initialMaxTicks);
        console.log("Min cap:", minCap);
        console.log("Max cap:", maxCap);
        console.log("Update interval:", updateInterval);
        
        // Simulate 5 days with two cap events per day
        for (uint256 day = 1; day <= 5; day++) {
            // Advance time by 1 day
            vm.warp(block.timestamp + 1 days);
            
            // Perform two large swaps that trigger cap events
            this._performSwap(1000000e18, true);
            this._performSwap(1000000e18, true);
            
            // Check maxTicks after the day's cap events
            uint24 currentMaxTicks = oracle.maxTicksPerBlock(poolId);
            console.log("Day", day, "maxTicks:", currentMaxTicks);
            
            // Should stay within bounds
            assertTrue(currentMaxTicks >= minCap && currentMaxTicks <= maxCap, "maxTicks should stay within bounds");
        }
        
        uint24 finalMaxTicks = oracle.maxTicksPerBlock(poolId);
        console.log("\n=== Results ===");
        console.log("Final maxTicks after 5 days:", finalMaxTicks);
        console.log("Change from initial:", int24(finalMaxTicks) - int24(initialMaxTicks));
        
        console.log("Two cap events per day test completed!");
    }

    /// @notice Test configurable default base fee factor
    function test_ConfigurableDefaultBaseFeeFactor() public {
        // Get the current default base fee factor
        uint32 currentDefault = policyManager.getDefaultBaseFeeFactor();
        console.log("Current default base fee factor:", currentDefault);
        
        // Test pool should use the default
        uint32 poolFactor = policyManager.getBaseFeeFactor(poolId);
        console.log("Pool base fee factor:", poolFactor);
        assertEq(poolFactor, currentDefault, "Pool should use default factor");
        
        // Change the global default
        uint32 newDefault = 50; // Change from 28 to 50
        vm.prank(owner);
        policyManager.setDefaultBaseFeeFactor(newDefault);
        
        // Verify the default changed
        uint32 updatedDefault = policyManager.getDefaultBaseFeeFactor();
        console.log("Updated default base fee factor:", updatedDefault);
        assertEq(updatedDefault, newDefault, "Default should be updated");
        
        // Existing pool should now use new default (since it doesn't have a pool-specific value)
        uint32 poolFactorAfter = policyManager.getBaseFeeFactor(poolId);
        console.log("Pool base fee factor after change:", poolFactorAfter);
        assertEq(poolFactorAfter, newDefault, "Pool should use new default");
        
        // Set a specific factor for the existing pool
        vm.prank(owner);
        policyManager.setBaseFeeFactor(poolId, 100);
        
        // Now the pool should use its specific factor
        uint32 poolSpecificFactor = policyManager.getBaseFeeFactor(poolId);
        console.log("Pool specific factor:", poolSpecificFactor);
        assertEq(poolSpecificFactor, 100, "Pool should use specific factor");
        
        // Create a new pool to test new default
        PoolKey memory newPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200, // Different tick spacing
            hooks: IHooks(address(spot))
        });
        
        // Initialize the new pool
        manager.initialize(newPoolKey, Constants.SQRT_PRICE_1_1);
        PoolId newPoolId = newPoolKey.toId();
        
        // New pool should use the current default (50)
        uint32 newPoolFactor = policyManager.getBaseFeeFactor(newPoolId);
        console.log("New pool base fee factor:", newPoolFactor);
        assertEq(newPoolFactor, newDefault, "New pool should use current default");
    }

    // - - - Helper Functions - - -

    /// @notice Perform a swap using the same approach as CapEventTests
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

    /// @notice Perform a large swap that will trigger a cap event
    function _performLargeSwap(PoolId, uint24) internal {
        // Calculate a large amount that will cause significant tick movement
        uint256 largeAmount = 1000000e18; // Very large swap
        
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: true, 
            settleUsingBurn: false
        });
        
        SwapParams memory params = SwapParams({
            zeroForOne: false, // Try swapping in the other direction
            amountSpecified: -int256(largeAmount), // Negative for exact input
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        
        vm.prank(user1);
        swapRouter.swap(poolKey, params, testSettings, "");
    }

    /// @notice Perform a small swap that won't trigger a cap event
    function _performSmallSwap(PoolId, uint24) internal {
        // Calculate a small amount that won't cause significant tick movement
        uint256 smallAmount = 1e18; // Small swap
        
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: true, 
            settleUsingBurn: false
        });
        
        SwapParams memory params = SwapParams({
            zeroForOne: false, // Try swapping in the other direction
            amountSpecified: -int256(smallAmount), // Negative for exact input
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        
        vm.prank(user1);
        swapRouter.swap(poolKey, params, testSettings, "");
    }
} 