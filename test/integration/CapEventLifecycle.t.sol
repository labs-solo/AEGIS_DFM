// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {ForkSetup} from "./ForkSetup.t.sol";
import {FullRangeDynamicFeeManager} from "src/FullRangeDynamicFeeManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/**
 * @title CapEventLifecycle
 * @notice Tests for the CAP event lifecycle in the FullRangeDynamicFeeManager
 * @dev Focuses on the CAP event detection, surge fee application, and decay period
 */
contract CapEventLifecycle is ForkSetup {
    using PoolIdLibrary for PoolKey;

    // Test user
    address tester;
        
    // Helper variables
    uint160 internal constant MIN_SQRT_PRICE = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_SQRT_PRICE = TickMath.MAX_SQRT_PRICE - 1;
    
    // Events we'll be checking
    event TickChangeCapped(PoolId indexed poolId, int24 actualChange, int24 cappedChange);
    event CapEventStateChanged(PoolId indexed poolId, bool isInCapEvent);
    event SurgeFeeUpdated(PoolId indexed poolId, uint256 surgeFee, bool capEventOccurred);
    
    function setUp() public override {
        super.setUp();
        console.log("Parent setup completed");
        
        // Use testUser from ForkSetup instead of creating a new one
        tester = testUser;
        console.log("Test user address:", tester);
        
        // Now approve tokens for swapping
        vm.startPrank(tester);
        console.log("Started pranking as tester");
        
        // The tokens should already be funded in ForkSetup, so we don't need the deal calls
        // Remove these:
        deal(WETH_ADDRESS, tester, 1000e18);
        deal(USDC_ADDRESS, tester, 1_000_000e6);

        // Check token balances for the proper user
        console.log("WETH balance:", weth.balanceOf(tester));
        console.log("USDC balance:", usdc.balanceOf(tester));
        
        // Approve tokens for swapping
        IERC20Minimal(WETH_ADDRESS).approve(address(poolManager), type(uint256).max);
        IERC20Minimal(USDC_ADDRESS).approve(address(poolManager), type(uint256).max);   
        console.log("Tokens approved for poolManager");
        vm.stopPrank();
    }
        
    /**
     * @notice Helper to perform a swap
     * @param zeroForOne True if swapping token0 for token1, false otherwise
     * @param amountSpecified Amount to swap (positive for exact input, negative for exact output)
     * @param sqrtPriceLimitX96 Price limit for the swap
     */
    function _swap(
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) internal returns (BalanceDelta delta) {
        // First, we need to create a swap router
        PoolSwapTest swapRouter = new PoolSwapTest(poolManager);
        console.log("swapping");
        vm.startPrank(tester);
        
        console.log("approvals for swap");
        // Approve tokens for the new swap router if needed
        IERC20Minimal(WETH_ADDRESS).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(USDC_ADDRESS).approve(address(swapRouter), type(uint256).max);
        
        // Prepare for the swap
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        console.log("executing swap");
        // Execute swap
        delta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            testSettings,
            ""
        );

        // log the deltas
        console.log("delta0: ", delta.delta0);
        console.log("delta1: ", delta.delta1);

        console.log("swap completed");

        vm.stopPrank();
    }
    
    /**
     * @notice Helper to get the current tick of the pool
     */
    function _getCurrentTick() internal view returns (int24 tick) {
        (, tick, , ) = StateLibrary.getSlot0(poolManager, poolId);
    }
    
    /**
     * @notice Helper to perform a large swap that exceeds the max tick change
     */
    function _performLargeSwap() internal returns (BalanceDelta) {
        // Estimate a large amount that will exceed max tick change
        return _swap(true, 20e18, MIN_SQRT_PRICE); // Large exact input swap
    }
    
    /**
     * @notice Helper to perform a small swap that doesn't exceed the max tick change
     */
    function _performSmallSwap() internal returns (BalanceDelta) {
        return _swap(true, 0.1e18, MIN_SQRT_PRICE); // Small exact input swap
    }
    
    /**
     * @notice Test that a large swap triggers a CAP event
     */
    function test_CapEventTrigger_LargeSwap() public {
        // Check initial state
        assertFalse(dynamicFeeManager.isPoolInCapEvent(poolId), "Should not be in CAP event initially");
        
        // Expect events
        vm.expectEmit(true, true, false, false, address(dynamicFeeManager));
        emit TickChangeCapped(poolId, 0, 0); // We don't care about the exact change values
        
        vm.expectEmit(true, true, true, true, address(dynamicFeeManager));
        emit CapEventStateChanged(poolId, true);
        
        vm.expectEmit(true, true, true, true, address(dynamicFeeManager));
        emit SurgeFeeUpdated(poolId, dynamicFeeManager.INITIAL_SURGE_FEE_PPM(), true);
        
        // Perform a large swap
        _performLargeSwap();
        
        // Verify CAP event was triggered
        assertTrue(dynamicFeeManager.isPoolInCapEvent(poolId), "isInCapEvent should be true after large swap");
        
        // Verify surge fee
        uint256 totalFee = dynamicFeeManager.getCurrentDynamicFee(poolId);
        
        // Get the pool state to access its fields
        (uint128 baseFeePpm, uint128 currentSurgeFeePpm, , , , bool isInCapEvent, , ,) = dynamicFeeManager.poolStates(poolId);
        
        // Current fee should include the surge component
        uint256 expectedSurgeFee = dynamicFeeManager.INITIAL_SURGE_FEE_PPM();
        
        assertGt(totalFee, baseFeePpm, "Total fee should be greater than base fee");
        assertEq(totalFee, baseFeePpm + expectedSurgeFee, "Total fee should be base fee + surge fee");
    }
    
    /**
     * @notice Test that a small swap doesn't trigger a CAP event
     */
    function test_CapEvent_NoTrigger_SmallSwap() public {
        // Check initial state
        assertFalse(dynamicFeeManager.isPoolInCapEvent(poolId), "Should not be in CAP event initially");
        
        // Perform a small swap
        _performSmallSwap();
        
        // Verify CAP event was not triggered
        assertFalse(dynamicFeeManager.isPoolInCapEvent(poolId), "isInCapEvent should remain false after small swap");
        
        // Base case where we're not in a CAP event and want to ensure small swap doesn't trigger one
        
        // Now test the case where we're already in a CAP event and a small swap doesn't change that
        _performLargeSwap(); // Trigger CAP event
        assertTrue(dynamicFeeManager.isPoolInCapEvent(poolId), "isInCapEvent should be true after large swap");
        
        uint256 preSwapFee = dynamicFeeManager.getCurrentDynamicFee(poolId);
        
        // Perform another small swap, which shouldn't affect the CAP event state
        _performSmallSwap();
        
        // Should still be in CAP event
        assertTrue(dynamicFeeManager.isPoolInCapEvent(poolId), "isInCapEvent should remain true after subsequent small swap");
        
        uint256 postSwapFee = dynamicFeeManager.getCurrentDynamicFee(poolId);
        assertEq(preSwapFee, postSwapFee, "Fee should remain constant during CAP event");
    }
    
    /**
     * @notice Test CAP event ending
     */
    function test_CapEventEnding() public {
        // First, let's trigger a CAP event
        _performLargeSwap();
        assertTrue(dynamicFeeManager.isPoolInCapEvent(poolId), "isInCapEvent should be true after large swap");
        
        // Let a block pass
        vm.roll(block.number + 1);
        
        // Check the CAP event end time before
        (,,,uint48 capEventEndTime,,,,,) = dynamicFeeManager.poolStates(poolId);
        assertEq(capEventEndTime, 0, "capEventEndTime should be 0 during CAP event");
        
        // Expect events for CAP event ending
        vm.expectEmit(true, true, true, true, address(dynamicFeeManager));
        emit CapEventStateChanged(poolId, false);
        
        vm.expectEmit(true, true, true, true, address(dynamicFeeManager));
        emit SurgeFeeUpdated(poolId, dynamicFeeManager.INITIAL_SURGE_FEE_PPM(), false);
        
        // Advance oracle state with a small swap to end the CAP event
        _performSmallSwap();
        
        // Verify CAP event ended
        assertFalse(dynamicFeeManager.isPoolInCapEvent(poolId), "isInCapEvent should be false after small swap");
        
        // Check that capEventEndTime is set
        (,,,,uint48 newCapEventEndTime,,,,) = dynamicFeeManager.poolStates(poolId);
        assertEq(newCapEventEndTime, block.timestamp, "capEventEndTime should be set to current block timestamp");
    }
    
    /**
     * @notice Test surge fee decay at mid-point of decay period
     */
    function test_SurgeFeeDecay_MidPoint() public {
        // First, trigger a CAP event
        _performLargeSwap();
        assertTrue(dynamicFeeManager.isPoolInCapEvent(poolId), "Should be in CAP event");
        
        // End the CAP event with a small swap
        vm.roll(block.number + 1);
        _performSmallSwap();
        assertFalse(dynamicFeeManager.isPoolInCapEvent(poolId), "Should not be in CAP event");
        
        // Get initial fees right after CAP event ends
        (uint128 initialBaseFee,,,,,,,,) = dynamicFeeManager.poolStates(poolId);
        uint256 initialSurgeFee = dynamicFeeManager.INITIAL_SURGE_FEE_PPM();
        uint256 initialTotalFee = dynamicFeeManager.getCurrentDynamicFee(poolId);
        
        // Advance time to halfway through decay period
        uint256 halfDecay = dynamicFeeManager.SURGE_DECAY_PERIOD_SECONDS() / 2;
        vm.warp(block.timestamp + halfDecay);
        
        // Check fees at middle of decay
        uint256 midPointFee = dynamicFeeManager.getCurrentDynamicFee(poolId);
        uint256 expectedMidSurge = initialSurgeFee / 2; // Linear decay, should be half
        uint256 expectedMidTotal = initialBaseFee + expectedMidSurge;
        
        // Allow for small rounding error due to integer division
        assertApproxEqRel(midPointFee, expectedMidTotal, 0.01e18, "Fee should be approximately half decayed");
    }
    
    /**
     * @notice Test surge fee decay after full decay period
     */
    function test_SurgeFeeDecay_FullPeriod() public {
        // First, trigger a CAP event
        _performLargeSwap();
        
        // End the CAP event with a small swap
        vm.roll(block.number + 1);
        _performSmallSwap();
        
        // Get base fee (should remain constant)
        (uint128 baseFee,,,,,,,,) = dynamicFeeManager.poolStates(poolId);
        
        // Advance time past full decay period
        uint256 fullDecay = dynamicFeeManager.SURGE_DECAY_PERIOD_SECONDS() + 1;
        vm.warp(block.timestamp + fullDecay);
        
        // Get current fee
        uint256 currentFee = dynamicFeeManager.getCurrentDynamicFee(poolId);
        
        // Surge should be fully decayed, back to just base fee
        assertEq(currentFee, baseFee, "Fee should equal base fee after full decay");
    }
    
    /**
     * @notice Test surge fee during active CAP event (should remain at INITIAL_SURGE_FEE_PPM)
     */
    function test_SurgeFee_DuringCapEvent() public {
        // Trigger a CAP event
        _performLargeSwap();
        assertTrue(dynamicFeeManager.isPoolInCapEvent(poolId), "Should be in CAP event");
        
        // Get initial fees
        (uint128 initialBaseFee,,,,,,,,) = dynamicFeeManager.poolStates(poolId);
        uint256 initialSurgeFee = dynamicFeeManager.INITIAL_SURGE_FEE_PPM();
        uint256 initialTotalFee = dynamicFeeManager.getCurrentDynamicFee(poolId);
        
        // Advance time but remain in CAP event
        vm.warp(block.timestamp + dynamicFeeManager.SURGE_DECAY_PERIOD_SECONDS() / 2);
        
        // Check fees - should remain constant during CAP event
        uint256 currentFee = dynamicFeeManager.getCurrentDynamicFee(poolId);
        assertEq(currentFee, initialTotalFee, "Fee should remain constant during CAP event");
        assertEq(currentFee, initialBaseFee + initialSurgeFee, "Fee should be base fee + full surge fee");
    }
} 