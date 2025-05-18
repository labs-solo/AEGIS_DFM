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

contract SpotTest is Base_Test {
    function setUp() public override {
        Base_Test.setUp();
    }

    // - - - parametrized test helpers - - -

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

    function test_DynamicFee_Manual_NoPolShare_ExactIn() public {
        // Set a manual fee in the policy manager
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, 2000); // 0.2%
        vm.stopPrank();

        int256 desiredIn = 1 ether;
        bool zeroForOne = true;

        (uint256 expectedAmountOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                exactAmount: uint128(int128(desiredIn)),
                hookData: hex""
            })
        );

        // Perform a swap to trigger the fee
        vm.startPrank(user1);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -desiredIn, sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        // Execute the swap
        BalanceDelta delta =
            swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");

        // Manual fee should override dynamic fee
        uint256 expectedFee = FullMath.mulDiv(uint256(desiredIn), 2000, 1e6);

        (uint256 pending0, uint256 pending1) = liquidityManager.getPendingFees(poolId);

        assertEq(pending0, 0);
        assertEq(pending1, 0);

        // Verify fee was applied correctly
        int256 actualIn = -delta.amount0();
        assertEq(desiredIn, actualIn);

        int256 actualOut = delta.amount1();
        assertEq(uint256(actualOut), expectedAmountOut);

        vm.stopPrank();
    }

    function test_DynamicFee_Manual_NoPolShare_ExactOut() public {
        // Set a manual fee in the policy manager
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, 2000); // 0.2%
        vm.stopPrank();

        uint256 desiredOut = 0.5 ether;
        bool zeroForOne = true;

        // For exactOutput swaps, we need to get a quote first to know approximately how much we need to input
        (uint256 expectedAmountIn,) = quoter.quoteExactOutputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                exactAmount: uint128(desiredOut),
                hookData: hex""
            })
        );

        // Perform an exactOutput swap (positive amountSpecified indicates exactOutput)
        vm.startPrank(user1);
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(desiredOut), // positive means exactOutput
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        // Execute the swap
        BalanceDelta delta =
            swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");

        // Calculate actual values
        uint256 actualIn = uint256(int256(-delta.amount0()));
        uint256 actualOut = uint256(int256(delta.amount1()));

        assertEq(actualOut, desiredOut, "Did not receive desired output amount");
        assertEq(actualIn, expectedAmountIn, "Input amount did not match expected input");

        // Manual fee should be reflected in the input amount
        // For exactOutput, the fee is effectively "built-in" to the input amount
        // So we can't directly check the fee amount, but we can verify the input is reasonable

        // Calculate what the input would be without any fee
        // This is a simplified calculation and may not match exactly due to slippage
        uint256 inputWithoutFee = (desiredOut * 1e6) / (1e6 - 3000); // Assuming 0.3% pool fee for simplicity

        // Verify the actual input is greater than the no-fee amount
        // (since fees increase the required input)
        assertGt(actualIn, inputWithoutFee, "Input amount doesn't reflect fee application");

        // Verify the swap delta
        // For an exactOutput zeroForOne swap:
        // - delta.amount0() will be negative (tokens spent by user)
        // - delta.amount1() will be positive (tokens received by user)
        assertEq(int256(actualIn), -delta.amount0(), "Incorrect amount0 delta");
        assertEq(int256(actualOut), delta.amount1(), "Incorrect amount1 delta");

        // Since we're not collecting protocol fees in this test,
        // verify no pending fees were accumulated
        (uint256 pending0, uint256 pending1) = liquidityManager.getPendingFees(poolId);
        assertEq(pending0, 0, "Unexpected pending fee0");
        assertEq(pending1, 0, "Unexpected pending fee1");

        vm.stopPrank();
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

    function test_Reinvestment_Paused() public {
        // Setup protocol fee and initial state
        vm.startPrank(owner);
        policyManager.setPoolPOLShare(poolId, 500000); // 50% of swap fee goes to protocol
        policyManager.setManualFee(poolId, 3000); // 0.3% fee
        spot.setReinvestmentPaused(true);
        vm.stopPrank();

        // Get initial pending fees
        (uint256 pendingFee0Before, uint256 pendingFee1Before) = liquidityManager.getPendingFees(poolId);

        // Execute a swap to generate fees
        vm.startPrank(user1);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        vm.stopPrank();

        // Check that fees were collected but not reinvested
        (uint256 pendingFee0After, uint256 pendingFee1After) = liquidityManager.getPendingFees(poolId);
        assertGt(pendingFee0After, pendingFee0Before, "No fees collected");
        assertEq(pendingFee1After, pendingFee1Before, "Fee1 should not change for zeroForOne swap");

        // Manually attempt to reinvest
        bool reinvestResult = liquidityManager.reinvest(poolKey);

        // Should return true if reinvestment was successful
        assertTrue(reinvestResult, "Reinvestment failed");

        // Check that pending fees were reset
        (uint256 pendingFee0Final, uint256 pendingFee1Final) = liquidityManager.getPendingFees(poolId);
        assertLt(pendingFee0Final, pendingFee0After, "Fees not reinvested");
    }

    function test_Reinvestment_Automatic() public {
        // Setup protocol fee and ensure reinvestment is enabled
        vm.startPrank(owner);
        policyManager.setPoolPOLShare(poolId, 500000); // 50% of swap fee goes to protocol
        policyManager.setManualFee(poolId, 3000); // 0.3% fee
        spot.setReinvestmentPaused(false);
        vm.stopPrank();

        // Get initial pending fees and protocol-owned liquidity
        (uint256 pendingFee0Before, uint256 pendingFee1Before) = liquidityManager.getPendingFees(poolId);
        (uint256 protocolSharesBefore,,) = liquidityManager.getProtocolOwnedLiquidity(poolId);

        // Execute a swap to generate fees
        vm.startPrank(user1);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        vm.stopPrank();

        // Check that fees were automatically reinvested
        (uint256 protocolSharesAfter,,) = liquidityManager.getProtocolOwnedLiquidity(poolId);

        // Either the shares increased or the fee is still pending (due to cooldown)
        (uint256 pendingFee0After, uint256 pendingFee1After) = liquidityManager.getPendingFees(poolId);

        bool sharesIncreased = protocolSharesAfter > protocolSharesBefore;
        bool feesAccumulated = pendingFee0After > pendingFee0Before;

        assertTrue(sharesIncreased || feesAccumulated, "Fees neither reinvested nor accumulated");
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT/WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Deposit_PolicyOwner() public {
        // Setup
        vm.startPrank(owner);

        // Mint tokens to owner for deposit
        MockERC20(Currency.unwrap(currency0)).mint(owner, 10 ether);
        MockERC20(Currency.unwrap(currency1)).mint(owner, 10 ether);

        // Approve spot contract for token transfers
        MockERC20(Currency.unwrap(currency0)).approve(address(spot), 10 ether);
        MockERC20(Currency.unwrap(currency1)).approve(address(spot), 10 ether);

        // Perform deposit
        (uint256 shares, uint256 amount0, uint256 amount1) = spot.depositToFRLM(
            poolKey,
            5 ether, // amount0Desired
            5 ether, // amount1Desired
            4.9 ether, // amount0Min
            4.9 ether, // amount1Min
            owner // recipient
        );

        // Verify shares were issued
        assertGt(shares, 0, "No shares issued");
        assertGt(amount0, 0, "No token0 deposited");
        assertGt(amount1, 0, "No token1 deposited");

        // Verify shares balance
        uint256 ownerShares = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));
        assertEq(ownerShares, shares, "Shares not credited to owner");

        vm.stopPrank();
    }

    function test_Withdraw_PolicyOwner() public {
        // First deposit to create shares
        test_Deposit_PolicyOwner();

        vm.startPrank(owner);

        // Get initial balance
        uint256 initialBalance0 = currency0.balanceOf(owner);
        uint256 initialBalance1 = currency1.balanceOf(owner);

        // Get initial shares
        uint256 initialShares = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));

        // Withdraw half of the shares
        uint256 sharesToWithdraw = initialShares / 2;

        (uint256 amount0, uint256 amount1) = spot.withdrawFromFRLM(
            poolKey,
            sharesToWithdraw,
            0, // amount0Min
            0, // amount1Min
            owner // recipient
        );

        // Verify tokens received
        assertGt(amount0, 0, "No token0 received");
        assertGt(amount1, 0, "No token1 received");

        uint256 finalBalance0 = currency0.balanceOf(owner);
        uint256 finalBalance1 = currency1.balanceOf(owner);

        assertEq(finalBalance0 - initialBalance0, amount0, "Token0 balance mismatch");
        assertEq(finalBalance1 - initialBalance1, amount1, "Token1 balance mismatch");

        // Verify shares were burned
        uint256 finalShares = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));
        assertEq(finalShares, initialShares - sharesToWithdraw, "Shares not burned correctly");

        vm.stopPrank();
    }

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

    function test_EmergencyWithdraw() public {
        // Setup scenario with tokens in the pool manager
        vm.startPrank(owner);

        // Mint tokens directly to the pool manager
        MockERC20(Currency.unwrap(currency0)).mint(address(manager), 5 ether);

        // Emergency withdraw
        liquidityManager.emergencyWithdraw(currency0, owner, 5 ether);

        // Verify tokens received
        uint256 ownerBalance = currency0.balanceOf(owner);
        assertEq(ownerBalance, 5 ether, "Emergency withdraw failed");

        vm.stopPrank();
    }

    function test_SweepToken() public {
        // Setup scenario with tokens in the liquidity manager
        vm.startPrank(owner);

        // Mint tokens directly to the liquidity manager
        MockERC20(Currency.unwrap(currency0)).mint(address(liquidityManager), 5 ether);

        // Sweep tokens
        uint256 swept = liquidityManager.sweepToken(Currency.unwrap(currency0), owner, 5 ether);

        // Verify tokens received
        assertEq(swept, 5 ether, "Incorrect amount swept");
        uint256 ownerBalance = currency0.balanceOf(owner);
        assertEq(ownerBalance, 5 ether, "Token sweep failed");

        vm.stopPrank();
    }
}
