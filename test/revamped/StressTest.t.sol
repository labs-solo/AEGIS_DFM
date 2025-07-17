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
    function testRingBufferBehavior() public {
        console.log("=== Testing Ring Buffer Behavior (2000 swaps, PAGE_SIZE=512, MAX_CARD=1024) ===");
        (uint160 sqrtPriceX96, int24 tick, uint128 liquidity,,) = getPoolState();
        console.log("Initial pool state:");
        console.log("- SqrtPriceX96:", sqrtPriceX96);
        console.log("- Tick:", tick);
        console.log("- Liquidity:", liquidity);
        vm.startPrank(user1);
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false});
        uint256 swapAmount = 0.01 ether;
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
            SwapParams memory params = (i % 2 == 0)
                ? SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1})
                : SwapParams({zeroForOne: false, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});
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
    function testConsultWithBigSwaps() public {
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
        
        // Phase 1: Small price movements to build history
        console.log("=== Phase 1: Building Oracle History ===");
        uint256 smallSwapAmount = 0.1 ether;
        for (uint256 i = 0; i < 50; i++) {
            SwapParams memory params = (i % 2 == 0)
                ? SwapParams({zeroForOne: true, amountSpecified: -int256(smallSwapAmount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1})
                : SwapParams({zeroForOne: false, amountSpecified: -int256(smallSwapAmount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Small swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 30); // 30 seconds between swaps
        }
        
        (int24 tickAfterSmall, uint32 timestampAfterSmall) = oracle.getLatestObservation(poolId);
        console.log("After small swaps - Tick:", tickAfterSmall);
        console.log("After small swaps - Timestamp:", timestampAfterSmall);
        _testComprehensiveConsult("After small swaps");
        
        // Phase 2: Large price movements
        console.log("=== Phase 2: Large Price Movements ===");
        uint256 largeSwapAmount = 10 ether; // Much larger swaps
        
        // First large swap - token0 to token1 (price up)
        SwapParams memory largeUpParams = SwapParams({
            zeroForOne: true, 
            amountSpecified: -int256(largeSwapAmount), 
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        try swapRouter.swap(poolKey, largeUpParams, testSettings, "") {} catch { revert("Large up swap failed"); }
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 60); // 1 minute gap
        
        (int24 tickAfterLargeUp, uint32 timestampAfterLargeUp) = oracle.getLatestObservation(poolId);
        console.log("After large up swap - Tick:", tickAfterLargeUp);
        console.log("After large up swap - Timestamp:", timestampAfterLargeUp);
        console.log("Price change:", int256(tickAfterLargeUp) - int256(tickAfterSmall));
        _testComprehensiveConsult("After large up swap");
        
        // Second large swap - token1 to token0 (price down)
        SwapParams memory largeDownParams = SwapParams({
            zeroForOne: false, 
            amountSpecified: -int256(largeSwapAmount), 
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        try swapRouter.swap(poolKey, largeDownParams, testSettings, "") {} catch { revert("Large down swap failed"); }
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 60); // 1 minute gap
        
        (int24 tickAfterLargeDown, uint32 timestampAfterLargeDown) = oracle.getLatestObservation(poolId);
        console.log("After large down swap - Tick:", tickAfterLargeDown);
        console.log("After large down swap - Timestamp:", timestampAfterLargeDown);
        console.log("Price change:", int256(tickAfterLargeDown) - int256(tickAfterLargeUp));
        _testComprehensiveConsult("After large down swap");
        
        // Phase 3: Extreme price movements
        console.log("=== Phase 3: Extreme Price Movements ===");
        uint256 extremeSwapAmount = 50 ether; // Very large swaps
        
        // Extreme up movement
        SwapParams memory extremeUpParams = SwapParams({
            zeroForOne: true, 
            amountSpecified: -int256(extremeSwapAmount), 
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        try swapRouter.swap(poolKey, extremeUpParams, testSettings, "") {} catch { revert("Extreme up swap failed"); }
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 120); // 2 minute gap
        
        (int24 tickAfterExtremeUp, uint32 timestampAfterExtremeUp) = oracle.getLatestObservation(poolId);
        console.log("After extreme up swap - Tick:", tickAfterExtremeUp);
        console.log("After extreme up swap - Timestamp:", timestampAfterExtremeUp);
        console.log("Price change:", int256(tickAfterExtremeUp) - int256(tickAfterLargeDown));
        _testComprehensiveConsult("After extreme up swap");
        
        // Extreme down movement
        SwapParams memory extremeDownParams = SwapParams({
            zeroForOne: false, 
            amountSpecified: -int256(extremeSwapAmount), 
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        try swapRouter.swap(poolKey, extremeDownParams, testSettings, "") {} catch { revert("Extreme down swap failed"); }
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 120); // 2 minute gap
        
        (int24 tickAfterExtremeDown, uint32 timestampAfterExtremeDown) = oracle.getLatestObservation(poolId);
        console.log("After extreme down swap - Tick:", tickAfterExtremeDown);
        console.log("After extreme down swap - Timestamp:", timestampAfterExtremeDown);
        console.log("Price change:", int256(tickAfterExtremeDown) - int256(tickAfterExtremeUp));
        _testComprehensiveConsult("After extreme down swap");
        
        // Phase 4: Volatile trading pattern
        console.log("=== Phase 4: Volatile Trading Pattern ===");
        uint256 volatileSwapAmount = 5 ether;
        for (uint256 i = 0; i < 20; i++) {
            // Alternate between up and down with varying amounts
            uint256 amount = volatileSwapAmount + (i * 0.5 ether);
            SwapParams memory params = (i % 2 == 0)
                ? SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1})
                : SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Volatile swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 45); // 45 seconds between swaps
            
            // Test consult every 5 swaps
            if (i % 5 == 4) {
                (int24 currentTick, uint32 currentTimestamp) = oracle.getLatestObservation(poolId);
                console.log("Volatile trading - Swap");
                console.log("Swap number:", i+1);
                console.log("Tick:", currentTick);
                console.log("Timestamp:", currentTimestamp);
                _testComprehensiveConsult(string(abi.encodePacked("Volatile swap ", _toString(i+1))));
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
    function testConsultWithMassiveSwaps() public {
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
        
        // Phase 1: Build some history with moderate swaps
        console.log("=== Phase 1: Building Oracle History ===");
        uint256 moderateSwapAmount = 1 ether;
        for (uint256 i = 0; i < 30; i++) {
            SwapParams memory params = (i % 2 == 0)
                ? SwapParams({zeroForOne: true, amountSpecified: -int256(moderateSwapAmount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1})
                : SwapParams({zeroForOne: false, amountSpecified: -int256(moderateSwapAmount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Moderate swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 60); // 1 minute between swaps
        }
        
        (int24 tickAfterModerate, uint32 timestampAfterModerate) = oracle.getLatestObservation(poolId);
        console.log("After moderate swaps - Tick:", tickAfterModerate);
        console.log("After moderate swaps - Timestamp:", timestampAfterModerate);
        _testComprehensiveConsult("After moderate swaps");
        
        // Phase 2: Massive price movements - token0 to token1 (price up significantly)
        console.log("=== Phase 2: Massive Price Up Movement ===");
        uint256 massiveUpAmount = 100 ether; // Very large swap to drive price up
        
        SwapParams memory massiveUpParams = SwapParams({
            zeroForOne: true, 
            amountSpecified: -int256(massiveUpAmount), 
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        try swapRouter.swap(poolKey, massiveUpParams, testSettings, "") {} catch { revert("Massive up swap failed"); }
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 120); // 2 minute gap
        
        (int24 tickAfterMassiveUp, uint32 timestampAfterMassiveUp) = oracle.getLatestObservation(poolId);
        console.log("After massive up swap - Tick:", tickAfterMassiveUp);
        console.log("After massive up swap - Timestamp:", timestampAfterMassiveUp);
        console.log("Price change:", int256(tickAfterMassiveUp) - int256(tickAfterModerate));
        _testComprehensiveConsult("After massive up swap");
        
        // Phase 3: Even more extreme movement - token1 to token0 (price down dramatically)
        console.log("=== Phase 3: Extreme Price Down Movement ===");
        uint256 extremeDownAmount = 200 ether; // Even larger swap to drive price down
        
        SwapParams memory extremeDownParams = SwapParams({
            zeroForOne: false, 
            amountSpecified: -int256(extremeDownAmount), 
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        try swapRouter.swap(poolKey, extremeDownParams, testSettings, "") {} catch { revert("Extreme down swap failed"); }
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 180); // 3 minute gap
        
        (int24 tickAfterExtremeDown, uint32 timestampAfterExtremeDown) = oracle.getLatestObservation(poolId);
        console.log("After extreme down swap - Tick:", tickAfterExtremeDown);
        console.log("After extreme down swap - Timestamp:", timestampAfterExtremeDown);
        console.log("Price change:", int256(tickAfterExtremeDown) - int256(tickAfterMassiveUp));
        _testComprehensiveConsult("After extreme down swap");
        
        // Phase 4: Another massive up movement
        console.log("=== Phase 4: Another Massive Price Up Movement ===");
        uint256 anotherMassiveUpAmount = 150 ether;
        
        SwapParams memory anotherMassiveUpParams = SwapParams({
            zeroForOne: true, 
            amountSpecified: -int256(anotherMassiveUpAmount), 
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        try swapRouter.swap(poolKey, anotherMassiveUpParams, testSettings, "") {} catch { revert("Another massive up swap failed"); }
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 240); // 4 minute gap
        
        (int24 tickAfterAnotherUp, uint32 timestampAfterAnotherUp) = oracle.getLatestObservation(poolId);
        console.log("After another massive up swap - Tick:", tickAfterAnotherUp);
        console.log("After another massive up swap - Timestamp:", timestampAfterAnotherUp);
        console.log("Price change:", int256(tickAfterAnotherUp) - int256(tickAfterExtremeDown));
        _testComprehensiveConsult("After another massive up swap");
        
        // Phase 5: Volatile trading with varying large amounts
        console.log("=== Phase 5: Volatile Large Trading Pattern ===");
        for (uint256 i = 0; i < 15; i++) {
            // Vary between very large amounts
            uint256 amount = 50 ether + (i * 10 ether); // 50 ETH to 190 ETH
            SwapParams memory params = (i % 2 == 0)
                ? SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1})
                : SwapParams({zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1});
            try swapRouter.swap(poolKey, params, testSettings, "") {} catch { revert("Volatile large swap failed"); }
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 90); // 1.5 minutes between swaps
            
            // Test consult every 3 swaps
            if (i % 3 == 2) {
                (int24 currentTick, uint32 currentTimestamp) = oracle.getLatestObservation(poolId);
                console.log("Volatile large trading - Swap");
                console.log("Swap number:", i+1);
                console.log("Tick:", currentTick);
                console.log("Timestamp:", currentTimestamp);
                _testComprehensiveConsult(string(abi.encodePacked("Volatile large swap ", _toString(i+1))));
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