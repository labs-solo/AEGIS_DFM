// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LocalSetup} from "./LocalSetup.t.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

// import {StateLibrary}   from "v4-core/src/libraries/StateLibrary.sol"; // Keep commented out
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";


// Changed to absolute src imports
import {Spot} from "src/Spot.sol";
import {IFullRangeLiquidityManager} from "src/interfaces/IFullRangeLiquidityManager.sol";
import {IPoolPolicyManager} from "src/interfaces/IPoolPolicyManager.sol";
import {ISpot} from "src/interfaces/ISpot.sol";
// NOTE: SharedDeployLib is *not* used directly here, but keeping the structure consistent.
// If it *were* imported, the path would be updated below.
// import {SharedDeployLib} from "src/utils/SharedDeployLib.sol"; // Example of correct path

// import {IWETH9}         from "v4-periphery/interfaces/external/IWETH9.sol"; // Keep commented out
import {ERC20} from "solmate/src/tokens/ERC20.sol";
// import {CurrencySettler} from "uniswap-hooks/utils/CurrencySettler.sol"; // Removed import
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol"; // Added import
// import {PoolModifyLiquidityTest} from "./integration/routers/PoolModifyLiquidityTest.sol"; // Keep commented out
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol"; // <-- ADDED IMPORT
import {PoolPolicyManager} from "src/PoolPolicyManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {FullRangeLiquidityManager} from "src/FullRangeLiquidityManager.sol";

import "forge-std/console.sol";

// Remove local struct definition, use imported one
// struct LocalDepositParams {
//     PoolId poolId;
//     uint256 amount0Desired;
//     uint256 amount1Desired;
//     uint256 amount0Min;
//     uint256 amount1Min;
//     uint256 deadline;
// }

// The re-investment tests can run on the fully-wired environment that
// `LocalSetup` already gives us – no need to hand-roll another deployer.

