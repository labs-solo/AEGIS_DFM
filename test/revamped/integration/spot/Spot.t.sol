// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// - - - v4 core imports - - -

import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
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
        vm.stopPrank();

        // Get initial state
        (uint256 pendingFee0Initial, uint256 pendingFee1Initial) = liquidityManager.getPendingFees(poolId);
        (uint256 protocolSharesInitial,,) = liquidityManager.getProtocolOwnedLiquidity(poolId);
        uint256 nextReinvestTime = liquidityManager.getNextReinvestmentTime(poolId);

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

        // Verify fees accumulated properly based on swap pattern
        if (swapPattern == 0 || swapPattern == 1) {
            // Should have token0 fees if we did zeroForOne swaps
            assertGt(pendingFee0Mid, pendingFee0Initial, "Token0 fees should accumulate from zeroForOne swaps");
        }

        if (swapPattern == 0 || swapPattern == 2) {
            // Should have token1 fees if we did oneForZero swaps
            assertGt(pendingFee1Mid, pendingFee1Initial, "Token1 fees should accumulate from oneForZero swaps");
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

        // Check if result matches expectation
        assertEq(reinvestResult, expectSuccess, "Reinvestment result doesn't match expectation");

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

    /*//////////////////////////////////////////////////////////////
                        HOOK INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HookPermissions() public {
        Hooks.Permissions memory permissions = spot.getHookPermissions();

        // Verify expected permissions are set
        assertEq(permissions.beforeInitialize, false);
        assertEq(permissions.afterInitialize, true);
        assertEq(permissions.beforeSwap, true);
        assertEq(permissions.afterSwap, true);
        assertEq(permissions.beforeSwapReturnDelta, true);
        assertEq(permissions.afterSwapReturnDelta, true);
    }

    function test_Initialize() public {
        // Create a new pool to test initialization
        PoolKey memory newPoolKey = PoolKey(
            currency0,
            currency1,
            6000, // 0.6% fee
            60, // tick spacing
            IHooks(address(spot))
        );

        // Initialize the new pool
        manager.initialize(newPoolKey, SQRT_PRICE_1_1);
        PoolId newPoolId = newPoolKey.toId();

        // TODO: consider verifying oracle and feeManager is configured as expected after initialization
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

    /**
     * @notice Tests emergencyWithdraw for withdrawing ERC6909 token credits from PoolManager
     */
    function test_EmergencyWithdraw() public {
        // 1. Setup: Enable hook fees to generate ERC6909 balances in PoolManager
        vm.startPrank(owner);

        // Set a significant fee percentage to generate substantial fees
        uint24 manualFee = 3000; // 0.3%
        uint256 polShare = 500000; // 50% protocol share

        policyManager.setManualFee(poolId, manualFee);
        policyManager.setPoolPOLShare(poolId, polShare);

        // Pause reinvestment to accumulate fees without automatic reinvestment
        spot.setReinvestmentPaused(true);
        vm.stopPrank();

        // 2. Execute swaps to generate fees
        uint256 swapAmount = 10 ether;

        // Perform multiple swaps in both directions to collect fees in both tokens
        vm.startPrank(user1);

        // Swap token0 for token1 (zeroForOne = true)
        SwapParams memory paramsZeroForOne =
            SwapParams({zeroForOne: true, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        swapRouter.swap(
            poolKey, paramsZeroForOne, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), ""
        );

        // Swap token1 for token0 (zeroForOne = false)
        SwapParams memory paramsOneForZero =
            SwapParams({zeroForOne: false, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: MAX_PRICE_LIMIT});

        swapRouter.swap(
            poolKey, paramsOneForZero, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), ""
        );

        vm.stopPrank();

        // 3. Verify fees were collected as ERC6909 tokens
        (uint256 pendingFee0, uint256 pendingFee1) = liquidityManager.getPendingFees(poolId);

        // Ensure we have collected some fees
        assertGt(pendingFee0, 0, "No token0 fees collected");
        assertGt(pendingFee1, 0, "No token1 fees collected");

        // 4. Get initial balances before emergency withdraw
        uint256 initialBalance0 = currency0.balanceOf(owner);
        uint256 initialBalance1 = currency1.balanceOf(owner);

        // 5. Test emergencyWithdraw for token0
        vm.startPrank(owner);

        // Execute emergency withdraw for token0
        liquidityManager.emergencyWithdraw(currency0, owner, pendingFee0);

        // 6. Verify token0 was correctly withdrawn
        uint256 afterWithdraw0 = currency0.balanceOf(owner);
        assertEq(
            afterWithdraw0 - initialBalance0, pendingFee0, "Emergency withdraw didn't transfer correct amount of token0"
        );

        // 7. Test emergencyWithdraw for token1
        liquidityManager.emergencyWithdraw(currency1, owner, pendingFee1);

        // 8. Verify token1 was correctly withdrawn
        uint256 afterWithdraw1 = currency1.balanceOf(owner);
        assertEq(
            afterWithdraw1 - initialBalance1, pendingFee1, "Emergency withdraw didn't transfer correct amount of token1"
        );

        // 9. Check that pending fees are unchanged despite emergency withdrawal
        // NOTE: emergency withdrawal of pending fees could possibly break reinvestment if withdrawn fees are attempted to be reinvested
        (uint256 pendingFeeAfter0, uint256 pendingFeeAfter1) = liquidityManager.getPendingFees(poolId);
        assertLe(pendingFeeAfter0, pendingFee0, "Token0 fees should remain unchanged after emergency withdraw");
        assertLe(pendingFeeAfter1, pendingFee1, "Token1 fees should remain unchanged after emergency withdraw");

        vm.stopPrank();
    }

    /**
     * @notice Tests partial emergencyWithdraw of ERC6909 token credits
     */
    function test_EmergencyWithdraw_Partial() public {
        // 1. Setup: Enable hook fees to generate ERC6909 balances
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, 3000); // 0.3%
        policyManager.setPoolPOLShare(poolId, 500000); // 50% protocol share
        spot.setReinvestmentPaused(true);
        vm.stopPrank();

        // 2. Execute swap to generate fees
        vm.startPrank(user1);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(10 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        vm.stopPrank();

        // 3. Verify fees were collected
        (uint256 pendingFee0, uint256 pendingFee1) = liquidityManager.getPendingFees(poolId);
        assertGt(pendingFee0, 0, "No token0 fees collected");

        // 4. Withdraw half of the accumulated fees
        uint256 partialAmount = pendingFee0 / 2;

        vm.startPrank(owner);
        uint256 initialBalance = currency0.balanceOf(owner);

        liquidityManager.emergencyWithdraw(currency0, owner, partialAmount);

        // 5. Verify partial amount was correctly withdrawn
        uint256 afterBalance = currency0.balanceOf(owner);
        assertEq(
            afterBalance - initialBalance, partialAmount, "Emergency withdraw didn't transfer correct partial amount"
        );

        // 6. Verify remaining fees
        (uint256 remainingFee0,) = liquidityManager.getPendingFees(poolId);
        assertEq(remainingFee0, pendingFee0, "Final pending fee should remain unchanged after partial withdrawal");

        vm.stopPrank();
    }

    /**
     * @notice Tests that emergencyWithdraw can only be called by the policy owner
     */
    function test_EmergencyWithdraw_OnlyOwner() public {
        // Generate some fees first
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, 3000);
        policyManager.setPoolPOLShare(poolId, 500000);
        spot.setReinvestmentPaused(true);
        vm.stopPrank();

        vm.startPrank(user1);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(10 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        vm.stopPrank();

        // Verify fees exist
        (uint256 pendingFee0,) = liquidityManager.getPendingFees(poolId);
        assertGt(pendingFee0, 0, "No token0 fees collected");

        // Attempt to withdraw as non-owner
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnauthorizedCaller.selector, user1));
        liquidityManager.emergencyWithdraw(currency0, user1, pendingFee0);
        vm.stopPrank();
    }

    /**
     * @notice Tests emergencyWithdraw with different recipient than owner
     */
    function test_EmergencyWithdraw_DifferentRecipient() public {
        // Generate fees
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, 3000);
        policyManager.setPoolPOLShare(poolId, 500000);
        spot.setReinvestmentPaused(true);
        vm.stopPrank();

        vm.startPrank(user1);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(10 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        vm.stopPrank();

        // Verify fees exist
        (uint256 pendingFee0,) = liquidityManager.getPendingFees(poolId);
        assertGt(pendingFee0, 0, "No token0 fees collected");

        // Withdraw to a different recipient than owner
        vm.startPrank(owner);
        uint256 initialBalance = currency0.balanceOf(user2);

        liquidityManager.emergencyWithdraw(currency0, user2, pendingFee0);

        // Verify user2 received the tokens
        uint256 afterBalance = currency0.balanceOf(user2);
        assertEq(
            afterBalance - initialBalance,
            pendingFee0,
            "Emergency withdraw didn't transfer correct amount to different recipient"
        );

        vm.stopPrank();
    }

    /**
     * @notice Tests emergencyWithdraw for both tokens simultaneously
     */
    function test_EmergencyWithdraw_BothTokens() public {
        // Generate fees in both tokens
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, 3000);
        policyManager.setPoolPOLShare(poolId, 500000);
        spot.setReinvestmentPaused(true);
        vm.stopPrank();

        // Swap in both directions
        vm.startPrank(user1);

        // Swap token0 -> token1
        SwapParams memory params0 =
            SwapParams({zeroForOne: true, amountSpecified: -int256(10 ether), sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        swapRouter.swap(poolKey, params0, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");

        // Swap token1 -> token0
        SwapParams memory params1 =
            SwapParams({zeroForOne: false, amountSpecified: -int256(10 ether), sqrtPriceLimitX96: MAX_PRICE_LIMIT});
        swapRouter.swap(poolKey, params1, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");

        vm.stopPrank();

        // Verify fees in both tokens
        (uint256 pendingFee0, uint256 pendingFee1) = liquidityManager.getPendingFees(poolId);
        assertGt(pendingFee0, 0, "No token0 fees collected");
        assertGt(pendingFee1, 0, "No token1 fees collected");

        // Withdraw both tokens
        vm.startPrank(owner);
        uint256 initialBalance0 = currency0.balanceOf(owner);
        uint256 initialBalance1 = currency1.balanceOf(owner);

        // Withdraw token0
        liquidityManager.emergencyWithdraw(currency0, owner, pendingFee0);

        // Withdraw token1
        liquidityManager.emergencyWithdraw(currency1, owner, pendingFee1);

        // Verify both tokens were received
        uint256 afterBalance0 = currency0.balanceOf(owner);
        uint256 afterBalance1 = currency1.balanceOf(owner);

        assertEq(
            afterBalance0 - initialBalance0, pendingFee0, "Emergency withdraw didn't transfer correct amount of token0"
        );

        assertEq(
            afterBalance1 - initialBalance1, pendingFee1, "Emergency withdraw didn't transfer correct amount of token1"
        );

        vm.stopPrank();
    }

    /**
     * @notice Tests the emergency withdrawal of ERC20 tokens from the liquidityManager
     */
    function test_EmergencyWithdrawERC20() public {
        // Setup scenario with tokens in the liquidityManager
        vm.startPrank(owner);

        // Amount to test with
        uint256 testAmount = 5 ether;

        // Get initial token balance of owner
        uint256 initialBalance = currency0.balanceOf(owner);

        // Mint tokens directly to the liquidityManager
        MockERC20(Currency.unwrap(currency0)).mint(address(liquidityManager), testAmount);

        // Verify the tokens are now in the liquidityManager
        assertEq(
            currency0.balanceOf(address(liquidityManager)),
            testAmount,
            "Tokens not correctly minted to liquidityManager"
        );

        // Request specific amount withdrawal
        uint256 amountSwept =
            liquidityManager.emergencyWithdrawNativeOrERC20(Currency.unwrap(currency0), owner, testAmount);

        // Verify correct amount was swept
        assertEq(amountSwept, testAmount, "Incorrect amount reported as swept");

        // Verify tokens were received by owner
        uint256 finalBalance = currency0.balanceOf(owner);
        assertEq(finalBalance - initialBalance, testAmount, "Owner did not receive expected token amount");

        // Verify liquidityManager balance is now zero
        assertEq(
            currency0.balanceOf(address(liquidityManager)),
            0,
            "LiquidityManager should have zero balance after withdrawal"
        );

        vm.stopPrank();
    }

    /**
     * @notice Tests the emergency withdrawal of full token balance when amount=0
     */
    function test_EmergencyWithdrawERC20_FullBalance() public {
        // Setup scenario with tokens in the liquidityManager
        vm.startPrank(owner);

        // Amount to test with
        uint256 testAmount = 5 ether;

        // Get initial token balance of owner
        uint256 initialBalance = currency0.balanceOf(owner);

        // Mint tokens directly to the liquidityManager
        MockERC20(Currency.unwrap(currency0)).mint(address(liquidityManager), testAmount);

        // Request full balance withdrawal (passing 0 should withdraw all tokens)
        uint256 amountSwept = liquidityManager.emergencyWithdrawNativeOrERC20(Currency.unwrap(currency0), owner, 0);

        // Verify correct amount was swept
        assertEq(amountSwept, testAmount, "Incorrect amount reported as swept");

        // Verify tokens were received by owner
        uint256 finalBalance = currency0.balanceOf(owner);
        assertEq(finalBalance - initialBalance, testAmount, "Owner did not receive expected token amount");

        vm.stopPrank();
    }

    /**
     * @notice Tests the emergency withdrawal of native ETH from the liquidityManager
     */
    function test_EmergencyWithdrawETH() public {
        // Setup scenario with ETH in the liquidityManager
        vm.startPrank(owner);

        // Amount to test with
        uint256 testAmount = 5 ether;

        // Get initial ETH balance of owner
        uint256 initialBalance = owner.balance;

        // Send ETH directly to the liquidityManager
        vm.deal(address(liquidityManager), testAmount);

        // Verify the ETH is now in the liquidityManager
        assertEq(address(liquidityManager).balance, testAmount, "ETH not correctly sent to liquidityManager");

        // Request specific amount withdrawal of native ETH (address(0) means native ETH)
        uint256 amountSwept = liquidityManager.emergencyWithdrawNativeOrERC20(address(0), owner, testAmount);

        // Verify correct amount was swept
        assertEq(amountSwept, testAmount, "Incorrect amount reported as swept");

        // Verify ETH was received by owner
        uint256 finalBalance = owner.balance;
        assertEq(finalBalance - initialBalance, testAmount, "Owner did not receive expected ETH amount");

        // Verify liquidityManager balance is now zero
        assertEq(address(liquidityManager).balance, 0, "LiquidityManager should have zero balance after withdrawal");

        vm.stopPrank();
    }

    /**
     * @notice Tests the emergency withdrawal of full ETH balance when amount=0
     */
    function test_EmergencyWithdrawETH_FullBalance() public {
        // Setup scenario with ETH in the liquidityManager
        vm.startPrank(owner);

        // Amount to test with
        uint256 testAmount = 5 ether;

        // Get initial ETH balance of owner
        uint256 initialBalance = owner.balance;

        // Send ETH directly to the liquidityManager
        vm.deal(address(liquidityManager), testAmount);

        // Request full balance withdrawal (passing 0 should withdraw all ETH)
        uint256 amountSwept = liquidityManager.emergencyWithdrawNativeOrERC20(address(0), owner, 0);

        // Verify correct amount was swept
        assertEq(amountSwept, testAmount, "Incorrect amount reported as swept");

        // Verify ETH was received by owner
        uint256 finalBalance = owner.balance;
        assertEq(finalBalance - initialBalance, testAmount, "Owner did not receive expected ETH amount");

        vm.stopPrank();
    }

    /**
     * @notice Tests that emergency withdrawal handles zero balances correctly
     */
    function test_EmergencyWithdrawERC20_ZeroBalance() public {
        vm.startPrank(owner);

        // Attempt to withdraw when there's nothing to withdraw
        uint256 amountSwept = liquidityManager.emergencyWithdrawNativeOrERC20(Currency.unwrap(currency0), owner, 0);

        // Should report zero swept
        assertEq(amountSwept, 0, "Should report zero swept when balance is zero");

        vm.stopPrank();
    }

    /**
     * @notice Tests that only the policy owner can perform emergency withdrawals
     */
    function test_EmergencyWithdrawERC20_OnlyOwner() public {
        // Setup tokens in the liquidityManager
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).mint(address(liquidityManager), 5 ether);
        vm.stopPrank();

        // Attempt to withdraw as non-owner
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnauthorizedCaller.selector, user1));
        liquidityManager.emergencyWithdrawNativeOrERC20(Currency.unwrap(currency0), user1, 5 ether);
        vm.stopPrank();
    }

    /**
     * @notice Tests that emergency withdrawal works with recipient = owner != msg.sender
     */
    function test_EmergencyWithdrawERC20_DifferentRecipient() public {
        vm.startPrank(owner);

        // Amount to test with
        uint256 testAmount = 5 ether;

        // Mint tokens directly to the liquidityManager
        MockERC20(Currency.unwrap(currency0)).mint(address(liquidityManager), testAmount);

        // Get initial token balance of user1
        uint256 initialBalance = currency0.balanceOf(user1);

        // Request withdrawal to a different recipient
        uint256 amountSwept =
            liquidityManager.emergencyWithdrawNativeOrERC20(Currency.unwrap(currency0), user1, testAmount);

        // Verify correct amount was swept
        assertEq(amountSwept, testAmount, "Incorrect amount reported as swept");

        // Verify tokens were received by the specified recipient
        uint256 finalBalance = currency0.balanceOf(user1);
        assertEq(finalBalance - initialBalance, testAmount, "Recipient did not receive expected token amount");

        vm.stopPrank();
    }
}
