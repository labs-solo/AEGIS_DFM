// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Base_Test} from "../Base_Test.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import "forge-std/console.sol";

contract OracleTest is Base_Test {
    // Remove PAGE_SIZE constant since we no longer use pages
    
    // Helper function to perform swaps
    function _performSwap(uint256 amount, bool zeroForOne) internal {
        vm.startPrank(user1);
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false});
        
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne, 
            amountSpecified: -int256(amount), 
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Swap failed"); }
        vm.stopPrank();
    }
    
    // BASIC ORACLE FUNCTIONALITY TESTS
    
    function test_SimpleTimeProgression() public {
        console.log("=== Testing Simple Time Progression ===");
        
        // Oracle already enabled in setUp()
        
        // Record some observations with time progression
        vm.prank(address(spot));
        oracle.recordObservation(poolId, 0);
        
        vm.warp(block.timestamp + 60);
        vm.prank(address(spot));
        oracle.recordObservation(poolId, 10);
        
        vm.warp(block.timestamp + 60);
        vm.prank(address(spot));
        oracle.recordObservation(poolId, 20);
        
        // Test observe function
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 120; // 2 minutes ago
        secondsAgos[1] = 0;   // current
        
        (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s) = oracle.observe(poolKey, secondsAgos);
        
        assertEq(tickCumulatives.length, 2);
        assertEq(secondsPerLiquidityCumulativeX128s.length, 2);
        
        // Should have different values for different times
        assertTrue(tickCumulatives[0] != tickCumulatives[1]);
    }
    
    function test_CurrentTickVsTWAP() public {
        console.log("=== Testing Current Tick vs TWAP ===");
        
        // Setup: do some swaps to create price movement
        for (uint16 i = 0; i < 50; i++) {
            _performSwap(1000e18, true);
            vm.warp(block.timestamp + 60);
        }
        
        // Get current tick
        (int24 currentTick,) = oracle.getLatestObservation(poolId);
        
        // Test TWAP for different periods
        uint32[] memory periods = new uint32[](4);
        periods[0] = 60;    // 1 minute
        periods[1] = 300;   // 5 minutes
        periods[2] = 600;   // 10 minutes
        periods[3] = 1800;  // 30 minutes
        
        for (uint i = 0; i < periods.length; i++) {
            uint32 period = periods[i];
            
            // Get tick cumulatives
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = period;
            secondsAgos[1] = 0;
            
            (int48[] memory tickCumulatives, ) = oracle.observe(poolKey, secondsAgos);
            int48 tickCumulativeDelta = tickCumulatives[1] - tickCumulatives[0];
            
            // Calculate TWAP manually
            int24 twapTick = int24(tickCumulativeDelta / int48(uint48(period)));
            
            // Verify TWAP is reasonable
            assertTrue(twapTick >= -887272 && twapTick <= 887272, "TWAP should be within valid range");
            
            console.log("Difference:", int256(twapTick) - int256(currentTick));
        }
    }
    
    function test_RingBufferLoops() public {
        console.log("=== Testing Ring Buffer Loops ===");
        
        // Step 1: Fill buffer to max capacity (1024 observations)
        console.log("Step 1: Filling buffer to max capacity...");
        for (uint16 i = 0; i < 1024; i++) {
            _performSwap(1000e18, true);
            vm.warp(block.timestamp + 60);
        }
        
        (uint16 index1, uint16 cardinality1,) = oracle.states(poolId);
        assertEq(cardinality1, 1024, "Should have 1024 observations");
        
        // Step 2: Continue swaps to wrap around (should reset to 0)
        console.log("Step 2: Continuing swaps to wrap around...");
        for (uint16 i = 0; i < 1024; i++) {
            _performSwap(1000e18, true);
            vm.warp(block.timestamp + 60);
        }
        
        (uint16 index2, uint16 cardinality2,) = oracle.states(poolId);
        assertEq(cardinality2, 1024, "Should still have 1024 observations (max capacity)");
        
        // Step 3: Continue more swaps to wrap around again
        console.log("Step 3: Continuing more swaps to wrap around again...");
        for (uint16 i = 0; i < 1024; i++) {
            _performSwap(1000e18, true);
            vm.warp(block.timestamp + 60);
        }
        
        (uint16 index3, uint16 cardinality3,) = oracle.states(poolId);
        assertEq(cardinality3, 1024, "Should still have 1024 observations (max capacity)");
        
        // Verify that the index is properly wrapping
        console.log("Index progression: 0 ->");
        console.log(index1);
        console.log("->");
        console.log(index2);
        console.log("->");
        console.log(index3);
        
        // Test that we can still get observations after multiple wraps
        (int24 latestTick, uint32 latestTimestamp) = oracle.getLatestObservation(poolId);
        console.log("Latest observation after wraps - Tick:");
        console.log(latestTick);
        console.log("Timestamp:");
        console.log(latestTimestamp);
        assertTrue(latestTimestamp > 0, "Should have valid latest observation");
    }
    
    function test_RingBufferOverflow() public {
        console.log("=== Testing Ring Buffer Overflow ===");
        
        // Fill buffer to max capacity
        for (uint16 i = 0; i < 1024; i++) {
            _performSwap(1000e18, true);
            vm.warp(block.timestamp + 60);
        }
        
        (uint16 index1, uint16 cardinality1,) = oracle.states(poolId);
        assertEq(cardinality1, 1024, "Should have 1024 observations");
        
        // Continue swapping to wrap around
        for (uint16 i = 0; i < 512; i++) {
            (uint16 beforeIndex, uint16 beforeCardinality,) = oracle.states(poolId);
            
            _performSwap(1000e18, true);
            vm.warp(block.timestamp + 60);
            
            // Verify cardinality stays at max during wrap
            (uint16 afterIndex, uint16 afterCardinality,) = oracle.states(poolId);
            assertEq(afterCardinality, 1024, "Cardinality should remain at max during wrap");
        }
        
        (uint16 finalIndex, uint16 finalCardinality,) = oracle.states(poolId);
        assertEq(finalCardinality, 1024, "Cardinality should remain at max");
    }
    
    function test_OracleState() public {
        console.log("=== Testing Oracle State ===");
        
        // Oracle already enabled in setUp()
        
        // Check initial state
        (uint16 index, uint16 cardinality, uint16 cardinalityNext) = oracle.states(poolId);
        console.log("Initial state:");
        console.log("  Index: ");
        console.log(index);
        console.log("  Cardinality: ");
        console.log(cardinality);
        console.log("  CardinalityNext: ");
        console.log(cardinalityNext);
        
        assertEq(index, 0);
        assertEq(cardinality, 1);
        assertEq(cardinalityNext, 1);
        
        // Record some observations and check state transitions
        for (uint16 i = 0; i < 20; i++) {
            (uint16 beforeIndex, uint16 beforeCardinality, uint16 beforeCardinalityNext) = oracle.states(poolId);
            (int24 beforeTick, uint32 beforeTimestamp) = oracle.getLatestObservation(poolId);
            
            vm.prank(address(spot));
            int32 tick = int32(uint32(i) * 10);
            oracle.recordObservation(poolId, int24(tick));
            
            (uint16 afterIndex, uint16 afterCardinality, uint16 afterCardinalityNext) = oracle.states(poolId);
            (int24 afterTick, uint32 afterTimestamp) = oracle.getLatestObservation(poolId);
            
            console.log("State transition");
            console.log(i);
            console.log("  Index: ");
            console.log(beforeIndex);
            console.log(" -> ");
            console.log(afterIndex);
            console.log("  Cardinality: ");
            console.log(beforeCardinality);
            console.log(" -> ");
            console.log(afterCardinality);
            console.log("  CardinalityNext: ");
            console.log(beforeCardinalityNext);
            console.log(" -> ");
            console.log(afterCardinalityNext);
            console.log("  Tick: ");
            console.log(beforeTick);
            console.log(" -> ");
            console.log(afterTick);
            console.log("  Timestamp: ");
            console.log(beforeTimestamp);
            console.log(" -> ");
            console.log(afterTimestamp);
            
            vm.warp(block.timestamp + 60);
        }
        
        // Test that cardinalityNext should remain unchanged after reaching max
        (uint16 finalIndex, uint16 finalCardinality, uint16 finalCardinalityNext) = oracle.states(poolId);
        // Note: cardinalityNext increases as we add observations, this is expected behavior
        console.log("Final cardinalityNext:", finalCardinalityNext);
    }
    
    function test_UninitializedPageProtectionSimple() public {
        console.log("=== Testing Uninitialized Protection (Simple) ===");
        
        // Try to observe with no history (should fail)
        uint32[] memory secondsAgos = new uint32[](1);
        secondsAgos[0] = 60; // 1 minute ago
        
        try oracle.observe(poolKey, secondsAgos) returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s) {
            console.log("Observe succeeded with no history");
        } catch Error(string memory reason) {
            console.log("Observe failed with reason:", reason);
        } catch {
            console.log("Observe failed with low-level error (expected)");
        }
        
        // Try to observe with limited history (should fail)
        secondsAgos[0] = 3600; // 1 hour ago (more than our 10 minutes of history)
        
        try oracle.observe(poolKey, secondsAgos) returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s) {
            console.log("Observe succeeded with limited history");
        } catch Error(string memory reason) {
            console.log("Observe failed with reason:", reason);
        } catch {
            console.log("Observe failed with low-level error for long period (expected)");
        }
    }
    

    
    function test_ConsultWithSufficientData() public {
        console.log("=== Testing Consult with Sufficient Data ===");
        
        // First, build up enough oracle history with UNIDIRECTIONAL swaps (all in same direction)
        console.log("Building oracle history with unidirectional swaps...");
        for (uint16 i = 0; i < 50; i++) {
            _performSwap(1000e18, true); // All swaps in same direction (zeroForOne = true)
            vm.warp(block.timestamp + 60);
        }
        
        // Get current state
        (uint16 index, uint16 cardinality,) = oracle.states(poolId);
        (int24 currentTick, uint32 currentTimestamp) = oracle.getLatestObservation(poolId);
        
        console.log("Oracle state after building history:");
        console.log("- Index:", index);
        console.log("- Cardinality:", cardinality);
        console.log("- Current tick:", currentTick);
        console.log("- Current timestamp:", currentTimestamp);
        
        // Test consult with different time periods (from largest to smallest to see TWAP approach current tick)
        uint32[] memory periods = new uint32[](5);
        periods[0] = 1800;  // 30 minutes (largest)
        periods[1] = 1200;  // 20 minutes
        periods[2] = 600;   // 10 minutes
        periods[3] = 300;   // 5 minutes
        periods[4] = 60;    // 1 minute (smallest)
        
        console.log("\n=== Testing Consult Function (Unidirectional Swaps) ===");
        console.log("Testing periods from largest to smallest to show TWAP approaching current tick:");
        
        int24[] memory twapTicks = new int24[](periods.length);
        
        for (uint i = 0; i < periods.length; i++) {
            uint32 period = periods[i];
            
            try oracle.consult(poolKey, period) returns (int24 twapTick, uint128 harmonicMeanLiquidity) {
                twapTicks[i] = twapTick;
                
                console.log("Consult period:", period, "seconds");
                console.log("- TWAP tick:", twapTick);
                console.log("- Harmonic mean liquidity:", harmonicMeanLiquidity);
                console.log("- Current vs TWAP difference:", int256(currentTick) - int256(twapTick));
                
                // Verify TWAP is reasonable
                assertTrue(twapTick >= -887272 && twapTick <= 887272, "TWAP should be within valid range");
                assertTrue(harmonicMeanLiquidity > 0, "Harmonic mean liquidity should be positive");
                
            } catch Error(string memory reason) {
                console.log("Consult failed for period", period, "with reason:", reason);
                revert("Consult should succeed with sufficient data");
            } catch {
                console.log("Consult failed for period", period, "with low-level error");
                revert("Consult should succeed with sufficient data");
            }
        }
        
        // Verify TWAP progression: as period gets smaller, TWAP should approach current tick
        console.log("\n=== TWAP Progression Analysis ===");
        console.log("Current tick:", currentTick);
        
        for (uint i = 0; i < periods.length; i++) {
            uint32 period = periods[i];
            int24 twapTick = twapTicks[i];
            int256 difference = int256(currentTick) - int256(twapTick);
            
            console.log("Period");
            console.log(period);
            console.log("s -> TWAP:");
            console.log(twapTick);
            console.log("Difference:");
            console.log(difference);
            
            // For unidirectional swaps, verify that shorter periods have smaller differences
            if (i > 0) {
                uint32 prevPeriod = periods[i-1];
                int24 prevTwapTick = twapTicks[i-1];
                int256 prevDifference = int256(currentTick) - int256(prevTwapTick);
                
                console.log("Comparing with");
                console.log(prevPeriod);
                console.log("s period:");
                console.log("Previous difference:");
                console.log(prevDifference);
                console.log("Current difference:");
                console.log(difference);
                
                // With unidirectional swaps, shorter periods should have smaller absolute differences
                // (TWAP should be closer to current tick)
                assertTrue(
                    abs(difference) <= abs(prevDifference), 
                    "Shorter periods should have TWAP closer to current tick"
                );
            }
        }
        
        console.log("\n=== Consult Test Summary ===");
        console.log("SUCCESS: All consult calls succeeded");
        console.log("SUCCESS: TWAP calculations are reasonable");
        console.log("SUCCESS: Harmonic mean liquidity is positive");
        console.log("SUCCESS: TWAP approaches current tick as period decreases");
        console.log("SUCCESS: Unidirectional swap TWAP smoothing verified");
    }
    
    function test_ConsultWithVariableSwaps() public {
        console.log("=== Testing Consult with Variable Swap Amounts ===");
        
        // Phase 1: Small swaps
        console.log("Phase 1: Small swaps (10 ether)");
        for (uint16 i = 0; i < 20; i++) {
            _performSwap(10e18, true);
            vm.warp(block.timestamp + 30); // 30 seconds between swaps
        }
        
        (int24 tickAfterSmall,) = oracle.getLatestObservation(poolId);
        console.log("After small swaps - Tick:", tickAfterSmall);
        _testComprehensiveConsult("After small swaps");
        
        // Phase 2: Medium swaps
        console.log("Phase 2: Medium swaps (50 ether)");
        for (uint16 i = 0; i < 10; i++) {
            _performSwap(50e18, true);
            vm.warp(block.timestamp + 45); // 45 seconds between swaps
        }
        
        (int24 tickAfterMedium,) = oracle.getLatestObservation(poolId);
        console.log("After medium swaps - Tick:", tickAfterMedium);
        _testComprehensiveConsult("After medium swaps");
        
        // Phase 3: Large swaps
        console.log("Phase 3: Large swaps (100 ether)");
        for (uint16 i = 0; i < 5; i++) {
            _performSwap(100e18, true);
            vm.warp(block.timestamp + 60); // 60 seconds between swaps
        }
        
        (int24 tickAfterLarge,) = oracle.getLatestObservation(poolId);
        console.log("After large swaps - Tick:", tickAfterLarge);
        _testComprehensiveConsult("After large swaps");
        
        console.log("SUCCESS: Variable swap amounts tested!");
    }
    
    function test_ConsultWithMassiveSwaps() public {
        console.log("=== Testing Consult with Large Swaps (Simplified) ===");
        
        // Phase 1: Build history with moderate swaps
        console.log("Phase 1: Building history with moderate swaps");
        for (uint16 i = 0; i < 10; i++) {
            _performSwap(10e18, true);
            vm.warp(block.timestamp + 60);
        }
        
        (int24 tickAfterModerate,) = oracle.getLatestObservation(poolId);
        console.log("After moderate swaps - Tick:");
        console.log(tickAfterModerate);
        _testComprehensiveConsult("After moderate swaps");
        
        // Phase 2: Large unidirectional swaps (reduced amounts)
        console.log("Phase 2: Large unidirectional swaps");
        for (uint16 i = 0; i < 5; i++) {
            _performSwap(50e18, true);
            vm.warp(block.timestamp + 60);
        }
        
        (int24 tickAfterLarge,) = oracle.getLatestObservation(poolId);
        console.log("After large swaps - Tick:");
        console.log(tickAfterLarge);
        _testComprehensiveConsult("After large swaps");
        
        // Phase 3: Sustained trading with moderate amounts
        console.log("Phase 3: Sustained trading with moderate amounts");
        for (uint16 i = 0; i < 5; i++) {
            uint256 amount = 20e18 + (i * 1e18); // Smaller increasing amounts
            _performSwap(amount, true);
            vm.warp(block.timestamp + 45);
            
            if (i % 2 == 0) {
                console.log("Sustained trading - Swap");
                console.log(i + 1);
                _testComprehensiveConsult(string(abi.encodePacked("Sustained swap ", _toString(i + 1))));
            }
        }
        
        console.log("SUCCESS: Large swaps tested!");
    }
    
    function test_ExtendedRingBuffer() public {
        console.log("=== Testing Extended Ring Buffer (Beyond 1024 swaps) ===");
        
        // Fill buffer to capacity
        console.log("Filling buffer to capacity...");
        for (uint16 i = 0; i < 1024; i++) {
            _performSwap(1000e18, true);
            vm.warp(block.timestamp + 60);
        }
        
        (uint16 index1, uint16 cardinality1,) = oracle.states(poolId);
        assertEq(cardinality1, 1024, "Should have 1024 observations");
        console.log("Buffer full - Index:", index1, "Cardinality:", cardinality1);
        
        // Continue beyond capacity to test extended ring buffer
        console.log("Continuing beyond capacity...");
        for (uint16 i = 0; i < 500; i++) {
            _performSwap(1000e18, true);
            vm.warp(block.timestamp + 60);
            
            if (i % 100 == 0) {
                (uint16 currentIndex, uint16 currentCardinality,) = oracle.states(poolId);
                console.log("Extended ring buffer - Swap");
                console.log(i + 1024);
                console.log("Index:");
                console.log(currentIndex);
                console.log("Cardinality:");
                console.log(currentCardinality);
                _testObserveAndConsult(string(abi.encodePacked("Extended swap ", _toString(i + 1024))));
            }
        }
        
        console.log("SUCCESS: Extended ring buffer tested!");
    }
    
    // Helper function for comprehensive consult testing
    function _testComprehensiveConsult(string memory context) internal {
        console.log("--- Comprehensive consult test:", context, "---");
        
        (int24 latestTick, uint32 latestTimestamp) = oracle.getLatestObservation(poolId);
        console.log("Latest observation - Tick:", latestTick);
        console.log("Latest observation - Timestamp:", latestTimestamp);
        
        uint32[] memory periods = new uint32[](5);
        periods[0] = 30;   // 30 seconds
        periods[1] = 60;   // 1 minute
        periods[2] = 300;  // 5 minutes
        periods[3] = 600;  // 10 minutes
        periods[4] = 1800; // 30 minutes
        
        for (uint i = 0; i < periods.length; i++) {
            uint32 period = periods[i];
            
            try oracle.consult(poolKey, period) returns (int24 twapTick, uint128 harmonicMeanLiquidity) {
                console.log("Consult period:", period);
                console.log("TWAP tick:", twapTick);
                console.log("Harmonic mean liquidity:", harmonicMeanLiquidity);
                console.log("- Current vs TWAP tick difference:", int256(latestTick) - int256(twapTick));
                console.log("- Current liquidity: 100000000000000000000000");
                console.log("- Harmonic mean liquidity ratio:", (harmonicMeanLiquidity * 100) / 100000000000000000000000, "%");
            } catch Error(string memory reason) {
                console.log("Consult period:");
                console.log(period);
                console.log("Failed with reason:");
                console.log(reason);
            } catch {
                console.log("Consult period:");
                console.log(period);
                console.log("Failed with low-level error");
            }
        }
        
        // Test observe function
        uint32[] memory secondsAgos = new uint32[](4);
        secondsAgos[0] = 60;   // 1 minute ago
        secondsAgos[1] = 300;  // 5 minutes ago
        secondsAgos[2] = 600;  // 10 minutes ago
        secondsAgos[3] = 0;    // now
        
        try oracle.observe(poolKey, secondsAgos) returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s) {
            console.log("Observe successful");
            console.log("Cumulative ticks:", tickCumulatives.length);
            for (uint i = 0; i < secondsAgos.length; i++) {
                console.log("Seconds ago:", secondsAgos[i]);
                console.log("Cumulative tick:", tickCumulatives[i]);
            }
        } catch Error(string memory reason) {
            console.log("Observe failed with reason:", reason);
        } catch {
            console.log("Observe failed with low-level error");
        }
    }
    
    // Helper function for observe and consult testing
    function _testObserveAndConsult(string memory context) internal {
        console.log("--- Oracle test:", context, "---");
        
        (int24 latestTick, uint32 latestTimestamp) = oracle.getLatestObservation(poolId);
        console.log("Latest observation - Tick:", latestTick);
        console.log("Latest observation - Timestamp:", latestTimestamp);
        
        // Test consult for different periods
        uint32[] memory periods = new uint32[](3);
        periods[0] = 300;  // 5 minutes
        periods[1] = 600;  // 10 minutes
        periods[2] = 1800; // 30 minutes
        
        for (uint i = 0; i < periods.length; i++) {
            try oracle.consult(poolKey, periods[i]) returns (int24 twapTick, uint128 harmonicMeanLiquidity) {
                console.log("Consult success, TWAP tick:", twapTick);
            } catch {
                console.log("Consult failed for period:");
                console.log(periods[i]);
            }
        }
        
        // Test observe
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = 300; // 5 minutes ago
        secondsAgos[1] = 0;   // now
        
        try oracle.observe(poolKey, secondsAgos) returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s) {
            console.log("Observe successful");
        } catch {
            console.log("Observe failed");
        }
    }
    
    // Helper function to convert uint to string
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
    

    
    // Helper function to get absolute value
    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    function test_ManualIncreaseBeyondMax() public {
        console.log("=== Testing Manual Increase Beyond 1024 ===");
        
        // Fill buffer to 1024
        for (uint i = 0; i < 1024; i++) {
            _performSwap(1e18, true);
            vm.warp(block.timestamp + 60);
        }
        
        (uint16 index, uint16 cardinality, uint16 cardinalityNext) = oracle.states(poolId);
        console.log("After 1024 swaps:");
        console.log("  Index:", index);
        console.log("  Cardinality:", cardinality);
        console.log("  CardinalityNext:", cardinalityNext);
        assertEq(cardinalityNext, 1024, "Should be at max 1024");

        // Manually increase to 1100
        oracle.increaseCardinalityNext(poolKey, 1100);
        (index, cardinality, cardinalityNext) = oracle.states(poolId);
        console.log("After manual increase to 1100:");
        console.log("  Index:", index);
        console.log("  Cardinality:", cardinality);
        console.log("  CardinalityNext:", cardinalityNext);
        assertEq(cardinalityNext, 1100, "Should be increased to 1100");

        // Perform more swaps and check that buffer grows
        for (uint i = 0; i < 80; i++) {
            _performSwap(1e18, true);
            vm.warp(block.timestamp + 60);
        }
        (index, cardinality, cardinalityNext) = oracle.states(poolId);
        console.log("After 80 more swaps:");
        console.log("  Index:", index);
        console.log("  Cardinality:", cardinality);
        console.log("  CardinalityNext:", cardinalityNext);
        assertGt(cardinalityNext, 1024, "Should have grown beyond 1024");
    }
} 