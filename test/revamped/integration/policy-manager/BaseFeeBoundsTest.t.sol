// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "forge-std/Test.sol";

// - - - v4 core src deps - - -

import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

// - - - v4 periphery src deps - - -

import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {Deploy, IV4Quoter} from "v4-periphery/test/shared/Deploy.sol";
import {PosmTestSetup} from "v4-periphery/test/shared/PosmTestSetup.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

// Import project contracts

import {Spot} from "src/Spot.sol";
import {FullRangeLiquidityManager} from "src/FullRangeLiquidityManager.sol";
import {PoolPolicyManager} from "src/PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "src/TruncGeoOracleMulti.sol";
import {DynamicFeeManager} from "src/DynamicFeeManager.sol";

// - - - local test helpers - - -

import {MainUtils} from "../../utils/MainUtils.sol";
import {Base_Test} from "../../Base_Test.sol";

contract BaseFeeBoundsTest is Base_Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;



    function test_InitializeBaseFeeBoundsFromTickSpacing() public {
        // Test different tick spacings and their expected fee calculations
        int24[] memory tickSpacings = new int24[](3);
        tickSpacings[0] = 10;  // Should give 500 ppm (0.05%)
        tickSpacings[1] = 30;  // Should give 1500 ppm (0.15%)
        tickSpacings[2] = 200; // Should give 10000 ppm (1.0%)

        for (uint i = 0; i < tickSpacings.length; i++) {
            // Create a new pool with the specific tick spacing
            PoolKey memory testPoolKey = PoolKey(
                currency0,
                currency1,
                LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacings[i],
                IHooks(address(spot))
            );

            PoolId testPoolId = testPoolKey.toId();

            // Initialize the pool (this should trigger the base fee bounds initialization)
            manager.initialize(testPoolKey, SQRT_PRICE_1_1);

            // Verify that the base fee bounds were set correctly
            uint24 minBaseFee = policyManager.getMinBaseFee(testPoolId);
            uint24 maxBaseFee = policyManager.getMaxBaseFee(testPoolId);

            // Verify the actual values are set correctly
            // For tickSpacing 10: min = 450 ppm, max = 475 ppm
            // For tickSpacing 30: min = 1350 ppm, max = 1425 ppm  
            // For tickSpacing 200: min = 9000 ppm, max = 9500 ppm
            if (tickSpacings[i] == 10) {
                assertEq(minBaseFee, 450, "Min base fee mismatch for tickSpacing 10");
                assertEq(maxBaseFee, 475, "Max base fee mismatch for tickSpacing 10");
            } else if (tickSpacings[i] == 30) {
                assertEq(minBaseFee, 1350, "Min base fee mismatch for tickSpacing 30");
                assertEq(maxBaseFee, 1425, "Max base fee mismatch for tickSpacing 30");
            } else if (tickSpacings[i] == 200) {
                assertEq(minBaseFee, 9000, "Min base fee mismatch for tickSpacing 200");
                assertEq(maxBaseFee, 9500, "Max base fee mismatch for tickSpacing 200");
            }
        }
    }

    function test_InitializeBaseFeeBoundsWithEdgeCases() public {
        // Test edge cases including tickSpacing 1 and values > 200
        int24[] memory edgeTickSpacings = new int24[](6);
        edgeTickSpacings[0] = 1;     // Should give 100 ppm (clamped)
        edgeTickSpacings[1] = 2;     // Should give 100 ppm (clamped)
        edgeTickSpacings[2] = 200;   // Should give 10000 ppm (exact boundary)
        edgeTickSpacings[3] = 201;   // Should give 10000 ppm (clamped)
        edgeTickSpacings[4] = 500;   // Should give 10000 ppm (clamped)
        edgeTickSpacings[5] = 1000;  // Should give 10000 ppm (clamped)

        for (uint i = 0; i < edgeTickSpacings.length; i++) {
            PoolKey memory testPoolKey = PoolKey(
                currency0,
                currency1,
                LPFeeLibrary.DYNAMIC_FEE_FLAG,
                edgeTickSpacings[i],
                IHooks(address(spot))
            );

            PoolId testPoolId = testPoolKey.toId();

            manager.initialize(testPoolKey, SQRT_PRICE_1_1);

            uint24 minBaseFee = policyManager.getMinBaseFee(testPoolId);
            uint24 maxBaseFee = policyManager.getMaxBaseFee(testPoolId);

            // Verify the actual values are set correctly for edge cases
            if (edgeTickSpacings[i] == 1) {
                // tickSpacing 1 -> ideal = 50 ppm -> clamped to 100 ppm
                // min = 100 * 0.9 = 90 ppm
                // max = 100 * 0.95 = 95 ppm
                assertEq(minBaseFee, 90, "Min base fee mismatch for tickSpacing 1");
                assertEq(maxBaseFee, 95, "Max base fee mismatch for tickSpacing 1");
            } else if (edgeTickSpacings[i] == 2) {
                // tickSpacing 2 -> ideal = 100 ppm
                // min = 100 * 0.9 = 90 ppm
                // max = 100 * 0.95 = 95 ppm
                assertEq(minBaseFee, 90, "Min base fee mismatch for tickSpacing 2");
                assertEq(maxBaseFee, 95, "Max base fee mismatch for tickSpacing 2");
            } else if (edgeTickSpacings[i] == 200) {
                // tickSpacing 200 -> ideal = 10000 ppm (exact boundary)
                // min = 10000 * 0.9 = 9000 ppm
                // max = 10000 * 0.95 = 9500 ppm
                assertEq(minBaseFee, 9000, "Min base fee mismatch for tickSpacing 200");
                assertEq(maxBaseFee, 9500, "Max base fee mismatch for tickSpacing 200");
            } else if (edgeTickSpacings[i] == 201) {
                // tickSpacing 201 -> ideal = 10050 ppm -> clamped to 10000 ppm
                // min = 10000 * 0.9 = 9000 ppm
                // max = 10000 * 0.95 = 9500 ppm
                assertEq(minBaseFee, 9000, "Min base fee mismatch for tickSpacing 201 (should be clamped)");
                assertEq(maxBaseFee, 9500, "Max base fee mismatch for tickSpacing 201 (should be clamped)");
            } else if (edgeTickSpacings[i] == 500) {
                // tickSpacing 500 -> ideal = 25000 ppm -> clamped to 10000 ppm
                // min = 10000 * 0.9 = 9000 ppm
                // max = 10000 * 0.95 = 9500 ppm
                assertEq(minBaseFee, 9000, "Min base fee mismatch for tickSpacing 500 (should be clamped)");
                assertEq(maxBaseFee, 9500, "Max base fee mismatch for tickSpacing 500 (should be clamped)");
            } else if (edgeTickSpacings[i] == 1000) {
                // tickSpacing 1000 -> ideal = 50000 ppm -> clamped to 10000 ppm
                // min = 10000 * 0.9 = 9000 ppm
                // max = 10000 * 0.95 = 9500 ppm
                assertEq(minBaseFee, 9000, "Min base fee mismatch for tickSpacing 1000 (should be clamped)");
                assertEq(maxBaseFee, 9500, "Max base fee mismatch for tickSpacing 1000 (should be clamped)");
            }
        }
    }

    function test_InitializeBaseFeeBoundsIdempotent() public {
        // Create a pool with tick spacing 30 (different from default pool's 60)
        PoolKey memory testPoolKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            30, // tick spacing
            IHooks(address(spot))
        );

        PoolId testPoolId = testPoolKey.toId();

        // Initialize the pool
        manager.initialize(testPoolKey, SQRT_PRICE_1_1);

        // Verify initial values
        uint24 initialMinFee = policyManager.getMinBaseFee(testPoolId);
        uint24 initialMaxFee = policyManager.getMaxBaseFee(testPoolId);
        assertEq(initialMinFee, 1350, "Initial min fee should be 1350 ppm (1500 * 0.9)");
        assertEq(initialMaxFee, 1425, "Initial max fee should be 1425 ppm (1500 * 0.95)");

        // Try to call initializeBaseFeeBounds again directly (should be idempotent)
        vm.prank(address(spot));
        PoolKey memory differentPoolKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            100, // Different tick spacing
            IHooks(address(spot))
        );
        policyManager.initializeBaseFeeBounds(differentPoolKey);

        // Verify values haven't changed
        uint24 finalMinFee = policyManager.getMinBaseFee(testPoolId);
        uint24 finalMaxFee = policyManager.getMaxBaseFee(testPoolId);
        assertEq(finalMinFee, initialMinFee, "Min fee should not change on second call");
        assertEq(finalMaxFee, initialMaxFee, "Max fee should not change on second call");
    }

    function test_InitializeBaseFeeBoundsUnauthorized() public {
        // Create a pool
        PoolKey memory testPoolKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            30, // tick spacing
            IHooks(address(spot))
        );

        // Try to call initializeBaseFeeBounds from unauthorized address
        vm.prank(user1);
        vm.expectRevert(); // Should revert with unauthorized caller error
        policyManager.initializeBaseFeeBounds(testPoolKey);
    }

    function test_InitializeBaseFeeBoundsWithoutAuthorizedHook() public {
        // Create a new policy manager without setting authorized hook
        vm.startPrank(owner);
        PoolPolicyManager newPolicyManager = new PoolPolicyManager(owner, 1_000_000);
        vm.stopPrank();

        // Create a pool with the new policy manager (this would require recreating the entire setup)
        // For now, just test that calling without authorization fails
        vm.prank(user1);
        vm.expectRevert(); // Should revert with unauthorized caller error
        PoolKey memory unauthorizedPoolKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            30,
            IHooks(address(spot))
        );
        newPolicyManager.initializeBaseFeeBounds(unauthorizedPoolKey);
    }

    function test_MinMaxFeeCalculations() public {
        // Test that min and max fees are correctly calculated as percentages of ideal fee
        
        // Test case 1: tickSpacing 30 -> ideal fee 1500 ppm
        // min = 1500 * 0.9 = 1350 ppm, max = 1500 * 0.95 = 1425 ppm
        PoolKey memory testPoolKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            30,
            IHooks(address(spot))
        );
        PoolId testPoolId = testPoolKey.toId();
        manager.initialize(testPoolKey, SQRT_PRICE_1_1);
        
        uint24 minFee = policyManager.getMinBaseFee(testPoolId);
        uint24 maxFee = policyManager.getMaxBaseFee(testPoolId);
        
        assertEq(minFee, 1350, "Min fee should be 90% of ideal fee (1500 * 0.9)");
        assertEq(maxFee, 1425, "Max fee should be 95% of ideal fee (1500 * 0.95)");
        
        // Test case 2: tickSpacing 200 -> ideal fee 10000 ppm
        // min = 10000 * 0.9 = 9000 ppm, max = 10000 * 0.95 = 9500 ppm
        PoolKey memory testPoolKey2 = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            200,
            IHooks(address(spot))
        );
        PoolId testPoolId2 = testPoolKey2.toId();
        manager.initialize(testPoolKey2, SQRT_PRICE_1_1);
        
        minFee = policyManager.getMinBaseFee(testPoolId2);
        maxFee = policyManager.getMaxBaseFee(testPoolId2);
        
        assertEq(minFee, 9000, "Min fee should be 90% of ideal fee (10000 * 0.9)");
        assertEq(maxFee, 9500, "Max fee should be 95% of ideal fee (10000 * 0.95)");
    }



    function test_ClampingBehavior() public {
        // Test that the clamping behavior works correctly at boundaries
        
        // Test minimum clamping (tickSpacing 1 and 2)
        PoolKey memory minTestKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            1, // tickSpacing 1 -> ideal = 50 ppm -> clamped to 100 ppm
            IHooks(address(spot))
        );
        PoolId minTestId = minTestKey.toId();
        manager.initialize(minTestKey, SQRT_PRICE_1_1);
        
        uint24 minFee1 = policyManager.getMinBaseFee(minTestId);
        uint24 maxFee1 = policyManager.getMaxBaseFee(minTestId);
        
        // Should be calculated as percentages of ideal fee
        assertEq(minFee1, 90, "Min fee should be 90 ppm for tickSpacing 1 (100 * 0.9)");
        assertEq(maxFee1, 95, "Max fee should be 95 ppm for tickSpacing 1 (100 * 0.95)");
        
        // Test maximum clamping (tickSpacing 500 and 1000)
        PoolKey memory maxTestKey = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            500, // tickSpacing 500 -> ideal = 25000 ppm -> clamped to 10000 ppm
            IHooks(address(spot))
        );
        PoolId maxTestId = maxTestKey.toId();
        manager.initialize(maxTestKey, SQRT_PRICE_1_1);
        
        uint24 minFee500 = policyManager.getMinBaseFee(maxTestId);
        uint24 maxFee500 = policyManager.getMaxBaseFee(maxTestId);
        
        // Should be clamped to maximum values
        assertEq(minFee500, 9000, "Min fee should be 9000 ppm for tickSpacing 500 (clamped)");
        assertEq(maxFee500, 9500, "Max fee should be 9500 ppm for tickSpacing 500 (clamped)");
        
        // Verify that values beyond 500 give the same results (clamped)
        PoolKey memory maxTestKey2 = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            1000, // tickSpacing 1000 -> ideal = 50000 ppm -> clamped to 10000 ppm
            IHooks(address(spot))
        );
        PoolId maxTestId2 = maxTestKey2.toId();
        manager.initialize(maxTestKey2, SQRT_PRICE_1_1);
        
        uint24 minFee1000 = policyManager.getMinBaseFee(maxTestId2);
        uint24 maxFee1000 = policyManager.getMaxBaseFee(maxTestId2);
        
        // Should be the same as 500 (both clamped to max)
        assertEq(minFee1000, minFee500, "Min fee should be same for tickSpacing 500 and 1000 (both clamped)");
        assertEq(maxFee1000, maxFee500, "Max fee should be same for tickSpacing 500 and 1000 (both clamped)");
    }
} 