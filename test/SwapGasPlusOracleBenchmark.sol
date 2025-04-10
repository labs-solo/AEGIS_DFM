// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "./MarginTestBase.t.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {DepositParams} from "../src/interfaces/ISpot.sol";
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
import {PoolId} from "v4-core/src/types/PoolId.sol";

/**
 * @title SwapGasPlusOracleBenchmark
 * @notice Comprehensive benchmark for swap gas consumption, oracle accuracy, and CAP detection
 */
contract SwapGasPlusOracleBenchmark is MarginTestBase {
    using StateLibrary for IPoolManager;
    using FullMath for uint256;

    // Helper function for absolute value
    function abs(int24 x) public pure returns (int24) {
        return x >= 0 ? x : -x;
    }

    // === Constants ===
    bytes constant ZERO_BYTES = "";
    uint160 constant SQRT_RATIO_1_1 = 1 << 96;  // 1:1 price using Q64.96 format
    uint160 constant MIN_SQRT_RATIO = 4295128739;
    uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    
    // Default parameter values (can be overridden)
    uint256 constant DEFAULT_SWAP_COUNT = 50;
    uint256 constant DEFAULT_VOLATILITY = 10;
    int24 constant DEFAULT_TREND_STRENGTH = 5;  // Strength of price trend
    uint256 constant DEFAULT_TREND_DURATION = 8;  // Duration of trend in swaps
    uint256 constant DEFAULT_TIME_BETWEEN_SWAPS = 15;  // Time between swaps in seconds
    uint256 constant MAX_FAILED_SWAPS = 20; // Maximum number of failed swaps before stopping
    
    // Class variables for pool tracking
    PoolId public poolId;
    PoolKey public poolKey;
    
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
        
        // Create a regular pool without hooks
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
        
        // Create a hooked pool using the createPoolAndRegister helper
        (poolId, poolKey) = createPoolAndRegister(
            address(fullRange),
            address(liquidityManager),
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            DEFAULT_FEE,
            DEFAULT_TICK_SPACING,
            SQRT_RATIO_1_1
        );
        
        // Approve tokens for liquidity providers
        vm.startPrank(alice);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(charlie);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        vm.stopPrank();
        
        // Add core liquidity to regular pool
        // 1. Full range liquidity
        int24 minTick = TickMath.minUsableTick(regularPoolKey.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(regularPoolKey.tickSpacing);
        uint128 liquidity = 1e12; // Reduced liquidity
        
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(minTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(maxTick);
        
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1,
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidity
        );

        vm.startPrank(alice);
        lpRouter.modifyLiquidity(
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
        uint128 concentratedLiquidity = 1e11; // Reduced concentrated liquidity
        
        sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        
        (uint256 amount0Concentrated, uint256 amount1Concentrated) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_RATIO_1_1,
            sqrtRatioAX96,
            sqrtRatioBX96,
            concentratedLiquidity
        );
        
        lpRouter.modifyLiquidity(
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
        // Full range liquidity using the helper from MarginTestBase
        addFullRangeLiquidity(alice, poolId, 1e18, 1e18, 0);
        
        // Add concentrated liquidity to hooked pool
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
        
        lpRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(uint256(1e12)), // Reduced liquidity
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        vm.stopPrank();
        
        // Log initial state of both pools
        logPoolState(regularPoolKey, regularPoolId, "Regular pool initial state");
        logPoolState(poolKey, poolId, "Hooked pool initial state");
    }
    
    // The rest of your implementation methods...

    /**
     * @notice Helper to create a deposit collateral action
     * @param asset The token address or address(0) for Native
     * @param amount The amount to deposit
     */
    function createDepositAction(address asset, uint256 amount) internal pure override returns (IMarginData.BatchAction memory) {
        return IMarginData.BatchAction({
            actionType: IMarginData.ActionType.DepositCollateral,
            asset: asset,
            amount: amount,
            recipient: address(0),
            flags: 0,
            data: bytes("")
        });
    }

    /**
     * @dev Query the pool tick from a given poolId
     */
    function queryPoolTick(PoolId _poolId) internal view returns (int24, uint128) {
        (, int24 tick, uint128 liquidity, ) = StateLibrary.getSlot0(poolManager, _poolId);
        return (tick, liquidity);
    }

    /**
     * @dev Log the state of a pool to the console
     */
    function logPoolState(PoolKey memory _poolKey, PoolId _poolId, string memory label) internal view {
        (int24 tick, uint128 liquidity) = queryPoolTick(_poolId);
        console2.log(label);
        console2.log("Current tick:", tick);
        console2.log("Current liquidity:", liquidity);
    }

    /**
     * @dev Get oracle tick from the hooked pool
     */
    function getOracleTick() internal view returns (int24, uint128) {
        return queryPoolTick(poolId);
    }

    /**
     * @dev Reset the CAP detector
     */
    function resetCAPDetector() internal {
        // Implementation specific to your test
    }

    /**
     * @notice Sets up realistic liquidity distribution in both pools
     */
    function setupRealisticLiquidity() internal {
        console2.log("Setting up realistic liquidity distribution");
        
        (uint160 sqrtPriceRegular, , , ) = StateLibrary.getSlot0(poolManager, regularPoolId);
        (uint160 sqrtPriceHooked, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        
        if (sqrtPriceRegular == 0) {
            poolManager.initialize(regularPoolKey, SQRT_RATIO_1_1);
        }
        
        if (sqrtPriceHooked == 0) {
            poolManager.initialize(poolKey, SQRT_RATIO_1_1);
        }
        
        // Add liquidity to both pools if needed
        int24 minTick = TickMath.minUsableTick(regularPoolKey.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(regularPoolKey.tickSpacing);
        uint128 liquidity = 1e12; // Reduced liquidity
        
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(minTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(maxTick);
        
        vm.startPrank(alice);
        
        // Check if we need to add liquidity to regular pool
        uint128 currentLiquidityRegular = StateLibrary.getLiquidity(poolManager, regularPoolId);
        if (currentLiquidityRegular < liquidity / 10) {
            lpRouter.modifyLiquidity(
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
            uint128 concentratedLiquidity = 1e11; // Reduced concentrated liquidity
            
            lpRouter.modifyLiquidity(
                regularPoolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(concentratedLiquidity)),
                    salt: bytes32(0)
                }),
                ZERO_BYTES
            );
        }
        
        // Check if we need to add liquidity to hooked pool
        uint128 currentLiquidityHooked = StateLibrary.getLiquidity(poolManager, poolId);
        if (currentLiquidityHooked < liquidity / 10) {
            // Use the addFullRangeLiquidity helper from MarginTestBase
            addFullRangeLiquidity(alice, poolId, 1e18, 1e18, 0);
            
            minTick = TickMath.minUsableTick(poolKey.tickSpacing);
            maxTick = TickMath.maxUsableTick(poolKey.tickSpacing);
            
            lpRouter.modifyLiquidity(
                poolKey,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: minTick,
                    tickUpper: maxTick,
                    liquidityDelta: int256(uint256(1e12)),
                    salt: bytes32(0)
                }),
                ZERO_BYTES
            );
        }
        vm.stopPrank();
        
        logPoolState(regularPoolKey, regularPoolId, "Regular pool after setup");
        logPoolState(poolKey, poolId, "Hooked pool after setup");
    }
    
    /**
     * @notice Executes a sequence of swaps on a specific pool
     * @param _poolKey The pool key
     * @param _poolId The pool ID
     * @param swapSequence Array of swap instructions to execute
     * @param metrics Storage for recording execution metrics
     */
    function executeSwapSequence(
        PoolKey memory _poolKey,
        PoolId _poolId,
        SwapInstruction[] memory swapSequence, 
        PoolMetrics storage metrics
    ) internal {
        console2.log("Executing", swapSequence.length, "swaps on pool", uint256(uint160(address(_poolKey.hooks))));
        
        metrics.tickTrajectory = new int24[](swapSequence.length + 1);
        metrics.gasUsageHistory = new uint256[](swapSequence.length);
        
        (int24 initialTick,) = queryPoolTick(_poolId);
        metrics.tickTrajectory[0] = initialTick;
        
        vm.startPrank(bob);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        
        for (uint256 i = 0; i < swapSequence.length; i++) {
            // console2.log("Executing swap #", i, "for pool ID:", PoolId.unwrap(_poolId));
            executeSwap(_poolKey, _poolId, swapSequence[i], metrics);
            vm.warp(block.timestamp + simulationParams.timeBetweenSwaps);
        }
        
        vm.stopPrank();
    }
    
    /**
     * @notice Executes swaps and validates oracle accuracy at each step
     */
    function executeSwapSequenceAndValidateOracle(SwapInstruction[] memory swapSequence) internal {
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
     * @notice Executes a single swap on a specific pool
     */
    function executeSwap(
        PoolKey memory _poolKey,
        PoolId _poolId,
        SwapInstruction memory instruction,
        PoolMetrics storage metrics
    ) internal {
        if (metrics.totalFailedSwaps > MAX_FAILED_SWAPS) {
            console2.log("Skipping swap - too many failures");
            return;
        }

        (int24 currentTick, uint128 currentLiquidity) = queryPoolTick(_poolId);

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

        int256 amountSpecified = instruction.swapType == SwapType.EXACT_INPUT ?
            int256(instruction.amount) :
            -int256(instruction.amount); // Negative for exact output

        // Apply price limit adjustment logic
        uint160 currentSqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        uint160 adjustedPriceLimit = instruction.sqrtPriceLimitX96;
        if (instruction.zeroForOne) {
            if (currentSqrtPriceX96 > 0 && (uint256(currentSqrtPriceX96) - uint256(adjustedPriceLimit)) < uint256(currentSqrtPriceX96) / 1000) {
                adjustedPriceLimit = uint160(uint256(currentSqrtPriceX96) * 995 / 1000); // Push limit down
                if (adjustedPriceLimit < MIN_SQRT_RATIO) adjustedPriceLimit = MIN_SQRT_RATIO;
            }
        } else {
            if (currentSqrtPriceX96 > 0 && (uint256(adjustedPriceLimit) - uint256(currentSqrtPriceX96)) < uint256(currentSqrtPriceX96) / 1000) {
                adjustedPriceLimit = uint160(uint256(currentSqrtPriceX96) * 1005 / 1000); // Push limit up
                if (adjustedPriceLimit > MAX_SQRT_RATIO) adjustedPriceLimit = MAX_SQRT_RATIO;
            }
        }

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: instruction.zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: adjustedPriceLimit // Use adjusted limit
        });

        console2.log("Pre-swap details:");
        console2.log("  Current tick:", currentTick);
        console2.log("  Price limit:", uint256(params.sqrtPriceLimitX96));

        uint256 gasBefore = gasleft();
        bool success = false;
        BalanceDelta delta;

        vm.startPrank(bob);
        try swapRouter.swap(
            _poolKey,
            params,
            testSettings,
            ZERO_BYTES
        ) returns (BalanceDelta swapDelta) {
            delta = swapDelta;
            success = true;
            console2.log("Swap succeeded!");
        } catch Error(string memory reason) {
            success = false;
            console2.log("Swap failed with error:", reason);
        } catch (bytes memory lowLevelData) {
            success = false;
            console2.log("Swap failed with low-level data:");
            console2.logBytes(lowLevelData);
            if (lowLevelData.length >= 4) {
                bytes4 selector;
                assembly { selector := mload(add(lowLevelData, 32)) }
                if (selector == 0x7c9c6e8f) { console2.log("Price bound failure detected"); }
                else if (selector == bytes4(keccak256("ArithmeticOverflow(uint256)"))) { console2.log("Arithmetic overflow detected"); }
                else if (bytes4(lowLevelData) == bytes4(keccak256("Panic(uint256)")) && lowLevelData.length > 4) {
                    uint256 reasonCode;
                    assembly { reasonCode := mload(add(lowLevelData, 36)) }
                    if (reasonCode == 0x11) { console2.log("Panic: Arithmetic underflow/overflow (0x11)"); }
                    else if (reasonCode == 0x12) { console2.log("Panic: Divide by zero (0x12)"); }
                    else { console2.log("Panic code:", reasonCode); }
                }
            }
        }
        vm.stopPrank();

        uint256 gasUsed = gasBefore - gasleft();

        (int24 tickAfterSwap, uint128 liquidityAfterSwap) = queryPoolTick(_poolId);

        uint256 ticksCrossed = tickAfterSwap > currentTick ?
            uint256(uint24(tickAfterSwap - currentTick)) :
            uint256(uint24(currentTick - tickAfterSwap));

        console2.logString("  Gas used:"); console2.logUint(gasUsed);
        console2.logString("  Tick movement:"); console2.logInt(currentTick);
        console2.logString("  To:"); console2.logInt(tickAfterSwap);
        console2.logString("  Ticks crossed:"); console2.logUint(ticksCrossed);
        console2.logString("  Liquidity after:"); console2.logUint(uint256(liquidityAfterSwap));

        if (success) {
            metrics.totalSuccessfulSwaps++;
            metrics.totalTicksCrossed += ticksCrossed;
        } else {
            metrics.totalFailedSwaps++;
        }

        metrics.totalGasUsed += gasUsed;
        metrics.swapCount++;

        if (gasUsed < metrics.minGasUsed) metrics.minGasUsed = gasUsed;
        if (gasUsed > metrics.maxGasUsed) metrics.maxGasUsed = gasUsed;
        
        // Store trajectory and gas history if arrays are initialized
        if (metrics.tickTrajectory.length > metrics.swapCount) {
            metrics.tickTrajectory[metrics.swapCount] = tickAfterSwap;
        }
        if (metrics.gasUsageHistory.length > metrics.swapCount - 1) {
            metrics.gasUsageHistory[metrics.swapCount - 1] = gasUsed;
        }
    }
    
    /**
     * @notice Generates gas comparison report between regular and hooked pools
     */
    function generateGasComparisonReport() internal view {
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
    function generateOracleAccuracyReport() internal view {
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
     * @notice Generates comprehensive report for full simulation
     */
    function generateComprehensiveReport() internal view {
        console2.log("\n========================================");
        console2.log("===== COMPREHENSIVE MARKET SIMULATION REPORT =====");
        console2.log("========================================\n");
        
        generateGasComparisonReport();
        generateOracleAccuracyReport();
        
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
        
        uint256 overallScore = (gasScore * 40 + oracleScore * 60) / 100;
        
        console2.log("Gas Efficiency Score:", gasScore, "/100");
        console2.log("Oracle Accuracy Score:", oracleScore, "/100");
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
     * @notice Helper function for validating swap amounts
     */
    function validateSwapAmount(uint256 amount, uint128 liquidity) internal pure returns (uint256) {
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
     * @notice Checks if CAP detector has detected an event
     */
    function checkCAPWasTriggered() internal returns (bool) {
        return dynamicFeeManager.isPoolInCapEvent(poolId);
    }

    /**
     * @notice Generates a sequence of swaps designed to test CAP detection
     */
    function generateCAPTestSequence() internal returns (SwapInstruction[] memory) {
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
                uint256 capSeed = uint256(keccak256(abi.encodePacked(i, "cap", block.timestamp)));
                int24 randomComponent = int24(int256(capSeed % 8)) - 4;
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
     * @notice Bounds a tick value within the valid range and aligns it to the tick spacing
     */
    function boundTick(int24 value) internal pure returns (int24) {
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

    // ... existing code ...
}