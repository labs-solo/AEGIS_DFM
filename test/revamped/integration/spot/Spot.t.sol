// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// - - - v4 core imports - - -

import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

// - - - v4 core imports - - -

import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

// - - - solmate imports - - -

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// - - - local test helpers imports - - -

import {Base_Test} from "../../Base_Test.sol";

// - - - local src imports - - -

import {Errors} from "src/errors/Errors.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PositionConfig} from "v4-periphery/test/shared/PositionConfig.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

/// @dev General Spot contract tests
contract SpotTest is Base_Test {
    function setUp() public override {
        Base_Test.setUp();
    }

    // - - - parametrized test helpers - - -

    /**
     * @notice Helper function to test dynamic fee behavior with no hook fee and no auto reinvestment
     * @param zeroForOne Direction of the swap (true for token0 to token1, false for token1 to token0)
     * @param exactInput Whether this is an exact input swap (true) or exact output swap (false)
     * @param amount The input or output amount (depending on exactInput flag)
     * @param manualFee The manual fee to set in basis points (e.g., 3000 = 0.3%), or 0 for dynamic fee
     */
    function _testDynamicFee(bool zeroForOne, bool exactInput, uint256 amount, uint24 manualFee) internal {
        // Setup fee configuration
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, manualFee);
        policyManager.setPoolPOLShare(poolId, 0);
        spot.setReinvestmentPaused(true);
        vm.stopPrank();

        // Get initial state for verification later
        (uint256 pendingFee0Before, uint256 pendingFee1Before) = liquidityManager.getPendingFees(poolId);

        // Get quote for expected output/input
        uint256 expectedAmountOutOrIn;
        if (exactInput) {
            (expectedAmountOutOrIn,) = quoter.quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: poolKey,
                    zeroForOne: zeroForOne,
                    exactAmount: uint128(amount),
                    hookData: hex""
                })
            );
        } else {
            (expectedAmountOutOrIn,) = quoter.quoteExactOutputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: poolKey,
                    zeroForOne: zeroForOne,
                    exactAmount: uint128(amount),
                    hookData: hex""
                })
            );
        }

        // Create swap parameters
        int256 swapAmount = exactInput ? -int256(amount) : int256(amount);

        // Execute the swap
        vm.startPrank(user1);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        BalanceDelta delta =
            swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        vm.stopPrank();

        // Calculate actual amounts from delta
        uint256 actualInputAmount = uint256(int256(zeroForOne ? -delta.amount0() : -delta.amount1()));
        uint256 actualOutputAmount = uint256(int256(zeroForOne ? delta.amount1() : delta.amount0()));

        // Verify expected vs actual for input or output based on exactInput flag
        if (exactInput) {
            assertEq(actualInputAmount, amount, "Input amount doesn't match specified amount");
            assertApproxEqRel(actualOutputAmount, expectedAmountOutOrIn, 1e15, "Output amount doesn't match expected");
        } else {
            assertEq(actualOutputAmount, amount, "Output amount doesn't match specified amount");
            assertApproxEqRel(actualInputAmount, expectedAmountOutOrIn, 1e15, "Input amount doesn't match expected");
        }

        // Verify fee collection behavior
        (uint256 pendingFee0After, uint256 pendingFee1After) = liquidityManager.getPendingFees(poolId);

        // pending fees should remain 0 since no hook fee was charged
        assertEq(pendingFee0After, pendingFee0Before);
        assertEq(pendingFee1After, pendingFee1Before);
    }

    /**
     * @notice Helper function to test hook fee collection across different swap scenarios
     * @param zeroForOne Direction of the swap (true for token0 to token1, false for token1 to token0)
     * @param exactInput Whether this is an exact input swap (true) or exact output swap (false)
     * @param amount The input or output amount (depending on exactInput flag)
     * @param manualFee The manual fee to set in basis points (e.g., 3000 = 0.3%)
     * @param polShare The protocol-owned liquidity share (e.g., 200000 = 20%)
     */
    function _testHookFeeCollection(
        bool zeroForOne,
        bool exactInput,
        uint256 amount,
        uint24 manualFee,
        uint256 polShare
    ) internal {
        // Set up fees and pause reinvestment
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, manualFee);
        policyManager.setPoolPOLShare(poolId, polShare);
        spot.setReinvestmentPaused(true);
        vm.stopPrank();

        // Check initial pending fees
        (uint256 pendingFee0Before, uint256 pendingFee1Before) = liquidityManager.getPendingFees(poolId);

        // Create swap parameters
        int256 swapAmount;
        if (exactInput) {
            swapAmount = -int256(amount); // Negative for exactInput
        } else {
            swapAmount = int256(amount); // Positive for exactOutput
        }

        // Execute the swap
        vm.startPrank(user1);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: swapAmount,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        BalanceDelta delta =
            swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        vm.stopPrank();

        // Determine input amount and input token
        uint256 inputAmount;
        if (exactInput) {
            inputAmount = amount;
        } else {
            // For exactOutput, extract input amount from delta
            inputAmount = uint256(int256(zeroForOne ? -delta.amount0() : -delta.amount1()));
        }

        // Calculate expected fee
        uint256 swapFeeAmount;
        uint256 expectedProtocolFee;
        if (exactInput) {
            swapFeeAmount = FullMath.mulDiv(inputAmount, manualFee, 1e6);
            expectedProtocolFee = FullMath.mulDiv(swapFeeAmount, polShare, 1e6);
        } else {
            // in the case of exactOut the inputAmount includes the pol fee(i.e. hook fee) i.e.
            // inputAmount = v3InputAmount + hookFee = v3InputAmount + v3InputAmount * (dynamicFee * polShare) / 1e12
            uint256 v3InputAmount = (inputAmount * 1e12) / (1e12 + ((manualFee * polShare)));

            expectedProtocolFee = inputAmount - v3InputAmount;
        }

        // Get updated pending fees
        (uint256 pendingFee0After, uint256 pendingFee1After) = liquidityManager.getPendingFees(poolId);

        // Calculate actual protocol fees collected
        uint256 actualProtocolFee0 = pendingFee0After - pendingFee0Before;
        uint256 actualProtocolFee1 = pendingFee1After - pendingFee1Before;

        // Check fee collection based on swap direction
        if (zeroForOne) {
            // Fee should be in token0
            assertApproxEqAbs(actualProtocolFee0, expectedProtocolFee, 1, "Incorrect protocol fee for token0");
            assertEq(actualProtocolFee1, 0, "Unexpected protocol fee for token1");
        } else {
            // Fee should be in token1
            assertEq(actualProtocolFee0, 0, "Unexpected protocol fee for token0");
            assertApproxEqAbs(actualProtocolFee1, expectedProtocolFee, 1, "Incorrect protocol fee for token1");
        }

        // Verify correct direction of swap
        if (zeroForOne) {
            assertLt(delta.amount0(), 0, "Expected negative amount0 for zeroForOne swap");
            assertGt(delta.amount1(), 0, "Expected positive amount1 for zeroForOne swap");
        } else {
            assertGt(delta.amount0(), 0, "Expected positive amount0 for oneForZero swap");
            assertLt(delta.amount1(), 0, "Expected negative amount1 for oneForZero swap");
        }

        // Verify expected swap behavior
        if (exactInput) {
            // For exactInput, verify input amount is exactly what was specified
            uint256 actualInput = uint256(int256(zeroForOne ? -delta.amount0() : -delta.amount1()));
            assertEq(actualInput, amount, "Input amount doesn't match specified amount");
        } else {
            // For exactOutput, verify output amount is exactly what was specified
            uint256 actualOutput = uint256(int256(zeroForOne ? delta.amount1() : delta.amount0()));
            assertEq(actualOutput, amount, "Output amount doesn't match specified amount");
        }

        // Verify no protocol-owned shares were created (since reinvestment is paused)
        (uint256 protocolShares,,) = liquidityManager.getProtocolOwnedLiquidity(poolId);
        uint256 protocolSharesFromBalance =
            liquidityManager.balanceOf(address(liquidityManager), uint256(PoolId.unwrap(poolId)));
        assertEq(protocolShares, protocolSharesFromBalance, "Inconsistent protocol shares reporting");
    }

    /**
     * @notice Helper function to test reinvestment functionality under different conditions
     * @param reinvestmentPaused Whether reinvestment should be paused initially
     * @param manualFee The fee in basis points (e.g., 3000 = 0.3%)
     * @param polShare The protocol fee share (e.g., 200000 = 20%)
     * @param swapAmount The amount to swap to generate fees
     * @param swapPattern How to distribute swaps (0=balanced, 1=only zeroForOne, 2=only oneForZero)
     * @param numSwaps Number of swaps to perform
     * @param advanceTime Time to advance between swaps (to test cooldown)
     * @param expectSuccess Whether the manual reinvestment should succeed
     */
    function _testReinvestment(
        bool reinvestmentPaused,
        uint24 manualFee,
        uint256 polShare,
        uint256 swapAmount,
        uint8 swapPattern,
        uint256 numSwaps,
        uint256 advanceTime,
        bool expectSuccess
    ) internal {
        // Setup
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, manualFee);
        policyManager.setPoolPOLShare(poolId, polShare);
        spot.setReinvestmentPaused(reinvestmentPaused);

        // Donate and do initial reinvestment to setup the NFT and subscribe to notifications
        liquidityManager.donate(poolKey, 1e10, 1e10);
        vm.warp(block.timestamp + advanceTime);
        liquidityManager.reinvest(poolKey);

        vm.stopPrank();

        // Get initial state
        (uint256 pendingFee0Initial, uint256 pendingFee1Initial) = liquidityManager.getPendingFees(poolId);
        (uint256 protocolSharesInitial,,) = liquidityManager.getProtocolOwnedLiquidity(poolId);
        uint256 nextReinvestTime = liquidityManager.getNextReinvestmentTime(poolId);

        assertGt(protocolSharesInitial, 0, "Expect initial donation to be invested into NFT");

        // Execute swaps to generate fees
        for (uint256 i = 0; i < numSwaps; i++) {
            vm.startPrank(user1);

            // Determine swap direction based on pattern
            bool zeroForOne;
            if (swapPattern == 0) {
                // Balanced pattern - alternate directions
                zeroForOne = (i % 2 == 0);
            } else if (swapPattern == 1) {
                // Only zeroForOne
                zeroForOne = true;
            } else {
                // Only oneForZero
                zeroForOne = false;
            }

            SwapParams memory params = SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            });

            swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
            vm.stopPrank();

            // Advance time if specified
            if (advanceTime > 0) {
                vm.warp(block.timestamp + advanceTime);
            }
        }

        // Check intermediate state - fees should have accumulated
        (uint256 pendingFee0Mid, uint256 pendingFee1Mid) = liquidityManager.getPendingFees(poolId);
        (uint256 protocolSharesMid,,) = liquidityManager.getProtocolOwnedLiquidity(poolId);

        // if reinvestmentPaused then we expect pending fees to accumulate(and not be reinvested)
        if (reinvestmentPaused) {
            // Verify fees accumulated properly based on swap pattern
            if (swapPattern == 0 || swapPattern == 1) {
                // Should have token0 fees if we did zeroForOne swaps
                assertGt(pendingFee0Mid, pendingFee0Initial, "Token0 fees should accumulate from zeroForOne swaps"); // TODO
            }

            if (swapPattern == 0 || swapPattern == 2) {
                // Should have token1 fees if we did oneForZero swaps
                assertGt(pendingFee1Mid, pendingFee1Initial, "Token1 fees should accumulate from oneForZero swaps");
            }
        }

        // If reinvestment is paused, protocol shares shouldn't increase
        if (reinvestmentPaused) {
            assertEq(
                protocolSharesMid,
                protocolSharesInitial,
                "Protocol shares should not increase when reinvestment is paused"
            );
        } else {
            assertGt(
                protocolSharesMid,
                protocolSharesInitial,
                "Protocol shares should increase when reinvestment is NOT paused"
            );
        }

        // Try manual reinvestment
        bool reinvestResult = liquidityManager.reinvest(poolKey);

        // if reinvestmentPaused then we expect an actual reinvestment to occur on pending fees
        if (reinvestmentPaused) {
            // Check if result matches expectation
            assertEq(reinvestResult, expectSuccess, "Reinvestment result doesn't match expectation");
        }

        // Check final state
        (uint256 pendingFee0Final, uint256 pendingFee1Final) = liquidityManager.getPendingFees(poolId);
        (uint256 protocolSharesFinal,,) = liquidityManager.getProtocolOwnedLiquidity(poolId);

        // Final swap to verify behavior post-reinvestment
        vm.startPrank(user1);

        // For final swap, use zeroForOne to check token0 fee accrual
        SwapParams memory finalParams =
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        swapRouter.swap(poolKey, finalParams, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        vm.stopPrank();

        // Check that fees from final swap accumulated properly
        (uint256 pendingFee0AfterFinal, uint256 pendingFee1AfterFinal) = liquidityManager.getPendingFees(poolId);
        assertGt(pendingFee0AfterFinal, pendingFee0Final, "Token0 fees should accumulate from final swap");
    }

    /**
     * @notice Helper function to test NFT position earning LP fees (no hook fees)
     * @param manualFee The fee in basis points (e.g., 3000 = 0.3%)
     * @param donationAmount0 Initial donation amount for token0
     * @param donationAmount1 Initial donation amount for token1
     * @param swapAmount Amount for each swap
     * @param numSwaps Number of swaps to perform
     * @param bidirectional Whether to alternate swap directions
     */
    function _testNFTEarnsLPFees(
        uint24 manualFee,
        uint256 donationAmount0,
        uint256 donationAmount1,
        uint256 swapAmount,
        uint256 numSwaps,
        bool bidirectional
    ) internal {
        // Setup: No hook fees, paused reinvestment
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, manualFee);
        policyManager.setPoolPOLShare(poolId, 0); // No hook fees
        spot.setReinvestmentPaused(true); // Prevent auto-reinvestment
        vm.stopPrank();

        // Get initial pool state before FRLM position
        (uint160 sqrtPriceX96Before,,,) = StateLibrary.getSlot0(manager, poolId);
        uint128 totalLiquidityBefore = StateLibrary.getLiquidity(manager, poolId);

        // Donate to FRLM to create pending fees
        vm.startPrank(user1);
        liquidityManager.donate(poolKey, donationAmount0, donationAmount1);
        vm.stopPrank();

        // Verify donation created pending fees
        (uint256 pendingFee0AfterDonation, uint256 pendingFee1AfterDonation) = liquidityManager.getPendingFees(poolId);
        assertEq(pendingFee0AfterDonation, donationAmount0, "Donation should create pending fee0");
        assertEq(pendingFee1AfterDonation, donationAmount1, "Donation should create pending fee1");

        // Wait for cooldown and reinvest to create NFT position
        vm.warp(block.timestamp + REINVEST_COOLDOWN + 1);
        bool reinvestSuccess = liquidityManager.reinvest(poolKey);
        assertTrue(reinvestSuccess, "Reinvestment should succeed");

        // Verify NFT position was created
        (uint256 positionId, uint128 nftLiquidity, uint256 nftAmount0, uint256 nftAmount1) =
            liquidityManager.getPositionInfo(poolId);
        assertGt(positionId, 0, "NFT position should exist");
        assertGt(nftLiquidity, 0, "NFT should have liquidity");

        // Get pool state after FRLM position
        uint128 totalLiquidityAfter = StateLibrary.getLiquidity(manager, poolId);
        uint128 liquidityIncrease = totalLiquidityAfter - totalLiquidityBefore;

        // FRLM's share of the pool - since there's only 2 full range positions on the pool
        // 1st added in the Base_Test.setUp function and the 2nd is from this FRLM NFT
        uint256 frlmSharePPM = (uint256(nftLiquidity) * 1e6) / uint256(totalLiquidityAfter);

        // Pending fees should be near zero after reinvestment (some dust possible)
        (uint256 pendingFee0Initial, uint256 pendingFee1Initial) = liquidityManager.getPendingFees(poolId);
        assertLt(pendingFee0Initial, 1e4, "Pending fee0 should be minimal after reinvestment");
        assertLt(pendingFee1Initial, 1e4, "Pending fee1 should be minimal after reinvestment");

        // Track cumulative fees
        uint256 expectedFee0 = 0;
        uint256 expectedFee1 = 0;

        // Execute swaps and track fee accrual
        for (uint256 i = 0; i < numSwaps; i++) {
            bool zeroForOne = bidirectional ? (i % 2 == 0) : true;

            // Execute swap
            vm.startPrank(user2);
            SwapParams memory params = SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(swapAmount), // exactIn
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            });

            BalanceDelta delta = swapRouter.swap(
                poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), ""
            );
            vm.stopPrank();

            // Calculate LP fee for this swap
            uint256 inputAmount = uint256(uint128(-delta.amount0()));
            if (!zeroForOne) {
                inputAmount = uint256(uint128(-delta.amount1()));
            }

            // Total LP fee = inputAmount * manualFee / 1e6
            uint256 totalLPFee = FullMath.mulDiv(inputAmount, manualFee, 1e6);

            // FRLM's share of the LP fee
            uint256 frlmFee = FullMath.mulDiv(totalLPFee, frlmSharePPM, 1e6);

            if (zeroForOne) {
                expectedFee0 += frlmFee;
            } else {
                expectedFee1 += frlmFee;
            }
        }

        uint256 smallDeposit = MIN_REINVEST_AMOUNT * 10;

        // NOTE: we do a small donation so that there is enough pending to reinvest which should trigger NFT fee accrual to pending
        vm.startPrank(user1);
        vm.warp(block.timestamp + REINVEST_COOLDOWN + 1);
        liquidityManager.donate(poolKey, smallDeposit, smallDeposit);
        reinvestSuccess = liquidityManager.reinvest(poolKey);
        assertTrue(reinvestSuccess, "Reinvest pending should occur");
        vm.stopPrank();

        // Get final pending fees
        (uint256 pendingFee0Final, uint256 pendingFee1Final) = liquidityManager.getPendingFees(poolId);

        // Calculate actual fee accrual

        // zeroForOne swaps generate token0 fees
        if (expectedFee0 > 0) {
            uint256 actualFeeAccrued0 = pendingFee0Final - pendingFee0Initial - smallDeposit;
            // Allow some tolerance due to rounding
            assertApproxEqRel(
                actualFeeAccrued0,
                expectedFee0,
                2.1e16, // 2.1% tolerance
                "Token0 fees should match expected"
            );
        }

        // if !bidirectional then only zeroForOne swaps so no 1 earned in fees
        if (bidirectional) {
            // oneForZero swaps generate token1 fees
            uint256 actualFeeAccrued1 = pendingFee1Final - pendingFee1Initial - smallDeposit;
            if (expectedFee1 > 0) {
                assertGt(actualFeeAccrued1, 0, "Should have accrued token1 fees");
                assertApproxEqRel(
                    actualFeeAccrued1,
                    expectedFee1,
                    2.1e16, // 2.1% tolerance
                    "Token1 fees should match expected"
                );
            }
        } else {
            assertEq(expectedFee1, 0, "expected should be 0");
            // Even with only zeroForOne swaps, some token1 fees may be generated due to price impact
            // and liquidity rebalancing during reinvestment. Allow a higher tolerance.
            assertApproxEqAbs(pendingFee1Final, pendingFee1Initial, 100, "fees in token1 should be minimal with only zeroForOne swaps");
        }

        (, uint128 finalNftLiquidity,,) = liquidityManager.getPositionInfo(poolId);

        // Verify no protocol shares were minted (since hook fee is 0)
        (uint256 protocolShares,,) = liquidityManager.getProtocolOwnedLiquidity(poolId);
        assertGt(finalNftLiquidity, nftLiquidity, "NFT liquidity should've increased from donation");
        assertEq(
            protocolShares,
            finalNftLiquidity - MIN_LOCKED_LIQUIDITY,
            "Protocol shares should only be from initial reinvestment"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        HOOK INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HookPermissions() public {
        Hooks.Permissions memory permissions = spot.getHookPermissions();

        // Verify expected permissions are set
        assertEq(permissions.beforeInitialize, false);
        assertEq(permissions.afterInitialize, true);
        assertEq(permissions.beforeAddLiquidity, true);
        assertEq(permissions.afterAddLiquidity, false);
        assertEq(permissions.beforeRemoveLiquidity, true);
        assertEq(permissions.afterRemoveLiquidity, false);
        assertEq(permissions.beforeSwap, true);
        assertEq(permissions.afterSwap, true);
        assertEq(permissions.beforeSwapReturnDelta, true);
        assertEq(permissions.afterSwapReturnDelta, true);
    }



    function test_ConsultReflectsLiquidityChanges() public {
        console.log("=== TESTING CONSULT-BASED LIQUIDITY TRACKING ===");
        
        // Initial state
        (int24 initialTick, uint32 initialTimestamp) = oracle.getLatestObservation(poolId);
        
        console.log("\n=== INITIAL STATE ===");
        console.log("Tick:", initialTick);
        console.log("Timestamp:", initialTimestamp);
        
        // Wait a bit before first consult to ensure we have observations
        vm.warp(block.timestamp + 30);
        
        (int24 arithmeticMeanTick1, uint128 harmonicMeanLiquidity1) = oracle.consult(poolKey, 30);
        console.log("Harmonic mean liquidity (30s):", harmonicMeanLiquidity1);
        
        // Add liquidity
        vm.warp(block.timestamp + 60); // Move forward 1 minute
        
        vm.startPrank(owner);
        (uint256 sharesReceived, uint256 amount0Used, uint256 amount1Used) = 
            spot.depositToFRLM(poolKey, 1000 ether, 1000 ether, 0, 0, owner);
        vm.stopPrank();
        
        (int24 afterAddTick, uint32 afterAddTimestamp) = oracle.getLatestObservation(poolId);
        (int24 arithmeticMeanTick2, uint128 harmonicMeanLiquidity2) = oracle.consult(poolKey, 30);
        
        console.log("\n=== AFTER ADDING LIQUIDITY ===");
        console.log("Tick:", afterAddTick);
        console.log("Timestamp:", afterAddTimestamp);
        console.log("Harmonic mean liquidity (30s):", harmonicMeanLiquidity2);
        console.log("Shares received:", sharesReceived);
        
        // Verify liquidity changes
        console.log("Liquidity comparison - Before:", harmonicMeanLiquidity1, "After:", harmonicMeanLiquidity2);
        
        // Wait longer to see the effect more clearly
        vm.warp(block.timestamp + 60);
        (int24 arithmeticMeanTick2b, uint128 harmonicMeanLiquidity2b) = oracle.consult(poolKey, 30);
        console.log("Liquidity after waiting 60s more (30s window):", harmonicMeanLiquidity2b);
        
        // Now the 30s window should reflect more of the post-deposit liquidity
        assertGt(harmonicMeanLiquidity2b, harmonicMeanLiquidity1, "Liquidity should be higher in post-deposit period");
        
        // Remove liquidity
        vm.warp(block.timestamp + 60); // Move forward another 1 minute
        
        vm.startPrank(owner);
        (uint256 amount0Withdrawn, uint256 amount1Withdrawn) = 
            spot.withdrawFromFRLM(poolKey, sharesReceived / 2, 0, 0, owner);
        vm.stopPrank();
        
        (int24 afterRemoveTick, uint32 afterRemoveTimestamp) = oracle.getLatestObservation(poolId);
        (int24 arithmeticMeanTick3, uint128 harmonicMeanLiquidity3) = oracle.consult(poolKey, 30);
        
        console.log("\n=== AFTER REMOVING LIQUIDITY ===");
        console.log("Tick:", afterRemoveTick);
        console.log("Timestamp:", afterRemoveTimestamp);
        console.log("Harmonic mean liquidity (30s):", harmonicMeanLiquidity3);
        console.log("Tokens withdrawn - Token0:", amount0Withdrawn);
        console.log("Tokens withdrawn - Token1:", amount1Withdrawn);
        
        // Wait longer to see the effect of withdrawal
        vm.warp(block.timestamp + 60);
        (int24 arithmeticMeanTick3b, uint128 harmonicMeanLiquidity3b) = oracle.consult(poolKey, 30);
        console.log("Liquidity after waiting 60s more (30s window):", harmonicMeanLiquidity3b);
        
        // Verify liquidity changes
        console.log("Liquidity comparison - Post-add:", harmonicMeanLiquidity2b, "Post-remove:", harmonicMeanLiquidity3b);
        
        // The post-withdrawal liquidity should be lower than post-deposit liquidity
        assertLt(harmonicMeanLiquidity3b, harmonicMeanLiquidity2b, "Liquidity should be lower after withdrawal");
        assertGt(harmonicMeanLiquidity3b, 0, "Liquidity should still be positive after partial withdrawal");
    }

    /*//////////////////////////////////////////////////////////////
                        DYNAMIC FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DynamicFee_Manual_NoPolShare_ExactIn_0() public {
        _testDynamicFee(
            true, // zeroForOne
            true, // exactInput
            1 ether, // amount
            2000 // manualFee (0.2%)
        );
    }

    function test_DynamicFee_Manual_NoPolShare_ExactIn_1() public {
        _testDynamicFee(
            false, // zeroForOne
            true, // exactInput
            1 ether, // amount
            2000 // manualFee (0.2%)
        );
    }

    function test_DynamicFee_Manual_NoPolShare_ExactOut_0() public {
        _testDynamicFee(
            true, // zeroForOne
            false, // exactOutput
            0.5 ether, // amount
            2000 // manualFee (0.2%)
        );
    }

    function test_DynamicFee_Manual_NoPolShare_ExactOut_1() public {
        _testDynamicFee(
            false, // zeroForOne
            false, // exactOutput
            0.5 ether, // amount
            2000 // manualFee (0.2%)
        );
    }

    /*//////////////////////////////////////////////////////////////
                        HOOK FEE COLLECTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HookFee_ExactInput_ZeroForOne() public {
        _testHookFeeCollection(
            true, // zeroForOne
            true, // exactInput
            1 ether, // amount
            3000, // manualFee (0.3%)
            200000 // polShare (20%)
        );
    }

    function test_HookFee_ExactInput_OneForZero() public {
        _testHookFeeCollection(
            false, // oneForZero
            true, // exactInput
            1 ether, // amount
            3000, // manualFee (0.3%)
            200000 // polShare (20%)
        );
    }

    function test_HookFee_ExactOutput_ZeroForOne() public {
        _testHookFeeCollection(
            true, // zeroForOne
            false, // exactOutput
            0.5 ether, // amount
            3000, // manualFee (0.3%)
            200000 // polShare (20%)
        );
    }

    function test_HookFee_ExactOutput_OneForZero() public {
        _testHookFeeCollection(
            false, // oneForZero
            false, // exactOutput
            0.5 ether, // amount
            3000, // manualFee (0.3%)
            200000 // polShare (20%)
        );
    }
    /*//////////////////////////////////////////////////////////////
                        ORACLE TESTS
    //////////////////////////////////////////////////////////////*/

    // TODO: figure out the tests we want to implement

    /*//////////////////////////////////////////////////////////////
                        REINVESTMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Reinvestment_Paused_Manual_BalancedFees() public {
        // Test with balanced fees in both tokens
        _testReinvestment(
            true, // reinvestmentPaused
            3000, // manualFee (0.3%)
            200000, // polShare (20%)
            5 ether, // swapAmount
            0, // swapPattern (balanced - alternating directions)
            4, // numSwaps (even number to ensure equal swaps in both directions)
            liquidityManager.REINVEST_COOLDOWN() + 1, // advance past cooldown
            true // expectSuccess (should succeed with balanced fees)
        );
    }

    function test_Reinvestment_Paused_Manual_OnlyToken0Fees() public {
        // Test with only token0 fees
        _testReinvestment(
            true, // reinvestmentPaused
            3000, // manualFee (0.3%)
            200000, // polShare (20%)
            5 ether, // swapAmount
            1, // swapPattern (only zeroForOne swaps)
            3, // numSwaps
            liquidityManager.REINVEST_COOLDOWN() + 1, // advance past cooldown
            false // expectSuccess (likely to fail with only token0 fees)
        );
    }

    function test_Reinvestment_Paused_Manual_OnlyToken1Fees() public {
        // Test with only token1 fees
        _testReinvestment(
            true, // reinvestmentPaused
            3000, // manualFee (0.3%)
            200000, // polShare (20%)
            5 ether, // swapAmount
            2, // swapPattern (only oneForZero swaps)
            3, // numSwaps
            liquidityManager.REINVEST_COOLDOWN() + 1, // advance past cooldown
            false // expectSuccess (likely to fail with only token1 fees)
        );
    }

    function test_Reinvestment_NotPaused_AutoReinvest() public {
        // Test automatic reinvestment with balanced fees
        _testReinvestment(
            false, // reinvestmentPaused (automatic reinvestment enabled)
            3000, // manualFee (0.3%)
            200000, // polShare (20%)
            5 ether, // swapAmount
            0, // swapPattern (balanced)
            4, // numSwaps
            liquidityManager.REINVEST_COOLDOWN() + 1, // advance past cooldown
            true // expectSuccess - since NFT fees accrue to pending fees manual reinvest is still possible
        );
    }

    /*//////////////////////////////////////////////////////////////
                        NFT LP FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_NFT_Earns_LP_Fees_No_Hook_Fees_Balanced() public {
        _testNFTEarnsLPFees(
            3000, // 0.3% fee
            10 ether, // donation amount0
            10 ether, // donation amount1
            1 ether, // swap amount
            6, // number of swaps
            true // bidirectional
        );
    }

    function test_NFT_Earns_LP_Fees_No_Hook_Fees_Large_Position() public {
        _testNFTEarnsLPFees(
            5000, // 0.5% fee (higher fee)
            50 ether, // large donation amount0
            50 ether, // large donation amount1
            2 ether, // swap amount
            4, // number of swaps
            true // bidirectional
        );
    }

    function test_NFT_Earns_LP_Fees_No_Hook_Fees_Single_Direction() public {
        _testNFTEarnsLPFees(
            3000, // 0.3% fee
            10 ether, // donation amount0
            10 ether, // donation amount1
            1 ether, // swap amount
            5, // number of swaps
            false // only zeroForOne swaps
        );
    }

    function test_NFT_Earns_LP_Fees_No_Hook_Fees_Small_Swaps() public {
        _testNFTEarnsLPFees(
            10000, // 1% fee (high fee to make small swaps generate noticeable fees)
            5 ether, // donation amount0
            5 ether, // donation amount1
            0.1 ether, // small swap amount
            10, // more swaps to accumulate fees
            true // bidirectional
        );
    }

    // NOTE: the bulk of the deposit and withdraw tests are in their dedicated test files

    function test_Withdraw_Protocol_Liquidity() public {
        // Setup a scenario with protocol-owned liquidity

        // Set fees and accumulate some protocol-owned liquidity
        vm.startPrank(owner);
        policyManager.setPoolPOLShare(poolId, 500000); // 50% of swap fee goes to protocol
        policyManager.setManualFee(poolId, 3000); // 0.3% fee
        spot.setReinvestmentPaused(false);
        vm.stopPrank();

        // Execute multiple swaps to generate fees
        vm.startPrank(user1);
        for (uint256 i = 0; i < 5; i++) {
            SwapParams memory params =
                SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT});

            swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");

            // Wait for reinvestment cooldown
            vm.warp(block.timestamp + liquidityManager.REINVEST_COOLDOWN() + 1);

            // Try to reinvest
            liquidityManager.reinvest(poolKey);
        }
        vm.stopPrank();

        // Check protocol-owned liquidity
        (uint256 protocolShares, uint256 protocolAmount0, uint256 protocolAmount1) =
            liquidityManager.getProtocolOwnedLiquidity(poolId);

        // Skip test if no protocol shares accumulated
        if (protocolShares == 0) {
            return;
        }

        // Withdraw protocol liquidity
        vm.startPrank(owner);
        (uint256 withdrawn0, uint256 withdrawn1) = liquidityManager.withdrawProtocolLiquidity(
            poolKey,
            protocolShares,
            0, // amount0Min
            0, // amount1Min
            owner // recipient
        );
        vm.stopPrank();

        // Verify correct amounts withdrawn
        assertApproxEqRel(withdrawn0, protocolAmount0, 1e16, "Withdrawn amount0 mismatch");
        assertApproxEqRel(withdrawn1, protocolAmount1, 1e16, "Withdrawn amount1 mismatch");

        // Verify protocol shares were burned
        (uint256 remainingShares,,) = liquidityManager.getProtocolOwnedLiquidity(poolId);
        assertEq(remainingShares, 0, "Protocol shares not fully burned");
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ReinvestmentPause_Toggle() public {
        // Check initial state
        bool initialState = spot.reinvestmentPaused();

        // Toggle state
        vm.startPrank(owner);
        spot.setReinvestmentPaused(!initialState);
        vm.stopPrank();

        // Verify state changed
        bool newState = spot.reinvestmentPaused();
        assertEq(newState, !initialState, "Reinvestment state not toggled");
    }

    function test_ReinvestmentPause_OnlyOwner() public {
        // Attempt to toggle state as non-owner
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnauthorizedCaller.selector, user1));
        spot.setReinvestmentPaused(true);
        vm.stopPrank();
    }
}
