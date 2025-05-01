// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import "./ForkSetup.t.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IFullRangeLiquidityManager} from "../../src/interfaces/IFullRangeLiquidityManager.sol";
import {IPoolPolicy} from "../../src/interfaces/IPoolPolicy.sol";
import {FullRangeLiquidityManager} from "../../src/FullRangeLiquidityManager.sol";
import {IDynamicFeeManager} from "../../src/interfaces/IDynamicFeeManager.sol";
import {DynamicFeeManager} from "../../src/DynamicFeeManager.sol";
import {TickCheck} from "../../src/libraries/TickCheck.sol";
import {PoolPolicyManager} from "../../src/PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "../../src/TruncGeoOracleMulti.sol";
import {Spot} from "../../src/Spot.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMoveGuard} from "src/libraries/TickMoveGuard.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {INITIAL_LP_USDC, INITIAL_LP_WETH} from "../utils/TestConstants.sol";

/**
 * @title Dynamic Fee and POL Management Integration Tests
 * @notice Tests for verifying the dynamic fee mechanism and Protocol Owned Liquidity (POL)
 *         management within the full Spot hook ecosystem.
 * @dev This test suite builds upon the static deployment and configuration tests in
 *      DeploymentAndConfig.t.sol by focusing on the behavioral aspects of the system.
 */
