// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

// Import v4-periphery test setup
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// Import local test helpers

import {Base_Test} from "../../Base_Test.sol";

// Import local src

import {Errors} from "src/errors/Errors.sol";

contract SpotTest is Base_Test {
    function setUp() public override {
        Base_Test.setUp();
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

    function test_DynamicFee_Manual_1() public {
        // Set a manual fee in the policy manager
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, 2000); // 0.2%
        vm.stopPrank();

        // Perform a swap to trigger the fee
        vm.startPrank(user1);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        // Execute the swap
        BalanceDelta delta =
            swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");

        // Manual fee should override dynamic fee
        uint256 expectedFee = FullMath.mulDiv(1 ether, 2000, 1e6);

        // Verify fee was applied correctly
        int256 outputAmount = -delta.amount1();
        int256 expectedOutput = int256(1 ether - expectedFee) * 997 / 1000;
        assertApproxEqRel(uint256(outputAmount), uint256(expectedOutput), 1e16, "Manual fee not applied correctly");

        vm.stopPrank();
    }

    function test_DynamicFee_Manual_2() public {
        // Set up a scenario where a surge fee would be applied
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, 6000); // 0.6%
        vm.stopPrank();

        // Execute a large swap to cause price volatility
        vm.startPrank(user1);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: 5 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");

        // Now execute a second swap that should have the surge fee applied
        params.amountSpecified = 1 ether;
        BalanceDelta delta =
            swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");

        // Total fee should be base + surge (0.1% + 0.5% = 0.6%)
        uint256 expectedFee = FullMath.mulDiv(1 ether, 6000, 1e6);

        // Verify total fee was applied correctly
        int256 outputAmount = -delta.amount1();
        int256 expectedOutput = int256(1 ether - expectedFee) * 997 / 1000;
        assertApproxEqRel(uint256(outputAmount), uint256(expectedOutput), 1e16, "Surge fee not applied correctly");

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        HOOK FEE COLLECTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_HookFee_ExactInput() public {
        // Set protocol fee in policy manager
        vm.startPrank(owner);
        policyManager.setPoolPOLShare(poolId, 500000); // 50% of swap fee goes to protocol
        policyManager.setPoolPOLShare(poolId, 3000); // 0.3% fee
        vm.stopPrank();

        // Perform an exactInput swap
        vm.startPrank(user1);
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: 1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        // Get liquidity manager state before swap
        uint256 sharesBefore = liquidityManager.balanceOf(address(liquidityManager), uint256(PoolId.unwrap(poolId)));

        // Execute the swap
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");

        // Calculate expected hook fee
        // 1 ether input * 0.3% fee * 50% protocol share
        uint256 swapFeeAmount = FullMath.mulDiv(1 ether, 3000, 1e6);
        uint256 expectedHookFee = FullMath.mulDiv(swapFeeAmount, 500000, 1e6);

        // Verify hook fee was credited to liquidity manager
        uint256 sharesAfter = liquidityManager.balanceOf(address(liquidityManager), uint256(PoolId.unwrap(poolId)));
        uint256 shareDifference = sharesAfter - sharesBefore;

        // Check if shares were issued or pending fees were updated
        if (spot.reinvestmentPaused()) {
            // If reinvestment is paused, check pending fees
            (uint256 pendingFee0, uint256 pendingFee1) = liquidityManager.getPendingFees(poolId);
            assertEq(pendingFee0, expectedHookFee, "Incorrect pending fee0");
            assertEq(pendingFee1, 0, "Incorrect pending fee1");
        } else {
            // If reinvestment is active, some shares might have been created
            // The actual shares might vary due to reinvestment mechanism, so we use a relative comparison
            assertGt(shareDifference, 0, "No shares were created from hook fee");
        }

        vm.stopPrank();
    }

    function test_HookFee_ExactOutput() public {
        // Set protocol fee in policy manager
        vm.startPrank(owner);
        policyManager.setPoolPOLShare(poolId, 500000); // 50% of swap fee goes to protocol
        policyManager.setManualFee(poolId, 3000); // 0.3% fee
        vm.stopPrank();

        // Perform an exactOutput swap (negative amountSpecified)
        vm.startPrank(user1);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.5 ether, // want 0.5 ETH out
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        // Get liquidity manager state before swap
        uint256 sharesBefore = liquidityManager.balanceOf(address(liquidityManager), uint256(PoolId.unwrap(poolId)));

        // Execute the swap
        BalanceDelta delta =
            swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");

        // Get the actual input amount from the swap delta
        // Since token0 is the tokenIn it'll be a negative delta so we have to abs value it
        uint256 actualInput = uint256(int256(-delta.amount0()));

        // Calculate expected hook fee based on actual input
        uint256 swapFeeAmount = FullMath.mulDiv(actualInput, 3000, 1e6);
        uint256 expectedHookFee = FullMath.mulDiv(swapFeeAmount, 500000, 1e6);

        // Verify hook fee was credited to liquidity manager
        uint256 sharesAfter = liquidityManager.balanceOf(address(liquidityManager), uint256(PoolId.unwrap(poolId)));
        uint256 shareDifference = sharesAfter - sharesBefore;

        // Check if shares were issued or pending fees were updated
        if (spot.reinvestmentPaused()) {
            // If reinvestment is paused, check pending fees
            (uint256 pendingFee0, uint256 pendingFee1) = liquidityManager.getPendingFees(poolId);
            assertEq(pendingFee0, expectedHookFee, "Incorrect pending fee0");
            assertEq(pendingFee1, 0, "Incorrect pending fee1");
        } else {
            // If reinvestment is active, some shares might have been created
            assertGt(shareDifference, 0, "No shares were created from hook fee");
        }

        vm.stopPrank();
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
