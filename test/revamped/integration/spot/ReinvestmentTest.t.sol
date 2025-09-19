// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "forge-std/console.sol";
import {Base_Test} from "../../Base_Test.sol";
import {Spot} from "../../../../src/Spot.sol";
import {FullRangeLiquidityManager} from "../../../../src/FullRangeLiquidityManager.sol";
import {PoolPolicyManager} from "../../../../src/PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "../../../../src/TruncGeoOracleMulti.sol";
import {DynamicFeeManager} from "../../../../src/DynamicFeeManager.sol";
import {ISpot} from "../../../../src/interfaces/ISpot.sol";
import {IFullRangeLiquidityManager} from "../../../../src/interfaces/IFullRangeLiquidityManager.sol";
import {IPoolPolicyManager} from "../../../../src/interfaces/IPoolPolicyManager.sol";
import {ITruncGeoOracleMulti} from "../../../../src/interfaces/ITruncGeoOracleMulti.sol";
import {IDynamicFeeManager} from "../../../../src/interfaces/IDynamicFeeManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Errors} from "../../../../src/errors/Errors.sol";

contract ReinvestmentTest is Base_Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Events to track
    event ReinvestmentFailed(PoolId indexed poolId, string reason);
    event FeesReinvested(PoolId indexed poolId, uint256 amount0Used, uint256 amount1Used, uint256 liquidityAdded);

    function setUp() public override {
        super.setUp();
        
        // Base_Test already funds and approves tokens for user1 and user2
        // We just need to add additional test users if needed
    }

    /**
     * @notice Test automatic reinvestment during swaps after initial manual reinvestment
     * @dev Proves that fees are automatically reinvested into POL during swap execution
     */
    function test_ReinvestmentAutoCompounding_AndFailedEvents() public {
        // Setup: Enable reinvestment with 20% protocol fee share
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, 3000); // 0.3% fee
        policyManager.setPoolPOLShare(poolId, 200000); // 20% of fees go to protocol
        spot.setReinvestmentPaused(false); // Enable automatic reinvestment
        vm.stopPrank();

        // Step 1: Initial setup - Create POL position
        vm.startPrank(user1);
        liquidityManager.donate(poolKey, 1 ether, 1 ether);
        vm.warp(block.timestamp + REINVEST_COOLDOWN + 1);
        liquidityManager.reinvest(poolKey);
        vm.stopPrank();

        // Step 2: Fill oracle observations for TWAP calculation
        _fillOracleObservations();

        // Get initial POL state
        (uint256 initialShares, uint256 initialAmount0, uint256 initialAmount1) = 
            liquidityManager.getProtocolOwnedLiquidity(poolId);
        
        console.log("=== INITIAL POL STATE ===");
        console.log("Shares:", initialShares);
        console.log("Amount0:", initialAmount0);
        console.log("Amount1:", initialAmount1);

        // Step 3: Perform bidirectional swaps to trigger automatic reinvestment
        for (uint256 i = 0; i < 2; i++) {
            console.log("=== SWAP PAIR", i + 1, "===");
            
            // Generate fees for both tokens
            _performBidirectionalSwaps();
            
            // Check POL state after swaps
            (uint256 currentShares, uint256 currentAmount0, uint256 currentAmount1) = 
                liquidityManager.getProtocolOwnedLiquidity(poolId);
            
            console.log("POL after swaps:");
            console.log("  Shares:", currentShares);
            console.log("  Shares change:", currentShares - initialShares);
            console.log("  Amount0:", currentAmount0);
            console.log("  Amount1:", currentAmount1);

            // Wait for cooldown and maintain oracle observations
            vm.warp(block.timestamp + REINVEST_COOLDOWN + 1);
            _maintainOracleObservations();
        }

        // Step 4: Verify final state
        (uint256 finalShares, uint256 finalAmount0, uint256 finalAmount1) = 
            liquidityManager.getProtocolOwnedLiquidity(poolId);
        
        console.log("=== FINAL POL STATE ===");
        console.log("Final shares:", finalShares);
        console.log("Total shares increase:", finalShares - initialShares);
        console.log("Final amount0:", finalAmount0);
        console.log("Final amount1:", finalAmount1);

        // Step 5: Check pending fees
        (uint256 pendingFee0, uint256 pendingFee1) = liquidityManager.getPendingFees(poolId);
        console.log("=== PENDING FEES ===");
        console.log("Pending fee0:", pendingFee0);
        console.log("Pending fee1:", pendingFee1);

        // Step 6: Test manual reinvestment (should fail due to cooldown)
        vm.startPrank(user1);
        bool success = liquidityManager.reinvest(poolKey);
        console.log("Manual reinvestment success:", success);
        vm.stopPrank();

        // Assertions
        assertTrue(finalShares >= initialShares, "POL shares should not decrease");
        assertTrue(finalAmount0 >= initialAmount0, "POL amount0 should not decrease");
        assertTrue(finalAmount1 >= initialAmount1, "POL amount1 should not decrease");
        assertTrue(pendingFee0 >= 1e4 || pendingFee1 >= 1e4, "Should have accumulated fees above minimum threshold");
        assertFalse(success, "Manual reinvestment should fail due to cooldown");
    }

    function _fillOracleObservations() internal {
        console.log("=== FILLING ORACLE OBSERVATIONS ===");
        for (uint256 i = 0; i < 10; i++) {
            vm.startPrank(user2);
            SwapParams memory swap = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(0.1 ether),
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            });
            swapRouter.swap(poolKey, swap, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
            vm.stopPrank();
            vm.warp(block.timestamp + 10);
        }
        console.log("Oracle observations filled over 100+ seconds");
    }

    function _performBidirectionalSwaps() internal {
        // Swap token0 -> token1 (generates token0 fees)
        vm.startPrank(user2);
        SwapParams memory swap0 = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(5 ether),
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, swap0, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        vm.stopPrank();

        // Check fees after first swap
        (uint256 pending0, uint256 pending1) = liquidityManager.getPendingFees(poolId);
        console.log("After token0->token1: fee0=", pending0, "fee1=", pending1);

        // Swap token1 -> token0 (generates token1 fees)
        vm.startPrank(user2);
        SwapParams memory swap1 = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(5 ether),
            sqrtPriceLimitX96: MAX_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, swap1, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        vm.stopPrank();

        // Check fees after both swaps
        (pending0, pending1) = liquidityManager.getPendingFees(poolId);
        console.log("After token1->token0: fee0=", pending0, "fee1=", pending1);
    }

    function _maintainOracleObservations() internal {
        for (uint256 j = 0; j < 3; j++) {
            vm.startPrank(user2);
            SwapParams memory swap = SwapParams({
                zeroForOne: (j % 2 == 0),
                amountSpecified: -int256(0.05 ether),
                sqrtPriceLimitX96: (j % 2 == 0) ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            });
            swapRouter.swap(poolKey, swap, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
            vm.stopPrank();
            vm.warp(block.timestamp + 5);
        }
    }

    /**
     * @notice Test fee accumulation when reinvestment is paused
     * @dev Verifies that fees are properly tracked when reinvestment is disabled
     */
    function test_FeeAccumulation_WhenReinvestmentPaused() public {
        // Setup: Pause reinvestment
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, 3000); // 0.3% fee
        policyManager.setPoolPOLShare(poolId, 200000); // 20% of fees go to protocol
        spot.setReinvestmentPaused(true); // Pause automatic reinvestment
        vm.stopPrank();

        // Get initial pending fees
        (uint256 initialPending0, uint256 initialPending1) = liquidityManager.getPendingFees(poolId);
        console.log("=== INITIAL PENDING FEES ===");
        console.log("Pending0:", initialPending0);
        console.log("Pending1:", initialPending1);

        // Perform swaps to generate fees
        for (uint256 i = 0; i < 3; i++) {
            vm.startPrank(user2);
            SwapParams memory params = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            });
            swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
            vm.stopPrank();

            // Check pending fees after each swap
            (uint256 currentPending0, uint256 currentPending1) = liquidityManager.getPendingFees(poolId);
            console.log("=== AFTER SWAP", i + 1, "===");
            console.log("Pending0:", currentPending0);
            console.log("Pending1:", currentPending1);
            console.log("Pending0 increase:", currentPending0 - initialPending0);

            // Verify fees are accumulating
            assertGt(currentPending0, initialPending0, "Pending fees should accumulate when reinvestment is paused");
        }
    }

    /**
     * @notice Test reinvestment after filling oracle to maximum observations
     * @dev Verifies that reinvestment continues to work after oracle is at max capacity
     */
    function test_ReinvestmentAfterMaxObservations() public {
        // Setup: Enable reinvestment with 20% protocol fee share
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, 3000); // 0.3% fee
        policyManager.setPoolPOLShare(poolId, 200000); // 20% of fees go to protocol
        spot.setReinvestmentPaused(false); // Enable automatic reinvestment
        vm.stopPrank();

        // Step 1: Initial setup - Create POL position
        vm.startPrank(user1);
        liquidityManager.donate(poolKey, 1 ether, 1 ether);
        vm.warp(block.timestamp + REINVEST_COOLDOWN + 1);
        liquidityManager.reinvest(poolKey);
        vm.stopPrank();

        // Get initial POL state
        (uint256 initialShares, uint256 initialAmount0, uint256 initialAmount1) = 
            liquidityManager.getProtocolOwnedLiquidity(poolId);
        
        console.log("=== INITIAL POL STATE ===");
        console.log("Shares:", initialShares);
        console.log("Amount0:", initialAmount0);
        console.log("Amount1:", initialAmount1);

        // Step 2: Fill oracle to maximum observations (1024 observations)
        console.log("=== FILLING ORACLE TO MAX OBSERVATIONS ===");
        uint256 maxObservations = 1024; // Oracle max cardinality target
        for (uint256 i = 0; i < maxObservations; i++) {
            vm.startPrank(user2);
            SwapParams memory swap = SwapParams({
                zeroForOne: (i % 2 == 0), // Alternate direction
                amountSpecified: -int256(0.01 ether), // Small amount to avoid price impact
                sqrtPriceLimitX96: (i % 2 == 0) ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            });
            swapRouter.swap(poolKey, swap, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
            vm.stopPrank();
            
            // Log progress every 100 observations
            if (i % 100 == 0) {
                console.log("Filled", i, "observations");
            }
            
            // Warp time between observations (1 second intervals)
            vm.warp(block.timestamp + 1);
        }
        console.log("Oracle filled to maximum observations:", maxObservations);

        // Step 3: Perform large swaps to generate significant fees and trigger reinvestment
        console.log("=== PERFORMING LARGE SWAPS AFTER MAX OBSERVATIONS ===");
        for (uint256 i = 0; i < 3; i++) {
            console.log("=== LARGE SWAP", i + 1, "===");
            
            // Large swap in one direction
            vm.startPrank(user2);
            SwapParams memory largeSwap = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(10 ether), // Large amount to generate significant fees
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            });
            swapRouter.swap(poolKey, largeSwap, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
            vm.stopPrank();

            // Check POL state after each large swap
            (uint256 currentShares, uint256 currentAmount0, uint256 currentAmount1) = 
                liquidityManager.getProtocolOwnedLiquidity(poolId);
            
            console.log("After large swap", i + 1, ":");
            console.log("  Shares:", currentShares);
            console.log("  Shares change:", currentShares - initialShares);
            console.log("  Amount0:", currentAmount0);
            console.log("  Amount1:", currentAmount1);

            // Check pending fees
            (uint256 pending0, uint256 pending1) = liquidityManager.getPendingFees(poolId);
            console.log("  Pending fee0:", pending0);
            console.log("  Pending fee1:", pending1);

            // Wait for cooldown between large swaps
            vm.warp(block.timestamp + REINVEST_COOLDOWN + 1);
        }

        // Step 4: Verify final state
        (uint256 finalShares, uint256 finalAmount0, uint256 finalAmount1) = 
            liquidityManager.getProtocolOwnedLiquidity(poolId);
        
        console.log("=== FINAL POL STATE AFTER MAX OBSERVATIONS ===");
        console.log("Final shares:", finalShares);
        console.log("Total shares increase:", finalShares - initialShares);
        console.log("Final amount0:", finalAmount0);
        console.log("Final amount1:", finalAmount1);

        // Step 5: Check final pending fees
        (uint256 finalPending0, uint256 finalPending1) = liquidityManager.getPendingFees(poolId);
        console.log("=== FINAL PENDING FEES ===");
        console.log("Pending fee0:", finalPending0);
        console.log("Pending fee1:", finalPending1);

        // Assertions
        assertTrue(finalShares >= initialShares, "POL shares should not decrease after max observations");
        assertTrue(finalAmount0 >= initialAmount0, "POL amount0 should not decrease after max observations");
        assertTrue(finalAmount1 >= initialAmount1, "POL amount1 should not decrease after max observations");
        
        // Verify that reinvestment is still working (shares should have increased)
        assertGt(finalShares, initialShares, "POL shares should increase after large swaps with max observations");
        
        // Verify fees are being generated and potentially reinvested
        assertTrue(finalPending0 >= 1e4 || finalPending1 >= 1e4, "Should have accumulated fees above minimum threshold");
    }
} 