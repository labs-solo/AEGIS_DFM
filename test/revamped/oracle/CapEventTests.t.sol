// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Base_Test} from "../Base_Test.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IDynamicFeeManager} from "../../../src/interfaces/IDynamicFeeManager.sol";
import "forge-std/console.sol";

contract CapEventTests is Base_Test {
    // Events for testing
    event CapToggled(PoolId indexed poolId, bool inCap);

    function testCapEvents() public {
        // Test small swap - no cap expected
        _performSwap(1e18, true);
        vm.warp(block.timestamp + 60);
        
        bool capActive = feeManager.isCAPEventActive(poolId);
        assertFalse(capActive, "CAP event should not be active after small swap");

        // Test large swap - cap expected
        vm.expectEmit(true, false, false, true);
        emit CapToggled(poolId, true);
        
        _performSwap(1000000e18, true); // Large swap to trigger cap
        vm.warp(block.timestamp + 60);
        
        capActive = feeManager.isCAPEventActive(poolId);
        assertTrue(capActive, "CAP event should be active after large swap");
    }

    function testCapFrequencyDecay() public {
        console.log("=== Testing Cap Frequency Decay ===");
        
        // First, trigger a cap event to set initial frequency
        _performSwap(1000000e18, true); // Large swap to trigger cap
        vm.warp(block.timestamp + 60);
        
        // Get initial cap frequency (we'll need to add a getter for this)
        uint64 initialFreq = oracle.getCapFrequency(poolId);
        console.log("Initial cap frequency:", initialFreq);
        assertGt(initialFreq, 0, "Cap frequency should be greater than 0 after cap event");
        
        // Get the decay window from policy manager
        uint32 decayWindow = policyManager.getCapBudgetDecayWindow(poolId);
        console.log("Decay window:", decayWindow);
        
        // Test decay over time - should decay exponentially
        uint64 freqAfterHalfWindow = _getCapFrequencyAfterTime(decayWindow / 2);
        console.log("Cap frequency after half decay window:", freqAfterHalfWindow);
        assertLt(freqAfterHalfWindow, initialFreq, "Frequency should decay after half window");
        
        // Test full decay - should be 0 after full decay window
        uint64 freqAfterFullWindow = _getCapFrequencyAfterTime(decayWindow);
        console.log("Cap frequency after full decay window:", freqAfterFullWindow);
        assertEq(freqAfterFullWindow, 0, "Frequency should be 0 after full decay window");
        
        // Test that frequency stays at 0 after full decay
        uint64 freqAfterDoubleWindow = _getCapFrequencyAfterTime(decayWindow * 2);
        console.log("Cap frequency after double decay window:", freqAfterDoubleWindow);
        assertEq(freqAfterDoubleWindow, 0, "Frequency should stay at 0 after full decay");
    }

    function testSurgeFeeDecay() public {
        console.log("=== Testing Surge Fee Decay ===");
        
        // First, trigger a cap event to activate surge fees
        _performSwap(1000000e18, true); // Large swap to trigger cap
        vm.warp(block.timestamp + 60);
        
        // Check that surge fees are active
        bool capActive = feeManager.isCAPEventActive(poolId);
        assertTrue(capActive, "CAP event should be active after large swap");
        
        // Get the surge decay period from policy manager
        uint32 surgeDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);
        console.log("Surge decay period:", surgeDecayPeriod);
        
        // Test surge fee decay over time
        // After half the decay period, surge fees should still be active
        vm.warp(block.timestamp + surgeDecayPeriod / 2);
        _performSwap(1e18, true); // Trigger oracle update to check cap exit
        vm.warp(block.timestamp + 60);
        
        capActive = feeManager.isCAPEventActive(poolId);
        console.log("CAP active after half decay period:", capActive);
        assertTrue(capActive, "Surge fees should still be active after half decay period");
        
        // After full decay period, surge fees should be inactive
        vm.warp(block.timestamp + surgeDecayPeriod / 2); // Total time = full period
        _performSwap(1e18, true); // Trigger oracle update to check cap exit
        vm.warp(block.timestamp + 60);
        
        capActive = feeManager.isCAPEventActive(poolId);
        console.log("CAP active after full decay period:", capActive);
        assertFalse(capActive, "Surge fees should be inactive after full decay period");
        
        // Test that surge fees stay inactive after full decay
        vm.warp(block.timestamp + surgeDecayPeriod); // Additional full period
        _performSwap(1e18, true); // Trigger oracle update to check cap exit
        vm.warp(block.timestamp + 60);
        
        capActive = feeManager.isCAPEventActive(poolId);
        console.log("CAP active after double decay period:", capActive);
        assertFalse(capActive, "Surge fees should stay inactive after full decay");
    }

    function testCapAndSurgeFeeDecayTogether() public {
        console.log("=== Testing Cap Frequency and Surge Fee Decay Together ===");
        
        // Trigger a cap event
        _performSwap(1000000e18, true);
        vm.warp(block.timestamp + 60);
        
        // Check initial state
        uint64 initialFreq = oracle.getCapFrequency(poolId);
        bool capActive = feeManager.isCAPEventActive(poolId);
        console.log("Initial cap frequency:", initialFreq);
        console.log("Initial CAP active:", capActive);
        assertGt(initialFreq, 0, "Cap frequency should be greater than 0");
        assertTrue(capActive, "CAP event should be active");
        
        // Get decay periods
        uint32 capDecayWindow = policyManager.getCapBudgetDecayWindow(poolId);
        uint32 surgeDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);
        console.log("Cap decay window:", capDecayWindow);
        console.log("Surge decay period:", surgeDecayPeriod);
        
        // Test at different time points
        uint32[] memory testTimes = new uint32[](4);
        testTimes[0] = capDecayWindow / 4;      // Quarter cap decay
        testTimes[1] = capDecayWindow / 2;      // Half cap decay
        testTimes[2] = capDecayWindow;          // Full cap decay
        testTimes[3] = capDecayWindow * 2;      // Double cap decay
        
        for (uint i = 0; i < testTimes.length; i++) {
            uint32 testTime = testTimes[i];
            console.log("--- Testing at time:", testTime);
            
            // Warp to test time
            vm.warp(block.timestamp + testTime);
            
            // Perform a small swap to trigger decay updates
            _performSwap(1e18, true);
            vm.warp(block.timestamp + 60);
            
            // Check cap frequency
            uint64 currentFreq = oracle.getCapFrequency(poolId);
            console.log("  Cap frequency:", currentFreq);
            
            // Check surge fee status
            bool currentCapActive = feeManager.isCAPEventActive(poolId);
            console.log("  CAP active:", currentCapActive);
            
            // Verify expectations
            if (testTime >= capDecayWindow) {
                assertEq(currentFreq, 0, "Cap frequency should be 0 after full decay");
            } else {
                assertLt(currentFreq, initialFreq, "Cap frequency should decay over time");
            }
            
            if (testTime >= surgeDecayPeriod) {
                assertFalse(currentCapActive, "Surge fees should be inactive after surge decay period");
            } else {
                assertTrue(currentCapActive, "Surge fees should still be active before surge decay period");
            }
        }
    }

    function _getCapFrequencyAfterTime(uint32 timeElapsed) internal returns (uint64) {
        // Perform a small swap to trigger cap frequency update (decay)
        _performSwap(1e18, true);
        vm.warp(block.timestamp + timeElapsed);
        
        // Perform another small swap to trigger another update
        _performSwap(1e18, true);
        vm.warp(block.timestamp + 60);
        
        return oracle.getCapFrequency(poolId);
    }

    function _performSwap(uint256 amount, bool zeroForOne) internal {
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false});
        
        if (zeroForOne) {
            // Swap token0 for token1
            SwapParams memory params = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amount), // Negative for exact input
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
            
            vm.prank(user1);
            swapRouter.swap(poolKey, params, testSettings, "");
        } else {
            // Swap token1 for token0
            SwapParams memory params = SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amount), // Negative for exact input
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            });
            
            vm.prank(user1);
            swapRouter.swap(poolKey, params, testSettings, "");
        }

        // The Spot hook should automatically record observations during swaps
        // No need to manually call pushObservationAndCheckCap
    }
} 