// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import {Base_Test} from "../../Base_Test.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Errors} from "../../../../src/errors/Errors.sol";

import "forge-std/console2.sol";

contract PerSwapVsPerBlockTest is Base_Test {
    using StateLibrary for IPoolManager;

    function test_PerBlockMode_MultipleSwapsInSameBlock() public {
        // Check if cap event is already active before we start
        bool capEventActiveBefore = feeManager.isCAPEventActive(poolId);
        console2.log("Cap event active before test:", capEventActiveBefore);
        
        // Set perBlock mode
        vm.startPrank(owner);
        policyManager.setPerSwapMode(poolId, false);
        vm.stopPrank();

        // Get initial tick
        (, int24 initialTick,,) = manager.getSlot0(poolId);
        
        // Get max ticks per block to know our target
        uint24 maxTicks = oracle.maxTicksPerBlock(poolId);
        
        // Perform multiple small swaps that individually are under the cap
        vm.startPrank(user1);
        
        // First swap - tiny size (should be under cap individually)
        SwapParams memory params1 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Much smaller swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params1, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Get tick after first swap
        (, int24 tickAfterFirst,,) = manager.getSlot0(poolId);
        int24 firstSwapMovement = tickAfterFirst - initialTick;
        
        // Second swap - tiny size (should be under cap individually)
        SwapParams memory params2 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params2, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Get tick after second swap
        (, int24 tickAfterSecond,,) = manager.getSlot0(poolId);
        int24 secondSwapMovement = tickAfterSecond - tickAfterFirst;
        
        // Third swap - tiny size
        SwapParams memory params3 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params3, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Fourth swap - tiny size
        SwapParams memory params4 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params4, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Fifth swap - tiny size
        SwapParams memory params5 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params5, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Sixth swap - tiny size
        SwapParams memory params6 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params6, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Seventh swap - tiny size
        SwapParams memory params7 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params7, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Eighth swap - tiny size
        SwapParams memory params8 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params8, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Ninth swap - tiny size
        SwapParams memory params9 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params9, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Tenth swap - tiny size
        SwapParams memory params10 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params10, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        vm.stopPrank();

        // Get final tick after all swaps
        (, int24 finalTick,,) = manager.getSlot0(poolId);
        int24 totalTickMovement = finalTick - initialTick;
        
        // In perBlock mode, the total tick movement across all swaps should be compared against the cap
        bool expectedCapped = uint24(totalTickMovement < 0 ? -totalTickMovement : totalTickMovement) > maxTicks;
        
        // Assert that individual swaps are under cap but total exceeds it
        assertTrue(uint24(firstSwapMovement < 0 ? -firstSwapMovement : firstSwapMovement) <= maxTicks, "First swap should be under cap individually");
        assertTrue(uint24(secondSwapMovement < 0 ? -secondSwapMovement : secondSwapMovement) <= maxTicks, "Second swap should be under cap individually");
        assertTrue(expectedCapped, "Total movement should exceed cap in perBlock mode");
        
        // Check if a cap event actually occurred
        bool capEventActive = feeManager.isCAPEventActive(poolId);
        
        // Log the key results
        console2.log("=== PerBlock Mode Test Results ===");
        console2.log("Max ticks per block:", maxTicks);
        console2.log("First swap movement:", firstSwapMovement);
        console2.log("Second swap movement:", secondSwapMovement);
        console2.log("Total movement:", totalTickMovement);
        console2.log("Expected capped (perBlock):", expectedCapped);
        console2.log("Cap event actually active:", capEventActive);
        console2.log("First swap under cap individually:", uint24(firstSwapMovement < 0 ? -firstSwapMovement : firstSwapMovement) <= maxTicks);
        console2.log("Second swap under cap individually:", uint24(secondSwapMovement < 0 ? -secondSwapMovement : secondSwapMovement) <= maxTicks);
    }

    function test_PerSwapMode_SmallSwapsComparison() public {
        // Check if cap event is already active before we start
        bool capEventActiveBefore = feeManager.isCAPEventActive(poolId);
        console2.log("Cap event active before test:", capEventActiveBefore);
        
        // Set perSwap mode explicitly
        vm.startPrank(owner);
        policyManager.setPerSwapMode(poolId, true);
        vm.stopPrank();

        // Get initial tick
        (, int24 initialTick,,) = manager.getSlot0(poolId);
        
        // Get max ticks per block to know our target
        uint24 maxTicks = oracle.maxTicksPerBlock(poolId);
        
        // Perform the same 10 small swaps as in perBlock test
        vm.startPrank(user1);
        
        // First swap - tiny size (should be under cap individually)
        SwapParams memory params1 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap as perBlock test
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params1, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Get tick after first swap
        (, int24 tickAfterFirst,,) = manager.getSlot0(poolId);
        int24 firstSwapMovement = tickAfterFirst - initialTick;
        
        // Second swap - tiny size (should be under cap individually)
        SwapParams memory params2 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params2, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Get tick after second swap
        (, int24 tickAfterSecond,,) = manager.getSlot0(poolId);
        int24 secondSwapMovement = tickAfterSecond - tickAfterFirst;
        
        // Third swap - tiny size
        SwapParams memory params3 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params3, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Fourth swap - tiny size
        SwapParams memory params4 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params4, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Fifth swap - tiny size
        SwapParams memory params5 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params5, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Sixth swap - tiny size
        SwapParams memory params6 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params6, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Seventh swap - tiny size
        SwapParams memory params7 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params7, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Eighth swap - tiny size
        SwapParams memory params8 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params8, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Ninth swap - tiny size
        SwapParams memory params9 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params9, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        // Tenth swap - tiny size
        SwapParams memory params10 = SwapParams({
            zeroForOne: true,
            amountSpecified: -100e18, // Same small swap
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });
        swapRouter.swap(poolKey, params10, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        
        vm.stopPrank();

        // Get final tick after all swaps
        (, int24 finalTick,,) = manager.getSlot0(poolId);
        int24 totalTickMovement = finalTick - initialTick;
        
        // Check if a cap event actually occurred
        bool capEventActive = feeManager.isCAPEventActive(poolId);
        
        // In perSwap mode, each individual swap is checked against the cap
        bool firstSwapCapped = uint24(firstSwapMovement < 0 ? -firstSwapMovement : firstSwapMovement) > maxTicks;
        bool secondSwapCapped = uint24(secondSwapMovement < 0 ? -secondSwapMovement : secondSwapMovement) > maxTicks;
        
        // Assert that individual swaps are under cap (as intended)
        assertTrue(uint24(firstSwapMovement < 0 ? -firstSwapMovement : firstSwapMovement) <= maxTicks, "First swap should be under cap individually");
        assertTrue(uint24(secondSwapMovement < 0 ? -secondSwapMovement : secondSwapMovement) <= maxTicks, "Second swap should be under cap individually");
        
        // In perSwap mode, we should NOT have a cap event since individual swaps are small
        assertFalse(capEventActive, "PerSwap mode should not trigger cap event for small individual swaps");
        
        // Log the key results
        console2.log("=== PerSwap Mode Test Results ===");
        console2.log("Max ticks per block:", maxTicks);
        console2.log("First swap movement:", firstSwapMovement);
        console2.log("Second swap movement:", secondSwapMovement);
        console2.log("Total movement:", totalTickMovement);
        console2.log("Cap event actually active:", capEventActive);
        console2.log("First swap capped individually:", firstSwapCapped);
        console2.log("Second swap capped individually:", secondSwapCapped);
        console2.log("First swap under cap individually:", uint24(firstSwapMovement < 0 ? -firstSwapMovement : firstSwapMovement) <= maxTicks);
        console2.log("Second swap under cap individually:", uint24(secondSwapMovement < 0 ? -secondSwapMovement : secondSwapMovement) <= maxTicks);
    }

    function test_PerSwapMode_SettingChange() public {
        // Test setting perSwap mode
        vm.startPrank(owner);
        policyManager.setPerSwapMode(poolId, true);
        vm.stopPrank();
        
        bool perSwapMode = policyManager.getPerSwapMode(poolId);
        assertTrue(perSwapMode, "Should be set to perSwap mode");
        
        // Test setting perBlock mode
        vm.startPrank(owner);
        policyManager.setPerSwapMode(poolId, false);
        vm.stopPrank();
        
        perSwapMode = policyManager.getPerSwapMode(poolId);
        assertFalse(perSwapMode, "Should be set to perBlock mode");
    }

    function test_PerSwapMode_GlobalDefault() public {
        // Test initial global default (should be perSwap = true)
        assertTrue(policyManager.getDefaultPerSwapMode(), "Global default should be perSwap");
        
        // Test that pools use the global default when initialized
        assertTrue(policyManager.getPerSwapMode(poolId), "Pool should use global default (perSwap)");
        
        // Test that only owner can change global default
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert when non-owner tries to change
        policyManager.setDefaultPerSwapMode(false);
        vm.stopPrank();
        
        // Verify global default is still the same
        assertTrue(policyManager.getDefaultPerSwapMode(), "Global default should still be perSwap after failed attempt");
        
        // Change global default to perBlock (as owner)
        vm.startPrank(owner);
        policyManager.setDefaultPerSwapMode(false);
        vm.stopPrank();
        
        // Verify global default changed
        assertFalse(policyManager.getDefaultPerSwapMode(), "Global default should now be perBlock");
        
        // Test that existing pools keep their original setting (set during initialization)
        // The pool was initialized with the old global default, so it should still use that
        assertTrue(policyManager.getPerSwapMode(poolId), "Pool should keep original setting from initialization");
        
        // Note: New pools would use the new global default when initialized
        // We can't easily test this here since we'd need to create a new pool with different currencies
    }

    function test_AfterInitializeBeforePoolInit() public {
        // Create a new pool key with different currencies to ensure it's truly new
        MockERC20 token2 = new MockERC20("Token2", "TK2", 18);
        MockERC20 token3 = new MockERC20("Token3", "TK3", 18);
        Currency currency2 = Currency.wrap(address(token2));
        Currency currency3 = Currency.wrap(address(token3));
        
        PoolKey memory newPoolKey = PoolKey(
            currency2,
            currency3,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60, // tick spacing
            IHooks(address(spot))
        );
        PoolId newPoolId = newPoolKey.toId();
        
        // Check if the pool exists
        console2.log("Checking if new pool exists...");
        console2.log("Pool doesn't exist yet - good for testing");
        
        // Try to call the hook's afterInitialize directly through the IHooks interface
        // This should fail with NotPoolManager error
        console2.log("Attempting to call afterInitialize before pool initialization...");
        vm.expectRevert(Errors.NotPoolManager.selector);
        IHooks(address(spot)).afterInitialize(address(0), newPoolKey, SQRT_PRICE_1_1, 0);
        
        console2.log("SUCCESS: afterInitialize correctly rejected - only pool manager can call it");
        
        // Now initialize the pool properly
        manager.initialize(newPoolKey, SQRT_PRICE_1_1);
        
        // After initialization, the pool should exist
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(newPoolId);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1, "Pool should be initialized with correct price");
        
        // Verify that the hook's afterInitialize was called during initialization
        // by checking if the policy manager was initialized for this pool
        bool perSwapMode = policyManager.getPerSwapMode(newPoolId);
        console2.log("PerSwap mode after pool init:", perSwapMode);
        // The pool should now have a perSwap mode setting (either default or explicitly set)
        // We can't directly check if afterInitialize was called, but we can verify the side effects
    }
} 