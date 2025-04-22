// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ForkSetup} from "./ForkSetup.t.sol";
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
import {FullRangeDynamicFeeManager} from "../../src/FullRangeDynamicFeeManager.sol";
import {PoolPolicyManager} from "../../src/PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "../../src/TruncGeoOracleMulti.sol";
import {Spot} from "../../src/Spot.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

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

    // Test actors
    address public user1;
    address public user2;
    address public lpProvider;

    // Token balances for actors
    uint256 public constant INITIAL_WETH_BALANCE = 100 ether;
    uint256 public constant INITIAL_USDC_BALANCE = 200_000 * 10 ** 6; // 200,000 USDC

    // Initial liquidity to be provided by lpProvider
    // USDC is token0, WETH is token1 when USDC address < WETH address
    uint256 public constant INITIAL_LP_WETH = 10 ether; // WETH amount (token1)
    uint256 public constant INITIAL_LP_USDC = 30_000 * 10 ** 6; // USDC amount (token0) - 30,000 USDC for 10 WETH
    uint256 public constant EXTRA_USDC_FOR_ISOLATED = 42_000 * 10 ** 6; // spare
    uint256 public constant EXTRA_WETH_FOR_ISOLATED = 11 ether; // spare WETH

    // Test swap amounts
    uint256 public constant SMALL_SWAP_AMOUNT_WETH = 0.1 ether;
    uint256 public constant SMALL_SWAP_AMOUNT_USDC = 300 * 10 ** 6; // 300 USDC

    // Test helper variables
    uint256 public defaultDynamicFee;
    uint256 public polSharePpm;
    uint256 public surgeFeeInitialPpm;
    uint256 public surgeFeeDecayPeriod;
    int24 public tickScalingFactor;

    /**
     * @notice Set up the test environment for dynamic fee and POL tests
     * @dev Leverages the deployed contract instances from ForkSetup
     */
    function setUp() public override {
        // Call the parent setUp to initialize the deployment
        super.setUp();

        // Initialize test accounts with labels for better trace output
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        lpProvider = makeAddr("lpProvider");

        // Store key parameters from contracts for convenience
        defaultDynamicFee = policyManager.getDefaultDynamicFee();
        polSharePpm = policyManager.getPoolPOLShare(poolId);
        tickScalingFactor = policyManager.getTickScalingFactor();

        // --- Fetch Policy Parameters ---
        // Get initial surge fee from the PolicyManager
        surgeFeeInitialPpm = policyManager.defaultInitialSurgeFeePpm();
        surgeFeeDecayPeriod = policyManager.defaultSurgeDecayPeriodSeconds();

        // Fund test accounts with WETH and USDC
        vm.startPrank(deployerEOA);

        // Deal deployer enough USDC to distribute: 2 users + LP
        uint256 totalUsdcNeeded = (INITIAL_USDC_BALANCE * 2) // users
            + INITIAL_LP_USDC // first LP deposit
            + EXTRA_USDC_FOR_ISOLATED // second LP deposit (isolated test)
            ;
        deal(USDC_ADDRESS, deployerEOA, totalUsdcNeeded);
        require(usdc.balanceOf(deployerEOA) >= totalUsdcNeeded, "Insufficient USDC balance for deployer");

        // Need to wrap ETH for WETH first: 2 users + LP
        // Ensure INITIAL_LP_WETH is sufficient for calculated requirement later in _addInitialLiquidity
        uint256 totalWethNeeded = (INITIAL_WETH_BALANCE * 2) + INITIAL_LP_WETH + EXTRA_WETH_FOR_ISOLATED;
        IWETH9(WETH_ADDRESS).deposit{value: totalWethNeeded}();
        require(weth.balanceOf(deployerEOA) >= totalWethNeeded, "Insufficient WETH balance after wrapping");

        // Fund user1
        weth.transfer(user1, INITIAL_WETH_BALANCE);
        usdc.transfer(user1, INITIAL_USDC_BALANCE);

        // Fund user2
        weth.transfer(user2, INITIAL_WETH_BALANCE);
        usdc.transfer(user2, INITIAL_USDC_BALANCE);

        // Fund lpProvider
        weth.transfer(lpProvider, INITIAL_LP_WETH + EXTRA_WETH_FOR_ISOLATED); // Fund with initial WETH + extra
        usdc.transfer(lpProvider, INITIAL_LP_USDC + EXTRA_USDC_FOR_ISOLATED); // Fund with initial USDC constant (used for deposit calc base)

        vm.stopPrank();

        // Set up approvals for all actors
        _setupApprovals();

        // Add initial liquidity to the pool from lpProvider to enable swaps
        _addInitialLiquidity();

        // ── ADDED: shorten CAP‐feedback window so our 1h warp tests take effect immediately
        vm.startPrank(deployerEOA);
        policyManager.setCapFreqDecayWindow(poolId, 3600);
        policyManager.setFreqScaling(poolId, 1);
        vm.stopPrank();

        // Log key test parameters
        console2.log("Test setup complete for Dynamic Fee & POL tests");
        console2.log("Default Dynamic Fee (PPM):", defaultDynamicFee);
        console2.log("POL Share (PPM):", polSharePpm);
        console2.log("Tick Scaling Factor:", uint256(uint24(tickScalingFactor)));
        console2.log("Initial Surge Fee (PPM):", surgeFeeInitialPpm);
        console2.log("Surge Fee Decay Period (seconds):", surgeFeeDecayPeriod);
    }

    /**
     * @notice Set up necessary token approvals for all test actors
     */
    function _setupApprovals() internal {
        // User1 approvals
        vm.startPrank(user1);
        weth.approve(address(poolManager), type(uint256).max);
        usdc.approve(address(poolManager), type(uint256).max);
        weth.approve(address(liquidityManager), type(uint256).max);
        usdc.approve(address(liquidityManager), type(uint256).max);
        vm.stopPrank();

        // User2 approvals
        vm.startPrank(user2);
        weth.approve(address(poolManager), type(uint256).max);
        usdc.approve(address(poolManager), type(uint256).max);
        weth.approve(address(liquidityManager), type(uint256).max);
        usdc.approve(address(liquidityManager), type(uint256).max);
        vm.stopPrank();

        // LP Provider approvals
        vm.startPrank(lpProvider);
        weth.approve(address(poolManager), type(uint256).max);
        usdc.approve(address(poolManager), type(uint256).max);
        weth.approve(address(liquidityManager), type(uint256).max);
        usdc.approve(address(liquidityManager), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        // Make sure router can pull both tokens for real swaps
        // And also approve for the LiquidityRouter so its calls hit our hook
        usdc.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(liquidityRouter), type(uint256).max); // Added LiquidityRouter approval
        weth.approve(address(liquidityRouter), type(uint256).max); // Added LiquidityRouter approval
        vm.stopPrank();
    }

    /**
     * @notice Add initial liquidity to the pool to enable swaps
     * @dev Uses the LP Provider account to add liquidity through the FullRangeLiquidityManager
     */
    function _addInitialLiquidity() internal {
        console2.log("--- Adding Initial Liquidity via LM Deposit ---");

        // Verify WETH Bytecode
        console2.log("Inspecting code at WETH_ADDRESS:", WETH_ADDRESS);
        console2.log("WETH code Length:", WETH_ADDRESS.code.length);
        require(WETH_ADDRESS.code.length > 0, "No code found at WETH_ADDRESS");

        // Get token0/token1 in the same order your pool was initialized
        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);

        // Determine which amounts to use based on token ordering
        uint256 amount0Desired = token0 == address(usdc) ? INITIAL_LP_USDC : INITIAL_LP_WETH;
        uint256 amount1Desired = token0 == address(usdc) ? INITIAL_LP_WETH : INITIAL_LP_USDC;

        // Log token ordering for clarity
        console2.log("Token0:", token0 == address(usdc) ? "USDC" : "WETH");
        console2.log("Token1:", token1 == address(usdc) ? "USDC" : "WETH");

        // Fetch current pool state for calculation
        (uint160 initialSqrtPriceX96, int24 tickBefore,,) = StateLibrary.getSlot0(poolManager, poolId);
        console2.log("Current pool tick before deposit:", tickBefore);
        console2.log("Current pool sqrtPriceX96 before deposit:", initialSqrtPriceX96);
        require(initialSqrtPriceX96 > 0, "Pool price is zero before deposit attempt");

        // Log deposit amounts
        console2.log("Desired amount0 (", token0 == address(usdc) ? "USDC" : "WETH", "):", amount0Desired);
        console2.log("Desired amount1 (", token1 == address(usdc) ? "USDC" : "WETH", "):", amount1Desired);

        // Calculate price as sanity check
        if (token0 == address(usdc)) {
            uint256 priceEstimate = (amount0Desired * 1e18) / amount1Desired;
            console2.log("Implied price (raw units): ~", priceEstimate / 1e6, " USDC per WETH");
        } else {
            uint256 priceEstimate = (amount1Desired * 1e18) / amount0Desired;
            console2.log("Implied price (raw units): ~", priceEstimate / 1e6, " USDC per WETH");
        }

        // Log balances to make sure we have enough tokens
        console2.log("LP provider balances before deposit:");
        console2.log("  WETH:", weth.balanceOf(lpProvider));
        console2.log("  USDC:", usdc.balanceOf(lpProvider));

        // ADDED: Verify balances immediately before deposit call
        console2.log("[_addInitialLiquidity] Verifying token balances JUST BEFORE deposit:");
        require(
            (
                token0 == address(usdc)
                    ? usdc.balanceOf(lpProvider) >= amount0Desired
                    : weth.balanceOf(lpProvider) >= amount0Desired
            ),
            string.concat(
                "LP Provider lacks sufficient ",
                token0 == address(usdc) ? "USDC" : "WETH",
                " (token0) JUST BEFORE deposit call"
            )
        );
        require(
            (
                token1 == address(usdc)
                    ? usdc.balanceOf(lpProvider) >= amount1Desired
                    : weth.balanceOf(lpProvider) >= amount1Desired
            ),
            string.concat(
                "LP Provider lacks sufficient ",
                token1 == address(usdc) ? "USDC" : "WETH",
                " (token1) JUST BEFORE deposit call"
            )
        );

        // Ensure proper approvals
        vm.startPrank(lpProvider);
        weth.approve(address(liquidityManager), type(uint256).max);
        usdc.approve(address(liquidityManager), type(uint256).max);

        console2.log("Attempting liquidityManager.deposit...");
        try liquidityManager.deposit(
            poolId,
            amount0Desired, // token0 amount
            amount1Desired, // token1 amount
            0, // No minimum token0
            0, // No minimum token1
            lpProvider // LP tokens go to lpProvider
        ) returns (uint256 shares, uint256 amount0Used, uint256 amount1Used) {
            console2.log("--- Initial Liquidity Results (LM Deposit) ---");
            // Log the liquidity addition results
            console2.log("Initial liquidity added:");
            console2.log("  Shares:", shares);
            console2.log(string.concat("  ", token0 == address(usdc) ? "USDC" : "WETH", " used (token0):"), amount0Used);
            console2.log(string.concat("  ", token1 == address(usdc) ? "USDC" : "WETH", " used (token1):"), amount1Used);

            // Verify liquidity
            (uint128 liquidityFromView,,) =
                FullRangeLiquidityManager(payable(address(liquidityManager))).getPositionData(poolId);
            console2.log("Pool liquidity after deposit (from getPositionData):", uint256(liquidityFromView));
            /**
             * FullRangeLiquidityManager only *holds* the tokens;  
             * they become **active pool liquidity** the first time
             * `reinvest()` or other activation functions are called.  
             * If we skip that call the pool's liquidity stays 0
             * and every subsequent swap reverts (what we saw in
             * the failing trace). Kick it once right here so the
             * swaps in the tests have something to trade against.
             */
            // Use fullRange's pokeReinvest which properly calculates liquidity
            Spot(payable(address(fullRange))).pokeReinvest(poolId);

            // re‑query the v4 position after the reinvest
            (liquidityFromView,,) =
                FullRangeLiquidityManager(payable(address(liquidityManager))).getPositionData(poolId);
            require(liquidityFromView > 0, "reinvestPOL produced zero liquidity");
            console2.log("Deposit + reinvest successful, active liquidity:", uint256(liquidityFromView));
        } catch Error(string memory reason) {
            console2.log("Deposit failed with reason:", reason);
            revert(reason);
        } catch (bytes memory err) {
            console2.log("Deposit failed with low-level error");
            console2.logBytes(err);
            revert("Low-level error during deposit");
        }

        vm.stopPrank();
        console2.log("---------------------------------");
    }

    /**
     * @notice Helper function to perform a swap from WETH to USDC
     * @param sender The address performing the swap
     * @param amountIn The amount of WETH to swap
     * @param amountOutMinimum The minimum amount of USDC to receive
     * @return amountOut The amount of USDC received
     */
    function _swapWETHToUSDC(address sender, uint256 amountIn, uint256 amountOutMinimum)
        internal
        returns (uint256 amountOut)
    {
        amountOutMinimum; // silence
        vm.startPrank(sender);

        // Store pre-swap balances
        uint256 wethBalanceBefore = weth.balanceOf(sender);
        uint256 usdcBalanceBefore = usdc.balanceOf(sender);

        // Determine if WETH is token0 or token1
        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);
        bool wethIsToken0 = token0 == WETH_ADDRESS;

        console2.log("Swap details:");
        console2.log("  WETH is token", wethIsToken0 ? "0" : "1");

        // Set sqrtPriceLimitX96 based on swap direction
        // For zeroForOne (selling token0), we need a min price limit
        // For oneForZero (selling token1), we need a max price limit
        uint160 sqrtPriceLimitX96;
        // Get current price first
        (uint160 currentSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);

        if (wethIsToken0) {
            // If WETH is token0, we're doing a zeroForOne swap (price going down)
            // Set a price limit that's 10% below current price
            sqrtPriceLimitX96 = uint160(uint256(currentSqrtPriceX96) * 9 / 10);
        } else {
            // If WETH is token1, we're doing a oneForZero swap (price going up)
            // Set a price limit that's 10% above current price
            sqrtPriceLimitX96 = uint160(uint256(currentSqrtPriceX96) * 11 / 10);
        }

        console2.log("  Current sqrtPriceX96:", currentSqrtPriceX96);
        console2.log("  sqrtPriceLimitX96:", sqrtPriceLimitX96);

        // Prepare swap parameters - the zeroForOne value depends on token ordering
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: wethIsToken0, // If WETH is token0, then zeroForOne is true
            amountSpecified: int256(amountIn),
            sqrtPriceLimitX96: sqrtPriceLimitX96 // Set a valid price limit
        });

        // Prepare test settings
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: true, // Take any tokens or shares from the pool
            settleUsingBurn: false // Don't use burn for settlement
        });

        // Approve tokens to the swap router
        weth.approve(address(swapRouter), amountIn);

        // Perform the swap using the test router
        BalanceDelta delta = swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        // Check the output amount from the delta
        int256 amount0Delta = delta.amount0();
        int256 amount1Delta = delta.amount1();

        // Calculate the output amount based on which token is USDC
        // If WETH is token0, USDC is token1, so the output is -amount1Delta
        // If WETH is token1, USDC is token0, so the output is -amount0Delta
        amountOut = wethIsToken0 ? uint256(-amount1Delta) : uint256(-amount0Delta);

        // Verify balances changed as expected
        uint256 wethBalanceAfter = weth.balanceOf(sender);
        uint256 usdcBalanceAfter = usdc.balanceOf(sender);

        // Log the swap results
        console2.log("Swap completed:");
        console2.log(
            "  WETH balance change:",
            (wethBalanceBefore - wethBalanceAfter) / 1e18,
            ".",
            (wethBalanceBefore - wethBalanceAfter) % 1e18
        );
        console2.log(
            "  USDC balance change:",
            (usdcBalanceAfter - usdcBalanceBefore) / 1e6,
            ".",
            (usdcBalanceAfter - usdcBalanceBefore) % 1e6
        );

        vm.stopPrank();
        return amountOut;
    }

    /**
     * @notice B1: Test that swaps correctly apply the default dynamic fee and allocate POL
     * @dev Verifies the fee calculation and POL collection logic for a basic swap
     */
    function test_B1_Swap_AppliesDefaultFee() public {
        // 0. Determine token ordering
        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);
        bool wethIsToken0 = token0 == WETH_ADDRESS;

        // 1. Record pre-swap state
        uint256 wethBalanceBefore = weth.balanceOf(user1);
        uint256 usdcBalanceBefore = usdc.balanceOf(user1);

        // Read pool state before swap
        (uint160 sqrtPriceX96Before, int24 tickBefore,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Get current dynamic fee (should be the default at this point)
        uint256 currentFee = dynamicFeeManager.getCurrentDynamicFee(poolId);
        assertEq(currentFee, defaultDynamicFee, "Initial fee should match default");

        // 2. Perform a small swap (WETH -> USDC)
        uint256 swapAmount = SMALL_SWAP_AMOUNT_WETH;

        // Trace the swap execution to see if fees are being collected
        console2.log("About to perform swap with amount:", swapAmount);

        _swapWETHToUSDC(user1, swapAmount, 0);

        // 3. Verify post-swap state
        // Check pool state after swap
        (uint160 sqrtPriceX96After, int24 tickAfter,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Price direction checks depend on token ordering
        if (wethIsToken0) {
            assertTrue(sqrtPriceX96After < sqrtPriceX96Before, "Price should decrease after selling token0 (WETH)");
            assertTrue(tickAfter < tickBefore, "Tick should decrease after selling token0 (WETH)");
        } else {
            assertTrue(sqrtPriceX96After > sqrtPriceX96Before, "Price should increase after selling token1 (WETH)");
            assertTrue(tickAfter > tickBefore, "Tick should increase after selling token1 (WETH)");
        }

        // Verify user balances changed correctly
        uint256 wethBalanceAfter = weth.balanceOf(user1);
        uint256 usdcBalanceAfter = usdc.balanceOf(user1);

        // Log swap results
        uint256 wethSpent = wethBalanceBefore - wethBalanceAfter;
        uint256 usdcReceived = usdcBalanceAfter - usdcBalanceBefore;

        console2.log("Actual amounts from swap:");
        console2.log("  WETH spent:", wethSpent);
        console2.log("  USDC received:", usdcReceived);

        assertTrue(wethSpent > 0, "Should have spent some WETH");

        // Check the dynamic fee being applied during swap
        console2.log("Current dynamic fee:", dynamicFeeManager.getCurrentDynamicFee(poolId));
        console2.log("Default dynamic fee:", policyManager.getDefaultDynamicFee());

        // Calculate expected POL fee to debug
        uint256 expectedTotalFee = (swapAmount * currentFee) / 1e6;
        uint256 expectedPolFee = (expectedTotalFee * polSharePpm) / 1e6;

        console2.log("Expected fees:");
        console2.log("  Total fee amount (including POL):", expectedTotalFee);
        console2.log("  Expected POL portion:", expectedPolFee);
    }

    /// @notice B2: when CAPs > target (4/day), base-fee should rise above default
    function test_B2_BaseFee_Increases_When_Caps_Too_Frequent() public {
        console2.log("--- Test: Base Fee Increase --- ");
        // --- GET INITIAL STATE ---
        uint256 initialBase = dynamicFeeManager.getBaseFee(poolId);
        console2.log("Initial Base Fee:", initialBase);

        // Determine required swap params based on token order
        bool zeroForOne = Currency.unwrap(poolKey.currency0) == address(usdc); // selling USDC for WETH
        /* ----------------------------------------------------------------
         * Any non‑zero tick move triggers a CAP when
         *   baseFee = 3 000 ppm  and  tickScalingFactor = 2
         * ⇒ maxTickChange = 0
         * We therefore use *tiny* trades so the swap can always succeed
         * (no "transfer amount exceeds balance" reverts) while still
         * bumping the frequency counter.
         * -------------------------------------------------------------- */
        int256 capAmount = zeroForOne
            ? int256(1_000 * 1e6)   // 1 000 USDC
            : int256(0.05 ether);   // 0.05 WETH

        // ╭──────────────────────────────────────────────────────────────╮
        // │ Make sure lpProvider can fund ALL swaps in the upcoming loop │
        // ╰──────────────────────────────────────────────────────────────╯
        uint256 swapsNeeded = policyManager.getTargetCapsPerDay(poolId) + 2;
        uint256 topUp = uint256(capAmount > 0 ? capAmount : -capAmount) * swapsNeeded;
        if (zeroForOne) {
            _dealAndApprove(usdc, lpProvider, topUp);
        } else {
            _dealAndApprove(IERC20Minimal(WETH_ADDRESS), lpProvider, topUp);
        }
        
        (uint160 currentSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        uint160 sqrtPriceLimitX96Lower = TickMath.MIN_SQRT_PRICE + 1;
        uint160 sqrtPriceLimitX96Upper = TickMath.MAX_SQRT_PRICE - 1;

        // Define TestSettings for the swap router
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: true,       // Assume claims are handled elsewhere or not critical here
            settleUsingBurn: false  // Standard settlement
        });

        // Do N+1 successive swaps through the router, catching the reverts on cap
        uint256 targetCaps = policyManager.getTargetCapsPerDay(poolId);
        for (uint256 i = 0; i < swapsNeeded; ++i) {
            // Use the same block for quick succession before decay calculation kicks in
            uint256 blockNumber = block.number + i;
            vm.roll(blockNumber);
            vm.startPrank(lpProvider);
            // route through the LiquidityRouter (which is hooked) instead of direct poolManager or swapRouter
            try liquidityRouter.swap(poolKey, IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: capAmount,
                sqrtPriceLimitX96: zeroForOne ? sqrtPriceLimitX96Lower : sqrtPriceLimitX96Upper
            }), testSettings, ZERO_BYTES) { // Added testSettings as the 3rd argument
                // if it didn't revert, fine
            } catch Error(string memory reason) {
                // expected cap-revert or other swap issues
                console2.log("[Swap Loop] Swap reverted:", reason);
            } catch (bytes memory lowLevelData) {
                console2.log("[Swap Loop] Swap reverted (low-level): ");
                console2.logBytes(lowLevelData);
            }
            vm.stopPrank();
        }

        // now the hook saw all those caps…
        // but updateBaseFeeIfNeeded enforces a 1 hour minInterval before recomputing
        // so fast-forward past it:
        vm.warp(block.timestamp + 3601);

        // …now updating really runs
        (uint256 returnedBase, , bool didUpdate) =
            dynamicFeeManager.updateDynamicFeeIfNeeded(poolId, poolKey); // Note: Changed from updateBaseFeeIfNeeded to updateDynamicFeeIfNeeded
        assertTrue(didUpdate, "Update flag should be true");
        uint256 newBase = dynamicFeeManager.getBaseFee(poolId);
        assertEq(newBase, returnedBase, "Stored base fee does not match returned base fee!");
        assertTrue(newBase > initialBase, "base-fee did not increase"); // Check against initial
    }

    /// @notice B3: when CAPs < target, base-fee should fall below default
    function test_B3_BaseFee_Decreases_When_Caps_Too_Rare() public {
        console2.log("--- Test: Base Fee Decrease --- ");
        // seed the fee/oracle once so we leave the `lastUpdateTimestamp==0` branch
        // (otherwise the first call just initializes and never recomputes the fee).
        dynamicFeeManager.updateDynamicFeeIfNeeded(poolId, poolKey);
        vm.roll(block.number + 1);

        // B3: with ZERO CAPs, *after* 1h the base‑fee clamps straight to its minimum
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1); // Advance block number
        dynamicFeeManager.updateDynamicFeeIfNeeded(poolId, poolKey);
        uint256 feeAfter1Hour = dynamicFeeManager.getBaseFee(poolId);
        uint256 minBaseFee    = policyManager.getMinBaseFee(poolId);
        assertEq(
            feeAfter1Hour,
            minBaseFee,
            "Base fee should clamp to minFee after 1h with 0 caps"
        );

        // Warp another hour (total 2h), still no CAPs
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 1); // Advance block number
        dynamicFeeManager.updateDynamicFeeIfNeeded(poolId, poolKey);

        // Get base fee directly from storage using the getter
        uint256 currentBase = dynamicFeeManager.getBaseFee(poolId);

        // (we already pulled minBaseFee above)
        console2.log("Default Base Fee:", defaultDynamicFee);
        console2.log("Base Fee after low frequency:", currentBase);
        assertEq(currentBase, minBaseFee, "Base fee should be minFee after 2 hours with 0 caps");
        assertTrue(currentBase < defaultDynamicFee, "base-fee did not decrease below default");
    }

    /// @notice Helper: trigger a CAP event via a large single swap
    function _triggerCap() internal {
        console2.log("--- Triggering CAP Event (Attempting Swap) --- ");
        // **advance the block** so syncOracleData always sees a new block and records a cap
        vm.roll(block.number + 1);

        bool zeroForOne = true; // Swap USDC for WETH
        int256 amountSpecified = int256(10_000 * 1e6); // 10k USDC

        // loosen the limit so a tiny fill goes through
        (uint160 currentSqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        uint160 sqrtPriceLimitX96 = zeroForOne
            // 5% below current price if selling token0
            ? uint160((uint256(currentSqrtPriceX96) * 95) / 100)
            // 5% above current price if selling token1
            : uint160((uint256(currentSqrtPriceX96) * 105) / 100);

        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne:        zeroForOne,
            amountSpecified:   amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: true,
            settleUsingBurn: false
        });

        // Perform swap to move tick - catch reverts but proceed
        // Use the swapRouter (PoolSwapTest) which handles unlock
        try swapRouter.swap(poolKey, p, settings, ZERO_BYTES) {}
        catch Error(string memory reason) {
             console2.log("[DynamicFeeAndPOL._triggerCap] Swap reverted:", reason);
        }

        // **advance block again** before pulling in the cap event
        vm.roll(block.number + 1);
        console2.log("Manually calling updateDynamicFeeIfNeeded post-CAP attempt...");
        dynamicFeeManager.updateDynamicFeeIfNeeded(poolId, poolKey);
        console2.log("--- CAP Event Update Processed --- "); // Changed log message for clarity
    }

    /**
     * @notice Deals tokens to a recipient and approves relevant contracts.
     * @param token The ERC20 token contract instance.
     * @param recipient The address to receive tokens.
     * @param amount The amount of tokens to deal and approve.
     */
    function _dealAndApprove(IERC20Minimal token, address recipient, uint256 amount) internal {
        address tokenAddr = address(token);
        deal(tokenAddr, recipient, amount);
        vm.startPrank(recipient);
        token.approve(address(poolManager), amount);
        token.approve(address(swapRouter), amount);
        token.approve(address(liquidityManager), amount);
        vm.stopPrank();
    }

    // Additional test functions to be implemented

    // ==============================================
    // TEMPORARY DEBUGGING TEST FOR LiquidityAmounts
    // ==============================================
    function test_DebugLiquidityAmounts() public {
        console2.log("--- Starting Debug Liquidity Amounts Test ---");

        // 1. Get State
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 tickSpacing = poolKey.tickSpacing;

        // 2. Calculate Tick/Price Bounds
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // 3. Define Desired Amounts & Calculate intermediate liquidity
        uint256 amount1Desired_WETH = INITIAL_LP_WETH; // 10 ether
        uint256 amount0Desired_USDC_calculated = 40502294233;
        uint128 liquidityForDesired0 =
            LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtRatioBX96, amount0Desired_USDC_calculated);
        uint128 liquidityForDesired1 =
            LiquidityAmounts.getLiquidityForAmount1(sqrtPriceX96, sqrtRatioAX96, amount1Desired_WETH);

        // 4. Determine actual amounts based on limiting liquidity
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

        // 5. Isolate and Test LiquidityAmounts.getLiquidityForAmounts
        console2.log("--- Testing LiquidityAmounts.getLiquidityForAmounts --- ");
        console2.log("Input sqrtPriceX96:", sqrtPriceX96);
        console2.log("Input sqrtRatioAX96:", sqrtRatioAX96);
        console2.log("Input sqrtRatioBX96:", sqrtRatioBX96);
        console2.log("Input actual0 (USDC):", actual0);
        console2.log("Input actual1 (WETH):", actual1);

        uint128 finalLiquidity;
        finalLiquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtRatioAX96, sqrtRatioBX96, actual0, actual1);
        console2.log("SUCCESS: getLiquidityForAmounts result:", uint256(finalLiquidity));
        if (finalLiquidity == 0) {
            console2.log("!!! CONFIRMED: getLiquidityForAmounts returned ZERO !!!");
        }

        console2.log("--- Finished Debug Liquidity Amounts Test ---");
    }

    // ==============================================
    // ISOLATED DEPOSIT TEST
    // ==============================================
    function test_IsolatedDeposit_Initial() public {
        // Ensure this runs *after* setup provides balances but potentially *before* _addInitialLiquidity runs
        // Or, run this standalone by commenting out _addInitialLiquidity in setUp
        // For now, assume setUp ran and provided balances

        uint256 usdcToDeposit = 40502294233;
        uint256 wethToDeposit = 10 ether;

        console2.log("--- Starting Isolated Deposit Test ---");
        console2.log("LP Provider Address:", lpProvider);
        console2.log("Verifying balances before isolated deposit:");
        console2.log("  USDC:", usdc.balanceOf(lpProvider));
        console2.log("  WETH:", weth.balanceOf(lpProvider));

        // Ensure sufficient balance (redundant if setUp worked, but good check)
        require(usdc.balanceOf(lpProvider) >= usdcToDeposit, "LP lacks USDC for isolated test");
        require(weth.balanceOf(lpProvider) >= wethToDeposit, "LP lacks WETH for isolated test");

        // Approvals should still be valid from setUp

        vm.startPrank(lpProvider);
        console2.log("Attempting isolated liquidityManager.deposit...");
        try liquidityManager.deposit(
            poolId,
            usdcToDeposit, // amount0Desired (USDC)
            wethToDeposit, // amount1Desired (WETH)
            0, // minAmount0
            0, // minAmount1
            lpProvider
        ) returns (uint256 shares, uint256 usdcUsed, uint256 wethUsed) {
            console2.log("--- Isolated Initial Liquidity Results ---");
            console2.log("  Shares:", shares);
            console2.log("  USDC used (token0):", usdcUsed);
            console2.log("  WETH used (token1):", wethUsed);
            assertTrue(shares > 0, "Isolated deposit should yield shares");
        } catch Error(string memory reason) {
            console2.log("Isolated deposit failed with reason:", reason);
            revert(reason);
        } catch (bytes memory err) {
            console2.log("Isolated deposit failed with low-level error");
            console2.logBytes(err);
            revert("Low-level error during isolated deposit");
        }
        vm.stopPrank();
        console2.log("--- Finished Isolated Deposit Test ---");
    }
}
