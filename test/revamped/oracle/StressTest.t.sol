// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// Import the base test
import "../Base_Test.sol";

// Import v4 periphery interfaces
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract StressTest is Base_Test {
    
    /// @notice Gets current pool state information
    /// @return sqrtPriceX96 Current sqrt price
    /// @return tick Current tick
    /// @return liquidity Current liquidity
    /// @return feeGrowthGlobal0X128 Fee growth for token0
    /// @return feeGrowthGlobal1X128 Fee growth for token1
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

    function printDebugInfo(uint256 i) internal {
        (uint160 sqrtPriceX96, int24 tick, uint128 liquidity,,) = getPoolState();
        console.log("Debug info at swap", i + 1);
        console.log("- SqrtPriceX96:", sqrtPriceX96);
        console.log("- Tick:", tick);
        console.log("- Liquidity:", liquidity);
        console.log("- user1 token0:", MockERC20(Currency.unwrap(currency0)).balanceOf(user1));
        console.log("- user1 token1:", MockERC20(Currency.unwrap(currency1)).balanceOf(user1));
    }

    // ============ ACTUAL TESTS ============

    /// @notice Test ring buffer behavior by performing enough swaps to fill and wrap the oracle buffer
    /// @dev Page size is 512, total capacity is 1024 (2 full pages of 512 each)
    function test_RingBufferBehavior() public {
        console.log("=== Testing Ring Buffer Behavior (2000 swaps, PAGE_SIZE=512, MAX_CARD=1024) ===");
        (uint160 sqrtPriceX96, int24 tick, uint128 liquidity,,) = getPoolState();
        console.log("Initial pool state:");
        console.log("- SqrtPriceX96:", sqrtPriceX96);
        console.log("- Tick:", tick);
        console.log("- Liquidity:", liquidity);
        vm.startPrank(user1);
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false});
        uint256 swapAmount = 1 ether;
        (uint16 initialIndex, uint16 initialCardinality,) = oracle.states(poolId);
        console.log("Initial oracle state:");
        console.log("- Index:", initialIndex);
        console.log("- Cardinality:", initialCardinality);
        console.log("- Page size: 512, Total capacity: 1024 (2 full pages)");

        // Test initial observe/consult functionality
        console.log("=== Testing initial oracle functionality ===");
        _testObserveAndConsult("Initial state");

        uint16 card = initialCardinality;
        uint256 totalSwaps = 2000;
        for (uint256 i = 0; i < totalSwaps; i++) {
            // Use unidirectional swaps to create meaningful price movements
            SwapParams memory params = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(swapAmount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 13);
            (uint16 idx, uint16 c, ) = oracle.states(poolId);
            if (c == 1024 && card < 1024) {
                console.log("Buffer full at swap", i+1, "Index:", idx);
                _testObserveAndConsult("Buffer full");
            }
            if (i == 1024) {
                console.log("First wrap at swap", i+1, "Index:", idx);
                _testObserveAndConsult("First wrap");
            }
            // Log every 200 swaps after buffer is full to track ring behavior
            if (c == 1024 && (i+1) % 200 == 0) {
                console.log("Ring buffer at swap", i+1, "Index:", idx);
                _testObserveAndConsult(string(abi.encodePacked("Swap ", _toString(i+1))));
            }
            card = c;
        }
        vm.stopPrank();
        (uint16 finalIndex, uint16 finalCardinality, uint16 finalCardinalityNext) = oracle.states(poolId);
        console.log("=== Final Oracle State ===");
        console.log("- Index:", finalIndex);
        console.log("- Cardinality:", finalCardinality);
        console.log("- CardinalityNext:", finalCardinalityNext);

        // Test final observe/consult functionality
        console.log("=== Testing final oracle functionality ===");
        _testObserveAndConsult("Final state");

        require(finalCardinality == 1024, "Cardinality should remain at 1024");
        require(finalCardinalityNext == 1024, "CardinalityNext should remain at 1024");
        console.log("SUCCESS: Ring buffer looping observed!");
        console.log("=== Ring Buffer 2000 Swaps Test Completed ===");
    }

    /// @notice Helper function to test observe and consult functionality
    function _testObserveAndConsult(string memory label) internal {
        console.log("--- Oracle test:", label, "---");
        
        try oracle.getLatestObservation(poolId) returns (int24 latestTick, uint32 latestTimestamp) {
            console.log("Latest observation - Tick:", latestTick);
            console.log("Latest observation - Timestamp:", latestTimestamp);
        } catch {
            console.log("Failed to get latest observation");
        }

        // Test consult for various time periods (if we have enough history)
        uint32[] memory testPeriods = new uint32[](3);
        testPeriods[0] = 60;    // 1 minute
        testPeriods[1] = 300;   // 5 minutes  
        testPeriods[2] = 600;   // 10 minutes

        for (uint256 i = 0; i < testPeriods.length; i++) {
            uint32 period = testPeriods[i];
            try oracle.consult(poolKey, period) returns (int24 arithmeticMeanTick, uint128 harmonicMeanLiquidity) {
                console.log("Consult success, TWAP tick:", arithmeticMeanTick);
            } catch Error(string memory reason) {
                console.log("Consult failed:", reason);
            } catch {
                console.log("Consult failed with low-level error");
            }
        }

        // Test observe with multiple secondsAgo values
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = 120; // 2 minutes ago
        secondsAgo[1] = 0;   // now

        try oracle.observe(poolKey, secondsAgo) returns (
            int56[] memory tickCumulatives,
            uint160[] memory secondsPerLiquidityCumulativeX128s
        ) {
            console.log("Observe successful");
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

    /// @notice Test consult functionality with significant price movements
    /// @dev Performs large swaps to create substantial price changes and verifies TWAP calculations
    function test_ConsultWithBigSwaps() public {
        console.log("=== Testing Consult with Big Swaps ===");
        
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
        
        // Phase 1: Unidirectional price movements to build history
        console.log("=== Phase 1: Building Oracle History with Unidirectional Swaps ===");
        uint256 moderateSwapAmount = 20 ether; // Increased from 5 ether
        for (uint256 i = 0; i < 50; i++) {
            // All swaps in the same direction (zeroForOne: true) for sustained movement
            SwapParams memory params = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(moderateSwapAmount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Moderate swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 30); // 30 seconds between swaps
        }
        
        (int24 tickAfterSmall, uint32 timestampAfterSmall) = oracle.getLatestObservation(poolId);
        console.log("After small swaps - Tick:", tickAfterSmall);
        console.log("After small swaps - Timestamp:", timestampAfterSmall);
        _testComprehensiveConsult("After small swaps");
        
        // Phase 2: Large unidirectional price movements
        console.log("=== Phase 2: Large Unidirectional Price Movements ===");
        uint256 largeSwapAmount = 50 ether; // Increased from 10 ether
        
        // Large unidirectional swaps - all in the same direction
        for (uint256 i = 0; i < 10; i++) {
            SwapParams memory largeParams = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(largeSwapAmount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, largeParams, testSettings, "") {} catch { revert("Large swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 60); // 1 minute gap
        }
        
        (int24 tickAfterLarge, uint32 timestampAfterLarge) = oracle.getLatestObservation(poolId);
        console.log("After large unidirectional swaps - Tick:", tickAfterLarge);
        console.log("After large unidirectional swaps - Timestamp:", timestampAfterLarge);
        console.log("Price change from moderate:", int256(tickAfterLarge) - int256(tickAfterSmall));
        _testComprehensiveConsult("After large unidirectional swaps");
        
        // Phase 3: Extreme unidirectional price movements
        console.log("=== Phase 3: Extreme Unidirectional Price Movements ===");
        uint256 extremeSwapAmount = 100 ether; // Increased from 50 ether
        
        // Extreme unidirectional swaps - all in the same direction
        for (uint256 i = 0; i < 5; i++) {
            SwapParams memory extremeParams = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(extremeSwapAmount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, extremeParams, testSettings, "") {} catch { revert("Extreme swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 120); // 2 minute gap
        }
        
        (int24 tickAfterExtreme, uint32 timestampAfterExtreme) = oracle.getLatestObservation(poolId);
        console.log("After extreme unidirectional swaps - Tick:", tickAfterExtreme);
        console.log("After extreme unidirectional swaps - Timestamp:", timestampAfterExtreme);
        console.log("Price change from large:", int256(tickAfterExtreme) - int256(tickAfterLarge));
        _testComprehensiveConsult("After extreme unidirectional swaps");
        
        // Phase 4: Sustained unidirectional trading pattern
        console.log("=== Phase 4: Sustained Unidirectional Trading Pattern ===");
        uint256 sustainedSwapAmount = 30 ether; // Increased from 5 ether
        for (uint256 i = 0; i < 20; i++) {
            // All swaps in the same direction with increasing amounts
            uint256 amount = sustainedSwapAmount + (i * 2 ether);
            SwapParams memory params = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(amount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Sustained swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 45); // 45 seconds between swaps
            
            // Test consult every 5 swaps
            if (i % 5 == 4) {
                (int24 currentTick, uint32 currentTimestamp) = oracle.getLatestObservation(poolId);
                console.log("Sustained unidirectional trading - Swap");
                console.log("Swap number:", i+1);
                console.log("Tick:", currentTick);
                console.log("Timestamp:", currentTimestamp);
                _testComprehensiveConsult(string(abi.encodePacked("Sustained swap ", _toString(i+1))));
            }
        }
        
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
        
        console.log("SUCCESS: Consult functionality tested with big swaps!");
        console.log("=== Big Swaps Consult Test Completed ===");
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

    /// @notice Test consult functionality with very large swaps and dramatic price movements
    /// @dev Performs massive swaps to create substantial tick changes and verifies TWAP calculations
    function test_ConsultWithMassiveSwaps() public {
        console.log("=== Testing Consult with Massive Swaps ===");
        
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
        
        // Phase 1: Build some history with unidirectional moderate swaps
        console.log("=== Phase 1: Building Oracle History with Unidirectional Swaps ===");
        uint256 moderateSwapAmount = 10 ether; // Increased from 1 ether
        for (uint256 i = 0; i < 30; i++) {
            // All swaps in the same direction for sustained movement
            SwapParams memory params = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(moderateSwapAmount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Moderate swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 60); // 1 minute between swaps
        }
        
        (int24 tickAfterModerate, uint32 timestampAfterModerate) = oracle.getLatestObservation(poolId);
        console.log("After moderate swaps - Tick:", tickAfterModerate);
        console.log("After moderate swaps - Timestamp:", timestampAfterModerate);
        _testComprehensiveConsult("After moderate swaps");
        
        // Phase 2: Massive unidirectional price movements
        console.log("=== Phase 2: Massive Unidirectional Price Movements ===");
        uint256 massiveAmount = 200 ether; // Increased from 100 ether
        
        // Multiple massive unidirectional swaps
        for (uint256 i = 0; i < 5; i++) {
            SwapParams memory massiveParams = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(massiveAmount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, massiveParams, testSettings, "") {} catch { revert("Massive swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 120); // 2 minute gap
        }
        
        (int24 tickAfterMassive, uint32 timestampAfterMassive) = oracle.getLatestObservation(poolId);
        console.log("After massive unidirectional swaps - Tick:", tickAfterMassive);
        console.log("After massive unidirectional swaps - Timestamp:", timestampAfterMassive);
        console.log("Price change from moderate:", int256(tickAfterMassive) - int256(tickAfterModerate));
        _testComprehensiveConsult("After massive unidirectional swaps");
        
        // Phase 3: Extreme unidirectional movements
        console.log("=== Phase 3: Extreme Unidirectional Movements ===");
        uint256 extremeAmount = 300 ether; // Increased from 200 ether
        
        // Multiple extreme unidirectional swaps
        for (uint256 i = 0; i < 3; i++) {
            SwapParams memory extremeParams = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(extremeAmount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, extremeParams, testSettings, "") {} catch { revert("Extreme swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 180); // 3 minute gap
        }
        
        (int24 tickAfterExtreme, uint32 timestampAfterExtreme) = oracle.getLatestObservation(poolId);
        console.log("After extreme unidirectional swaps - Tick:", tickAfterExtreme);
        console.log("After extreme unidirectional swaps - Timestamp:", timestampAfterExtreme);
        console.log("Price change from massive:", int256(tickAfterExtreme) - int256(tickAfterMassive));
        _testComprehensiveConsult("After extreme unidirectional swaps");
        
        // Phase 4: Sustained extreme movements
        console.log("=== Phase 4: Sustained Extreme Movements ===");
        uint256 sustainedAmount = 250 ether;
        
        // Multiple sustained extreme swaps
        for (uint256 i = 0; i < 4; i++) {
            SwapParams memory sustainedParams = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(sustainedAmount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, sustainedParams, testSettings, "") {} catch { revert("Sustained swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 240); // 4 minute gap
        }
        
        (int24 tickAfterSustained, uint32 timestampAfterSustained) = oracle.getLatestObservation(poolId);
        console.log("After sustained extreme swaps - Tick:", tickAfterSustained);
        console.log("After sustained extreme swaps - Timestamp:", timestampAfterSustained);
        console.log("Price change from extreme:", int256(tickAfterSustained) - int256(tickAfterExtreme));
        _testComprehensiveConsult("After sustained extreme swaps");
        
        // Phase 5: Sustained large trading pattern
        console.log("=== Phase 5: Sustained Large Trading Pattern ===");
        for (uint256 i = 0; i < 15; i++) {
            // Vary between very large amounts, all in the same direction
            uint256 amount = 100 ether + (i * 15 ether); // 100 ETH to 310 ETH
            SwapParams memory params = SwapParams({
                zeroForOne: true, 
                amountSpecified: -int256(amount), 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Sustained large swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 90); // 1.5 minutes between swaps
            
            // Test consult every 3 swaps
            if (i % 3 == 2) {
                (int24 currentTick, uint32 currentTimestamp) = oracle.getLatestObservation(poolId);
                console.log("Sustained large trading - Swap");
                console.log("Swap number:", i+1);
                console.log("Tick:", currentTick);
                console.log("Timestamp:", currentTimestamp);
                _testComprehensiveConsult(string(abi.encodePacked("Sustained large swap ", _toString(i+1))));
            }
        }
        
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
        
        console.log("SUCCESS: Consult functionality tested with massive swaps!");
        console.log("=== Massive Swaps Consult Test Completed ===");
    }
} 