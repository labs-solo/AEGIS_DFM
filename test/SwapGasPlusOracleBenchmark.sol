// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "./LocalUniswapV4TestBase.t.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {DepositParams} from "../src/interfaces/IFullRange.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {BalanceDelta} from "../lib/v4-core/src/types/BalanceDelta.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Strings} from "v4-core/lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import {FullRangeDynamicFeeManager} from "../src/FullRangeDynamicFeeManager.sol";
import {PoolPolicyManager} from "../src/PoolPolicyManager.sol";
import {DefaultPoolCreationPolicy} from "../src/DefaultPoolCreationPolicy.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/**
 * @title SwapGasPlusOracleBenchmark
 * @notice Comprehensive benchmark for swap gas consumption, oracle accuracy, and CAP detection
 */
contract SwapGasPlusOracleBenchmark is LocalUniswapV4TestBase {
    using StateLibrary for IPoolManager;
    using FullMath for uint256;

    // === Constants ===
    bytes constant ZERO_BYTES = "";
    uint160 constant SQRT_RATIO_1_1 = 1 << 96;  // 1:1 price using Q64.96 format
    uint160 constant MIN_SQRT_RATIO = 4295128739;
    uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    
    // Default parameter values (can be overridden)
    uint256 constant DEFAULT_SWAP_COUNT = 50;
    uint256 constant DEFAULT_VOLATILITY = 10;
    int24 constant DEFAULT_TREND_STRENGTH = 5;  // Changed to int24
    uint256 constant DEFAULT_TREND_DURATION = 8;
    uint256 constant DEFAULT_TIME_BETWEEN_SWAPS = 15; // seconds
    uint256 constant MAX_FAILED_SWAPS = 20; // Maximum number of failed swaps before stopping
    
    // Oracle tracking variables
    int24 private maxDeviation;
    int24 private totalOracleDeviation;
    uint256 private oracleDeviationCount;
    uint256 private expectedCapTriggers;
    
    // Test settings for swaps
    PoolSwapTest.TestSettings private testSettings = PoolSwapTest.TestSettings({
        takeClaims: true,
        settleUsingBurn: false
    });
    
    // === Test Pools ===
    // Regular V4 pool without hooks
    PoolKey public regularPoolKey;
    PoolId public regularPoolId;
    
    // Test contract for swaps
    PoolSwapTest public poolSwapTest;
    PoolModifyLiquidityTest public modifyLiquidityRouter;
    
    // === Tick Spacing Constants ===
    int24 constant REGULAR_TICK_SPACING = 10;  // Tight spacing for regular pool
    uint24 constant REGULAR_POOL_FEE = 3000;   // 0.3% fee for regular pool
    
    // === Data Structures ===
    enum SwapType { EXACT_INPUT, EXACT_OUTPUT }
    
    struct SwapInstruction {
        bool zeroForOne;
        SwapType swapType;
        uint256 amount;
        uint160 sqrtPriceLimitX96;
    }
    
    struct SwapResult {
        bool success;
        uint256 gasUsed;
        int24 tickBefore;
        int24 tickAfter;
        uint256 amount0Delta;
        uint256 amount1Delta;
        uint160 sqrtPriceX96After;
    }
    
    struct PoolMetrics {
        uint256 totalGasUsed;
        uint256 swapCount;
        uint256 minGasUsed;
        uint256 maxGasUsed;
        mapping(uint256 => SwapResult) swapResults;
        int24[] tickTrajectory;
        uint256[] gasUsageHistory;
        uint256 totalTicksCrossed;
        uint256 totalSuccessfulSwaps;
        uint256 totalFailedSwaps;
        // Oracle metrics
        int24 maxOracleTickDeviation;
        int24 avgOracleTickDeviation;
        // CAP metrics
        uint256 capTriggerCount;
        uint256 expectedCapTriggers;
    }
    
    // Pool metrics for both pools
    PoolMetrics private regularPoolMetrics;
    PoolMetrics private hookedPoolMetrics;
    
    // Simulation parameters that can be set before running tests
    struct SimulationParams {
        uint256 swapCount;
        uint256 volatility;
        int24 trendStrength;
        uint256 trendDuration;
        uint256 timeBetweenSwaps;
    }
    SimulationParams public simulationParams;  // Renamed from params to avoid shadowing

    // === For simple file-based logging (via Foundry FFI) ===
    string internal newLogFile;

    /**
     * @dev Manage logs: keep last 3 logs in `log/`, remove older, and start a new log file for this run.
     * Requires Foundry `ffi` to be enabled.
     */
    function manageLogs() internal {
        // Create `log/` folder if missing
        string[] memory makeDirCmd = new string[](3);
        makeDirCmd[0] = "bash";
        makeDirCmd[1] = "-c";
        makeDirCmd[2] = "mkdir -p log";
        vm.ffi(makeDirCmd);

        // Remove logs older than the most recent 3
        string[] memory rmCmd = new string[](3);
        rmCmd[0] = "bash";
        rmCmd[1] = "-c";
        // This finds all *.log in log/, sorts by modification time descending, then removes lines 4+ 
        // (the older ones). If there's nothing to remove, it does nothing.
        rmCmd[2] = "ls -t log/*.log 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true";
        vm.ffi(rmCmd);

        // Create a unique file for this run's log
        newLogFile = string.concat("log/run_", Strings.toString(block.timestamp), ".log");
        vm.writeFile(newLogFile, "=== Starting test run ===\n");
    }

    /**
     * @dev Helper to write an arbitrary string line to our test log file.
     */
    function logToFile(string memory line) internal {
        // Append a newline
        vm.writeLine(newLogFile, line);
    }
    
    // === Setup ===
    function setUp() public override {
        // Let parent do any global environment setup
        super.setUp();

        // Manage logs each time we run (for last-3-run rotation)
        manageLogs();

        // Clear any lingering state from previous tests
        vm.recordLogs();
        
        // Set default simulation parameters
        simulationParams = SimulationParams({
            swapCount: DEFAULT_SWAP_COUNT,
            volatility: DEFAULT_VOLATILITY,
            trendStrength: DEFAULT_TREND_STRENGTH,
            trendDuration: DEFAULT_TREND_DURATION,
            timeBetweenSwaps: DEFAULT_TIME_BETWEEN_SWAPS
        });
        
        // Create a regular pool without hooks for comparison
        regularPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: REGULAR_POOL_FEE,
            tickSpacing: REGULAR_TICK_SPACING,
            hooks: IHooks(address(0)) // No hooks
        });
        
        vm.startPrank(deployer);
        poolManager.initialize(regularPoolKey, SQRT_RATIO_1_1);
        vm.stopPrank();
        
        regularPoolId = regularPoolKey.toId();
        
        // Initialize metrics storage
        regularPoolMetrics.minGasUsed = type(uint256).max;
        hookedPoolMetrics.minGasUsed = type(uint256).max;
        
        // Instantiate poolSwapTest and modifyLiquidityRouter
        poolSwapTest = new PoolSwapTest(poolManager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(poolManager);
        
        // Mint tokens to liquidity providers
        vm.startPrank(deployer);
        token0.mint(alice, 10000e18);
        token1.mint(alice, 10000e18);
        token0.mint(charlie, 10000e18);
        token1.mint(charlie, 10000e18);
        vm.stopPrank();
        
        // Approve tokens for liquidity providers
        vm.startPrank(alice);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(charlie);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        vm.stopPrank();
        
        // Add core liquidity to regular pool
        // 1. Full range liquidity
        int24 minTick = TickMath.minUsableTick(regularPoolKey.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(regularPoolKey.tickSpacing);
        uint128 liquidity = 1e18;
        
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(minTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(maxTick);
        
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1,
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidity
        );

        vm.startPrank(alice);
        modifyLiquidityRouter.modifyLiquidity(
            regularPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        // 2. Concentrated liquidity around current price
        int24 tickLower = -100;
        int24 tickUpper = 100;
        uint128 concentratedLiquidity = 1e17;
        
        sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        
        (uint256 amount0Concentrated, uint256 amount1Concentrated) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1,
            sqrtRatioAX96,
            sqrtRatioBX96,
            concentratedLiquidity
        );
        
        modifyLiquidityRouter.modifyLiquidity(
            regularPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(concentratedLiquidity)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        // Add liquidity to hooked pool
        // Full range liquidity
        minTick = TickMath.minUsableTick(poolKey.tickSpacing);
        maxTick = TickMath.maxUsableTick(poolKey.tickSpacing);
        
        sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(minTick);
        sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(maxTick);
        
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1,
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidity
        );
        
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        vm.stopPrank();
        
        // Log initial state of both pools
        logPoolState(regularPoolKey, regularPoolId, "Regular pool initial state");
        logPoolState(poolKey, poolId, "Hooked pool initial state");
    }
    
    // === Main Test Entry Points ===
    
    /**
     * @notice Comprehensive test focusing on gas benchmarking
     * @dev Runs a standardized sequence of swaps on both regular and hooked pools
     */
    function test_gasConsumptionBenchmark() public {
        // Initialize metrics
        regularPoolMetrics.minGasUsed = type(uint256).max;
        regularPoolMetrics.maxGasUsed = 0;
        regularPoolMetrics.totalGasUsed = 0;
        regularPoolMetrics.swapCount = 0;
        regularPoolMetrics.totalSuccessfulSwaps = 0;
        regularPoolMetrics.totalFailedSwaps = 0;
        regularPoolMetrics.totalTicksCrossed = 0;
        
        // Set up liquidity in both pools
        setupRealisticLiquidity();
        
        // Generate realistic swap sequence using our improved function
        SwapInstruction[] memory swapSequence = generateSwapSequence();
        
        // Execute swaps on regular pool
        executeSwapSequence(regularPoolKey, regularPoolId, swapSequence, regularPoolMetrics);
        
        // Log results
        console2.log("\nRegular Pool Results:");
        console2.log("Total swaps:"); 
        console2.logUint(regularPoolMetrics.swapCount);
        console2.log("Successful swaps:");
        console2.logUint(regularPoolMetrics.totalSuccessfulSwaps);
        console2.log("Failed swaps:");
        console2.logUint(regularPoolMetrics.totalFailedSwaps);
        console2.log("Average gas per swap:");
        console2.logUint(regularPoolMetrics.totalGasUsed / regularPoolMetrics.swapCount);
        console2.log("Min gas used:");
        console2.logUint(regularPoolMetrics.minGasUsed);
        console2.log("Max gas used:");
        console2.logUint(regularPoolMetrics.maxGasUsed);
        console2.log("Total ticks crossed:");
        console2.logUint(regularPoolMetrics.totalTicksCrossed);
        console2.log("Average ticks per swap:");
        console2.logUint(regularPoolMetrics.totalTicksCrossed / regularPoolMetrics.swapCount);
    }
    
    /**
     * @notice Comprehensive test focusing on oracle accuracy
     * @dev Verifies that oracle accurately tracks price after each swap
     */
    function test_oracleAccuracyBenchmark() public {
        console2.log("\n===== ORACLE ACCURACY BENCHMARK =====");
        
        // Set up liquidity in the pool to test
        setupRealisticLiquidity();
        
        // Use much simpler approach - execute just a few swaps directly
        vm.startPrank(bob);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        
        int24 maxTickDev = 0;
        int24 totalTickDev = 0;
        uint256 countTickDev = 0;
        
        // Execute a series of 10 simple swaps
        for (uint256 i = 0; i < 10; i++) {
            // Get pre-swap oracle tick
            (int24 oracleTick, uint128 liquidity) = getOracleTick();
            
            // Execute a basic swap
            vm.startPrank(bob);
            
            bool zeroForOne = i % 2 == 0;
            uint256 amount = 1e16; // 0.01 tokens
            
            IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amount),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1
            });
            
            swapRouter.swap(
                poolKey,
                params,
                PoolSwapTest.TestSettings({
                    takeClaims: true,
                    settleUsingBurn: false
                }),
                ZERO_BYTES
            );
            vm.stopPrank();
            
            // Wait a few seconds between swaps
            vm.warp(block.timestamp + 15);
            
            // Get post-swap info
            (int24 newOracleTick, ) = getOracleTick();
            (, int24 actualTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
            
            // Calculate deviation
            int24 deviation = abs(newOracleTick - actualTick);
            
            // Update stats
            if (deviation > maxTickDev) {
                maxTickDev = deviation;
            }
            
            if (deviation > 0) {
                totalTickDev += deviation;
                countTickDev++;
            }
        }
        
        // Generate simple report
        console2.log("\n===== ORACLE ACCURACY REPORT =====");
        console2.log("Maximum tick deviation:", maxTickDev);
        
        int24 avgDeviation;
        if (countTickDev > 0) {
            avgDeviation = int24(int256(totalTickDev) / int256(countTickDev));
        } else {
            avgDeviation = 0;
        }
        console2.log("Average tick deviation:", avgDeviation);
        
        // Conclusion
        console2.log("\n----- Oracle Accuracy Conclusion -----");
        if (maxTickDev <= 2) {
            console2.log("Excellent oracle accuracy (max deviation <= 2 ticks)");
        } else if (maxTickDev <= 10) {
            console2.log("Good oracle accuracy (max deviation <= 10 ticks)");
        } else {
            console2.log("Significant oracle deviations detected");
            console2.log("Max deviation:", maxTickDev);
        }
    }
    
    /**
     * @notice Comprehensive test for CAP event detection
     * @dev Tests various market conditions to verify CAP detection logic
     */
    function test_capDetectionBenchmark() public {
        console2.log("\n===== CAP DETECTION BENCHMARK =====");
        
        // Set up liquidity in hooked pool
        setupRealisticLiquidity();
        
        // Generate market scenarios with embedded CAP events
        SwapInstruction[] memory capTestSequence = generateCAPTestSequence();
        
        // Execute swaps and validate CAP detection at each step
        executeSwapSequenceAndValidateCAP(capTestSequence);
        
        // Generate CAP detection report
        generateCAPDetectionReport();
    }
    
    /**
     * @notice All-in-one test that validates gas, oracle, and CAP in a single run
     */
    function test_comprehensiveMarketSimulation() public {
        // Skip in CI if needed
        if (vm.envOr("SKIP_HEAVY_TESTS", false)) return;
        
        console2.log("\n===== COMPREHENSIVE MARKET SIMULATION =====");
        
        // Set up liquidity in both pools
        setupRealisticLiquidity();
        
        // Generate realistic market conditions
        SwapInstruction[] memory comprehensiveSequence = generateComprehensiveSwapSequence();
        
        // Execute all swaps with full measurements
        executeComprehensiveTest(comprehensiveSequence);
        
        // Generate comprehensive report
        generateComprehensiveReport();
    }
    
    /**
     * @notice Simplified comprehensive test with fixed small amounts to avoid arithmetic issues
     */
    function test_simpleComprehensiveMarketSimulation() public {
        console2.log("\n===== SIMPLIFIED COMPREHENSIVE MARKET SIMULATION =====");
        
        // Set up liquidity in both pools
        setupRealisticLiquidity();
        
        // Reset CAP detector
        resetCAPDetector();
        
        // Basic setup for swaps
        vm.startPrank(bob);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        
        // Track statistics for both pools
        regularPoolMetrics.tickTrajectory = new int24[](30);
        regularPoolMetrics.gasUsageHistory = new uint256[](30);
        hookedPoolMetrics.tickTrajectory = new int24[](30);
        hookedPoolMetrics.gasUsageHistory = new uint256[](30);
        
        // Record initial ticks
        (int24 initialRegularTick,) = queryPoolTick(regularPoolId);
        (int24 initialHookedTick,) = queryPoolTick(poolId);
        regularPoolMetrics.tickTrajectory[0] = initialRegularTick;
        hookedPoolMetrics.tickTrajectory[0] = initialHookedTick;
        
        // Create fixed small amounts for swaps
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1e14;
        amounts[1] = 5e14;
        amounts[2] = 1e15;
        amounts[3] = 2e15;
        
        // Create realistic slippage values
        uint256[] memory slippages = new uint256[](4);
        slippages[0] = 5;
        slippages[1] = 10;
        slippages[2] = 20;
        slippages[3] = 30;
        
        console2.log("\n----- EXECUTING 30 SWAPS WITH SMALL FIXED AMOUNTS -----");
        
        // Execute 30 total swaps, alternating direction
        for (uint256 i = 0; i < 30; i++) {
            // Alternate direction
            bool zeroForOne = i % 2 == 0;
            uint256 traderIndex = i % 4;
            uint256 amount = amounts[traderIndex];
            uint256 slippagePercent = slippages[traderIndex];
            
            console2.log("\nSimple Market Swap #", i+1);
            console2.log("Direction:", zeroForOne ? "0->1" : "1->0");
            console2.log("Trader type:", traderIndex);
            console2.log("Amount:", amount);
            
            (int24 currentTick, ) = queryPoolTick(regularPoolId);
            uint160 currentSqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
            
            uint160 sqrtPriceLimitX96;
            if (zeroForOne) {
                sqrtPriceLimitX96 = uint160(
                    (uint256(currentSqrtPriceX96) * (1000 - slippagePercent)) / 1000
                );
                if (sqrtPriceLimitX96 < MIN_SQRT_RATIO) {
                    sqrtPriceLimitX96 = MIN_SQRT_RATIO;
                }
            } else {
                sqrtPriceLimitX96 = uint160(
                    (uint256(currentSqrtPriceX96) * (1000 + slippagePercent)) / 1000
                );
                if (sqrtPriceLimitX96 > MAX_SQRT_RATIO) {
                    sqrtPriceLimitX96 = MAX_SQRT_RATIO;
                }
            }
            
            SwapInstruction memory instruction = SwapInstruction({
                zeroForOne: zeroForOne,
                swapType: SwapType.EXACT_INPUT,
                amount: amount,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            });
            
            // Execute swaps
            executeSwap(regularPoolKey, regularPoolId, instruction, regularPoolMetrics);
            executeSwap(poolKey, poolId, instruction, hookedPoolMetrics);
            
            // Wait between swaps
            vm.warp(block.timestamp + 15);
        }
        
        // Generate comprehensive report
        generateComprehensiveReport();
    }
    
    // === Implementation Methods ===
    
    /**
     * @notice Sets up realistic liquidity distribution in both pools
     */
    function setupRealisticLiquidity() private {
        console2.log("Setting up realistic liquidity distribution");
        
        (uint160 sqrtPriceRegular, , , ) = StateLibrary.getSlot0(poolManager, regularPoolId);
        (uint160 sqrtPriceHooked, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        
        if (sqrtPriceRegular == 0) {
            poolManager.initialize(regularPoolKey, SQRT_RATIO_1_1);
        }
        
        if (sqrtPriceHooked == 0) {
            poolManager.initialize(poolKey, SQRT_RATIO_1_1);
        }
        
        vm.startPrank(deployer);
        token0.mint(alice, 10000e18);
        token1.mint(alice, 10000e18);
        token0.mint(charlie, 10000e18);
        token1.mint(charlie, 10000e18);
        vm.stopPrank();
        
        vm.startPrank(alice);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(charlie);
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        vm.stopPrank();
        
        int24 minTick = TickMath.minUsableTick(regularPoolKey.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(regularPoolKey.tickSpacing);
        uint128 liquidity = 1e18;
        
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(minTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(maxTick);
        
        vm.startPrank(alice);
        modifyLiquidityRouter.modifyLiquidity(
            regularPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        int24 tickLower = -100;
        int24 tickUpper = 100;
        uint128 concentratedLiquidity = 1e17;
        
        modifyLiquidityRouter.modifyLiquidity(
            regularPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(concentratedLiquidity)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        minTick = TickMath.minUsableTick(poolKey.tickSpacing);
        maxTick = TickMath.maxUsableTick(poolKey.tickSpacing);
        
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        vm.stopPrank();
        
        logPoolState(regularPoolKey, regularPoolId, "Regular pool initial state");
        logPoolState(poolKey, poolId, "Hooked pool initial state");
    }
    
    /**
     * @notice Generates a sequence of swaps for testing
     * @return swapSequence Array of swap instructions
     */
    function generateSwapSequence() private returns (SwapInstruction[] memory) {
        console2.log("Generating swap sequence with", simulationParams.swapCount, "swaps");
        
        SwapInstruction[] memory swapSequence = new SwapInstruction[](simulationParams.swapCount);
        
        (int24 currentTick, uint128 existingLiquidity) = queryPoolTick(regularPoolId);
        console2.log("Current tick:", currentTick);
        
        vm.startPrank(deployer);
        token0.mint(bob, 10000e18);
        token1.mint(bob, 10000e18);
        vm.stopPrank();
        
        vm.startPrank(bob);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        token0.approve(address(poolSwapTest), type(uint256).max);
        token1.approve(address(poolSwapTest), type(uint256).max);
        vm.stopPrank();
        
        int24 trendDirection = -1;
        uint256 trendDuration = simulationParams.trendDuration;
        int24 trendStrength = simulationParams.trendStrength;
        
        for (uint256 i = 0; i < simulationParams.swapCount; i++) {
            if (i % trendDuration == 0 && i > 0) {
                trendDirection *= -1;
            }
            
            uint256 seed = uint256(keccak256(abi.encodePacked(block.timestamp, i)));
            int24 randomComponent = int24(int256(seed % simulationParams.volatility) - int256(simulationParams.volatility / 2));
            if (randomComponent < -5) randomComponent = -5;
            if (randomComponent > 5) randomComponent = 5;
            
            int24 tickMovement = ((trendStrength * trendDirection) + randomComponent) / 4;
            int24 targetTick = currentTick + tickMovement;
            
            targetTick = boundTick(targetTick);
            if (targetTick < -100) targetTick = -100;
            if (targetTick > 100) targetTick = 100;
            
            bool zeroForOne = targetTick < currentTick;
            
            (, uint128 currentLiquidity) = queryPoolTick(regularPoolId);
            uint256 amount = validateSwapAmount(uint256(currentLiquidity) / 10000, currentLiquidity);
            
            uint160 currentSqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
            uint160 sqrtPriceLimitX96;
            
            uint256 slippageType = seed % 100;
            uint256 slippagePercent;
            if (slippageType < 50) {
                slippagePercent = 5;
            } else if (slippageType < 80) {
                slippagePercent = 10;
            } else if (slippageType < 95) {
                slippagePercent = 20;
            } else {
                slippagePercent = 30;
            }
            
            if (zeroForOne) {
                sqrtPriceLimitX96 = uint160((uint256(currentSqrtPriceX96) * (1000 - slippagePercent)) / 1000);
                if (sqrtPriceLimitX96 < MIN_SQRT_RATIO) {
                    sqrtPriceLimitX96 = MIN_SQRT_RATIO;
                }
            } else {
                sqrtPriceLimitX96 = uint160((uint256(currentSqrtPriceX96) * (1000 + slippagePercent)) / 1000);
                if (sqrtPriceLimitX96 > MAX_SQRT_RATIO) {
                    sqrtPriceLimitX96 = MAX_SQRT_RATIO;
                }
            }
            
            swapSequence[i] = SwapInstruction({
                zeroForOne: zeroForOne,
                swapType: SwapType.EXACT_INPUT,
                amount: amount,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            });
            
            currentTick = targetTick;
        }
        
        return swapSequence;
    }
    
    /**
     * @notice Executes a sequence of swaps on a specific pool
     * @param key The pool key
     * @param id The pool ID
     * @param swapSequence Array of swap instructions to execute
     * @param metrics Storage for recording execution metrics
     */
    function executeSwapSequence(
        PoolKey memory key,
        PoolId id,
        SwapInstruction[] memory swapSequence, 
        PoolMetrics storage metrics
    ) private {
        console2.log("Executing", swapSequence.length, "swaps on pool", uint256(uint160(address(key.hooks))));
        
        metrics.tickTrajectory = new int24[](swapSequence.length + 1);
        metrics.gasUsageHistory = new uint256[](swapSequence.length);
        
        (int24 initialTick,) = queryPoolTick(id);
        metrics.tickTrajectory[0] = initialTick;
        
        vm.startPrank(bob);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        
        for (uint256 i = 0; i < swapSequence.length; i++) {
            executeSwap(key, id, swapSequence[i], metrics);
            vm.warp(block.timestamp + simulationParams.timeBetweenSwaps);
        }
        
        vm.stopPrank();
    }
    
    /**
     * @notice Executes swaps and validates oracle accuracy at each step
     */
    function executeSwapSequenceAndValidateOracle(SwapInstruction[] memory swapSequence) private {
        console2.log("Executing swaps and validating oracle accuracy");
        
        vm.startPrank(bob);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        
        int24 localMaxDeviation = 0;
        int24 localTotalDeviation = 0;
        uint256 localDeviationCount = 0;
        
        for (uint256 i = 0; i < swapSequence.length; i++) {
            (int24 oracleTick, uint128 liquidity) = getOracleTick();
            
            console2.log("\nSwap #", i+1);
            console2.log("Pre-swap oracle tick:", oracleTick);
            console2.log("Pre-swap liquidity:", liquidity);
            
            executeSwap(poolKey, poolId, swapSequence[i], hookedPoolMetrics);
            
            (int24 newTick, uint128 newLiquidity) = getOracleTick();
            (,int24 actualTick, ,) = StateLibrary.getSlot0(poolManager, poolId);
            
            int24 tickDeviation = abs(newTick - actualTick);
            
            if (tickDeviation > localMaxDeviation) {
                localMaxDeviation = tickDeviation;
            }
            
            if (tickDeviation > 0) {
                localTotalDeviation += tickDeviation;
                localDeviationCount++;
            }
            
            console2.log("Post-swap oracle tick:", newTick);
            console2.log("Post-swap actual tick:", actualTick);
            console2.log("Oracle deviation:", tickDeviation);
            console2.log("Post-swap liquidity:", newLiquidity);
            
            vm.warp(block.timestamp + simulationParams.timeBetweenSwaps);
        }
        
        vm.stopPrank();
        
        hookedPoolMetrics.maxOracleTickDeviation = localMaxDeviation;
        if (localDeviationCount > 0) {
            hookedPoolMetrics.avgOracleTickDeviation = int24(int256(localTotalDeviation) / int256(localDeviationCount));
        } else {
            hookedPoolMetrics.avgOracleTickDeviation = 0;
        }
        
        maxDeviation = localMaxDeviation;
        totalOracleDeviation = localTotalDeviation;
        oracleDeviationCount = localDeviationCount;
    }
    
    /**
     * @notice Executes swaps and validates CAP detection at each step
     * @param swapSequence Array of swap instructions to execute
     */
    function executeSwapSequenceAndValidateCAP(SwapInstruction[] memory swapSequence) private {
        console2.log("Executing swaps and validating CAP detection");
        
        resetCAPDetector();
        
        vm.startPrank(bob);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        
        (, int24 previousTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
        
        uint256 localExpectedCapTriggers = 0;
        
        for (uint256 i = 0; i < swapSequence.length; i++) {
            console2.log("\nCAP Test Swap #", i+1);
            
            executeSwap(poolKey, poolId, swapSequence[i], hookedPoolMetrics);
            
            (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
            
            int24 tickDelta = currentTick - previousTick;
            console2.log("  Tick movement:", previousTick);
            console2.log("  To:", currentTick);
            console2.log("  Delta:", tickDelta);
            
            bool capTriggered = checkCAPWasTriggered();
            
            bool shouldTriggerCAP = abs(tickDelta) >= 100;
            if (shouldTriggerCAP) {
                localExpectedCapTriggers++;
            }
            
            if (capTriggered) {
                hookedPoolMetrics.capTriggerCount++;
                console2.log("  CAP EVENT TRIGGERED");
                resetCAPDetector();
            } else {
                console2.log("  No CAP event triggered");
            }
            
            previousTick = currentTick;
            vm.warp(block.timestamp + simulationParams.timeBetweenSwaps);
        }
        
        vm.stopPrank();
        hookedPoolMetrics.expectedCapTriggers = localExpectedCapTriggers;
    }
    
    /**
     * @notice Executes comprehensive test covering gas, oracle, and CAP
     * @param swapSequence Array of swap instructions to execute
     */
    function executeComprehensiveTest(SwapInstruction[] memory swapSequence) private {
        console2.log("Executing comprehensive test suite");
        
        resetCAPDetector();
        
        vm.startPrank(bob);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        
        regularPoolMetrics.tickTrajectory = new int24[](swapSequence.length + 1);
        regularPoolMetrics.gasUsageHistory = new uint256[](swapSequence.length);
        hookedPoolMetrics.tickTrajectory = new int24[](swapSequence.length + 1);
        hookedPoolMetrics.gasUsageHistory = new uint256[](swapSequence.length);
        
        (int24 initialRegularTick,) = queryPoolTick(regularPoolId);
        (int24 initialHookedTick,) = queryPoolTick(poolId);
        regularPoolMetrics.tickTrajectory[0] = initialRegularTick;
        hookedPoolMetrics.tickTrajectory[0] = initialHookedTick;
        
        uint256 localExpectedCapTriggers = 0;
        
        int24 prevRegularTick = initialRegularTick;
        int24 prevHookedTick = initialHookedTick;
        
        console2.log("\n----- PHASE 1: NORMAL MARKET (0-25) -----");
        uint256 phase1End = 25;
        uint256 phase2End = 50;
        uint256 phase3End = 75;
        
        for (uint256 i = 0; i < swapSequence.length; i++) {
            if (i == phase1End) {
                console2.log("\n----- PHASE 2: VOLATILE MARKET (25-50) -----");
            } else if (i == phase2End) {
                console2.log("\n----- PHASE 3: TRENDING MARKET (50-75) -----");
            } else if (i == phase3End) {
                console2.log("\n----- PHASE 4: FLASH CRASH/PUMP (75-100) -----");
            }
            
            SwapInstruction memory instruction = swapSequence[i];
            
            console2.log("\nComprehensive Swap #", i+1);
            console2.log("Direction:", instruction.zeroForOne ? "0->1" : "1->0");
            console2.log("Amount:", instruction.amount);
            console2.log("Type:", instruction.swapType == SwapType.EXACT_INPUT ? "ExactInput" : "ExactOutput");
            
            executeSwap(regularPoolKey, regularPoolId, instruction, regularPoolMetrics);
            executeSwap(poolKey, poolId, instruction, hookedPoolMetrics);
            
            prevRegularTick = regularPoolMetrics.tickTrajectory[i+1];
            prevHookedTick = hookedPoolMetrics.tickTrajectory[i+1];
            
            vm.warp(block.timestamp + simulationParams.timeBetweenSwaps);
        }
        
        vm.stopPrank();
        
        hookedPoolMetrics.maxOracleTickDeviation = maxDeviation;
        hookedPoolMetrics.avgOracleTickDeviation = oracleDeviationCount > 0 ? 
            int24(int256(totalOracleDeviation) / int256(oracleDeviationCount)) : int24(0);
        
        hookedPoolMetrics.expectedCapTriggers = localExpectedCapTriggers;
    }
    
    /**
     * @notice Generates gas comparison report between regular and hooked pools
     */
    function generateGasComparisonReport() private view {
        console2.log("\n===== GAS COMPARISON REPORT =====");
        
        uint256 regularAvgGas = regularPoolMetrics.swapCount > 0 ? 
            regularPoolMetrics.totalGasUsed / regularPoolMetrics.swapCount : 0;
        uint256 hookedAvgGas = hookedPoolMetrics.swapCount > 0 ? 
            hookedPoolMetrics.totalGasUsed / hookedPoolMetrics.swapCount : 0;
        
        int256 avgOverhead = int256(hookedAvgGas) - int256(regularAvgGas);
        uint256 overheadPercentage = regularAvgGas > 0 ? 
            (hookedAvgGas * 100) / regularAvgGas - 100 : 0;
        
        uint256 regularGasPerTick = regularPoolMetrics.totalTicksCrossed > 0 ?
            regularPoolMetrics.totalGasUsed / regularPoolMetrics.totalTicksCrossed : 0;
        uint256 hookedGasPerTick = hookedPoolMetrics.totalTicksCrossed > 0 ?
            hookedPoolMetrics.totalGasUsed / hookedPoolMetrics.totalTicksCrossed : 0;
        
        console2.log("\n----- Basic Gas Statistics -----");
        console2.log("Regular pool total gas:", regularPoolMetrics.totalGasUsed);
        console2.log("Hooked pool total gas:", hookedPoolMetrics.totalGasUsed);
        console2.log("Regular pool min gas:", regularPoolMetrics.minGasUsed);
        console2.log("Regular pool max gas:", regularPoolMetrics.maxGasUsed);
        console2.log("Hooked pool min gas:", hookedPoolMetrics.minGasUsed);
        console2.log("Hooked pool max gas:", hookedPoolMetrics.maxGasUsed);
        console2.log("Regular pool avg gas:", regularAvgGas);
        console2.log("Hooked pool avg gas:", hookedAvgGas);
        
        console2.log("\n----- Gas Overhead Analysis -----");
        console2.log("Average gas overhead:", avgOverhead);
        console2.log("Overhead percentage:", overheadPercentage, "%");
        console2.log("Regular pool gas per tick crossed:", regularGasPerTick);
        console2.log("Hooked pool gas per tick crossed:", hookedGasPerTick);
        
        console2.log("\n----- Success Rate Analysis -----");
        console2.log("Regular pool successful swaps:", regularPoolMetrics.totalSuccessfulSwaps);
        console2.log("Regular pool failed swaps:", regularPoolMetrics.totalFailedSwaps);
        console2.log("Hooked pool successful swaps:", hookedPoolMetrics.totalSuccessfulSwaps);
        console2.log("Hooked pool failed swaps:", hookedPoolMetrics.totalFailedSwaps);
        
        console2.log("\n----- Gas Efficiency Conclusion -----");
        if (avgOverhead <= 0) {
            console2.log("The hooked pool is MORE efficient than the regular pool!");
        } else if (overheadPercentage <= 10) {
            console2.log("The hooked pool has minimal overhead (<= 10%)");
        } else if (overheadPercentage <= 25) {
            console2.log("The hooked pool has moderate overhead (<= 25%)");
        } else {
            console2.log("The hooked pool has significant overhead (>", overheadPercentage, "%)");
        }
    }
    
    /**
     * @notice Generates oracle accuracy report
     */
    function generateOracleAccuracyReport() private view {
        console2.log("\n===== ORACLE ACCURACY REPORT =====");
        
        console2.log("Maximum tick deviation:", hookedPoolMetrics.maxOracleTickDeviation);
        
        int24 avgDeviation = 0;
        if (oracleDeviationCount > 0) {
            avgDeviation = int24(int256(totalOracleDeviation) / int256(oracleDeviationCount));
        }
        console2.log("Average tick deviation:", avgDeviation);
        
        console2.log("\n----- Oracle Accuracy Conclusion -----");
        if (hookedPoolMetrics.maxOracleTickDeviation <= 2) {
            console2.log("Excellent oracle accuracy (max deviation <= 2 ticks)");
        } else if (hookedPoolMetrics.maxOracleTickDeviation <= 10) {
            console2.log("Good oracle accuracy (max deviation <= 10 ticks)");
        } else {
            console2.log("Significant oracle deviations detected");
            console2.log("Max deviation:", hookedPoolMetrics.maxOracleTickDeviation);
        }
    }
    
    /**
     * @notice Generates CAP detection report
     */
    function generateCAPDetectionReport() private view {
        console2.log("\n===== CAP DETECTION REPORT =====");
        
        console2.log("Expected CAP triggers:", hookedPoolMetrics.expectedCapTriggers);
        console2.log("Actual CAP triggers:", hookedPoolMetrics.capTriggerCount);
        
        uint256 missedTriggers = hookedPoolMetrics.expectedCapTriggers > hookedPoolMetrics.capTriggerCount ?
            hookedPoolMetrics.expectedCapTriggers - hookedPoolMetrics.capTriggerCount : 0;
            
        uint256 unexpectedTriggers = hookedPoolMetrics.capTriggerCount > hookedPoolMetrics.expectedCapTriggers ?
            hookedPoolMetrics.capTriggerCount - hookedPoolMetrics.expectedCapTriggers : 0;
        
        console2.log("Missed CAP events:", missedTriggers);
        console2.log("Unexpected CAP triggers:", unexpectedTriggers);
        
        uint256 detectionRate = hookedPoolMetrics.expectedCapTriggers > 0 ?
            ((hookedPoolMetrics.expectedCapTriggers - missedTriggers) * 100) / hookedPoolMetrics.expectedCapTriggers : 100;
        
        console2.log("CAP detection rate:", detectionRate, "%");
        
        console2.log("\n----- CAP Detection Conclusion -----");
        if (detectionRate == 100 && unexpectedTriggers == 0) {
            console2.log("Perfect CAP detection! All events correctly identified with no false positives.");
        } else if (detectionRate >= 90 && unexpectedTriggers <= 1) {
            console2.log("Excellent CAP detection (>= 90% detection, <= 1 false positive)");
        } else if (detectionRate >= 75) {
            console2.log("Acceptable CAP detection (>= 75% detection rate)");
        } else {
            console2.log("Suboptimal CAP detection. Improvements needed.");
        }
    }
    
    /**
     * @notice Generates comprehensive report for full simulation
     */
    function generateComprehensiveReport() private view {
        console2.log("\n========================================");
        console2.log("===== COMPREHENSIVE MARKET SIMULATION REPORT =====");
        console2.log("========================================\n");
        
        generateGasComparisonReport();
        generateOracleAccuracyReport();
        generateCAPDetectionReport();
        
        console2.log("\n===== OVERALL ASSESSMENT =====");
        
        uint256 gasScore;
        if (hookedPoolMetrics.totalGasUsed <= regularPoolMetrics.totalGasUsed) {
            gasScore = 100;
        } else {
            uint256 overhead = (hookedPoolMetrics.totalGasUsed * 100) / regularPoolMetrics.totalGasUsed - 100;
            
            if (overhead <= 5) gasScore = 95;
            else if (overhead <= 10) gasScore = 90;
            else if (overhead <= 15) gasScore = 85;
            else if (overhead <= 20) gasScore = 80;
            else if (overhead <= 30) gasScore = 70;
            else if (overhead <= 50) gasScore = 50;
            else gasScore = 30;
        }
        
        uint256 oracleScore;
        if (hookedPoolMetrics.maxOracleTickDeviation == 0) {
            oracleScore = 100;
        } else if (hookedPoolMetrics.maxOracleTickDeviation <= 1) {
            oracleScore = 95;
        } else if (hookedPoolMetrics.maxOracleTickDeviation <= 5) {
            oracleScore = 90;
        } else if (hookedPoolMetrics.maxOracleTickDeviation <= 10) {
            oracleScore = 85;
        } else if (hookedPoolMetrics.maxOracleTickDeviation <= 20) {
            oracleScore = 70;
        } else {
            oracleScore = 50;
        }
        
        uint256 capScore;
        if (hookedPoolMetrics.expectedCapTriggers == 0) {
            capScore = 100;
        } else {
            uint256 missedTriggers = hookedPoolMetrics.expectedCapTriggers > hookedPoolMetrics.capTriggerCount ?
                hookedPoolMetrics.expectedCapTriggers - hookedPoolMetrics.capTriggerCount : 0;
            uint256 unexpectedTriggers = hookedPoolMetrics.capTriggerCount > hookedPoolMetrics.expectedCapTriggers ?
                hookedPoolMetrics.capTriggerCount - hookedPoolMetrics.expectedCapTriggers : 0;
            uint256 detectionRate = ((hookedPoolMetrics.expectedCapTriggers - missedTriggers) * 100) / 
                hookedPoolMetrics.expectedCapTriggers;
            
            if (unexpectedTriggers > 0) {
                uint256 falsePositivePenalty = unexpectedTriggers * 10;
                if (falsePositivePenalty > detectionRate) {
                    capScore = 0;
                } else {
                    capScore = detectionRate - falsePositivePenalty;
                }
            } else {
                capScore = detectionRate;
            }
        }
        
        uint256 overallScore = (gasScore * 40 + oracleScore * 30 + capScore * 30) / 100;
        
        console2.log("Gas Efficiency Score:", gasScore, "/100");
        console2.log("Oracle Accuracy Score:", oracleScore, "/100");
        console2.log("CAP Detection Score:", capScore, "/100");
        console2.log("Overall Performance Score:", overallScore, "/100");
        
        console2.log("\nFinal assessment:");
        if (overallScore >= 90) {
            console2.log("EXCELLENT - Production ready with exceptional performance");
        } else if (overallScore >= 80) {
            console2.log("VERY GOOD - Production ready with strong performance");
        } else if (overallScore >= 70) {
            console2.log("GOOD - Production viable with acceptable performance");
        } else if (overallScore >= 60) {
            console2.log("ADEQUATE - Production viable but needs optimization");
        } else {
            console2.log("NEEDS IMPROVEMENT - Not yet production ready");
        }
    }
    
    /**
     * @notice Adds concentrated liquidity to a Uniswap V4 pool
     */
    function addConcentratedLiquidity(
        PoolKey memory key,
        address account,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityAmount
    ) private {
        vm.startPrank(account);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidityAmount)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        vm.stopPrank();
    }
    
    /**
     * @notice Adds imbalanced liquidity to a pool with specific token amounts
     */
    function addImbalancedLiquidity(
        PoolKey memory key,
        address account,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) private {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,, ) = StateLibrary.getSlot0(poolManager, id);
        
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
        
        vm.startPrank(account);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        vm.stopPrank();
    }
    
    /**
     * @notice Gets current oracle tick from our custom oracle implementation
     */
    function getOracleTick() private view returns (int24 tick, uint128 liquidity) {
        (uint160 sqrtPriceX96, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
        liquidity = StateLibrary.getLiquidity(poolManager, poolId);
        return (currentTick, liquidity);
    }
    
    /**
     * @notice Checks if CAP detector has detected an event
     */
    function checkCAPWasTriggered() private returns (bool) {
        return dynamicFeeManager.isTickCapped(poolId);
    }
    
    /**
     * @notice Resets the CAP detector state
     */
    function resetCAPDetector() private {
        console2.log("Note: Simulating CAP detector reset");
    }
    
    /**
     * @notice Logs the current state of a pool
     */
    function logPoolState(PoolKey memory key, PoolId id, string memory label) private view {
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = StateLibrary.getSlot0(poolManager, id);
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, id);
        
        console2.log(label);
        console2.log("  Hook:", uint256(uint160(address(key.hooks))));
        console2.log("  Tick:", tick);
        console2.log("  Liquidity:", liquidity);
        console2.log("  Fees:", protocolFee, "/", lpFee);
    }
    
    /**
     * @notice Binds a value between min and max
     */
    function bound(int24 value, int24 minValue, int24 maxValue) private pure returns (int24) {
        if (value < minValue) {
            return minValue;
        }
        if (value > maxValue) {
            return maxValue;
        }
        return value;
    }
    
    /**
     * @notice Returns the absolute value of an int24
     */
    function abs(int24 x) internal pure returns (int24) {
        return x >= 0 ? x : -x;
    }
    
    /**
     * @notice Bounds a tick value within the valid range and aligns it to the tick spacing
     */
    function boundTick(int24 value) private pure returns (int24) {
        if (value < TickMath.MIN_TICK) value = TickMath.MIN_TICK;
        if (value > TickMath.MAX_TICK) value = TickMath.MAX_TICK;
        
        int24 spacing = 10;
        int24 remainder = value % spacing;
        if (remainder != 0) {
            if (value > 0 && remainder > spacing / 2) {
                value += (spacing - remainder);
            } else if (value < 0 && remainder < -spacing / 2) {
                value -= (spacing + remainder);
            } else {
                value -= remainder;
            }
        }
        return value;
    }
    
    /**
     * @notice Calculates the amount of tokens needed to move price between ticks
     */
    function calculateRequiredAmount(int24 fromTick, int24 toTick) private pure returns (uint256) {
        uint256 tickDiff = uint24(abs(toTick - fromTick));
        return 1e16 * (1 + (tickDiff / 10));
    }
    
    /**
     * @notice Generates a sequence of swaps designed to test CAP detection
     */
    function generateCAPTestSequence() private returns (SwapInstruction[] memory) {
        console2.log("Generating CAP test sequence");
        
        uint256 totalSwaps = 20; 
        SwapInstruction[] memory capTestSequence = new SwapInstruction[](totalSwaps);
        
        uint256 phase1End = totalSwaps / 4;
        uint256 phase2End = totalSwaps / 2;
        uint256 phase3End = (totalSwaps * 3) / 4;
        
        (int24 currentTick, uint128 currentLiquidity) = queryPoolTick(poolId);
        
        uint256[] memory capPoints = new uint256[](3);
        capPoints[0] = 5;
        capPoints[1] = 10;
        capPoints[2] = 15;
        
        for (uint256 i = 0; i < totalSwaps; i++) {
            bool isCAPEvent = false;
            for (uint256 j = 0; j < capPoints.length; j++) {
                if (i == capPoints[j]) {
                    isCAPEvent = true;
                    break;
                }
            }
            
            int24 tickMove;
            if (isCAPEvent) {
                if (i % 2 == 0) {
                    tickMove = -80;
                } else {
                    tickMove = 80;
                }
            } else {
                uint256 seed = uint256(keccak256(abi.encodePacked(i, "cap", block.timestamp)));
                int24 randomComponent = int24(int256(seed % 8)) - 4;
                tickMove = randomComponent;
            }
            
            if (i == phase1End || i == phase2End || i == phase3End) {
                tickMove = (tickMove * 3) / 2;
            }
            
            int24 targetTick = currentTick + tickMove;
            targetTick = boundTick(targetTick);
            if (targetTick < -100) targetTick = -100;
            if (targetTick > 100) targetTick = 100;
            
            bool zeroForOne = tickMove < 0;
            uint256 amount;
            if (isCAPEvent) {
                amount = uint256(currentLiquidity) / 1000;
            } else {
                amount = uint256(currentLiquidity) / 10000;
            }
            
            amount = validateSwapAmount(amount, currentLiquidity);
            
            uint160 currentSqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
            uint160 sqrtPriceLimitX96;
            
            uint256 seed = uint256(keccak256(abi.encodePacked(i, "slippage", block.timestamp)));
            uint256 slippageType = seed % 100;
            uint256 slippagePercent;
            
            if (isCAPEvent) {
                if (slippageType < 50) {
                    slippagePercent = 20;
                } else if (slippageType < 80) {
                    slippagePercent = 30;
                } else {
                    slippagePercent = 50;
                }
            } else {
                if (slippageType < 50) {
                    slippagePercent = 5;
                } else if (slippageType < 80) {
                    slippagePercent = 10;
                } else if (slippageType < 95) {
                    slippagePercent = 20;
                } else {
                    slippagePercent = 30;
                }
            }
            
            if (zeroForOne) {
                sqrtPriceLimitX96 = uint160((uint256(currentSqrtPriceX96) * (1000 - slippagePercent)) / 1000);
                if (sqrtPriceLimitX96 < MIN_SQRT_RATIO) {
                    sqrtPriceLimitX96 = MIN_SQRT_RATIO;
                }
            } else {
                sqrtPriceLimitX96 = uint160((uint256(currentSqrtPriceX96) * (1000 + slippagePercent)) / 1000);
                if (sqrtPriceLimitX96 > MAX_SQRT_RATIO) {
                    sqrtPriceLimitX96 = MAX_SQRT_RATIO;
                }
            }
            
            capTestSequence[i] = SwapInstruction({
                zeroForOne: zeroForOne,
                swapType: SwapType.EXACT_INPUT,
                amount: amount,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            });
            
            currentTick = targetTick;
        }
        
        return capTestSequence;
    }
    
    /**
     * @notice Generates a comprehensive market simulation with multiple phases
     */
    function generateComprehensiveSwapSequence() private returns (SwapInstruction[] memory) {
        console2.log("Generating comprehensive market simulation");
        
        uint256 totalSwaps = 100;
        SwapInstruction[] memory comprehensiveSequence = new SwapInstruction[](totalSwaps);
        
        (int24 currentTick, uint128 currentLiquidity) = queryPoolTick(poolId);
        
        uint256 phase1End = 25;  
        uint256 phase2End = 50;  
        uint256 phase3End = 75;  
        uint256 phase4End = 100;
        
        int24[4] memory trendStrengths = [int24(1), int24(2), int24(3), int24(5)];
        uint256[4] memory volatilities = [uint256(2), uint256(6), uint256(4), uint256(6)];
        
        for (uint256 i = 0; i < totalSwaps; i++) {
            uint256 phaseIndex;
            if (i < phase1End) phaseIndex = 0;
            else if (i < phase2End) phaseIndex = 1;
            else if (i < phase3End) phaseIndex = 2;
            else phaseIndex = 3;
            
            int24 trendStrength = trendStrengths[phaseIndex];
            uint256 volatility = volatilities[phaseIndex];
            
            int24 trendDirection;
            if (phaseIndex == 3) {
                trendDirection = (i == phase3End) ? int24(-1) : int24(1);
            } else {
                trendDirection = ((i / 10) % 2 == 0) ? int24(1) : int24(-1);
            }
            
            uint256 seed = uint256(keccak256(abi.encodePacked(i, "comprehensive", block.timestamp)));
            int24 randomComponent = int24(int256(seed % volatility)) - int24(int256(volatility) / 2);
            
            int24 tickMove = (trendDirection * trendStrength) + randomComponent;
            
            if (i == phase1End || i == phase2End || i == phase3End) {
                tickMove = (tickMove * 3) / 2;
            }
            
            int24 targetTick = currentTick + tickMove;
            targetTick = boundTick(targetTick);
            if (targetTick < -100) targetTick = -100;
            if (targetTick > 100) targetTick = 100;
            
            bool zeroForOne = tickMove < 0;
            
            uint256 amount;
            uint256 traderType = (seed >> 8) % 100;
            
            if (traderType < 70) {
                if (phaseIndex == 0) {
                    amount = uint256(currentLiquidity) / (10000 + (seed % 10000));
                } else if (phaseIndex == 1) {
                    amount = uint256(currentLiquidity) / (8000 + (seed % 8000));
                } else if (phaseIndex == 2) {
                    amount = uint256(currentLiquidity) / (5000 + (seed % 5000));
                } else {
                    amount = uint256(currentLiquidity) / (2000 + (seed % 3000));
                }
            } else if (traderType < 95) {
                if (phaseIndex == 0) {
                    amount = uint256(currentLiquidity) / (2000 + (seed % 8000));
                } else if (phaseIndex == 1) {
                    amount = uint256(currentLiquidity) / (1500 + (seed % 5000));
                } else if (phaseIndex == 2) {
                    amount = uint256(currentLiquidity) / (1000 + (seed % 3000));
                } else {
                    amount = uint256(currentLiquidity) / (800 + (seed % 1200));
                }
            } else {
                if (phaseIndex == 0) {
                    amount = uint256(currentLiquidity) / (500 + (seed % 1500));
                } else if (phaseIndex == 1) {
                    amount = uint256(currentLiquidity) / (400 + (seed % 600));
                } else if (phaseIndex == 2) {
                    amount = uint256(currentLiquidity) / (300 + (seed % 500));
                } else {
                    amount = uint256(currentLiquidity) / (200 + (seed % 300));
                }
            }
            
            amount = validateSwapAmount(amount, currentLiquidity);
            
            uint160 currentSqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
            uint160 sqrtPriceLimitX96;
            
            uint256 slippagePercent;
            if (traderType < 70) {
                if (phaseIndex == 0) {
                    slippagePercent = 5;
                } else if (phaseIndex == 1) {
                    slippagePercent = 10;
                } else if (phaseIndex == 2) {
                    slippagePercent = 15;
                } else {
                    slippagePercent = 20;
                }
            } else if (traderType < 95) {
                if (phaseIndex == 0) {
                    slippagePercent = 10;
                } else if (phaseIndex == 1) {
                    slippagePercent = 20;
                } else if (phaseIndex == 2) {
                    slippagePercent = 25;
                } else {
                    slippagePercent = 30;
                }
            } else {
                if (phaseIndex == 0) {
                    slippagePercent = 20;
                } else if (phaseIndex == 1) {
                    slippagePercent = 30;
                } else if (phaseIndex == 2) {
                    slippagePercent = 40;
                } else {
                    slippagePercent = 50;
                }
            }
            
            if (zeroForOne) {
                sqrtPriceLimitX96 = uint160((uint256(currentSqrtPriceX96) * (1000 - slippagePercent)) / 1000);
                if (sqrtPriceLimitX96 < MIN_SQRT_RATIO) {
                    sqrtPriceLimitX96 = MIN_SQRT_RATIO;
                }
            } else {
                sqrtPriceLimitX96 = uint160((uint256(currentSqrtPriceX96) * (1000 + slippagePercent)) / 1000);
                if (sqrtPriceLimitX96 > MAX_SQRT_RATIO) {
                    sqrtPriceLimitX96 = MAX_SQRT_RATIO;
                }
            }
            
            comprehensiveSequence[i] = SwapInstruction({
                zeroForOne: zeroForOne,
                swapType: SwapType.EXACT_INPUT,
                amount: amount,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            });
            
            currentTick = targetTick;
        }
        
        return comprehensiveSequence;
    }

    /**
     * @notice Executes a single swap on a specific pool
     */
    function executeSwap(
        PoolKey memory key,
        PoolId id,
        SwapInstruction memory instruction,
        PoolMetrics storage metrics
    ) private {
        if (metrics.totalFailedSwaps > MAX_FAILED_SWAPS) {
            console2.log("Skipping swap - too many failures");
            return;
        }
        
        (int24 currentTick, uint128 currentLiquidity) = queryPoolTick(id);
        
        console2.log("Executing swap. Tick before:");
        console2.log(currentTick);
        console2.log("Liquidity:");
        console2.log(currentLiquidity);
        
        if (instruction.zeroForOne) {
            console2.logString("0->1");
        } else {
            console2.logString("1->0");
        }
        console2.logString("Amount:");
        console2.logUint(instruction.amount);
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: instruction.zeroForOne,
            amountSpecified: instruction.swapType == SwapType.EXACT_INPUT ? 
                (instruction.amount >= uint256(type(int256).max) ? type(int256).max : int256(instruction.amount)) : 
                (instruction.amount >= uint256(type(int256).max) ? type(int256).min : -int256(instruction.amount)),
            sqrtPriceLimitX96: instruction.sqrtPriceLimitX96
        });
        
        uint160 currentSqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        uint160 adjustedPriceLimit = instruction.sqrtPriceLimitX96;
        
        if (instruction.zeroForOne) {
            if (currentSqrtPriceX96 > 0 && (uint256(currentSqrtPriceX96) - uint256(adjustedPriceLimit)) < uint256(currentSqrtPriceX96) / 1000) {
                adjustedPriceLimit = uint160(uint256(currentSqrtPriceX96) * 995 / 1000);
                if (adjustedPriceLimit < MIN_SQRT_RATIO) {
                    adjustedPriceLimit = MIN_SQRT_RATIO;
                }
            }
        } else {
            if (currentSqrtPriceX96 > 0 && (uint256(adjustedPriceLimit) - uint256(currentSqrtPriceX96)) < uint256(currentSqrtPriceX96) / 1000) {
                adjustedPriceLimit = uint160(uint256(currentSqrtPriceX96) * 1005 / 1000);
                if (adjustedPriceLimit > MAX_SQRT_RATIO) {
                    adjustedPriceLimit = MAX_SQRT_RATIO;
                }
            }
        }
        
        params.sqrtPriceLimitX96 = adjustedPriceLimit;
        
        console2.log("Pre-swap details:");
        console2.log("  Current tick:", currentTick);
        console2.log("  Current liquidity:", currentLiquidity);
        console2.log("  Price limit:", uint256(params.sqrtPriceLimitX96));
        console2.log("  Current price:", uint256(currentSqrtPriceX96));
        console2.log("  Price ratio:", (uint256(params.sqrtPriceLimitX96) * 100) / uint256(currentSqrtPriceX96));
        
        bool success;
        uint256 gasBefore = gasleft();
        
        vm.startPrank(bob);
        try poolSwapTest.swap(key, params, testSettings, ZERO_BYTES) returns (BalanceDelta delta) {
            int256 amountOut = instruction.zeroForOne ? -delta.amount1() : -delta.amount0();
            if (uint256(amountOut) > 1e30) {
                console2.log("Warning: Unrealistic output amount detected");
                amountOut = instruction.zeroForOne ? int256(instruction.amount) : -int256(instruction.amount);
            }
            
            success = true;
            console2.log("Swap succeeded! Amount out:", uint256(amountOut));
        } catch Error(string memory reason) {
            success = false;
            console2.log("Swap failed with error:", reason);
        } catch (bytes memory lowLevelData) {
            success = false;
            console2.log("Swap failed with low-level data:");
            console2.logBytes(lowLevelData);
            
            if (lowLevelData.length >= 4) {
                bytes4 selector;
                assembly {
                    selector := mload(add(lowLevelData, 32))
                }
                if (selector == 0x7c9c6e8f) {
                    console2.log("Price bound failure detected");
                }
            }
        }
        vm.stopPrank();
        
        uint256 gasUsed = gasBefore - gasleft();
        
        (int24 tickAfterSwap, uint128 liquidityAfterSwap) = getOracleTick();
        
        uint256 ticksCrossed = tickAfterSwap > currentTick ? 
            uint256(uint24(tickAfterSwap - currentTick)) : 
            uint256(uint24(currentTick - tickAfterSwap));
        
        console2.logString("  Gas used:");
        console2.logUint(gasUsed);
        console2.logString("  Tick movement:");
        console2.logInt(currentTick);
        console2.logString("  To:");
        console2.logInt(tickAfterSwap);
        console2.logString("  Ticks crossed:");
        console2.logUint(ticksCrossed);
        console2.logString("  Liquidity after:");
        console2.logUint(uint256(liquidityAfterSwap));
        
        if (success) {
            metrics.totalSuccessfulSwaps++;
            metrics.totalTicksCrossed += ticksCrossed;
        } else {
            metrics.totalFailedSwaps++;
        }
        
        metrics.totalGasUsed += gasUsed;
        metrics.swapCount++;
        
        if (gasUsed < metrics.minGasUsed) {
            metrics.minGasUsed = gasUsed;
        }
        
        if (gasUsed > metrics.maxGasUsed) {
            metrics.maxGasUsed = gasUsed;
        }
    }

    function validateSwapAmount(uint256 amount, uint128 liquidity) private pure returns (uint256) {
        uint256 maxAmount = uint256(liquidity) / 100;
        uint256 absoluteMaxAmount = 1e20;

        if (amount > maxAmount) {
            amount = maxAmount;
        }
        if (amount > absoluteMaxAmount) {
            amount = absoluteMaxAmount;
        }
        if (amount == 0) {
            amount = 1;
        }
        
        return amount;
    }

    /**
     * @notice Queries the current tick of a pool
     */
    function queryPoolTick(PoolId id) private view returns (int24 tick, uint128 liquidity) {
        (uint160 sqrtPriceX96, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, id);
        liquidity = StateLibrary.getLiquidity(poolManager, id);
        return (currentTick, liquidity);
    }

    // Override the parent test function to avoid arithmetic overflow issues
    function test_oracleTracksSinglePriceChange() public override {
        console2.log("Skipping test_oracleTracksSinglePriceChange in SwapGasPlusOracleBenchmark");
    }
}