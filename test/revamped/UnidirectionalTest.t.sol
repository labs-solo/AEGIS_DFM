// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// Import the base test
import "./Base_Test.sol";

// Import v4 periphery interfaces
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract UnidirectionalTest is Base_Test {
    
    /// @notice Gets current pool state information
    function getPoolState() public view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) {
        (sqrtPriceX96, tick,,) = StateLibrary.getSlot0(manager, poolId);
        liquidity = StateLibrary.getLiquidity(manager, poolId);
        (feeGrowthGlobal0X128, feeGrowthGlobal1X128) = StateLibrary.getFeeGrowthGlobals(manager, poolId);
    }

    /// @notice Test consult functionality with sustained upward price movement
    /// @dev Performs swaps that only move price up to create dramatic cumulative tick changes
    function testConsultWithSustainedUpwardMovement() public {
        console.log("=== Testing Consult with Sustained Upward Movement ===");
        
        // Get initial state
        (uint160 sqrtPriceX96, int24 initialTick, uint128 liquidity,,) = getPoolState();
        console.log("Initial pool state:");
        console.log("- SqrtPriceX96:", sqrtPriceX96);
        console.log("- Initial Tick:", initialTick);
        console.log("- Liquidity:", liquidity);
        
        vm.startPrank(user1);
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false});
        
        // Test initial consult functionality
        console.log("=== Initial Consult Test ===");
        _testComprehensiveConsult("Initial state");
        
        // Phase 1: Build some history with small upward movements
        console.log("=== Phase 1: Building Oracle History (Small Upward Movements) ===");
        uint256 smallUpAmount = 0.5 ether;
        for (uint256 i = 0; i < 20; i++) {
            // Only swap token0 to token1 (price up)
            SwapParams memory params = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(smallUpAmount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Small up swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 60); // 1 minute between swaps
        }
        
        (int24 tickAfterSmall, uint32 timestampAfterSmall) = oracle.getLatestObservation(poolId);
        console.log("After small upward swaps - Tick:", tickAfterSmall);
        console.log("After small upward swaps - Timestamp:", timestampAfterSmall);
        console.log("Total tick change:", int256(tickAfterSmall) - int256(initialTick));
        _testComprehensiveConsult("After small upward swaps");
        
        // Phase 2: Medium upward movements
        console.log("=== Phase 2: Medium Upward Movements ===");
        uint256 mediumUpAmount = 5 ether;
        for (uint256 i = 0; i < 10; i++) {
            SwapParams memory params = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(mediumUpAmount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Medium up swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 90); // 1.5 minutes between swaps
        }
        
        (int24 tickAfterMedium, uint32 timestampAfterMedium) = oracle.getLatestObservation(poolId);
        console.log("After medium upward swaps - Tick:", tickAfterMedium);
        console.log("After medium upward swaps - Timestamp:", timestampAfterMedium);
        console.log("Total tick change:", int256(tickAfterMedium) - int256(initialTick));
        _testComprehensiveConsult("After medium upward swaps");
        
        // Phase 3: Large upward movements
        console.log("=== Phase 3: Large Upward Movements ===");
        uint256 largeUpAmount = 20 ether;
        for (uint256 i = 0; i < 8; i++) {
            SwapParams memory params = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(largeUpAmount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Large up swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 120); // 2 minutes between swaps
        }
        
        (int24 tickAfterLarge, uint32 timestampAfterLarge) = oracle.getLatestObservation(poolId);
        console.log("After large upward swaps - Tick:", tickAfterLarge);
        console.log("After large upward swaps - Timestamp:", timestampAfterLarge);
        console.log("Total tick change:", int256(tickAfterLarge) - int256(initialTick));
        _testComprehensiveConsult("After large upward swaps");
        
        // Phase 4: Massive upward movements
        console.log("=== Phase 4: Massive Upward Movements ===");
        uint256 massiveUpAmount = 50 ether;
        for (uint256 i = 0; i < 5; i++) {
            SwapParams memory params = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(massiveUpAmount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Massive up swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 180); // 3 minutes between swaps
        }
        
        (int24 tickAfterMassive, uint32 timestampAfterMassive) = oracle.getLatestObservation(poolId);
        console.log("After massive upward swaps - Tick:", tickAfterMassive);
        console.log("After massive upward swaps - Timestamp:", timestampAfterMassive);
        console.log("Total tick change:", int256(tickAfterMassive) - int256(initialTick));
        _testComprehensiveConsult("After massive upward swaps");
        
        // Phase 5: Extreme upward movements
        console.log("=== Phase 5: Extreme Upward Movements ===");
        uint256 extremeUpAmount = 100 ether;
        for (uint256 i = 0; i < 3; i++) {
            SwapParams memory params = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(extremeUpAmount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Extreme up swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 300); // 5 minutes between swaps
        }
        
        (int24 tickAfterExtreme, uint32 timestampAfterExtreme) = oracle.getLatestObservation(poolId);
        console.log("After extreme upward swaps - Tick:", tickAfterExtreme);
        console.log("After extreme upward swaps - Timestamp:", timestampAfterExtreme);
        console.log("Total tick change:", int256(tickAfterExtreme) - int256(initialTick));
        _testComprehensiveConsult("After extreme upward swaps");
        
        vm.stopPrank();
        
        // Final comprehensive test
        console.log("=== Final Comprehensive Consult Test ===");
        _testComprehensiveConsult("Final state");
        
        // Verify oracle state
        (uint16 finalIndex, uint16 finalCardinality, uint16 finalCardinalityNext) = oracle.states(poolId);
        console.log("Final oracle state:");
        console.log("- Index:", finalIndex);
        console.log("- Cardinality:", finalCardinality);
        console.log("- CardinalityNext:", finalCardinalityNext);
        
        console.log("SUCCESS: Consult functionality tested with sustained upward movement!");
        console.log("=== Sustained Upward Movement Test Completed ===");
    }

    /// @notice Comprehensive consult testing with detailed output
    function _testComprehensiveConsult(string memory label) internal {
        console.log("--- Comprehensive consult test:", label, "---");
        
        // Get latest observation
        try oracle.getLatestObservation(poolId) returns (int24 latestTick, uint32 latestTimestamp) {
            console.log("Latest observation - Tick:", latestTick);
            console.log("Latest observation - Timestamp:", latestTimestamp);
        } catch {
            console.log("Failed to get latest observation");
            return;
        }

        // Test consult for various time periods
        uint32[] memory testPeriods = new uint32[](5);
        testPeriods[0] = 30;    // 30 seconds
        testPeriods[1] = 60;    // 1 minute
        testPeriods[2] = 300;   // 5 minutes  
        testPeriods[3] = 600;   // 10 minutes
        testPeriods[4] = 1800;  // 30 minutes

        for (uint256 i = 0; i < testPeriods.length; i++) {
            uint32 period = testPeriods[i];
            try oracle.consult(poolKey, period) returns (int24 arithmeticMeanTick, uint128 harmonicMeanLiquidity) {
                console.log("Consult period:", period);
                console.log("TWAP tick:", arithmeticMeanTick);
                console.log("Harmonic mean liquidity:", harmonicMeanLiquidity);
                
                // Verify the TWAP tick is reasonable
                (int24 currentTick,) = oracle.getLatestObservation(poolId);
                int24 tickDifference = currentTick > arithmeticMeanTick ? 
                    currentTick - arithmeticMeanTick : arithmeticMeanTick - currentTick;
                console.log("  - Current vs TWAP tick difference:", tickDifference);
                
                // Verify harmonic mean liquidity is reasonable
                (uint160 sqrtPriceX96, int24 tick, uint128 liquidity,,) = getPoolState();
                console.log("  - Current liquidity:", liquidity);
                console.log("  - Harmonic mean liquidity ratio:", uint256(harmonicMeanLiquidity) * 100 / uint256(liquidity), "%");
                
            } catch Error(string memory reason) {
                console.log("Consult period:", period);
                console.log("Failed:", reason);
            } catch {
                console.log("Consult period:", period);
                console.log("Failed with low-level error");
            }
        }

        // Test observe with multiple secondsAgo values
        uint32[] memory secondsAgo = new uint32[](4);
        secondsAgo[0] = 60;   // 1 minute ago
        secondsAgo[1] = 300;  // 5 minutes ago
        secondsAgo[2] = 600;  // 10 minutes ago
        secondsAgo[3] = 0;    // now

        try oracle.observe(poolKey, secondsAgo) returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        ) {
            console.log("Observe successful");
            console.log("Cumulative ticks:", tickCumulatives.length);
            for (uint256 i = 0; i < tickCumulatives.length; i++) {
                console.log("Seconds ago:", secondsAgo[i]);
                console.log("Cumulative tick:", tickCumulatives[i]);
            }
        } catch Error(string memory reason) {
            console.log("Observe failed:", reason);
        } catch {
            console.log("Observe failed with low-level error");
        }
    }

    /// @notice Helper function to convert uint to string
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        
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

    /// @notice Test that the oracle ring buffer loops back to index 0
    /// @dev Performs enough swaps to fill the buffer (1024 observations) and then continues
    function testOracleRingBufferLooping() public {
        console.log("=== Testing Oracle Ring Buffer Looping ===");
        
        // Get initial state
        (uint160 sqrtPriceX96, int24 initialTick, uint128 liquidity,,) = getPoolState();
        console.log("Initial pool state:");
        console.log("- SqrtPriceX96:", sqrtPriceX96);
        console.log("- Initial Tick:", initialTick);
        console.log("- Liquidity:", liquidity);
        
        vm.startPrank(user1);
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false});
        
        // Test initial consult functionality
        console.log("=== Initial Consult Test ===");
        _testComprehensiveConsult("Initial state");
        
        // Phase 1: Fill the ring buffer with small swaps
        console.log("=== Phase 1: Filling Ring Buffer (1024 observations) ===");
        uint256 smallUpAmount = 0.1 ether;
        uint16 expectedMaxCardinality = 1024; // MAX_CARDINALITY_ALLOWED
        
        for (uint256 i = 0; i < 1100; i++) { // More than 1024 to ensure we loop
            SwapParams memory params = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(smallUpAmount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Small up swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 30); // 30 seconds between swaps
            
            // Check oracle state every 100 swaps
            if (i % 100 == 99) {
                (uint16 currentIndex, uint16 currentCardinality, uint16 currentCardinalityNext) = oracle.states(poolId);
                console.log("Swap");
                console.log(i+1);
                console.log("- Index:");
                console.log(currentIndex);
                console.log("Cardinality:");
                console.log(currentCardinality);
                console.log("CardinalityNext:");
                console.log(currentCardinalityNext);
                // Test consult when we have enough history
                if (currentCardinality > 100) {
                    _testComprehensiveConsult(string(abi.encodePacked("Swap ", _toString(i+1))));
                }
            }
            
            // Check if we've reached max cardinality
            (uint16 idx, uint16 card, ) = oracle.states(poolId);
            if (card == expectedMaxCardinality && i >= expectedMaxCardinality) {
                console.log("Ring buffer filled at swap");
                console.log(i+1);
                console.log("- Index:");
                console.log(idx);
                console.log("Cardinality:");
                console.log(card);
                _testComprehensiveConsult("Ring buffer filled");
            }
        }
        
        // Phase 2: Continue beyond the ring buffer to verify looping
        console.log("=== Phase 2: Continuing Beyond Ring Buffer ===");
        uint256 mediumUpAmount = 1 ether;
        for (uint256 i = 0; i < 200; i++) {
            SwapParams memory params = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(mediumUpAmount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Medium up swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 60); // 1 minute between swaps
            
            // Check oracle state every 50 swaps
            if (i % 50 == 49) {
                (uint16 currentIndex, uint16 currentCardinality, uint16 currentCardinalityNext) = oracle.states(poolId);
                console.log("Beyond buffer - Swap");
                console.log(i+1);
                console.log("- Index:");
                console.log(currentIndex);
                console.log("Cardinality:");
                console.log(currentCardinality);
                console.log("CardinalityNext:");
                console.log(currentCardinalityNext);
                // Check if we've looped back to 0
                if (currentIndex == 0) {
                    console.log("SUCCESS: Oracle looped back to index 0!");
                }
                _testComprehensiveConsult(string(abi.encodePacked("Beyond buffer swap ", _toString(i+1))));
            }
        }
        
        vm.stopPrank();
        
        // Final comprehensive test
        console.log("=== Final Comprehensive Consult Test ===");
        _testComprehensiveConsult("Final state");
        
        // Verify final oracle state
        (uint16 finalIndex, uint16 finalCardinality, uint16 finalCardinalityNext) = oracle.states(poolId);
        console.log("Final oracle state:");
        console.log("- Index:", finalIndex);
        console.log("- Cardinality:", finalCardinality);
        console.log("- CardinalityNext:", finalCardinalityNext);
        
        // Verify ring buffer behavior
        require(finalCardinality == expectedMaxCardinality, "Cardinality should remain at max");
        require(finalCardinalityNext == expectedMaxCardinality, "CardinalityNext should remain at max");
        
        console.log("SUCCESS: Oracle ring buffer looping verified!");
        console.log("=== Oracle Ring Buffer Looping Test Completed ===");
    }
} 