// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// - - - v4-core src imports - - -

import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

// - - - local test imports - - -

import {Base_Test} from "../../Base_Test.sol";

// - - - local src imports - - -

import {Errors} from "src/errors/Errors.sol";
import {PolicyManagerErrors} from "src/errors/PolicyManagerErrors.sol";
import {PrecisionConstants} from "src/libraries/PrecisionConstants.sol";
import {IPoolPolicyManager} from "src/interfaces/IPoolPolicyManager.sol";

contract PoolPolicyManagerTest is Base_Test {
    uint24 MIN_TRADING_FEE = 10; // 0.001% (minimum allowed)
    uint24 MAX_TRADING_FEE = 100_000; // 10% (maximum allowed)
    uint32 DEFAULT_BASE_FEE_STEP_PPM = 20_000;

    function setUp() public override {
        Base_Test.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                      POL SHARE MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Success_SetPoolPOLShare_WhenValidPercentage() public {
        // Setup: Use a valid POL share percentage (20% = 200,000 PPM)
        uint256 newPolSharePpm = 200_000;

        // Get initial POL share to verify change
        uint256 initialPolShare = policyManager.getPoolPOLShare(poolId);

        // Execute: Set the POL share using owner account
        vm.startPrank(owner);

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.PoolPOLShareChanged(poolId, newPolSharePpm);

        // Call the function
        policyManager.setPoolPOLShare(poolId, newPolSharePpm);
        vm.stopPrank();

        // Verify: Check that the POL share was updated correctly
        uint256 updatedPolShare = policyManager.getPoolPOLShare(poolId);

        // Assert the value was changed from initial value
        assertNotEq(updatedPolShare, initialPolShare, "POL share should have changed");

        // Assert the value matches what we set
        assertEq(updatedPolShare, newPolSharePpm, "POL share not set to expected value");

        // Test with another valid value (50% = 500,000 PPM)
        uint256 anotherPolSharePpm = 500_000;

        vm.startPrank(owner);
        policyManager.setPoolPOLShare(poolId, anotherPolSharePpm);
        vm.stopPrank();

        // Verify second update
        updatedPolShare = policyManager.getPoolPOLShare(poolId);
        assertEq(updatedPolShare, anotherPolSharePpm, "POL share not updated to new value");

        // Test edge case: 100% = 1,000,000 PPM (maximum allowed)
        uint256 maxPolSharePpm = 1_000_000; // 100%

        vm.startPrank(owner);
        policyManager.setPoolPOLShare(poolId, maxPolSharePpm);
        vm.stopPrank();

        // Verify max value update
        updatedPolShare = policyManager.getPoolPOLShare(poolId);
        assertEq(updatedPolShare, maxPolSharePpm, "POL share not set to maximum value");
    }

    function test_Success_SetPoolPOLShare_WhenSetToZero() public {
        // Setup: First set a non-zero POL share to ensure we're testing a change to zero
        uint256 initialPolSharePpm = 300_000; // 30%

        vm.startPrank(owner);
        policyManager.setPoolPOLShare(poolId, initialPolSharePpm);
        vm.stopPrank();

        // Verify initial setup worked
        uint256 currentPolShare = policyManager.getPoolPOLShare(poolId);
        assertEq(currentPolShare, initialPolSharePpm, "Initial POL share setup failed");

        // Execute: Set the POL share to zero
        vm.startPrank(owner);

        // Expect event to be emitted with zero value
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.PoolPOLShareChanged(poolId, 0);

        // Call the function to set POL share to zero
        policyManager.setPoolPOLShare(poolId, 0);
        vm.stopPrank();

        // Verify: Check that the POL share was updated to zero
        uint256 updatedPolShare = policyManager.getPoolPOLShare(poolId);

        // Assert the value is now zero
        assertEq(updatedPolShare, 0, "POL share should be set to zero");

        // Functional verification: Perform a swap to ensure no protocol fees are taken

        // Set manual fee to a known value for predictable test
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, 3000); // 0.3% fee
        spot.setReinvestmentPaused(true); // Pause reinvestment to make verification easier
        vm.stopPrank();

        // Check initial pending fees
        (uint256 pendingFee0Before, uint256 pendingFee1Before) = liquidityManager.getPendingFees(poolId);

        // Execute a swap that would normally generate protocol fees
        vm.startPrank(user1);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1 ether), // Swap 1 ETH of token0 for token1
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        vm.stopPrank();

        // Verify: Check that no protocol fees were collected despite the swap
        (uint256 pendingFee0After, uint256 pendingFee1After) = liquidityManager.getPendingFees(poolId);

        // Assert no change in pending fees (since POL share is zero)
        assertEq(pendingFee0After, pendingFee0Before, "No token0 fees should be collected when POL share is zero");
        assertEq(pendingFee1After, pendingFee1Before, "No token1 fees should be collected when POL share is zero");
    }

    function test_Revert_SetPoolPOLShare_WhenCalledByNonOwner() public {
        // Setup: Define a valid POL share percentage
        uint256 newPolSharePpm = 200_000; // 20%

        // Get the initial POL share value to verify no change happens
        uint256 initialPolShare = policyManager.getPoolPOLShare(poolId);

        // Execute: Attempt to set the POL share as a non-owner account (user1)
        vm.startPrank(user1);

        // Expect the transaction to revert because only the owner can call this function
        // The error comes from Solmate's Owned contract which uses a custom error pattern
        vm.expectRevert("UNAUTHORIZED");

        // Call the function that should revert
        policyManager.setPoolPOLShare(poolId, newPolSharePpm);
        vm.stopPrank();
    }

    function test_Revert_SetPoolPOLShare_WhenPercentageExceedsMaximum() public {
        // Define an invalid POL share percentage that exceeds the maximum (> 100%)
        uint256 invalidPolSharePpm = PrecisionConstants.PPM_SCALE + 1; // 1,000,001 PPM (> 100%)

        // Execute: Attempt to set the excessive POL share as the owner
        vm.startPrank(owner);

        // Expect the transaction to revert with ParameterOutOfRange error
        // The error should contain the invalid value, minimum (0), and maximum (1,000,000 PPM)
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector, invalidPolSharePpm, 0, PrecisionConstants.PPM_SCALE
            )
        );

        // Call the function that should revert
        policyManager.setPoolPOLShare(poolId, invalidPolSharePpm);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                      MANUAL FEE MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Success_SetManualFee_WhenWithinValidRange() public {
        // Setup: Define valid manual fee values within allowed range
        uint24 midValidFee = 3000; // 0.3% (typical fee)

        // Execute: Set the minimum valid fee
        vm.startPrank(owner);

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.ManualFeeSet(poolId, MIN_TRADING_FEE);

        // Call the function
        policyManager.setManualFee(poolId, MIN_TRADING_FEE);

        // Verify: Check that the manual fee was set correctly
        (uint24 fee, bool isSet) = policyManager.getManualFee(poolId);
        assertEq(fee, MIN_TRADING_FEE, "Manual fee not set to minimum valid value");
        assertTrue(isSet, "Manual fee flag should be set");

        // Test functional impact: Perform a swap to verify fee is applied
        // First, set POL share to capture some fees for verification
        policyManager.setPoolPOLShare(poolId, 200_000); // 20%
        spot.setReinvestmentPaused(true); // Pause reinvestment for easier verification
        vm.stopPrank();

        // Check initial pending fees
        (uint256 pendingFee0Before, uint256 pendingFee1Before) = liquidityManager.getPendingFees(poolId);

        // Execute a swap that will generate fees
        vm.startPrank(user1);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1 ether), // Swap 1 ETH of token0 for token1
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        vm.stopPrank();

        // Verify fees were collected using the set manual fee
        (uint256 pendingFee0After, uint256 pendingFee1After) = liquidityManager.getPendingFees(poolId);

        // Calculate expected fee (input amount * fee rate * POL share)
        uint256 inputAmount = 1 ether;
        uint256 expectedFeeAmount = (inputAmount * MIN_TRADING_FEE * 200_000) / (1e6 * 1e6);

        // Assert fees were collected based on the manual fee
        assertGt(pendingFee0After, pendingFee0Before, "Token0 fees should be collected");
        assertApproxEqAbs(
            pendingFee0After - pendingFee0Before,
            expectedFeeAmount,
            2, // Small allowance for rounding
            "Collected fee doesn't match expected amount"
        );

        // Now test with mid-range fee
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.ManualFeeSet(poolId, midValidFee);
        policyManager.setManualFee(poolId, midValidFee);
        vm.stopPrank();

        // Verify mid-range fee was set correctly
        (fee, isSet) = policyManager.getManualFee(poolId);
        assertEq(fee, midValidFee, "Manual fee not set to mid-range valid value");
        assertTrue(isSet, "Manual fee flag should be set");

        // Finally test with maximum fee
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.ManualFeeSet(poolId, MAX_TRADING_FEE);
        policyManager.setManualFee(poolId, MAX_TRADING_FEE);
        vm.stopPrank();

        // Verify maximum fee was set correctly
        (fee, isSet) = policyManager.getManualFee(poolId);
        assertEq(fee, MAX_TRADING_FEE, "Manual fee not set to maximum valid value");
        assertTrue(isSet, "Manual fee flag should be set");
    }

    function test_Success_ClearManualFee_WhenFeeExists() public {
        // Setup: First set a manual fee so we have something to clear
        uint24 initialFee = 3000; // 0.3%

        vm.startPrank(owner);
        policyManager.setManualFee(poolId, initialFee);
        vm.stopPrank();

        // Verify setup worked correctly
        (uint24 fee, bool isSet) = policyManager.getManualFee(poolId);
        assertEq(fee, initialFee, "Initial manual fee setup failed");
        assertTrue(isSet, "Manual fee flag should be set after initialization");

        // Execute: Clear the manual fee as the owner
        vm.startPrank(owner);

        // Expect event to be emitted with zero fee value
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.ManualFeeSet(poolId, 0);

        // Call the function to clear the manual fee
        policyManager.clearManualFee(poolId);
        vm.stopPrank();

        // Verify: Check that the manual fee was cleared
        (fee, isSet) = policyManager.getManualFee(poolId);
        assertEq(fee, 0, "Manual fee should be reset to zero");
        assertFalse(isSet, "Manual fee flag should be cleared");

        // Functional verification: Perform a swap to ensure dynamic fees are used instead
        // First set up the environment
        vm.startPrank(owner);

        // Set POL share to capture some fees for verification
        policyManager.setPoolPOLShare(poolId, 200_000); // 20%

        // Configure dynamic fee parameters to be distinguishable from the cleared manual fee
        // For example, set min base fee higher than the manual fee we cleared
        policyManager.setMinBaseFee(poolId, 5000); // 0.5% min base fee
        policyManager.setMaxBaseFee(poolId, 10000); // 1% max base fee

        // Set up dynamic fee manager to use a predictable fee
        // This depends on the implementation, but we can force a specific fee through policy settings

        spot.setReinvestmentPaused(true); // Pause reinvestment for easier verification
        vm.stopPrank();

        // Check current dynamic fee state (may require accessing the dynamic fee manager)
        // This is implementation-specific, but we need to know what fee to expect

        // Check initial pending fees
        (uint256 pendingFee0Before, uint256 pendingFee1Before) = liquidityManager.getPendingFees(poolId);

        // Execute a swap that will generate fees
        vm.startPrank(user1);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1 ether), // Swap 1 ETH of token0 for token1
            sqrtPriceLimitX96: MIN_PRICE_LIMIT
        });

        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        vm.stopPrank();

        // Verify fees were collected using the dynamic fee (not the cleared manual fee)
        (uint256 pendingFee0After, uint256 pendingFee1After) = liquidityManager.getPendingFees(poolId);

        // Assert fees were collected (we can't easily predict the exact amount since it's using dynamic fees)
        assertGt(pendingFee0After, pendingFee0Before, "Token0 fees should be collected");

        // The collected fee should be based on at least the minimum base fee (5000) we set
        // which is higher than the cleared manual fee (3000)
        uint256 inputAmount = 1 ether;
        uint256 minExpectedFeeAmount = (inputAmount * 5000 * 200_000) / (1e6 * 1e6);

        // The actual collected fee should be at least the minimum expected
        assertGe(
            pendingFee0After - pendingFee0Before,
            minExpectedFeeAmount,
            "Collected fee should be based on dynamic fee, not cleared manual fee"
        );
    }

    function test_Revert_SetManualFee_WhenCalledByNonOwner() public {
        // Setup: Define a valid manual fee
        uint24 validFee = 3000; // 0.3%

        // Get the initial manual fee state to verify no change happens
        (uint24 initialFee, bool initialIsSet) = policyManager.getManualFee(poolId);

        // Execute: Attempt to set the manual fee as a non-owner account (user1)
        vm.startPrank(user1);

        // Expect the transaction to revert because only the owner can call this function
        // The error comes from Solmate's Owned contract which uses a custom error pattern
        vm.expectRevert("UNAUTHORIZED");

        // Call the function that should revert
        policyManager.setManualFee(poolId, validFee);
        vm.stopPrank();

        // Verify: Check that the manual fee state was not changed
        (uint24 currentFee, bool currentIsSet) = policyManager.getManualFee(poolId);
        assertEq(currentFee, initialFee, "Manual fee should not have changed");
        assertEq(currentIsSet, initialIsSet, "Manual fee flag should not have changed");

        // Verification: Confirm the owner can still set the value (positive control)
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, validFee);
        vm.stopPrank();

        // Verify the owner successfully changed the value
        (currentFee, currentIsSet) = policyManager.getManualFee(poolId);
        assertEq(currentFee, validFee, "Owner should be able to set manual fee");
        assertTrue(currentIsSet, "Manual fee flag should be set by owner");
    }

    function test_Revert_ClearManualFee_WhenCalledByNonOwner() public {
        // Setup: First set a manual fee so we have something to clear
        uint24 initialFee = 3000; // 0.3%

        vm.startPrank(owner);
        policyManager.setManualFee(poolId, initialFee);
        vm.stopPrank();

        // Verify setup worked correctly
        (uint24 fee, bool isSet) = policyManager.getManualFee(poolId);
        assertEq(fee, initialFee, "Initial manual fee setup failed");
        assertTrue(isSet, "Manual fee flag should be set after initialization");

        // Execute: Attempt to clear the manual fee as a non-owner account (user1)
        vm.startPrank(user1);

        // Expect the transaction to revert because only the owner can call this function
        vm.expectRevert("UNAUTHORIZED");

        // Call the function that should revert
        policyManager.clearManualFee(poolId);
        vm.stopPrank();

        // Verify: Check that the manual fee state was not changed
        (fee, isSet) = policyManager.getManualFee(poolId);
        assertEq(fee, initialFee, "Manual fee should not have changed");
        assertTrue(isSet, "Manual fee flag should still be set");

        // Verification: Confirm the owner can still clear the value (positive control)
        vm.startPrank(owner);
        policyManager.clearManualFee(poolId);
        vm.stopPrank();

        // Verify the owner successfully cleared the value
        (fee, isSet) = policyManager.getManualFee(poolId);
        assertEq(fee, 0, "Owner should be able to clear manual fee");
        assertFalse(isSet, "Manual fee flag should be cleared by owner");
    }

    function test_Revert_SetManualFee_WhenBelowMinimum() public {
        // Setup: Define fee values below the minimum allowed (10 = 0.001%)
        uint24 belowMinFee1 = 9; // Just below minimum
        uint24 belowMinFee2 = 5; // Half of minimum
        uint24 belowMinFee3 = 0; // Zero

        // Get the initial manual fee state to verify no change happens
        (uint24 initialFee, bool initialIsSet) = policyManager.getManualFee(poolId);

        // Execute: Attempt to set a fee just below the minimum
        vm.startPrank(owner);

        // Expect the transaction to revert with ParameterOutOfRange error
        // The error should contain the invalid value, minimum (10), and maximum (100,000)
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                belowMinFee1,
                10, // MIN_TRADING_FEE
                100_000 // MAX_TRADING_FEE
            )
        );

        // Call the function that should revert
        policyManager.setManualFee(poolId, belowMinFee1);

        // Attempt to set a fee at half the minimum
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                belowMinFee2,
                10, // MIN_TRADING_FEE
                100_000 // MAX_TRADING_FEE
            )
        );

        policyManager.setManualFee(poolId, belowMinFee2);

        // Attempt to set a zero fee
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                belowMinFee3,
                10, // MIN_TRADING_FEE
                100_000 // MAX_TRADING_FEE
            )
        );

        policyManager.setManualFee(poolId, belowMinFee3);
        vm.stopPrank();

        // Verify: Check that the manual fee state was not changed
        (uint24 currentFee, bool currentIsSet) = policyManager.getManualFee(poolId);
        assertEq(currentFee, initialFee, "Manual fee should not have changed");
        assertEq(currentIsSet, initialIsSet, "Manual fee flag should not have changed");

        // Verification: Confirm that the minimum value can be set (boundary test)
        uint24 minValidFee = 10; // Minimum allowed fee (0.001%)

        vm.startPrank(owner);
        policyManager.setManualFee(poolId, minValidFee);
        vm.stopPrank();

        // Verify the minimum fee was set correctly
        (currentFee, currentIsSet) = policyManager.getManualFee(poolId);
        assertEq(currentFee, minValidFee, "Minimum valid fee should be settable");
        assertTrue(currentIsSet, "Manual fee flag should be set for minimum valid fee");
    }

    function test_Revert_SetManualFee_WhenAboveMaximum() public {
        // Setup: Define fee values above the maximum allowed (100,000 = 10%)
        uint24 aboveMaxFee1 = 100_001; // Just above maximum
        uint24 aboveMaxFee2 = 200_000; // Double the maximum
        uint24 aboveMaxFee3 = type(uint24).max; // Maximum uint24 value

        // Get the initial manual fee state to verify no change happens
        (uint24 initialFee, bool initialIsSet) = policyManager.getManualFee(poolId);

        // Execute: Attempt to set a fee just above the maximum
        vm.startPrank(owner);

        // Expect the transaction to revert with ParameterOutOfRange error
        // The error should contain the invalid value, minimum (10), and maximum (100,000)
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                aboveMaxFee1,
                10, // MIN_TRADING_FEE
                100_000 // MAX_TRADING_FEE
            )
        );

        // Call the function that should revert
        policyManager.setManualFee(poolId, aboveMaxFee1);

        // Attempt to set a fee at double the maximum
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                aboveMaxFee2,
                10, // MIN_TRADING_FEE
                100_000 // MAX_TRADING_FEE
            )
        );

        policyManager.setManualFee(poolId, aboveMaxFee2);

        // Attempt to set an extremely high fee (max uint24)
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                aboveMaxFee3,
                10, // MIN_TRADING_FEE
                100_000 // MAX_TRADING_FEE
            )
        );

        policyManager.setManualFee(poolId, aboveMaxFee3);
        vm.stopPrank();

        // Verify: Check that the manual fee state was not changed
        (uint24 currentFee, bool currentIsSet) = policyManager.getManualFee(poolId);
        assertEq(currentFee, initialFee, "Manual fee should not have changed");
        assertEq(currentIsSet, initialIsSet, "Manual fee flag should not have changed");

        // Verification: Confirm that the maximum value can be set (boundary test)
        uint24 maxValidFee = 100_000; // Maximum allowed fee (10%)

        vm.startPrank(owner);
        policyManager.setManualFee(poolId, maxValidFee);
        vm.stopPrank();

        // Verify the maximum fee was set correctly
        (currentFee, currentIsSet) = policyManager.getManualFee(poolId);
        assertEq(currentFee, maxValidFee, "Maximum valid fee should be settable");
        assertTrue(currentIsSet, "Manual fee flag should be set for maximum valid fee");
    }

    /*//////////////////////////////////////////////////////////////
                    MIN/MAX BASE FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Success_SetMinBaseFee_WhenWithinValidRange() public {
        // Setup: Define valid minimum base fee values
        uint24 minValidBaseFee = 100; // 0.01% (global minimum allowed)
        uint24 midValidBaseFee = 1000; // 0.1% (typical minimum)

        // Set the max base fee first to ensure we can set min fees below it
        uint24 maxBaseFee = 10000; // 1% (for testing)

        vm.startPrank(owner);
        policyManager.setMaxBaseFee(poolId, maxBaseFee);
        vm.stopPrank();

        // Get initial state
        uint24 initialMinBaseFee = policyManager.getMinBaseFee(poolId);

        // For the first test, use a value different from the default
        // since the default is already 100 (MIN_TRADING_FEE)
        uint24 firstTestValue = 200; // 0.02%, different from default

        // Execute: Set a minimum base fee value
        vm.startPrank(owner);

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.MinBaseFeeSet(poolId, firstTestValue);

        // Call the function
        policyManager.setMinBaseFee(poolId, firstTestValue);

        // Verify: Check that the minimum base fee was set correctly
        uint24 updatedMinBaseFee = policyManager.getMinBaseFee(poolId);

        // Assert the value was changed from initial value
        assertNotEq(updatedMinBaseFee, initialMinBaseFee, "Min base fee should have changed");

        // Assert the value matches what we set
        assertEq(updatedMinBaseFee, firstTestValue, "Min base fee not set to expected value");

        // Functional verification: Test setting a mid-range value
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.MinBaseFeeSet(poolId, midValidBaseFee);

        // Call the function with mid-range value
        policyManager.setMinBaseFee(poolId, midValidBaseFee);

        // Verify mid-range value was set correctly
        updatedMinBaseFee = policyManager.getMinBaseFee(poolId);
        assertEq(updatedMinBaseFee, midValidBaseFee, "Min base fee not set to mid-range value");

        // Test edge case: Set min fee to just below max fee
        uint24 justBelowMaxFee = maxBaseFee - 1;

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.MinBaseFeeSet(poolId, justBelowMaxFee);

        // Call the function with value just below max fee
        policyManager.setMinBaseFee(poolId, justBelowMaxFee);

        // Verify value just below max was set correctly
        updatedMinBaseFee = policyManager.getMinBaseFee(poolId);
        assertEq(updatedMinBaseFee, justBelowMaxFee, "Min base fee not set to value just below max");

        // Finally, test that we can set it back to the minimum valid value
        // This is technically different from the default, as we're explicitly setting it
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.MinBaseFeeSet(poolId, minValidBaseFee);

        policyManager.setMinBaseFee(poolId, minValidBaseFee);

        updatedMinBaseFee = policyManager.getMinBaseFee(poolId);
        assertEq(updatedMinBaseFee, minValidBaseFee, "Min base fee not set to minimum valid value");

        vm.stopPrank();
    }

    function test_Success_SetMaxBaseFee_WhenWithinValidRange() public {
        // Setup: Define valid maximum base fee values
        uint24 midValidMaxFee = 25000; // 2.5% (mid-range)
        uint24 highValidMaxFee = 49999; // 4.9999% (just below max)
        uint24 maxValidMaxFee = 50000; // 5% (global maximum allowed)

        // Get initial state
        uint24 initialMaxBaseFee = policyManager.getMaxBaseFee(poolId);

        // Execute: Set a mid-range maximum base fee
        vm.startPrank(owner);

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.MaxBaseFeeSet(poolId, midValidMaxFee);

        // Call the function
        policyManager.setMaxBaseFee(poolId, midValidMaxFee);

        // Verify: Check that the maximum base fee was set correctly
        uint24 updatedMaxBaseFee = policyManager.getMaxBaseFee(poolId);

        // Assert the value was changed from initial value
        assertNotEq(updatedMaxBaseFee, initialMaxBaseFee, "Max base fee should have changed");

        // Assert the value matches what we set
        assertEq(updatedMaxBaseFee, midValidMaxFee, "Max base fee not set to expected value");

        // Functional verification: Test setting a value near the maximum
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.MaxBaseFeeSet(poolId, highValidMaxFee);

        // Call the function with high value
        policyManager.setMaxBaseFee(poolId, highValidMaxFee);

        // Verify high value was set correctly
        updatedMaxBaseFee = policyManager.getMaxBaseFee(poolId);
        assertEq(updatedMaxBaseFee, highValidMaxFee, "Max base fee not set to high value");

        // Test setting the maximum allowed value
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.MaxBaseFeeSet(poolId, maxValidMaxFee);

        // Call the function with maximum allowed value
        policyManager.setMaxBaseFee(poolId, maxValidMaxFee);

        // Verify maximum value was set correctly
        updatedMaxBaseFee = policyManager.getMaxBaseFee(poolId);
        assertEq(updatedMaxBaseFee, maxValidMaxFee, "Max base fee not set to maximum allowed value");

        // Test the interaction with minimum base fee
        // Set a specific minimum base fee
        uint24 specificMinFee = 5000; // 0.5%
        policyManager.setMinBaseFee(poolId, specificMinFee);

        // Now set a max fee that's higher than this min fee
        uint24 higherThanMinFee = 20000; // 2%

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.MaxBaseFeeSet(poolId, higherThanMinFee);

        // Call the function
        policyManager.setMaxBaseFee(poolId, higherThanMinFee);

        // Verify value was set correctly
        updatedMaxBaseFee = policyManager.getMaxBaseFee(poolId);
        assertEq(updatedMaxBaseFee, higherThanMinFee, "Max base fee not set correctly relative to min fee");

        vm.stopPrank();
    }

    function test_Revert_SetMinBaseFee_WhenCalledByNonOwner() public {
        // Setup: Define a valid minimum base fee
        uint24 validMinBaseFee = 500; // 0.05%

        // Get the initial min base fee value to verify no change happens
        uint24 initialMinBaseFee = policyManager.getMinBaseFee(poolId);

        // Execute: Attempt to set the minimum base fee as a non-owner account (user1)
        vm.startPrank(user1);

        // Expect the transaction to revert because only the owner can call this function
        // The error comes from Solmate's Owned contract which uses a custom error pattern
        vm.expectRevert("UNAUTHORIZED");

        // Call the function that should revert
        policyManager.setMinBaseFee(poolId, validMinBaseFee);
        vm.stopPrank();

        // Verify: Check that the minimum base fee was not changed
        uint24 currentMinBaseFee = policyManager.getMinBaseFee(poolId);
        assertEq(currentMinBaseFee, initialMinBaseFee, "Min base fee should not have changed");

        // Verification: Confirm the owner can still set the value
        vm.startPrank(owner);
        policyManager.setMinBaseFee(poolId, validMinBaseFee);
        vm.stopPrank();

        // Verify the owner successfully changed the value
        currentMinBaseFee = policyManager.getMinBaseFee(poolId);
        assertEq(currentMinBaseFee, validMinBaseFee, "Owner should be able to set min base fee");
    }

    function test_Revert_SetMaxBaseFee_WhenCalledByNonOwner() public {
        // Setup: Define a valid maximum base fee
        uint24 validMaxBaseFee = 25000; // 2.5%

        // Get the initial max base fee value to verify no change happens
        uint24 initialMaxBaseFee = policyManager.getMaxBaseFee(poolId);

        // Execute: Attempt to set the maximum base fee as a non-owner account (user1)
        vm.startPrank(user1);

        // Expect the transaction to revert because only the owner can call this function
        // The error comes from Solmate's Owned contract which uses a custom error pattern
        vm.expectRevert("UNAUTHORIZED");

        // Call the function that should revert
        policyManager.setMaxBaseFee(poolId, validMaxBaseFee);
        vm.stopPrank();

        // Execute: Attempt to set the maximum base fee as another non-owner account (user2)
        vm.startPrank(user2);

        // Expect the same revert for any non-owner account
        vm.expectRevert("UNAUTHORIZED");

        // Call the function that should revert
        policyManager.setMaxBaseFee(poolId, validMaxBaseFee);
        vm.stopPrank();

        // Verify: Check that the maximum base fee was not changed
        uint24 currentMaxBaseFee = policyManager.getMaxBaseFee(poolId);
        assertEq(currentMaxBaseFee, initialMaxBaseFee, "Max base fee should not have changed");

        // Verification: Confirm the owner can still set the value
        vm.startPrank(owner);
        policyManager.setMaxBaseFee(poolId, validMaxBaseFee);
        vm.stopPrank();

        // Verify the owner successfully changed the value
        currentMaxBaseFee = policyManager.getMaxBaseFee(poolId);
        assertEq(currentMaxBaseFee, validMaxBaseFee, "Owner should be able to set max base fee");
    }

    function test_Revert_SetMinBaseFee_WhenBelowMinimumAllowed() public {
        // Setup: Define fee values below the absolute minimum allowed (10 = 0.001%)
        uint24 belowMinFee1 = 9; // Just below minimum
        uint24 belowMinFee2 = 5; // Half of minimum
        uint24 belowMinFee3 = 0; // Zero

        // Get the initial min base fee value to verify no change happens
        uint24 initialMinBaseFee = policyManager.getMinBaseFee(poolId);

        // Execute: Attempt to set a fee just below the minimum
        vm.startPrank(owner);

        // Expect the transaction to revert with InvalidFeeRange error
        // The error should contain the invalid value, minimum (100), and maximum (the current max fee)
        uint24 currentMaxFee = policyManager.getMaxBaseFee(poolId);

        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManagerErrors.InvalidFeeRange.selector,
                belowMinFee1,
                10, // MIN_TRADING_FEE
                currentMaxFee
            )
        );

        // Call the function that should revert
        policyManager.setMinBaseFee(poolId, belowMinFee1);

        // Attempt to set a fee at half the minimum
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManagerErrors.InvalidFeeRange.selector,
                belowMinFee2,
                10, // MIN_TRADING_FEE
                currentMaxFee
            )
        );

        policyManager.setMinBaseFee(poolId, belowMinFee2);

        // Attempt to set a zero fee
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManagerErrors.InvalidFeeRange.selector,
                belowMinFee3,
                10, // MIN_TRADING_FEE
                currentMaxFee
            )
        );

        policyManager.setMinBaseFee(poolId, belowMinFee3);
        vm.stopPrank();

        // Verify: Check that the min base fee state was not changed
        uint24 currentMinBaseFee = policyManager.getMinBaseFee(poolId);
        assertEq(currentMinBaseFee, initialMinBaseFee, "Min base fee should not have changed");

        // Verification: Confirm that the minimum value can be set (boundary test)
        uint24 minValidFee = 10; // Minimum allowed fee (0.001%)

        vm.startPrank(owner);
        policyManager.setMinBaseFee(poolId, minValidFee);
        vm.stopPrank();

        // Verify the minimum fee was set correctly
        currentMinBaseFee = policyManager.getMinBaseFee(poolId);
        assertEq(currentMinBaseFee, minValidFee, "Minimum valid fee should be settable");
    }

    function test_Revert_SetMinBaseFee_WhenAboveOrEqualToMaxFee() public {
        // Setup: First set a specific max fee to test against
        uint24 specificMaxFee = 8000; // 0.8%

        vm.startPrank(owner);
        policyManager.setMaxBaseFee(poolId, specificMaxFee);
        vm.stopPrank();

        // Verify setup worked correctly
        uint24 currentMaxFee = policyManager.getMaxBaseFee(poolId);
        assertEq(currentMaxFee, specificMaxFee, "Max fee setup failed");

        // Get the initial min base fee value to verify no change happens
        uint24 initialMinBaseFee = policyManager.getMinBaseFee(poolId);

        // Define test cases: equal to max and above max
        uint24 equalToMaxFee = specificMaxFee; // Equal to max (0.8%)
        uint24 slightlyAboveMaxFee = specificMaxFee + 1; // Just above max
        uint24 wayAboveMaxFee = specificMaxFee * 2; // Far above max

        // Execute: Attempt to set min fee equal to max fee
        vm.startPrank(owner);

        // Should NOT revert if we attempt to set min fee to max fee
        policyManager.setMinBaseFee(poolId, equalToMaxFee);

        // reset minBaseFee
        policyManager.setMinBaseFee(poolId, initialMinBaseFee);

        // - - -

        // Attempt to set min fee slightly above max fee
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManagerErrors.InvalidFeeRange.selector,
                slightlyAboveMaxFee,
                10, // MIN_TRADING_FEE
                specificMaxFee
            )
        );

        policyManager.setMinBaseFee(poolId, slightlyAboveMaxFee);

        // Attempt to set min fee way above max fee
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManagerErrors.InvalidFeeRange.selector,
                wayAboveMaxFee,
                10, // MIN_TRADING_FEE
                specificMaxFee
            )
        );

        policyManager.setMinBaseFee(poolId, wayAboveMaxFee);
        vm.stopPrank();

        // Verify: Check that the min base fee state was not changed
        uint24 currentMinBaseFee = policyManager.getMinBaseFee(poolId);
        assertEq(currentMinBaseFee, initialMinBaseFee, "Min base fee should not have changed");

        // Verification: Confirm that a value just below max can be set (boundary test)
        uint24 justBelowMaxFee = specificMaxFee - 1; // 0.799%

        vm.startPrank(owner);
        policyManager.setMinBaseFee(poolId, justBelowMaxFee);
        vm.stopPrank();

        // Verify the fee just below max was set correctly
        currentMinBaseFee = policyManager.getMinBaseFee(poolId);
        assertEq(currentMinBaseFee, justBelowMaxFee, "Min fee just below max should be settable");
    }

    function test_Revert_SetMaxBaseFee_WhenBelowMinFee() public {
        // Setup: First set a specific min fee to test against
        uint24 specificMinFee = 5000; // 0.5%

        vm.startPrank(owner);
        policyManager.setMinBaseFee(poolId, specificMinFee);
        vm.stopPrank();

        // Verify setup worked correctly
        uint24 currentMinFee = policyManager.getMinBaseFee(poolId);
        assertEq(currentMinFee, specificMinFee, "Min fee setup failed");

        // Get the initial max base fee value to verify no change happens
        uint24 initialMaxBaseFee = policyManager.getMaxBaseFee(poolId);

        // Define test cases: below min fee
        uint24 wayBelowMinFee = specificMinFee / 2; // Half of min fee
        uint24 slightlyBelowMinFee = specificMinFee - 1; // Just below min fee

        // Execute: Attempt to set max fee way below min fee
        vm.startPrank(owner);

        // Expect the transaction to revert with InvalidFeeRange error
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManagerErrors.InvalidFeeRange.selector,
                wayBelowMinFee,
                specificMinFee,
                100_000 // MAX_TRADING_FEE
            )
        );

        // Call the function that should revert
        policyManager.setMaxBaseFee(poolId, wayBelowMinFee);

        // Attempt to set max fee slightly below min fee
        vm.expectRevert(
            abi.encodeWithSelector(
                PolicyManagerErrors.InvalidFeeRange.selector,
                slightlyBelowMinFee,
                specificMinFee,
                100_000 // MAX_TRADING_FEE
            )
        );

        policyManager.setMaxBaseFee(poolId, slightlyBelowMinFee);
        vm.stopPrank();

        // Verify: Check that the max base fee state was not changed
        uint24 currentMaxBaseFee = policyManager.getMaxBaseFee(poolId);
        assertEq(currentMaxBaseFee, initialMaxBaseFee, "Max base fee should not have changed");

        // Verification: Confirm that a value equal to min fee can be set (boundary test)
        vm.startPrank(owner);
        policyManager.setMaxBaseFee(poolId, specificMinFee);
        vm.stopPrank();

        // Verify the fee equal to min was set correctly
        currentMaxBaseFee = policyManager.getMaxBaseFee(poolId);
        assertEq(currentMaxBaseFee, specificMinFee, "Max fee equal to min should be settable");

        // Verification: Confirm that a value above min fee can be set
        uint24 aboveMinFee = specificMinFee + 1000; // 0.6%

        vm.startPrank(owner);
        policyManager.setMaxBaseFee(poolId, aboveMinFee);
        vm.stopPrank();

        // Verify the fee above min was set correctly
        currentMaxBaseFee = policyManager.getMaxBaseFee(poolId);
        assertEq(currentMaxBaseFee, aboveMinFee, "Max fee above min should be settable");
    }

    /*//////////////////////////////////////////////////////////////
                    SURGE FEE PARAMETER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Success_SetSurgeDecayPeriodSeconds_WhenWithinValidRange() public {
        // Setup: Define valid surge decay period values
        uint32 minValidPeriod = 60; // 60 seconds (minimum allowed)
        uint32 midValidPeriod = 3600; // 1 hour (typical)
        uint32 maxValidPeriod = 1 days; // 1 day (maximum allowed)

        // Get initial state for verification
        uint32 initialDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);

        // Execute: Set the minimum valid decay period
        vm.startPrank(owner);

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.SurgeDecayPeriodSet(poolId, minValidPeriod);

        // Call the function
        policyManager.setSurgeDecayPeriodSeconds(poolId, minValidPeriod);

        // Verify: Check that the decay period was set correctly
        uint32 updatedDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);

        // Assert the value matches what we set
        assertEq(updatedDecayPeriod, minValidPeriod, "Decay period not set to minimum valid value");

        // Test with mid-range value
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.SurgeDecayPeriodSet(poolId, midValidPeriod);

        // Call the function with mid-range value
        policyManager.setSurgeDecayPeriodSeconds(poolId, midValidPeriod);

        // Verify mid-range value was set correctly
        updatedDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);
        assertEq(updatedDecayPeriod, midValidPeriod, "Decay period not set to mid-range value");

        // Test with maximum value
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.SurgeDecayPeriodSet(poolId, maxValidPeriod);

        // Call the function with maximum value
        policyManager.setSurgeDecayPeriodSeconds(poolId, maxValidPeriod);

        // Verify maximum value was set correctly
        updatedDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);
        assertEq(updatedDecayPeriod, maxValidPeriod, "Decay period not set to maximum valid value");

        // Additional test: Set a custom value that's between min and max
        uint32 customPeriod = 12 hours; // 12 hours

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.SurgeDecayPeriodSet(poolId, customPeriod);

        // Call the function with custom value
        policyManager.setSurgeDecayPeriodSeconds(poolId, customPeriod);

        // Verify custom value was set correctly
        updatedDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);
        assertEq(updatedDecayPeriod, customPeriod, "Decay period not set to custom value");

        vm.stopPrank();
    }

    function test_Success_SetSurgeFeeMultiplierPpm_WhenWithinValidRange() public {
        // Setup: Define valid surge fee multiplier values
        uint24 minValidMultiplier = 1; // Minimum allowed (0.0001%)
        uint24 lowValidMultiplier = 100_000; // 10%
        uint24 midValidMultiplier = 1_000_000; // 100%
        uint24 highValidMultiplier = 2_000_000; // 200%
        uint24 maxValidMultiplier = 3_000_000; // 300% (maximum allowed)

        // Get initial state for verification
        uint24 initialMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);

        // Execute: Set the minimum valid multiplier
        vm.startPrank(owner);

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.SurgeFeeMultiplierSet(poolId, minValidMultiplier);

        // Call the function
        policyManager.setSurgeFeeMultiplierPpm(poolId, minValidMultiplier);

        // Verify: Check that the multiplier was set correctly
        uint24 updatedMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);

        // Assert the value matches what we set
        assertEq(updatedMultiplier, minValidMultiplier, "Multiplier not set to minimum valid value");

        // Test with low value (10%)
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.SurgeFeeMultiplierSet(poolId, lowValidMultiplier);

        // Call the function with low value
        policyManager.setSurgeFeeMultiplierPpm(poolId, lowValidMultiplier);

        // Verify low value was set correctly
        updatedMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);
        assertEq(updatedMultiplier, lowValidMultiplier, "Multiplier not set to low valid value");

        // Test with mid-range value (100%)
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.SurgeFeeMultiplierSet(poolId, midValidMultiplier);

        // Call the function with mid-range value
        policyManager.setSurgeFeeMultiplierPpm(poolId, midValidMultiplier);

        // Verify mid-range value was set correctly
        updatedMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);
        assertEq(updatedMultiplier, midValidMultiplier, "Multiplier not set to mid-range value");

        // Test with high value (200%)
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.SurgeFeeMultiplierSet(poolId, highValidMultiplier);

        // Call the function with high value
        policyManager.setSurgeFeeMultiplierPpm(poolId, highValidMultiplier);

        // Verify high value was set correctly
        updatedMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);
        assertEq(updatedMultiplier, highValidMultiplier, "Multiplier not set to high value");

        // Test with maximum value (300%)
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.SurgeFeeMultiplierSet(poolId, maxValidMultiplier);

        // Call the function with maximum value
        policyManager.setSurgeFeeMultiplierPpm(poolId, maxValidMultiplier);

        // Verify maximum value was set correctly
        updatedMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);
        assertEq(updatedMultiplier, maxValidMultiplier, "Multiplier not set to maximum valid value");

        vm.stopPrank();
    }

    function test_Revert_SetSurgeDecayPeriodSeconds_WhenCalledByNonOwner() public {
        // Setup: Define a valid surge decay period
        uint32 validDecayPeriod = 1800; // 30 minutes

        // Get the initial decay period value to verify no change happens
        uint32 initialDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);

        // Execute: Attempt to set the decay period as a non-owner account (user1)
        vm.startPrank(user1);

        // Expect the transaction to revert because only the owner can call this function
        // The error comes from Solmate's Owned contract which uses a custom error pattern
        vm.expectRevert("UNAUTHORIZED");

        // Call the function that should revert
        policyManager.setSurgeDecayPeriodSeconds(poolId, validDecayPeriod);
        vm.stopPrank();

        // Execute: Attempt to set the decay period as another non-owner account (user2)
        vm.startPrank(user2);

        // Expect the same revert for any non-owner account
        vm.expectRevert("UNAUTHORIZED");

        // Call the function that should revert
        policyManager.setSurgeDecayPeriodSeconds(poolId, validDecayPeriod);
        vm.stopPrank();

        // Verify: Check that the decay period was not changed
        uint32 currentDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);
        assertEq(currentDecayPeriod, initialDecayPeriod, "Decay period should not have changed");

        // Verification: Confirm the owner can still set the value
        vm.startPrank(owner);
        policyManager.setSurgeDecayPeriodSeconds(poolId, validDecayPeriod);
        vm.stopPrank();

        // Verify the owner successfully changed the value
        currentDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);
        assertEq(currentDecayPeriod, validDecayPeriod, "Owner should be able to set decay period");
    }

    function test_Revert_SetSurgeFeeMultiplierPpm_WhenCalledByNonOwner() public {
        // Setup: Define a valid surge fee multiplier
        uint24 validMultiplier = 500_000; // 50%

        // Get the initial multiplier value to verify no change happens
        uint24 initialMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);

        // Execute: Attempt to set the multiplier as a non-owner account (user1)
        vm.startPrank(user1);

        // Expect the transaction to revert because only the owner can call this function
        // The error comes from Solmate's Owned contract which uses a custom error pattern
        vm.expectRevert("UNAUTHORIZED");

        // Call the function that should revert
        policyManager.setSurgeFeeMultiplierPpm(poolId, validMultiplier);
        vm.stopPrank();

        // Verify: Check that the multiplier was not changed
        uint24 currentMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);
        assertEq(currentMultiplier, initialMultiplier, "Surge fee multiplier should not have changed");

        // Verification: Confirm the owner can still set the value
        vm.startPrank(owner);
        policyManager.setSurgeFeeMultiplierPpm(poolId, validMultiplier);
        vm.stopPrank();

        // Verify the owner successfully changed the value
        currentMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);
        assertEq(currentMultiplier, validMultiplier, "Owner should be able to set surge fee multiplier");
    }

    function test_Revert_SetSurgeDecayPeriodSeconds_WhenBelowMinimum() public {
        // Setup: Define surge decay period values below the minimum allowed (60 seconds)
        uint32 belowMinPeriod1 = 59; // Just below minimum
        uint32 belowMinPeriod2 = 30; // Half of minimum
        uint32 belowMinPeriod3 = 0; // Zero

        // Get the initial decay period value to verify no change happens
        uint32 initialDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);

        // Execute: Attempt to set a period just below the minimum
        vm.startPrank(owner);

        // Expect the transaction to revert with ParameterOutOfRange error
        // The error should contain the invalid value, minimum (60), and maximum (1 day)
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                belowMinPeriod1,
                60, // Minimum (60 seconds)
                1 days // Maximum (1 day)
            )
        );

        // Call the function that should revert
        policyManager.setSurgeDecayPeriodSeconds(poolId, belowMinPeriod1);

        // Attempt to set a period at half the minimum
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                belowMinPeriod2,
                60, // Minimum (60 seconds)
                1 days // Maximum (1 day)
            )
        );

        policyManager.setSurgeDecayPeriodSeconds(poolId, belowMinPeriod2);

        // Attempt to set a zero period
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                belowMinPeriod3,
                60, // Minimum (60 seconds)
                1 days // Maximum (1 day)
            )
        );

        policyManager.setSurgeDecayPeriodSeconds(poolId, belowMinPeriod3);
        vm.stopPrank();

        // Verify: Check that the decay period was not changed
        uint32 currentDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);
        assertEq(currentDecayPeriod, initialDecayPeriod, "Decay period should not have changed");

        // Verification: Confirm that the minimum value can be set (boundary test)
        uint32 minValidPeriod = 60; // Minimum allowed (60 seconds)

        vm.startPrank(owner);
        policyManager.setSurgeDecayPeriodSeconds(poolId, minValidPeriod);
        vm.stopPrank();

        // Verify the minimum period was set correctly
        currentDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);
        assertEq(currentDecayPeriod, minValidPeriod, "Minimum valid period should be settable");
    }

    function test_Revert_SetSurgeDecayPeriodSeconds_WhenAboveMaximum() public {
        // Setup: Define surge decay period values above the maximum allowed (1 day)
        uint32 justAboveMaxPeriod = 1 days + 1; // Just above maximum
        uint32 slightlyAboveMaxPeriod = 1 days + 3600; // 1 hour above maximum
        uint32 farAboveMaxPeriod = 7 days; // Far above maximum

        // Get the initial decay period value to verify no change happens
        uint32 initialDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);

        // Execute: Attempt to set a period just above the maximum
        vm.startPrank(owner);

        // Expect the transaction to revert with ParameterOutOfRange error
        // The error should contain the invalid value, minimum (60), and maximum (1 day)
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                justAboveMaxPeriod,
                60, // Minimum (60 seconds)
                1 days // Maximum (1 day)
            )
        );

        // Call the function that should revert
        policyManager.setSurgeDecayPeriodSeconds(poolId, justAboveMaxPeriod);

        // Attempt to set a period slightly above the maximum
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                slightlyAboveMaxPeriod,
                60, // Minimum (60 seconds)
                1 days // Maximum (1 day)
            )
        );

        policyManager.setSurgeDecayPeriodSeconds(poolId, slightlyAboveMaxPeriod);

        // Attempt to set a period far above the maximum
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                farAboveMaxPeriod,
                60, // Minimum (60 seconds)
                1 days // Maximum (1 day)
            )
        );

        policyManager.setSurgeDecayPeriodSeconds(poolId, farAboveMaxPeriod);
        vm.stopPrank();

        // Verify: Check that the decay period was not changed
        uint32 currentDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);
        assertEq(currentDecayPeriod, initialDecayPeriod, "Decay period should not have changed");

        // Verification: Confirm that the maximum value can be set (boundary test)
        uint32 maxValidPeriod = 1 days; // Maximum allowed (1 day)

        vm.startPrank(owner);
        policyManager.setSurgeDecayPeriodSeconds(poolId, maxValidPeriod);
        vm.stopPrank();

        // Verify the maximum period was set correctly
        currentDecayPeriod = policyManager.getSurgeDecayPeriodSeconds(poolId);
        assertEq(currentDecayPeriod, maxValidPeriod, "Maximum valid period should be settable");
    }

    function test_Revert_SetSurgeFeeMultiplierPpm_WhenZero() public {
        // Setup: Define a zero surge fee multiplier
        uint24 zeroMultiplier = 0; // 0%

        // Get the initial multiplier value to verify no change happens
        uint24 initialMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);

        // Execute: Attempt to set a zero multiplier
        vm.startPrank(owner);

        // Expect the transaction to revert with ParameterOutOfRange error
        // The error should contain the invalid value (0), minimum (1), and maximum (10,000,000)
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                zeroMultiplier,
                1, // Minimum (0.0001%)
                10_000_000 // Maximum (1000%)
            )
        );

        // Call the function that should revert
        policyManager.setSurgeFeeMultiplierPpm(poolId, zeroMultiplier);
        vm.stopPrank();

        // Verify: Check that the multiplier was not changed
        uint24 currentMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);
        assertEq(currentMultiplier, initialMultiplier, "Surge fee multiplier should not have changed");

        // Verification: Confirm that the minimum value (1) can be set (boundary test)
        uint24 minValidMultiplier = 1; // Minimum allowed (0.0001%)

        vm.startPrank(owner);
        policyManager.setSurgeFeeMultiplierPpm(poolId, minValidMultiplier);
        vm.stopPrank();

        // Verify the minimum multiplier was set correctly
        currentMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);
        assertEq(currentMultiplier, minValidMultiplier, "Minimum valid multiplier should be settable");

        // Additional verification: Confirm that a small but non-zero value can be set
        uint24 smallValidMultiplier = 100; // Small but valid (0.01%)

        vm.startPrank(owner);
        policyManager.setSurgeFeeMultiplierPpm(poolId, smallValidMultiplier);
        vm.stopPrank();

        // Verify the small multiplier was set correctly
        currentMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);
        assertEq(currentMultiplier, smallValidMultiplier, "Small valid multiplier should be settable");
    }

    function test_Revert_SetSurgeFeeMultiplierPpm_WhenAboveMaximum() public {
        // Setup: Define surge fee multiplier values above the maximum allowed (10,000,000 = 1000%)
        uint24 justAboveMaxMultiplier = 10_000_001; // Just above maximum
        uint24 slightlyAboveMaxMultiplier = 15_000_000; // 1500% (50% above maximum)
        uint24 farAboveMaxMultiplier = 15_000_000; // 1500% (far above maximum)

        // Get the initial multiplier value to verify no change happens
        uint24 initialMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);

        // Execute: Attempt to set a multiplier just above the maximum
        vm.startPrank(owner);

        // Expect the transaction to revert with ParameterOutOfRange error
        // The error should contain the invalid value, minimum (1), and maximum (10,000,000)
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                justAboveMaxMultiplier,
                1, // Minimum (0.0001%)
                10_000_000 // Maximum (1000%)
            )
        );

        // Call the function that should revert
        policyManager.setSurgeFeeMultiplierPpm(poolId, justAboveMaxMultiplier);

        // Attempt to set a multiplier slightly above the maximum
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                slightlyAboveMaxMultiplier,
                1, // Minimum (0.0001%)
                10_000_000 // Maximum (1000%)
            )
        );

        policyManager.setSurgeFeeMultiplierPpm(poolId, slightlyAboveMaxMultiplier);

        // Attempt to set a multiplier far above the maximum
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                farAboveMaxMultiplier,
                1, // Minimum (0.0001%)
                10_000_000 // Maximum (1000%)
            )
        );

        policyManager.setSurgeFeeMultiplierPpm(poolId, farAboveMaxMultiplier);
        vm.stopPrank();

        // Verify: Check that the multiplier was not changed
        uint24 currentMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);
        assertEq(currentMultiplier, initialMultiplier, "Surge fee multiplier should not have changed");

        // Verification: Confirm that the maximum value can be set (boundary test)
        uint24 maxValidMultiplier = 10_000_000; // Maximum allowed (1000%)

        vm.startPrank(owner);
        policyManager.setSurgeFeeMultiplierPpm(poolId, maxValidMultiplier);
        vm.stopPrank();

        // Verify the maximum multiplier was set correctly
        currentMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);
        assertEq(currentMultiplier, maxValidMultiplier, "Maximum valid multiplier should be settable");

        // Additional verification: Confirm that a value just below maximum can be set
        uint24 justBelowMaxMultiplier = 9_999_999; // Just below maximum (999.9999%)

        vm.startPrank(owner);
        policyManager.setSurgeFeeMultiplierPpm(poolId, justBelowMaxMultiplier);
        vm.stopPrank();

        // Verify the value just below maximum was set correctly
        currentMultiplier = policyManager.getSurgeFeeMultiplierPpm(poolId);
        assertEq(currentMultiplier, justBelowMaxMultiplier, "Value just below maximum should be settable");
    }

    /*//////////////////////////////////////////////////////////////
                    CAP BUDGET PARAMETER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Success_SetCapBudgetDecayWindow_WhenValidValue() public {
        // Setup: Define valid CAP budget decay window values
        uint32 shortWindow = 86400; // 1 day
        uint32 mediumWindow = 7776000; // 90 days
        uint32 longWindow = 15552000; // 180 days (default value)
        uint32 veryLongWindow = 31536000; // 365 days

        // Get initial state for verification
        uint32 initialDecayWindow = policyManager.getCapBudgetDecayWindow(poolId);

        // Execute: Set a short decay window
        vm.startPrank(owner);

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.CapBudgetDecayWindowSet(poolId, shortWindow);

        // Call the function
        policyManager.setCapBudgetDecayWindow(poolId, shortWindow);

        // Verify: Check that the decay window was set correctly
        uint32 updatedDecayWindow = policyManager.getCapBudgetDecayWindow(poolId);

        // Assert the value matches what we set
        assertEq(updatedDecayWindow, shortWindow, "Decay window not set to short value");

        // Test with medium window
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.CapBudgetDecayWindowSet(poolId, mediumWindow);

        // Call the function with medium window
        policyManager.setCapBudgetDecayWindow(poolId, mediumWindow);

        // Verify medium window was set correctly
        updatedDecayWindow = policyManager.getCapBudgetDecayWindow(poolId);
        assertEq(updatedDecayWindow, mediumWindow, "Decay window not set to medium value");

        // Test with long window (default value)
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.CapBudgetDecayWindowSet(poolId, longWindow);

        // Call the function with long window
        policyManager.setCapBudgetDecayWindow(poolId, longWindow);

        // Verify long window was set correctly
        updatedDecayWindow = policyManager.getCapBudgetDecayWindow(poolId);
        assertEq(updatedDecayWindow, longWindow, "Decay window not set to long value");

        // Test with very long window
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.CapBudgetDecayWindowSet(poolId, veryLongWindow);

        // Call the function with very long window
        policyManager.setCapBudgetDecayWindow(poolId, veryLongWindow);

        // Verify very long window was set correctly
        updatedDecayWindow = policyManager.getCapBudgetDecayWindow(poolId);
        assertEq(updatedDecayWindow, veryLongWindow, "Decay window not set to very long value");

        // Test with minimum allowed value
        uint32 minValidWindow = 1; // 1 second (minimum allowed)

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.CapBudgetDecayWindowSet(poolId, minValidWindow);

        // Call the function with minimum value
        policyManager.setCapBudgetDecayWindow(poolId, minValidWindow);

        // Verify minimum value was set correctly
        updatedDecayWindow = policyManager.getCapBudgetDecayWindow(poolId);
        assertEq(updatedDecayWindow, minValidWindow, "Decay window not set to minimum value");

        // Test with maximum allowed value (uint32 max)
        uint32 maxValidWindow = type(uint32).max; // Maximum uint32 value

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.CapBudgetDecayWindowSet(poolId, maxValidWindow);

        // Call the function with maximum value
        policyManager.setCapBudgetDecayWindow(poolId, maxValidWindow);

        // Verify maximum value was set correctly
        updatedDecayWindow = policyManager.getCapBudgetDecayWindow(poolId);
        assertEq(updatedDecayWindow, maxValidWindow, "Decay window not set to maximum value");

        vm.stopPrank();
    }

    function test_Success_SetDailyBudgetPpm_WhenValidValue() public {
        // Setup: Define valid daily budget values
        uint32 smallBudget = 100_000; // 10% of PPM_SCALE
        uint32 mediumBudget = 500_000; // 50% of PPM_SCALE
        uint32 largeBudget = 1_000_000; // 100% of PPM_SCALE (default)

        // Test first with small budget
        vm.startPrank(owner);

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.DailyBudgetSet(smallBudget);

        // Call the function
        policyManager.setDailyBudgetPpm(smallBudget);

        // Verify: Check that the daily budget was set correctly
        // Note: getDailyBudgetPpm takes a poolId parameter but it's not pool-specific in v1
        uint32 updatedBudget = policyManager.getDailyBudgetPpm(poolId);

        // Assert the value matches what we set
        assertEq(updatedBudget, smallBudget, "Daily budget not set to small value");

        // Test with medium budget
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.DailyBudgetSet(mediumBudget);

        // Call the function with medium budget
        policyManager.setDailyBudgetPpm(mediumBudget);

        // Verify medium budget was set correctly
        updatedBudget = policyManager.getDailyBudgetPpm(poolId);
        assertEq(updatedBudget, mediumBudget, "Daily budget not set to medium value");

        // Test with large budget (default value)
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.DailyBudgetSet(largeBudget);

        // Call the function with large budget
        policyManager.setDailyBudgetPpm(largeBudget);

        // Verify large budget was set correctly
        updatedBudget = policyManager.getDailyBudgetPpm(poolId);
        assertEq(updatedBudget, largeBudget, "Daily budget not set to large value");

        vm.stopPrank();
    }

    function test_Success_SetDecayWindow_WhenValidValue() public {
        // Setup: Define valid global decay window values
        uint32 shortWindow = 86400; // 1 day
        uint32 mediumWindow = 7776000; // 90 days
        uint32 longWindow = 15552000; // 180 days (default value)
        uint32 veryLongWindow = 31536000; // 365 days

        // Test with short window
        vm.startPrank(owner);

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.GlobalDecayWindowSet(shortWindow);

        // Call the function
        policyManager.setDecayWindow(shortWindow);

        // Verify: Check that the global decay window was set correctly
        // We need to check its effect on a pool that doesn't have a specific setting
        PoolId newPoolId = PoolId.wrap(bytes32(0)); // corrupted poolId that doesn't have a specific setting
        uint32 updatedDecayWindow = policyManager.getCapBudgetDecayWindow(newPoolId);

        // Assert the value matches what we set
        assertEq(updatedDecayWindow, shortWindow, "Global decay window not set to short value");

        // Test with medium window
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.GlobalDecayWindowSet(mediumWindow);

        // Call the function with medium window
        policyManager.setDecayWindow(mediumWindow);

        // Verify medium window was set correctly
        updatedDecayWindow = policyManager.getCapBudgetDecayWindow(newPoolId);
        assertEq(updatedDecayWindow, mediumWindow, "Global decay window not set to medium value");

        // Test with long window (default value)
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.GlobalDecayWindowSet(longWindow);

        // Call the function with long window
        policyManager.setDecayWindow(longWindow);

        // Verify long window was set correctly
        updatedDecayWindow = policyManager.getCapBudgetDecayWindow(newPoolId);
        assertEq(updatedDecayWindow, longWindow, "Global decay window not set to long value");

        // Test with very long window
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.GlobalDecayWindowSet(veryLongWindow);

        // Call the function with very long window
        policyManager.setDecayWindow(veryLongWindow);

        // Verify very long window was set correctly
        updatedDecayWindow = policyManager.getCapBudgetDecayWindow(newPoolId);
        assertEq(updatedDecayWindow, veryLongWindow, "Global decay window not set to very long value");

        // Test with minimum allowed value
        uint32 minValidWindow = 1; // 1 second (minimum allowed)

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.GlobalDecayWindowSet(minValidWindow);

        // Call the function with minimum value
        policyManager.setDecayWindow(minValidWindow);

        // Verify minimum value was set correctly
        updatedDecayWindow = policyManager.getCapBudgetDecayWindow(newPoolId);
        assertEq(updatedDecayWindow, minValidWindow, "Global decay window not set to minimum value");

        // Test with maximum allowed value (uint32 max)
        uint32 maxValidWindow = type(uint32).max; // Maximum uint32 value

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.GlobalDecayWindowSet(maxValidWindow);

        // Call the function with maximum value
        policyManager.setDecayWindow(maxValidWindow);

        // Verify maximum value was set correctly
        updatedDecayWindow = policyManager.getCapBudgetDecayWindow(newPoolId);
        assertEq(updatedDecayWindow, maxValidWindow, "Global decay window not set to maximum value");

        // Verify that pool-specific settings take precedence over global settings
        // First set a pool-specific decay window
        policyManager.setCapBudgetDecayWindow(poolId, shortWindow);

        // Then set a different global decay window
        policyManager.setDecayWindow(longWindow);

        // Verify that the pool-specific setting is unchanged
        uint32 poolSpecificWindow = policyManager.getCapBudgetDecayWindow(poolId);
        assertEq(poolSpecificWindow, shortWindow, "Pool-specific decay window should take precedence");

        // Verify that the global setting applies to other pools
        updatedDecayWindow = policyManager.getCapBudgetDecayWindow(newPoolId);
        assertEq(updatedDecayWindow, longWindow, "Global decay window should apply to pools without specific settings");

        vm.stopPrank();
    }

    function test_Revert_SetCapBudgetDecayWindow_WhenCalledByNonOwner() public {
        // Setup: Define a valid CAP budget decay window
        uint32 validDecayWindow = 7776000; // 90 days

        // Get the initial decay window value to verify no change happens
        uint32 initialDecayWindow = policyManager.getCapBudgetDecayWindow(poolId);

        // Execute: Attempt to set the decay window as a non-owner account (user1)
        vm.startPrank(user1);

        // Expect the transaction to revert because only the owner can call this function
        // The error comes from Solmate's Owned contract which uses a custom error pattern
        vm.expectRevert("UNAUTHORIZED");

        // Call the function that should revert
        policyManager.setCapBudgetDecayWindow(poolId, validDecayWindow);
        vm.stopPrank();

        // Execute: Attempt to set the decay window as another non-owner account (user2)
        vm.startPrank(user2);

        // Expect the same revert for any non-owner account
        vm.expectRevert("UNAUTHORIZED");

        // Call the function that should revert
        policyManager.setCapBudgetDecayWindow(poolId, validDecayWindow);
        vm.stopPrank();

        // Verify: Check that the decay window was not changed
        uint32 currentDecayWindow = policyManager.getCapBudgetDecayWindow(poolId);
        assertEq(currentDecayWindow, initialDecayWindow, "CAP budget decay window should not have changed");

        // Verification: Confirm the owner can still set the value
        vm.startPrank(owner);
        policyManager.setCapBudgetDecayWindow(poolId, validDecayWindow);
        vm.stopPrank();

        // Verify the owner successfully changed the value
        currentDecayWindow = policyManager.getCapBudgetDecayWindow(poolId);
        assertEq(currentDecayWindow, validDecayWindow, "Owner should be able to set CAP budget decay window");
    }

    function test_Revert_SetDailyBudgetPpm_WhenCalledByNonOwner() public {
        // Setup: Define a valid daily budget value
        uint32 validDailyBudget = 500_000; // 50% of PPM_SCALE

        // Get the initial daily budget value to verify no change happens
        uint32 initialDailyBudget = policyManager.getDailyBudgetPpm(poolId);

        // Execute: Attempt to set the daily budget as a non-owner account (user1)
        vm.startPrank(user1);

        // Expect the transaction to revert because only the owner can call this function
        vm.expectRevert("UNAUTHORIZED");

        // Call the function that should revert
        policyManager.setDailyBudgetPpm(validDailyBudget);
        vm.stopPrank();

        // Verify: Check that the daily budget was not changed
        uint32 currentDailyBudget = policyManager.getDailyBudgetPpm(poolId);
        assertEq(currentDailyBudget, initialDailyBudget, "Daily budget should not have changed");

        // Verification: Confirm the owner can still set the value
        vm.startPrank(owner);
        policyManager.setDailyBudgetPpm(validDailyBudget);
        vm.stopPrank();

        // Verify the owner successfully changed the value
        currentDailyBudget = policyManager.getDailyBudgetPpm(poolId);
        assertEq(currentDailyBudget, validDailyBudget, "Owner should be able to set daily budget");
    }

    function test_Revert_SetDecayWindow_WhenCalledByNonOwner() public {
        // Setup: Define a valid global decay window value
        uint32 validDecayWindow = 7776000; // 90 days

        // Corrupted poolId that doesn't have specific settings to test global defaults
        PoolId newPoolId = PoolId.wrap(bytes32(0));

        // Get the initial global decay window value to verify no change happens
        uint32 initialDecayWindow = policyManager.getCapBudgetDecayWindow(newPoolId);

        // Execute: Attempt to set the global decay window as a non-owner account (user1)
        vm.startPrank(user1);

        // Expect the transaction to revert because only the owner can call this function
        vm.expectRevert("UNAUTHORIZED");

        // Call the function that should revert
        policyManager.setDecayWindow(validDecayWindow);
        vm.stopPrank();

        // Verify: Check that the global decay window was not changed
        uint32 currentDecayWindow = policyManager.getCapBudgetDecayWindow(newPoolId);
        assertEq(currentDecayWindow, initialDecayWindow, "Global decay window should not have changed");

        // Verification: Confirm the owner can still set the value
        vm.startPrank(owner);
        policyManager.setDecayWindow(validDecayWindow);
        vm.stopPrank();

        // Verify the owner successfully changed the value
        currentDecayWindow = policyManager.getCapBudgetDecayWindow(newPoolId);
        assertEq(currentDecayWindow, validDecayWindow, "Owner should be able to set global decay window");
    }

    function test_Revert_SetCapBudgetDecayWindow_WhenZero() public {
        // Setup: Define a zero decay window value
        uint32 zeroDecayWindow = 0;

        // Get the initial decay window value to verify no change happens
        uint32 initialDecayWindow = policyManager.getCapBudgetDecayWindow(poolId);

        // Execute: Attempt to set a zero decay window
        vm.startPrank(owner);

        // Expect the transaction to revert with ParameterOutOfRange error
        // The error should contain the invalid value (0), minimum (1), and maximum (uint32.max)
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                zeroDecayWindow,
                1, // Minimum (1 second)
                type(uint32).max // Maximum (uint32 max)
            )
        );

        // Call the function that should revert
        policyManager.setCapBudgetDecayWindow(poolId, zeroDecayWindow);
        vm.stopPrank();

        // Verify: Check that the decay window was not changed
        uint32 currentDecayWindow = policyManager.getCapBudgetDecayWindow(poolId);
        assertEq(currentDecayWindow, initialDecayWindow, "CAP budget decay window should not have changed");

        // Verification: Confirm that the minimum value can be set (boundary test)
        uint32 minValidDecayWindow = 1; // Minimum allowed (1 second)

        vm.startPrank(owner);
        policyManager.setCapBudgetDecayWindow(poolId, minValidDecayWindow);
        vm.stopPrank();

        // Verify the minimum window was set correctly
        currentDecayWindow = policyManager.getCapBudgetDecayWindow(poolId);
        assertEq(currentDecayWindow, minValidDecayWindow, "Minimum valid decay window should be settable");
    }

    /*//////////////////////////////////////////////////////////////
                    BASE FEE ADJUSTMENT PARAMETER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Success_SetBaseFeeParams_WhenValidValues() public {
        // Setup: Define valid base fee adjustment parameters
        uint32 lowStep = 5_000; // 0.5% step
        uint32 midStep = 20_000; // 2% step (default)
        uint32 highStep = 100_000; // 10% step (maximum allowed)

        uint32 shortInterval = 1 hours; // 1 hour interval
        uint32 mediumInterval = 1 days; // 1 day interval (default)
        uint32 longInterval = 7 days; // 1 week interval

        // Get initial state for verification
        uint32 initialStep = policyManager.getBaseFeeStepPpm(poolId);
        uint32 initialInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);

        // Execute: Set low step with short interval
        vm.startPrank(owner);

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.BaseFeeParamsSet(poolId, lowStep, shortInterval);

        // Call the function
        policyManager.setBaseFeeParams(poolId, lowStep, shortInterval);

        // Verify: Check that the parameters were set correctly
        uint32 updatedStep = policyManager.getBaseFeeStepPpm(poolId);
        uint32 updatedInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);

        // Assert the values match what we set
        assertEq(updatedStep, lowStep, "Base fee step not set to low value");
        assertEq(updatedInterval, shortInterval, "Update interval not set to short value");

        // Test with mid-range values
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.BaseFeeParamsSet(poolId, midStep, mediumInterval);

        // Call the function with mid-range values
        policyManager.setBaseFeeParams(poolId, midStep, mediumInterval);

        // Verify mid-range values were set correctly
        updatedStep = policyManager.getBaseFeeStepPpm(poolId);
        updatedInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        assertEq(updatedStep, midStep, "Base fee step not set to mid-range value");
        assertEq(updatedInterval, mediumInterval, "Update interval not set to mid-range value");

        // Test with high step and long interval
        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.BaseFeeParamsSet(poolId, highStep, longInterval);

        // Call the function with high step and long interval
        policyManager.setBaseFeeParams(poolId, highStep, longInterval);

        // Verify high values were set correctly
        updatedStep = policyManager.getBaseFeeStepPpm(poolId);
        updatedInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        assertEq(updatedStep, highStep, "Base fee step not set to high value");
        assertEq(updatedInterval, longInterval, "Update interval not set to long value");

        // Test with zero step (which should use default when retrieved)
        uint32 zeroStep = 0;

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.BaseFeeParamsSet(poolId, zeroStep, shortInterval);

        // Call the function with zero step
        policyManager.setBaseFeeParams(poolId, zeroStep, shortInterval);

        // When we call getBaseFeeStepPpm, we should get the default value (not zero)
        updatedStep = policyManager.getBaseFeeStepPpm(poolId);
        updatedInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);

        // The correct assertion is to check against the default value
        assertEq(updatedStep, DEFAULT_BASE_FEE_STEP_PPM, "When step is set to zero, getter should return default value");
        assertEq(updatedInterval, shortInterval, "Update interval should still be updated with zero step");

        // Test with zero interval (should be rejected by contract)
        // Expect the transaction to revert because zero interval is not allowed
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                0, // invalid value
                1, // minimum
                type(uint32).max // maximum
            )
        );

        // Call the function with zero interval - should revert
        policyManager.setBaseFeeParams(poolId, midStep, 0);

        // After revert, verify the values are still the same as before the failed attempt
        // (from the zero step test: step=20000 default, interval=3600)
        updatedStep = policyManager.getBaseFeeStepPpm(poolId);
        updatedInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        assertEq(updatedStep, 20000, "Base fee step should remain unchanged after failed zero interval attempt");
        assertEq(updatedInterval, 3600, "Update interval should remain unchanged after failed zero interval attempt");

        // Test with maximum interval value
        uint32 maxInterval = type(uint32).max;

        // Expect event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true);
        emit IPoolPolicyManager.BaseFeeParamsSet(poolId, midStep, maxInterval);

        // Call the function with maximum interval
        policyManager.setBaseFeeParams(poolId, midStep, maxInterval);

        // Verify maximum interval was set correctly
        updatedStep = policyManager.getBaseFeeStepPpm(poolId);
        updatedInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        assertEq(updatedStep, midStep, "Base fee step should still be updated with max interval");
        assertEq(updatedInterval, maxInterval, "Update interval not set to maximum value");

        vm.stopPrank();
    }

    function test_Revert_SetBaseFeeParams_WhenCalledByNonOwner() public {
        // Setup: Define valid base fee parameters
        uint32 validStep = 20_000; // 2% step
        uint32 validInterval = 1 days; // 1 day interval

        // Get the initial values to verify no change happens
        uint32 initialStep = policyManager.getBaseFeeStepPpm(poolId);
        uint32 initialInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);

        // Execute: Attempt to set the parameters as a non-owner account (user1)
        vm.startPrank(user1);

        // Expect the transaction to revert because only the owner can call this function
        // The error comes from Solmate's Owned contract which uses a custom error pattern
        vm.expectRevert("UNAUTHORIZED");

        // Call the function that should revert
        policyManager.setBaseFeeParams(poolId, validStep, validInterval);
        vm.stopPrank();

        // Verify: Check that the parameters were not changed
        uint32 currentStep = policyManager.getBaseFeeStepPpm(poolId);
        uint32 currentInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        assertEq(currentStep, initialStep, "Base fee step should not have changed");
        assertEq(currentInterval, initialInterval, "Update interval should not have changed");

        // Verification: Confirm the owner can still set the values
        vm.startPrank(owner);
        policyManager.setBaseFeeParams(poolId, validStep, validInterval);
        vm.stopPrank();

        // Verify the owner successfully changed the values
        currentStep = policyManager.getBaseFeeStepPpm(poolId);
        currentInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        assertEq(currentStep, validStep, "Owner should be able to set base fee step");
        assertEq(currentInterval, validInterval, "Owner should be able to set update interval");
    }

    function test_Revert_SetBaseFeeParams_WhenStepExceedsMaximum() public {
        // Setup: Define step values above the maximum allowed (100,000 = 10%)
        uint32 justAboveMaxStep = 100_001; // Just above maximum
        uint32 slightlyAboveMaxStep = 150_000; // 15% (5% above maximum)
        uint32 farAboveMaxStep = 500_000; // 50% (far above maximum)

        // Define a valid interval for testing
        uint32 validInterval = 1 days; // 1 day interval

        // Get the initial values to verify no change happens
        uint32 initialStep = policyManager.getBaseFeeStepPpm(poolId);
        uint32 initialInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);

        // Execute: Attempt to set a step just above the maximum
        vm.startPrank(owner);

        // Expect the transaction to revert with ParameterOutOfRange error
        // The error should contain the invalid value, minimum (0), and maximum (100,000)
        uint32 MAX_STEP_PPM = 100_000; // 10% (from the contract)

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                justAboveMaxStep,
                0, // Minimum (0%)
                MAX_STEP_PPM // Maximum (10%)
            )
        );

        // Call the function that should revert
        policyManager.setBaseFeeParams(poolId, justAboveMaxStep, validInterval);

        // Attempt to set a step slightly above the maximum
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                slightlyAboveMaxStep,
                0, // Minimum (0%)
                MAX_STEP_PPM // Maximum (10%)
            )
        );

        policyManager.setBaseFeeParams(poolId, slightlyAboveMaxStep, validInterval);

        // Attempt to set a step far above the maximum
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                farAboveMaxStep,
                0, // Minimum (0%)
                MAX_STEP_PPM // Maximum (10%)
            )
        );

        policyManager.setBaseFeeParams(poolId, farAboveMaxStep, validInterval);
        vm.stopPrank();

        // Verify: Check that the parameters were not changed
        uint32 currentStep = policyManager.getBaseFeeStepPpm(poolId);
        uint32 currentInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        assertEq(currentStep, initialStep, "Base fee step should not have changed");
        assertEq(currentInterval, initialInterval, "Update interval should not have changed");

        // Verification: Confirm that the maximum value can be set (boundary test)
        uint32 maxValidStep = MAX_STEP_PPM; // Maximum allowed (10%)

        vm.startPrank(owner);
        policyManager.setBaseFeeParams(poolId, maxValidStep, validInterval);
        vm.stopPrank();

        // Verify the maximum step was set correctly
        currentStep = policyManager.getBaseFeeStepPpm(poolId);
        currentInterval = policyManager.getBaseFeeUpdateIntervalSeconds(poolId);
        assertEq(currentStep, maxValidStep, "Maximum valid step should be settable");
        assertEq(currentInterval, validInterval, "Update interval should be updated with maximum valid step");
    }

    /*//////////////////////////////////////////////////////////////
                      POOL INITIALIZATION POL SHARE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PoolInitializedWithDefaultPOLShare() public {
        // Test that the existing pool (from setUp) has the correct default 10% POL share
        
        // Verify that the pool was initialized with the default 10% POL share
        uint256 polShare = policyManager.getPoolPOLShare(poolId);
        uint256 expectedDefaultPolShare = 100_000; // 10% = 100,000 PPM
        
        assertEq(polShare, expectedDefaultPolShare, "Pool should be initialized with 10% POL share");
        
        // Test that the default behavior is consistent by checking the constant
        // We can verify this by setting a different value and then checking
        // that the default behavior is maintained for new pools
        
        // Set a custom POL share for the existing pool
        vm.startPrank(owner);
        policyManager.setPoolPOLShare(poolId, 200_000); // 20%
        vm.stopPrank();
        
        // Verify the custom value was set
        polShare = policyManager.getPoolPOLShare(poolId);
        assertEq(polShare, 200_000, "Custom POL share should be set correctly");
        
        // Reset back to default to verify the default value
        vm.startPrank(owner);
        policyManager.setPoolPOLShare(poolId, expectedDefaultPolShare);
        vm.stopPrank();
        
        // Verify it's back to default
        polShare = policyManager.getPoolPOLShare(poolId);
        assertEq(polShare, expectedDefaultPolShare, "Pool should be reset to default 10% POL share");
    }

    function test_DefaultPOLShareIsCorrectlySet() public {
        // Test that the existing pool (from setUp) has the correct default POL share
        
        uint256 polShare = policyManager.getPoolPOLShare(poolId);
        uint256 expectedDefaultPolShare = 100_000; // 10% = 100,000 PPM
        
        assertEq(polShare, expectedDefaultPolShare, "Existing pool should have 10% POL share");
        
        // Verify that this is indeed the default by checking the constant
        // The constant DEFAULT_POOL_POL_SHARE_PPM should be 100_000
        // We can verify this by setting a different value and then checking
        // that the default behavior is maintained for new pools
        
        // Set a custom POL share for the existing pool
        vm.startPrank(owner);
        policyManager.setPoolPOLShare(poolId, 200_000); // 20%
        vm.stopPrank();
        
        // Verify the custom value was set
        polShare = policyManager.getPoolPOLShare(poolId);
        assertEq(polShare, 200_000, "Custom POL share should be set correctly");
        
        // Verify that the default value is correctly set to 10%
        // We can test this by checking that the default behavior is consistent
        // and that the value can be set and retrieved correctly
        
        // Test edge case: 0% POL share
        vm.startPrank(owner);
        policyManager.setPoolPOLShare(poolId, 0);
        vm.stopPrank();
        
        // Verify zero value was set
        polShare = policyManager.getPoolPOLShare(poolId);
        assertEq(polShare, 0, "Zero POL share should be set correctly");
        
        // Test edge case: 100% POL share
        vm.startPrank(owner);
        policyManager.setPoolPOLShare(poolId, 1_000_000); // 100%
        vm.stopPrank();
        
        // Verify 100% value was set
        polShare = policyManager.getPoolPOLShare(poolId);
        assertEq(polShare, 1_000_000, "100% POL share should be set correctly");
    }
}