contract InternalReinvestTest is LocalSetup {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20; // Updated to use IERC20 instead of IERC20Minimal

    address internal keeper = makeAddr("keeper");
    address internal feeSink = makeAddr("feeSink");

    Spot internal spotHook;
    IFullRangeLiquidityManager internal lm;
    IPoolManager internal pm; // Renamed from poolManager for consistency with snippet
    IPoolPolicyManager internal policyMgr;

    Currency internal c0;
    Currency internal c1;

    uint256 constant MIN_REINVEST_AMOUNT = 1e4; // From FullRangeLiquidityManager
    uint256 constant REINVEST_COOLDOWN = 1 days; // From FullRangeLiquidityManager

    address token0;
    address token1;

    function _ensureHookApprovals() internal {
        address t0 = Currency.unwrap(c0);
        address t1 = Currency.unwrap(c1);

        uint256 MAX = type(uint256).max;

        // ── LiquidityManager (FLM) must allow PM to pull during settle()
        vm.prank(address(liquidityManager));
        IERC20Minimal(t0).approve(address(poolManager), MAX);
        vm.prank(address(liquidityManager));
        IERC20Minimal(t1).approve(address(poolManager), MAX);

        // ── Hook must let FLM pull for deposits *and* PM pull for debt settlement
        vm.startPrank(address(spotHook));
        ERC20(t0).approve(address(liquidityManager), MAX);
        ERC20(t1).approve(address(liquidityManager), MAX);
        ERC20(t0).approve(address(poolManager), MAX);
        ERC20(t1).approve(address(poolManager), MAX);
        vm.stopPrank();
    }

    /* ---------- set‑up ---------------------------------------------------- */
    function setUp() public override {
        super.setUp();

        spotHook = Spot(fullRange);
        lm = IFullRangeLiquidityManager(liquidityManager);
        pm = poolManager; // Assign pm
        policyMgr = policyManager;

        c0 = poolKey.currency0;
        c1 = poolKey.currency1;

        vm.deal(keeper, 10 ether);

        token0 = Currency.unwrap(c0);
        token1 = Currency.unwrap(c1);

        vm.prank(deployerEOA);
        FullRangeLiquidityManager(payable(address(liquidityManager))).setReinvestmentTwap(0);
    }

    /* ---------- helpers --------------------------------------------------- */
    function _swapWETHToUSDC(address sender, uint256 amountIn) internal {
        address token0Local = Currency.unwrap(poolKey.currency0);
        bool wethIsToken0 = token0Local == address(_WETH9);
        (uint160 currentSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

        uint160 sqrtPriceLimitX96 = wethIsToken0
            ? uint160(uint256(currentSqrtPriceX96) * 9 / 10)
            : uint160(uint256(currentSqrtPriceX96) * 11 / 10);

        SwapParams memory params = SwapParams({
            zeroForOne: wethIsToken0,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false});

        vm.startPrank(sender);
        swapRouter.swap(poolKey, params, settings, ZERO_BYTES);
        vm.stopPrank();
    }

    function _swapUSDCToWETH(address sender, uint256 amountIn) internal {
        address token0Local = Currency.unwrap(poolKey.currency0);
        bool usdcIsToken0 = token0Local == address(usdc);
        (uint160 currentSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

        uint160 sqrtPriceLimitX96 = usdcIsToken0
            ? uint160(uint256(currentSqrtPriceX96) * 9 / 10)
            : uint160(uint256(currentSqrtPriceX96) * 11 / 10);

        SwapParams memory params = SwapParams({
            zeroForOne: usdcIsToken0,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false});

        vm.startPrank(sender);
        swapRouter.swap(poolKey, params, settings, ZERO_BYTES);
        vm.stopPrank();
    }

    function _ensurePendingFees(uint256 minAmount) internal {
        for (uint256 i = 0; i < 3; i++) {
            (uint256 pending0, uint256 pending1) = lm.getPendingFees(poolId);
            if (pending0 >= minAmount && pending1 >= minAmount) {
                return;
            }
            _swapWETHToUSDC(user1, 10 ether);
            _swapUSDCToWETH(user1, 50_000 * 1e6);
        }

        (uint256 finalPending0, uint256 finalPending1) = lm.getPendingFees(poolId);
        require(finalPending0 >= minAmount && finalPending1 >= minAmount, "pending fees too low");
    }

    /// @dev Add some full‐range liquidity so that pokeReinvest actually has something to grow.
    function _addInitialLiquidity(uint256 amount0, uint256 amount1) internal {
        _ensureHookApprovals();

        // Leverage LocalSetup helper which mints tokens to the governor (deployerEOA),
        // approves the LiquidityManager and routes the call through Spot.depositToFRLM.
        _addLiquidityAsGovernance(poolId, amount0, amount1, 0, 0, deployerEOA);
    }

    /* ---------- Test 1 ---------------------------------------------------- */
    function test_ReinvestSkippedWhenBelowThreshold() public {
        uint256 cooldown = FullRangeLiquidityManager(payable(address(liquidityManager))).REINVEST_COOLDOWN();
        vm.warp(block.timestamp + cooldown + 1);

        vm.recordLogs();
        vm.prank(keeper);
        bool success = lm.reinvest(poolKey);
        assertFalse(success, "Reinvest should fail when below threshold");
    }

    /* ---------- Test 2.5: Global Pause ---------------------------------- */
    function test_ReinvestSkippedWhenGlobalPaused() public {
        uint256 cooldown = FullRangeLiquidityManager(payable(address(liquidityManager))).REINVEST_COOLDOWN();
        vm.warp(block.timestamp + cooldown + 1);

        // 1) Enable global pause
        vm.prank(PoolPolicyManager(address(policyMgr)).owner());
        spotHook.setReinvestmentPaused(true);

        // 2) Perform a swap to accrue fees; reinvest should be skipped while paused
        (, uint128 liqBefore,,) = lm.getPositionInfo(poolId);
        _ensurePendingFees(MIN_REINVEST_AMOUNT);
        (, uint128 liqAfterPaused,,) = lm.getPositionInfo(poolId);
        assertEq(liqAfterPaused, liqBefore, "Liquidity changed while paused");

        // 3) Disable global pause and check success
        vm.prank(PoolPolicyManager(address(policyMgr)).owner());
        spotHook.setReinvestmentPaused(false);

        vm.recordLogs();
        vm.prank(keeper);
        bool success = lm.reinvest(poolKey);
        assertTrue(success, "Reinvest should succeed after unpause");
    }

    /* ---------- Test 3 ---------------------------------------------------- */
    function test_ReinvestSucceedsAfterBalance() public {
        // Seed the pool with initial liquidity
        _addInitialLiquidity(100 * (10 ** 6), 1 ether / 10);

        _ensurePendingFees(MIN_REINVEST_AMOUNT);

        uint256 cooldown = FullRangeLiquidityManager(payable(address(liquidityManager))).REINVEST_COOLDOWN();
        vm.warp(block.timestamp + cooldown + 1);

        // Get initial liquidity
        (, uint128 liqBefore,,) = lm.getPositionInfo(poolId);
        assertTrue(liqBefore > 0, "Initial liquidity should be non-zero");

        // Perform reinvestment
        vm.recordLogs();
        vm.prank(keeper);
        bool success = lm.reinvest(poolKey);
        assertTrue(success, "Reinvestment should succeed");

        // Check for FeesReinvested event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 successSig = keccak256("FeesReinvested(bytes32,uint256,uint256,uint256)");
        bool foundEvent = false;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == successSig) {
                foundEvent = true;
                break;
            }
        }
        assertTrue(foundEvent, "FeesReinvested event not emitted");

        // Verify liquidity increased
        (, uint128 liqAfter,,) = lm.getPositionInfo(poolId);
        assertGt(liqAfter, liqBefore, "Liquidity should increase after reinvestment");
    }

}