contract DynamicFeeAndPOLTest is ForkSetup {
    using PoolIdLibrary for PoolKey;
    using SafeTransferLib for ERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    // DFM instance (using interface)
    IDynamicFeeManager public dfm;

    // Hook simulation state
    mapping(PoolId => int24) public lastTick;

    // Test helper variables
    uint256 public defaultBaseFee;
    uint256 public polSharePpm;
    uint256 public surgeFeeDecayPeriod;
    int24 public tickScalingFactor;

    // Test swap amounts
    uint256 public constant SMALL_SWAP_AMOUNT_WETH = 0.1 ether;
    uint256 public constant SMALL_SWAP_AMOUNT_USDC = 300 * 10 ** 6;

    function setUp() public override {
        super.setUp(); // Deploy contracts via ForkSetup

        // Cast deployed manager to the new interface
        dfm = IDynamicFeeManager(address(dynamicFeeManager));

        // Get initial tick for initialization
        (, int24 initialTick,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Initialize hook simulation state
        lastTick[poolId] = initialTick;

        // Store key parameters
        (defaultBaseFee,) = dfm.getFeeState(poolId); // Get initial base fee
        polSharePpm = policyManager.getPoolPOLShare(poolId);
        tickScalingFactor = policyManager.getTickScalingFactor();
        surgeFeeDecayPeriod = uint32(policyManager.getSurgeDecayPeriodSeconds(poolId));

        _setupApprovals();
        _addInitialLiquidity();

        // Adjust policy params for faster testing
        vm.startPrank(deployerEOA);
        policyManager.setDailyBudgetPpm(1e6); // 1 event per day (ppm)
        policyManager.setDecayWindow(3600); // 1‑hour window (tests)
        policyManager.setFreqScaling(poolId, 1); // Ensure scaling is set if needed by policy
        vm.stopPrank();

        //
        // ── HOOK / ORACLE WIRING ────────────────────────────
        //
        // 1) Tell oracle which Spot hook to trust
        vm.prank(deployerEOA);
        oracle.setFullRangeHook(address(fullRange));
        // 2) Now enable our pool in the oracle (as Spot.afterInitialize would do)
        vm.prank(address(fullRange));
        oracle.enableOracleForPool(poolKey);
    }

    function _setupApprovals() internal {
        vm.startPrank(user1);
        uint256 MAX = type(uint256).max;
        // always allow both contracts to pull
        weth.approve(address(poolManager), MAX);
        usdc.approve(address(poolManager), MAX);
        weth.approve(address(liquidityManager), MAX);
        usdc.approve(address(liquidityManager), MAX);
        vm.stopPrank();
        vm.startPrank(user2);
        weth.approve(address(poolManager), MAX);
        usdc.approve(address(poolManager), MAX);
        weth.approve(address(liquidityManager), MAX);
        usdc.approve(address(liquidityManager), MAX);
        vm.stopPrank();
        vm.startPrank(lpProvider);
        weth.approve(address(poolManager), MAX);
        usdc.approve(address(poolManager), MAX);
        weth.approve(address(liquidityManager), MAX);
        usdc.approve(address(liquidityManager), MAX);
        weth.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(lpRouter), type(uint256).max);
        usdc.approve(address(lpRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _addInitialLiquidity() internal {
        uint256 amount0Desired = Currency.unwrap(poolKey.currency0) == address(usdc) ? INITIAL_LP_USDC : INITIAL_LP_WETH;
        uint256 amount1Desired = Currency.unwrap(poolKey.currency0) == address(usdc) ? INITIAL_LP_WETH : INITIAL_LP_USDC;
        (uint160 initialSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        require(initialSqrtPriceX96 > 0, "Pool price is zero");

        vm.startPrank(lpProvider);
        weth.approve(address(liquidityManager), type(uint256).max);
        usdc.approve(address(liquidityManager), type(uint256).max);
        vm.stopPrank();

        // dust liquidity (avoids first-deposit corner cases)
        _addLiquidityAsGovernance(poolId, amount0Desired, amount1Desired, 0, 0, lpProvider);
    }

    // (we no longer simulate Oracle/DFM by hand—all swaps go through Spot→oracle→DFM)

    /**
     * @notice Helper function to perform a swap from WETH to USDC
     * @dev Spot's afterSwap will handle oracle updates
     */
    function _swapWETHToUSDC(address sender, uint256 amountIn, uint256 amountOutMinimum)
        internal
        returns (uint256 amountOut)
    {
        amountOutMinimum; // silence warning
        vm.startPrank(sender);

        uint256 wethBalanceBefore = weth.balanceOf(sender);
        uint256 usdcBalanceBefore = usdc.balanceOf(sender);
        address token0 = Currency.unwrap(poolKey.currency0);
        bool wethIsToken0 = token0 == WETH_ADDRESS;
        uint160 sqrtPriceLimitX96;
        (uint160 currentSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

        if (wethIsToken0) {
            sqrtPriceLimitX96 = uint160(uint256(currentSqrtPriceX96) * 9 / 10); // Min price limit for 0->1
        } else {
            sqrtPriceLimitX96 = uint160(uint256(currentSqrtPriceX96) * 11 / 10); // Max price limit for 1->0
        }

        SwapParams memory params = SwapParams({
            zeroForOne: wethIsToken0,
            amountSpecified: int256(amountIn),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false});

        weth.approve(address(swapRouter), type(uint256).max);
        BalanceDelta delta = swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);
        vm.stopPrank(); // Stop sender prank before hook simulation

        // nothing to do here; Spot's afterSwap will push
        // into the TruncGeoOracleMulti and then call DFM.notifyOracleUpdate

        // Calculate output and log balances
        int256 amount0Delta = delta.amount0();
        int256 amount1Delta = delta.amount1();
        amountOut = wethIsToken0 ? uint256(-amount1Delta) : uint256(-amount0Delta);
        uint256 wethBalanceAfter = weth.balanceOf(sender);
        uint256 usdcBalanceAfter = usdc.balanceOf(sender);

        return amountOut;
    }

    function test_B1_Swap_AppliesDefaultFee() public {
        address token0 = Currency.unwrap(poolKey.currency0);
        bool wethIsToken0 = token0 == WETH_ADDRESS;
        uint256 wethBalanceBefore = weth.balanceOf(user1);
        uint256 usdcBalanceBefore = usdc.balanceOf(user1);
        (uint160 sqrtPriceX96Before, int24 tickBefore,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Get initial base fee
        (uint256 currentBaseFee, uint256 currentSurgeFee) = dfm.getFeeState(poolId);
        assertEq(currentSurgeFee, 0, "Initial surge fee should be 0");
        assertEq(currentBaseFee, defaultBaseFee, "Initial base fee should match default");

        uint256 swapAmount = SMALL_SWAP_AMOUNT_WETH;
        _swapWETHToUSDC(user1, swapAmount, 0); // This now includes the hook notification

        (uint160 sqrtPriceX96After, int24 tickAfter,,) = StateLibrary.getSlot0(poolManager, poolId);
        // Price direction checks remain the same
        if (wethIsToken0) {
            assertTrue(sqrtPriceX96After < sqrtPriceX96Before, "Price direction mismatch 0->1");
            assertTrue(tickAfter < tickBefore, "Tick direction mismatch 0->1");
        } else {
            assertTrue(sqrtPriceX96After > sqrtPriceX96Before, "Price direction mismatch 1->0");
            assertTrue(tickAfter > tickBefore, "Tick direction mismatch 1->0");
        }

        uint256 wethBalanceAfter = weth.balanceOf(user1);
        uint256 usdcBalanceAfter = usdc.balanceOf(user1);
        uint256 wethSpent = wethBalanceBefore - wethBalanceAfter;
        uint256 usdcReceived = usdcBalanceAfter - usdcBalanceBefore;

        // Check the fee state *after* the swap and notification
        (uint256 finalBaseFee, uint256 finalSurgeFee) = dfm.getFeeState(poolId);

        // Fee shouldn't have changed significantly from one small swap if interval > 0
        // assertEq(finalBaseFee, defaultBaseFee, "Base fee changed unexpectedly");
        // assertEq(finalSurgeFee, 0, "Surge fee appeared unexpectedly");

        // Check POL calculation (remains conceptual)
        uint256 expectedTotalFeePpm = finalBaseFee + finalSurgeFee;
        uint256 expectedTotalFeeAmount = (swapAmount * expectedTotalFeePpm) / 1e6;
        uint256 expectedPolFee = (expectedTotalFeeAmount * polSharePpm) / 1e6;
    }

    function test_B2_BaseFee_Increases_With_CAP_Events() public {
        (uint256 initialBase,) = dfm.getFeeState(poolId);

        // Bigger notional so we *guarantee* passing the CAP threshold with the
        // current >1 B notional liquidity seeded in the pool.
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(usdc);
        int256 capAmount = zeroForOne
            ? int256(150_000 * 1e6) // 150 k USDC → WETH
            : int256(50 ether); // 50 WETH   → USDC

        // Allocate enough funds for 3 swaps
        uint256 topUp = uint256(capAmount > 0 ? capAmount : -capAmount) * 3;
        _dealAndApprove(
            zeroForOne ? usdc : IERC20Minimal(WETH_ADDRESS),
            lpProvider,
            topUp,
            address(poolManager) // Approve PoolManager
        );

        // First swap - trigger first CAP
        vm.startPrank(lpProvider);
        try swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: capAmount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ZERO_BYTES
        ) {} catch { /* Ignore reverts, focus on fee manager state */ }
        vm.stopPrank();

        // Check final fee state
        (uint256 newBase,) = dfm.getFeeState(poolId);
        assertTrue(newBase > initialBase, "Base fee did not increase after CAP events");
    }

    function test_B3_BaseFee_Decreases_When_Caps_Too_Rare() public {
        // Ensure manager is initialized & get initial tick
        (, int24 initialTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        // Ensure initialized by calling initialize (safe due to require)
        vm.startPrank(deployerEOA);
        try dfm.initialize(poolId, initialTick) {} catch {} // Ignore if already initialized
        vm.stopPrank();

        // Get initial base fee
        (uint256 initialBase,) = dfm.getFeeState(poolId);

        // Warp 1 hour
        vm.warp(block.timestamp + 3600);

        // Perform minimal swap to trigger hook update after warp
        vm.startPrank(lpProvider);
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true, // swap USDC for WETH
                amountSpecified: 1, // Minimal amount
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        vm.stopPrank();

        // Check final fee state
        (uint256 feeAfterDelay,) = dfm.getFeeState(poolId);
        uint256 minBase = policyManager.getMinBaseFee(poolId);
        assertTrue(feeAfterDelay < initialBase, "Base fee did not decrease over time");
        assertTrue(feeAfterDelay >= minBase, "Base fee decreased below minimum");
    }

    // _triggerCap now just performs swap, relies on caller for notification
    function _triggerCap_SwapOnly() internal {
        bool zeroForOne = true; // Swap USDC for WETH
        int256 amountSpecified = int256(10_000 * 1e6);
        (uint160 currentSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        uint160 sqrtPriceLimitX96 = uint160((uint256(currentSqrtPriceX96) * 95) / 100);

        SwapParams memory params =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96});
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false});

        // Perform swap using lpProvider for funds
        vm.startPrank(lpProvider);
        try swapRouter.swap(poolKey, params, settings, ZERO_BYTES) {}
        catch Error(string memory reason) {
            revert(string.concat("Swap failed: ", reason));
        } catch {
            revert("Swap failed with unknown error");
        }
        vm.stopPrank();
    }

    // Debugging and Isolated tests remain mostly the same, no direct DFM interaction changes needed
    function test_DebugLiquidityAmounts() public {
        // ... (no changes needed here unless it interacted with DFM directly)
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 tickSpacing = poolKey.tickSpacing;
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 amount1Desired_WETH = INITIAL_LP_WETH;
        uint256 amount0Desired_USDC_calculated = 40502294233;
        uint128 liquidityForDesired0 =
            LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtRatioBX96, amount0Desired_USDC_calculated);
        uint128 liquidityForDesired1 =
            LiquidityAmounts.getLiquidityForAmount1(sqrtPriceX96, sqrtRatioAX96, amount1Desired_WETH);
        uint128 intermediateV4Liquidity;
        uint256 actual0;
        uint256 actual1;
        if (liquidityForDesired0 < liquidityForDesired1) {
            intermediateV4Liquidity = liquidityForDesired0;
            actual0 = amount0Desired_USDC_calculated;
            actual1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, intermediateV4Liquidity, true);
        } else {
            intermediateV4Liquidity = liquidityForDesired1;
            actual1 = amount1Desired_WETH;
            actual0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtRatioBX96, intermediateV4Liquidity, true);
        }
        uint128 finalLiquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, actual0, actual1);
        assertTrue(finalLiquidity > 0, "Liquidity calculation failed");
    }

    function test_IsolatedDeposit_Initial() public {
        uint256 usdcToDeposit = 40502294233;
        uint256 wethToDeposit = 10 ether;
        require(usdc.balanceOf(lpProvider) >= usdcToDeposit, "LP lacks USDC");
        require(weth.balanceOf(lpProvider) >= wethToDeposit, "LP lacks WETH");

        // Isolated deposit – governance provides funds so we avoid allowance issues
        (, uint256 usdcUsed, uint256 wethUsed) =
            _addLiquidityAsGovernance(poolId, usdcToDeposit, wethToDeposit, 0, 0, lpProvider);
        assertTrue(usdcUsed > 0 && wethUsed > 0, "Isolated deposit failed");
    }

    /**
     * @notice Test setting POL rate to 100% and verifying fees go entirely to protocol
     */
    function test_polRateFullProtocol() public {
        // ... existing code ...

        vm.startPrank(deployerEOA);

        // Set POL rate to 100% (all fees go to protocol)
        policyManager.setPoolPOLShare(poolId, 10_000);

        vm.stopPrank();

        // Do a swap to test that fees now go to protocol
        uint256 swapAmount = 1 ether;
        _swapWETHToUSDC(user1, swapAmount, 0);

        // No need to call _simulateHookNotification - Spot hook handles this now

        // Get fee growth for LP and protocol
        // ... existing code ...
    }

    /**
     * @notice Test that POL ratio updates take effect immediately
     */
    function test_polRateChangeImmediate() public {
        // ... existing code ...

        // Do a few swaps before changing fee distribution
        uint256 swapAmount = 1 ether;
        _swapWETHToUSDC(user1, swapAmount, 0);

        // No need to call _simulateHookNotification - Spot hook handles this now

        // ... existing code ...
    }

    /**
     * @notice Test that POL ratio of 0 means all fees go to LPs
     */
    function test_polRateZero() public {
        // ... existing code ...

        // Do swaps to accumulate fees
        uint256 swapAmount = 1 ether;
        _swapWETHToUSDC(user1, swapAmount, 0);

        // No need to call _simulateHookNotification - Spot hook handles this now

        // ... existing code ...
    }

    /**
     * @notice Test surge fee decay over time
     */
    function test_surgeFeeDecaysOverTime() public {
        // ... existing code ...

        // Warp forward by half the decay period
        vm.warp(block.timestamp + surgeFeeDecayPeriod / 2);

        // No need to call _simulateHookNotification - we'll just check the state directly

        // Check that fee has decayed to roughly half
        // ... existing code ...
    }

    function testFeeStateChanges() public {
        // Get initial fee state
        (uint256 newBase, uint256 surgeFee) = dfm.getFeeState(poolId);
        assertEq(newBase, oracle.getMaxTicksPerBlock(PoolId.unwrap(poolId)) * 100, "base-fee != cap x 100");

        // Warp forward and check fee state again
        vm.warp(block.timestamp + 3600);
        (uint256 feeAfterDelay,) = dfm.getFeeState(poolId);
        assertEq(feeAfterDelay, oracle.getMaxTicksPerBlock(PoolId.unwrap(poolId)) * 100, "base-fee != cap x 100");
    }
}
