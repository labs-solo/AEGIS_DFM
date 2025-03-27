// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "./LocalUniswapV4TestBase.t.sol";
import "forge-std/console2.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {DepositParams} from "../src/interfaces/IFullRange.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/**
 * @title GasBenchmarkTest
 * @notice Compares gas costs between regular Uniswap V4 pools (tight tick spacing) and FullRange hook pools (wide tick spacing)
 */
contract GasBenchmarkTest is LocalUniswapV4TestBase {
    using StateLibrary for IPoolManager;
    
    // Regular pool without hooks (tight tick spacing)
    PoolKey public regularPoolKey;
    PoolId public regularPoolId;
    
    // Constants for tick spacing
    int24 constant REGULAR_TICK_SPACING = 10;  // Tight spacing for regular pool
    int24 constant HOOK_TICK_SPACING = 200;    // Wide spacing for hook pool
    uint24 constant REGULAR_POOL_FEE = 3000;   // 0.3% fee for regular pool
    
    function setUp() public override {
        // Call parent setUp to initialize the environment with the hook already deployed
        super.setUp();
        
        // Create a regular pool without hooks and tight tick spacing
        regularPoolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: REGULAR_POOL_FEE,
            tickSpacing: REGULAR_TICK_SPACING,
            hooks: IHooks(address(0)) // No hooks for regular pool
        });
        regularPoolId = regularPoolKey.toId();
        
        // Initialize the regular pool at the center of a tick space
        int24 regularTickSpaceCenter = ((0 / REGULAR_TICK_SPACING) * REGULAR_TICK_SPACING) + (REGULAR_TICK_SPACING / 2);
        uint160 centerSqrtPriceX96 = TickMath.getSqrtPriceAtTick(regularTickSpaceCenter);
        
        vm.startPrank(deployer);
        poolManager.initialize(regularPoolKey, centerSqrtPriceX96);
        vm.stopPrank();
    }
    
    function test_compareAddLiquidity() public {
        // Test first-time initialization cost vs subsequent operations
        // We'll use a consistent amount to isolate the initialization effect
        uint128 liquidityAmount = 1e9;
        
        console2.log("\n----- PHASE 1: First-time operations (cold storage) -----");
        
        // First measure regular pool first-time liquidity addition
        vm.startPrank(alice);
        
        // Measure approval gas costs
        uint256 gasStartApproval = gasleft();
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        uint256 approvalGas = gasStartApproval - gasleft();
        console2.log("Regular pool approval gas (first-time):", approvalGas);
        
        // Measure actual liquidity addition gas for first operation
        uint256 gasStartRegular = gasleft();
        lpRouter.modifyLiquidity(
            regularPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: getMinTick(REGULAR_TICK_SPACING),
                tickUpper: getMaxTick(REGULAR_TICK_SPACING),
                liquidityDelta: int256(uint256(liquidityAmount)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        uint256 regularAddLiqFirstGas = gasStartRegular - gasleft();
        console2.log("Regular pool add liquidity gas (first-time):", regularAddLiqFirstGas);
        vm.stopPrank();
        
        // Then measure hooked pool first-time liquidity addition
        vm.startPrank(alice);
        
        // Measure approval gas costs
        gasStartApproval = gasleft();
        token0.approve(address(liquidityManager), type(uint256).max);
        token1.approve(address(liquidityManager), type(uint256).max);
        uint256 hookedApprovalGas = gasStartApproval - gasleft();
        console2.log("Hooked pool approval gas (first-time):", hookedApprovalGas);
        
        // Measure actual liquidity addition gas for first operation
        uint256 gasStartHooked = gasleft();
        DepositParams memory params = DepositParams({
            poolId: poolId,
            amount0Desired: liquidityAmount,
            amount1Desired: liquidityAmount,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });
        fullRange.deposit(params);
        uint256 hookedAddLiqFirstGas = gasStartHooked - gasleft();
        console2.log("Hooked pool add liquidity gas (first-time):", hookedAddLiqFirstGas);
        vm.stopPrank();
        
        // Calculate and log first-time operation differences
        console2.log("Hook add liquidity overhead (first-time):", hookedAddLiqFirstGas > regularAddLiqFirstGas ? 
            hookedAddLiqFirstGas - regularAddLiqFirstGas : 0);
        console2.log("Total gas (regular, first-time):", approvalGas + regularAddLiqFirstGas);
        console2.log("Total gas (hooked, first-time):", hookedApprovalGas + hookedAddLiqFirstGas);
        console2.log("Total overhead (first-time):", 
            (hookedApprovalGas + hookedAddLiqFirstGas) > (approvalGas + regularAddLiqFirstGas) ? 
            (hookedApprovalGas + hookedAddLiqFirstGas) - (approvalGas + regularAddLiqFirstGas) : 0);
        
        // Now test subsequent operations with warmed storage
        console2.log("\n----- PHASE 2: Subsequent operations (warm storage) -----");
        
        // Test with small amount to prove it's not amount-dependent
        console2.log("Using same amount size:", liquidityAmount);
        
        // Regular pool subsequent addition
        vm.startPrank(alice);
        
        // Approval costs should be lower (warmed storage)
        gasStartApproval = gasleft();
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        uint256 approvalGasWarm = gasStartApproval - gasleft();
        console2.log("Regular pool approval gas (subsequent):", approvalGasWarm);
        console2.log("Approval gas reduction:", approvalGas > approvalGasWarm ? approvalGas - approvalGasWarm : 0);
        
        // Subsequent liquidity addition should be cheaper
        gasStartRegular = gasleft();
        lpRouter.modifyLiquidity(
            regularPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: getMinTick(REGULAR_TICK_SPACING),
                tickUpper: getMaxTick(REGULAR_TICK_SPACING),
                liquidityDelta: int256(uint256(liquidityAmount)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        uint256 regularAddLiqSubsequentGas = gasStartRegular - gasleft();
        console2.log("Regular pool add liquidity gas (subsequent):", regularAddLiqSubsequentGas);
        console2.log("Gas reduction from first-time:", regularAddLiqFirstGas > regularAddLiqSubsequentGas ? 
            regularAddLiqFirstGas - regularAddLiqSubsequentGas : 0);
        vm.stopPrank();
        
        // Hooked pool subsequent addition
        vm.startPrank(alice);
        
        // Approval costs should be lower (warmed storage)
        gasStartApproval = gasleft();
        token0.approve(address(liquidityManager), type(uint256).max);
        token1.approve(address(liquidityManager), type(uint256).max);
        uint256 hookedApprovalGasWarm = gasStartApproval - gasleft();
        console2.log("Hooked pool approval gas (subsequent):", hookedApprovalGasWarm);
        console2.log("Approval gas reduction:", hookedApprovalGas > hookedApprovalGasWarm ? 
            hookedApprovalGas - hookedApprovalGasWarm : 0);
        
        // Subsequent liquidity addition should be cheaper
        gasStartHooked = gasleft();
        params = DepositParams({
            poolId: poolId,
            amount0Desired: liquidityAmount,
            amount1Desired: liquidityAmount,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });
        fullRange.deposit(params);
        uint256 hookedAddLiqSubsequentGas = gasStartHooked - gasleft();
        console2.log("Hooked pool add liquidity gas (subsequent):", hookedAddLiqSubsequentGas);
        console2.log("Gas reduction from first-time:", hookedAddLiqFirstGas > hookedAddLiqSubsequentGas ? 
            hookedAddLiqFirstGas - hookedAddLiqSubsequentGas : 0);
        vm.stopPrank();
        
        // Calculate and log subsequent operation differences
        console2.log("Hook add liquidity overhead (subsequent):", hookedAddLiqSubsequentGas > regularAddLiqSubsequentGas ? 
            hookedAddLiqSubsequentGas - regularAddLiqSubsequentGas : 0);
        console2.log("Total gas (regular, subsequent):", approvalGasWarm + regularAddLiqSubsequentGas);
        console2.log("Total gas (hooked, subsequent):", hookedApprovalGasWarm + hookedAddLiqSubsequentGas);
        console2.log("Total overhead (subsequent):", 
            (hookedApprovalGasWarm + hookedAddLiqSubsequentGas) > (approvalGasWarm + regularAddLiqSubsequentGas) ? 
            (hookedApprovalGasWarm + hookedAddLiqSubsequentGas) - (approvalGasWarm + regularAddLiqSubsequentGas) : 0);
        
        // Test with different amounts to verify amount size is not the factor
        console2.log("\n----- PHASE 3: Different amounts (with warm storage) -----");
        
        // Test medium amount
        uint128 mediumAmount = 1e12;
        vm.startPrank(alice);
        gasStartRegular = gasleft();
        lpRouter.modifyLiquidity(
            regularPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: getMinTick(REGULAR_TICK_SPACING),
                tickUpper: getMaxTick(REGULAR_TICK_SPACING),
                liquidityDelta: int256(uint256(mediumAmount)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        uint256 regularMediumGas = gasStartRegular - gasleft();
        vm.stopPrank();
        
        vm.startPrank(alice);
        gasStartHooked = gasleft();
        params = DepositParams({
            poolId: poolId,
            amount0Desired: mediumAmount,
            amount1Desired: mediumAmount,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });
        fullRange.deposit(params);
        uint256 hookedMediumGas = gasStartHooked - gasleft();
        vm.stopPrank();
        
        // Test large amount
        uint128 largeAmount = 1e18;
        vm.startPrank(alice);
        gasStartRegular = gasleft();
        lpRouter.modifyLiquidity(
            regularPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: getMinTick(REGULAR_TICK_SPACING),
                tickUpper: getMaxTick(REGULAR_TICK_SPACING),
                liquidityDelta: int256(uint256(largeAmount)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        uint256 regularLargeGas = gasStartRegular - gasleft();
        vm.stopPrank();
        
        vm.startPrank(alice);
        gasStartHooked = gasleft();
        params = DepositParams({
            poolId: poolId,
            amount0Desired: largeAmount,
            amount1Desired: largeAmount,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });
        fullRange.deposit(params);
        uint256 hookedLargeGas = gasStartHooked - gasleft();
        vm.stopPrank();
        
        // Show amount has minimal impact once storage is warmed
        console2.log("Regular pool add liquidity gas (small):", regularAddLiqSubsequentGas);
        console2.log("Regular pool add liquidity gas (medium):", regularMediumGas);
        console2.log("Regular pool add liquidity gas (large):", regularLargeGas);
        console2.log("Hooked pool add liquidity gas (small):", hookedAddLiqSubsequentGas);
        console2.log("Hooked pool add liquidity gas (medium):", hookedMediumGas);
        console2.log("Hooked pool add liquidity gas (large):", hookedLargeGas);
        
        // Final summary
        console2.log("\n----- SUMMARY: First-time vs Subsequent Operation -----");
        console2.log("Regular pool first-time operation:", regularAddLiqFirstGas);
        console2.log("Regular pool subsequent operation:", regularAddLiqSubsequentGas);
        console2.log("Regular pool initialization overhead:", regularAddLiqFirstGas - regularAddLiqSubsequentGas);
        console2.log("Regular pool initialization overhead %:", ((regularAddLiqFirstGas - regularAddLiqSubsequentGas) * 100) / regularAddLiqSubsequentGas, "%");
        
        console2.log("Hooked pool first-time operation:", hookedAddLiqFirstGas);
        console2.log("Hooked pool subsequent operation:", hookedAddLiqSubsequentGas);
        console2.log("Hooked pool initialization overhead:", hookedAddLiqFirstGas - hookedAddLiqSubsequentGas);
        console2.log("Hooked pool initialization overhead %:", ((hookedAddLiqFirstGas - hookedAddLiqSubsequentGas) * 100) / hookedAddLiqSubsequentGas, "%");
    }
    
    function test_compareSwaps() public {
        // Declare variables used throughout the test
        uint160 sqrtPriceX96;
        int24 currentTick;
        int24 currentTickSpace;
        int24 currentTickSpaceLowerBound;
        int24 currentTickSpaceUpperBound;
        int24 startTick;
        int24 endTick;
        int24 tickSpacesCrossed;
        int24 targetTick;
        
        // First add liquidity to both pools
        uint128 liquidityAmount = 1e9;
        
        // Add liquidity to regular pool in a narrow range to control tick space crossing
        vm.startPrank(alice);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        
        // Get regular pool state and calculate its tick space boundaries
        (sqrtPriceX96, currentTick, , ) = StateLibrary.getSlot0(poolManager, regularPoolId);
        currentTickSpace = currentTick / REGULAR_TICK_SPACING;
        currentTickSpaceLowerBound = currentTickSpace * REGULAR_TICK_SPACING;
        currentTickSpaceUpperBound = (currentTickSpace + 1) * REGULAR_TICK_SPACING;
        
        // Add liquidity spanning the current tick space
        lpRouter.modifyLiquidity(
            regularPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: currentTickSpaceLowerBound,
                tickUpper: currentTickSpaceUpperBound,
                liquidityDelta: int256(uint256(liquidityAmount)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        vm.stopPrank();
        
        // Add liquidity to hooked pool
        vm.startPrank(alice);
        token0.approve(address(liquidityManager), type(uint256).max);
        token1.approve(address(liquidityManager), type(uint256).max);
        DepositParams memory params = DepositParams({
            poolId: poolId,
            amount0Desired: liquidityAmount,
            amount1Desired: liquidityAmount,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });
        fullRange.deposit(params);
        vm.stopPrank();
        
        // Test settings for swaps
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Test 1: Small swap in regular pool (staying within current tick space)
        uint256 smallSwapAmount = 1e6;
        vm.startPrank(bob);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        
        // Set price limit using a fixed tick offset to ensure it's below the current price
        targetTick = currentTick - 20; // Small offset for small swap
        uint160 smallSwapPriceLimit = TickMath.getSqrtPriceAtTick(targetTick);
        
        // Record starting tick and its tick space
        (sqrtPriceX96, startTick, , ) = StateLibrary.getSlot0(poolManager, regularPoolId);
        int24 startTickSpace = startTick / REGULAR_TICK_SPACING;
        
        uint256 gasStartSmall = gasleft();
        console2.log("Gas before small swap:", gasStartSmall);
        swapRouter.swap(
            regularPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(smallSwapAmount),
                sqrtPriceLimitX96: smallSwapPriceLimit
            }),
            testSettings,
            ZERO_BYTES
        );
        uint256 gasEndSmall = gasleft();
        console2.log("Gas after small swap:", gasEndSmall);
        uint256 regularSmallSwapGas = gasStartSmall - gasEndSmall;
        
        // Record ending tick and calculate boundaries crossed
        (, endTick, , ) = StateLibrary.getSlot0(poolManager, regularPoolId);
        int24 endTickSpace = endTick / REGULAR_TICK_SPACING;
        tickSpacesCrossed = startTickSpace - endTickSpace;
        console2.log("Regular pool swap gas (small swap):", regularSmallSwapGas);
        console2.log("Starting tick:", startTick);
        console2.log("Ending tick:", endTick);
        console2.log("Starting tick space:", startTickSpace);
        console2.log("Ending tick space:", endTickSpace);
        console2.log("Tick spaces crossed (small swap):", tickSpacesCrossed >= 0 ? uint24(tickSpacesCrossed) : uint24(-tickSpacesCrossed));
        vm.stopPrank();
        
        // Reset pool state by adding more liquidity at the center of the tick space
        vm.startPrank(alice);
        uint256 gasBeforeReset = gasleft();
        lpRouter.modifyLiquidity(
            regularPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: currentTickSpaceLowerBound,
                tickUpper: currentTickSpaceUpperBound,
                liquidityDelta: int256(uint256(liquidityAmount)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        uint256 gasUsedForReset = gasBeforeReset - gasleft();
        console2.log("Gas used for liquidity reset:", gasUsedForReset);
        vm.stopPrank();
        
        // Test 2: Large swap in regular pool (crossing tick space boundary)
        vm.startPrank(bob);
        uint256 largeSwapAmount = 1e9;  // Larger amount to ensure crossing into next tick space
        // Set price limit using a larger fixed tick offset
        targetTick = currentTick - 100; // Larger offset for large swap
        uint160 largeSwapPriceLimit = TickMath.getSqrtPriceAtTick(targetTick);
        
        // Record starting tick and its tick space
        (sqrtPriceX96, startTick, , ) = StateLibrary.getSlot0(poolManager, regularPoolId);
        startTickSpace = startTick / REGULAR_TICK_SPACING;
        
        uint256 gasStartLarge = gasleft();
        console2.log("Gas before large swap:", gasStartLarge);
        swapRouter.swap(
            regularPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(largeSwapAmount),
                sqrtPriceLimitX96: largeSwapPriceLimit
            }),
            testSettings,
            ZERO_BYTES
        );
        uint256 gasEndLarge = gasleft();
        console2.log("Gas after large swap:", gasEndLarge);
        uint256 regularLargeSwapGas = gasStartLarge - gasEndLarge;
        
        // Record ending tick and calculate boundaries crossed
        (, endTick, , ) = StateLibrary.getSlot0(poolManager, regularPoolId);
        endTickSpace = endTick / REGULAR_TICK_SPACING;
        tickSpacesCrossed = startTickSpace - endTickSpace;
        console2.log("Regular pool swap gas (large swap):", regularLargeSwapGas);
        console2.log("Starting tick:", startTick);
        console2.log("Ending tick:", endTick);
        console2.log("Starting tick space:", startTickSpace);
        console2.log("Ending tick space:", endTickSpace);
        console2.log("Tick spaces crossed (large swap):", tickSpacesCrossed >= 0 ? uint24(tickSpacesCrossed) : uint24(-tickSpacesCrossed));
        vm.stopPrank();
        
        // Reset pool state again before hooked pool test
        vm.startPrank(alice);
        lpRouter.modifyLiquidity(
            regularPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: currentTickSpaceLowerBound,
                tickUpper: currentTickSpaceUpperBound,
                liquidityDelta: int256(uint256(liquidityAmount)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        vm.stopPrank();
        
        // Get hooked pool state and calculate its tick space boundaries
        // Hook tick spacing of 200 means ticks 0-199 are in one space, 200-399 in another, etc.
        (sqrtPriceX96, currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
        currentTickSpace = currentTick / HOOK_TICK_SPACING;
        currentTickSpaceLowerBound = currentTickSpace * HOOK_TICK_SPACING;
        currentTickSpaceUpperBound = (currentTickSpace + 1) * HOOK_TICK_SPACING;
        
        // Test 3: Standard swap in hooked pool (staying within current tick space boundary)
        vm.startPrank(bob);
        // Set price limit using a fixed tick offset to ensure it's below the current price
        int24 fixedOffset = 100; // Using a fixed offset of 100 ticks below current
        targetTick = currentTick - fixedOffset;
        uint160 hookSwapPriceLimit = TickMath.getSqrtPriceAtTick(targetTick);
        
        // Record starting tick and its tick space
        (sqrtPriceX96, startTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
        startTickSpace = startTick / HOOK_TICK_SPACING;
        
        uint256 gasStartHooked = gasleft();
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(smallSwapAmount),
                sqrtPriceLimitX96: hookSwapPriceLimit
            }),
            testSettings,
            ZERO_BYTES
        );
        uint256 hookedSwapGas = gasStartHooked - gasleft();
        
        // Record ending tick and calculate boundaries crossed
        (, endTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
        endTickSpace = endTick / HOOK_TICK_SPACING;
        tickSpacesCrossed = startTickSpace - endTickSpace;
        console2.log("Hooked pool swap gas:", hookedSwapGas);
        console2.log("Starting tick:", startTick);
        console2.log("Ending tick:", endTick);
        console2.log("Starting tick space:", startTickSpace);
        console2.log("Ending tick space:", endTickSpace);
        console2.log("Tick spaces crossed (hooked pool):", tickSpacesCrossed >= 0 ? uint24(tickSpacesCrossed) : uint24(-tickSpacesCrossed));
        vm.stopPrank();
        
        console2.log("Hook vs small swap overhead:", hookedSwapGas > regularSmallSwapGas ? hookedSwapGas - regularSmallSwapGas : 0);
        // For tick space boundary crossing comparison, show savings instead of overhead when hook is more efficient
        if (hookedSwapGas > regularLargeSwapGas) {
            console2.log("Hook overhead vs large swap:", hookedSwapGas - regularLargeSwapGas);
        } else {
            console2.log("Hook savings vs large swap:", regularLargeSwapGas - hookedSwapGas);
        }
    }
    
    function test_compareSwapsReversed() public {
        // Declare variables used throughout the test
        uint160 sqrtPriceX96;
        int24 currentTick;
        int24 currentTickSpace;
        int24 currentTickSpaceLowerBound;
        int24 currentTickSpaceUpperBound;
        int24 startTick;
        int24 endTick;
        int24 tickSpacesCrossed;
        int24 targetTick;
        
        // First add liquidity to the regular pool
        uint128 liquidityAmount = 1e9;
        
        // Add liquidity to regular pool in a narrow range to control tick space crossing
        vm.startPrank(alice);
        token0.approve(address(lpRouter), type(uint256).max);
        token1.approve(address(lpRouter), type(uint256).max);
        
        // Get regular pool state and calculate its tick space boundaries
        (sqrtPriceX96, currentTick, , ) = StateLibrary.getSlot0(poolManager, regularPoolId);
        currentTickSpace = currentTick / REGULAR_TICK_SPACING;
        currentTickSpaceLowerBound = currentTickSpace * REGULAR_TICK_SPACING;
        currentTickSpaceUpperBound = (currentTickSpace + 1) * REGULAR_TICK_SPACING;
        
        // Add liquidity spanning the current tick space
        lpRouter.modifyLiquidity(
            regularPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: currentTickSpaceLowerBound,
                tickUpper: currentTickSpaceUpperBound,
                liquidityDelta: int256(uint256(liquidityAmount)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        vm.stopPrank();
        
        // Test settings for swaps
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Doing the LARGE swap FIRST (REVERSED order)
        vm.startPrank(bob);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        
        uint256 largeSwapAmount = 1e9;
        // Calculate target tick for large swap - two tick spaces down
        targetTick = currentTickSpaceLowerBound - 2 * REGULAR_TICK_SPACING;
        uint160 largeSwapPriceLimit = TickMath.getSqrtPriceAtTick(targetTick);
        
        // Record starting tick and its tick space
        (sqrtPriceX96, startTick, , ) = StateLibrary.getSlot0(poolManager, regularPoolId);
        int24 startTickSpace = startTick / REGULAR_TICK_SPACING;
        
        console2.log("REVERSED ORDER TEST");
        uint256 gasStartLarge = gasleft();
        console2.log("Gas before large swap (first):", gasStartLarge);
        swapRouter.swap(
            regularPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(largeSwapAmount),
                sqrtPriceLimitX96: largeSwapPriceLimit
            }),
            testSettings,
            ZERO_BYTES
        );
        uint256 gasEndLarge = gasleft();
        console2.log("Gas after large swap (first):", gasEndLarge);
        uint256 regularLargeSwapGas = gasStartLarge - gasEndLarge;
        
        // Record ending tick and calculate boundaries crossed
        (, endTick, , ) = StateLibrary.getSlot0(poolManager, regularPoolId);
        int24 endTickSpace = endTick / REGULAR_TICK_SPACING;
        tickSpacesCrossed = startTickSpace - endTickSpace;
        console2.log("Regular pool swap gas (large swap first):", regularLargeSwapGas);
        console2.log("Starting tick:", startTick);
        console2.log("Ending tick:", endTick);
        console2.log("Starting tick space:", startTickSpace);
        console2.log("Ending tick space:", endTickSpace);
        console2.log("Tick spaces crossed (large swap):", tickSpacesCrossed >= 0 ? uint24(tickSpacesCrossed) : uint24(-tickSpacesCrossed));
        
        // Reset pool state
        vm.stopPrank();
        vm.startPrank(alice);
        uint256 gasBeforeReset = gasleft();
        lpRouter.modifyLiquidity(
            regularPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: currentTickSpaceLowerBound,
                tickUpper: currentTickSpaceUpperBound,
                liquidityDelta: int256(uint256(liquidityAmount)),
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        uint256 gasUsedForReset = gasBeforeReset - gasleft();
        console2.log("Gas used for liquidity reset:", gasUsedForReset);
        vm.stopPrank();
        
        // Then do a SMALL swap SECOND
        vm.startPrank(bob);
        uint256 smallSwapAmount = 1e6;
        
        // Get current tick for the small swap after the large swap and reset
        (sqrtPriceX96, currentTick, , ) = StateLibrary.getSlot0(poolManager, regularPoolId);
        currentTickSpace = currentTick / REGULAR_TICK_SPACING;
        currentTickSpaceLowerBound = currentTickSpace * REGULAR_TICK_SPACING;
        
        // Calculate a price limit that's below the current price
        targetTick = currentTick - 50; // Fixed offset of 50 ticks below current
        uint160 smallSwapPriceLimit = TickMath.getSqrtPriceAtTick(targetTick);
        
        // Record starting tick and its tick space
        (sqrtPriceX96, startTick, , ) = StateLibrary.getSlot0(poolManager, regularPoolId);
        startTickSpace = startTick / REGULAR_TICK_SPACING;
        
        uint256 gasStartSmall = gasleft();
        console2.log("Gas before small swap (second):", gasStartSmall);
        swapRouter.swap(
            regularPoolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(smallSwapAmount),
                sqrtPriceLimitX96: smallSwapPriceLimit
            }),
            testSettings,
            ZERO_BYTES
        );
        uint256 gasEndSmall = gasleft();
        console2.log("Gas after small swap (second):", gasEndSmall);
        uint256 regularSmallSwapGas = gasStartSmall - gasEndSmall;
        
        // Record ending tick and calculate boundaries crossed
        (, endTick, , ) = StateLibrary.getSlot0(poolManager, regularPoolId);
        endTickSpace = endTick / REGULAR_TICK_SPACING;
        tickSpacesCrossed = startTickSpace - endTickSpace;
        console2.log("Regular pool swap gas (small swap second):", regularSmallSwapGas);
        console2.log("Starting tick:", startTick);
        console2.log("Ending tick:", endTick);
        console2.log("Starting tick space:", startTickSpace);
        console2.log("Ending tick space:", endTickSpace);
        console2.log("Tick spaces crossed (small swap):", tickSpacesCrossed >= 0 ? uint24(tickSpacesCrossed) : uint24(-tickSpacesCrossed));
        vm.stopPrank();
        
        console2.log("REVERSED ORDER DIFFERENCE:");
        if (regularLargeSwapGas > regularSmallSwapGas) {
            console2.log("Large swap used more gas by:", regularLargeSwapGas - regularSmallSwapGas);
        } else {
            console2.log("Small swap used more gas by:", regularSmallSwapGas - regularLargeSwapGas);
        }
    }
    
    // Helper functions
    bytes constant ZERO_BYTES = "";
    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;  // 1:1 price
    uint160 constant MIN_SQRT_RATIO = 4295128739;
    uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    
    function getMinTick(int24 tickSpacing) internal pure returns (int24) {
        return (-887272 / tickSpacing) * tickSpacing;
    }
    
    function getMaxTick(int24 tickSpacing) internal pure returns (int24) {
        return (887272 / tickSpacing) * tickSpacing;
    }
} 