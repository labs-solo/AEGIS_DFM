// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

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
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

// - - - v4 core imports - - -

import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

// - - - solmate imports - - -

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// - - - local test helpers imports - - -

import {Base_Test} from "../../Base_Test.sol";

// - - - local src imports - - -

import {Errors} from "src/errors/Errors.sol";

contract Spot_WithdrawFromFRLM_Test is Base_Test {
    function setUp() public override {
        Base_Test.setUp();
    }

    // - - - parametrized test helpers - - -

    /**
     * @notice Helper function to test fee accrual during withdrawal
     * @param reinvestmentPaused Whether reinvestment is paused
     * @param polShare The protocol-owned liquidity share (e.g., 200000 = 20%)
     * @param numPreSwaps Number of swaps to execute before withdrawal to generate fees
     * @param swapAmount Amount to use for each swap
     * @param sharesToWithdraw Number of shares to withdraw
     */
    function _testWithdrawFeeAccrual(
        bool reinvestmentPaused,
        uint256 polShare,
        uint256 numPreSwaps,
        uint256 swapAmount,
        uint256 sharesToWithdraw
    ) internal {
        // Setup - configure fee parameters
        vm.startPrank(owner);
        policyManager.setManualFee(poolId, DEFAULT_MANUAL_FEE);
        policyManager.setPoolPOLShare(poolId, polShare);
        spot.setReinvestmentPaused(reinvestmentPaused);
        vm.stopPrank();

        // Make initial deposit as owner to get shares
        uint256 depositAmount0 = 10 ether;
        uint256 depositAmount1 = 10 ether;

        // Ensure owner has sufficient tokens for deposit
        _ensureOwnerTokens(depositAmount0, depositAmount1);

        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), depositAmount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), depositAmount1);

        (uint256 sharesReceived, uint256 amount0Used, uint256 amount1Used) = spot.depositToFRLM(
            poolKey,
            depositAmount0,
            depositAmount1,
            0, // No minimum amounts for simplicity
            0,
            owner
        );
        vm.stopPrank();

        // Make sure we have enough shares for the test
        require(sharesReceived >= sharesToWithdraw, "Not enough shares for test");

        // Get initial state before swaps
        (uint256 pendingFee0Before, uint256 pendingFee1Before) = liquidityManager.getPendingFees(poolId);

        // Execute swaps to generate fees
        vm.startPrank(user1);
        for (uint256 i = 0; i < numPreSwaps; i++) {
            // Alternate swap directions to ensure fees in both tokens
            bool zeroForOne = (i % 2 == 0);
            SwapParams memory params = SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            });

            swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}), "");
        }
        vm.stopPrank();

        // Get state after swaps but before withdrawal
        (uint256 pendingFee0AfterSwaps, uint256 pendingFee1AfterSwaps) = liquidityManager.getPendingFees(poolId);

        // NOTE: if reinvestmentPaused then we expect pendingFees to accumulate otherwise it'll likely be reinvested
        if (reinvestmentPaused) {
            // Verify fees were collected during swaps
            if (numPreSwaps > 0 && polShare > 0) {
                assertGt(pendingFee0AfterSwaps, pendingFee0Before, "No fees0 collected from swaps");
                assertGt(pendingFee1AfterSwaps, pendingFee1Before, "No fees1 collected from swaps");
            }
        }

        // Track balances before withdrawal
        uint256 ownerBalance0Before = currency0.balanceOf(owner);
        uint256 ownerBalance1Before = currency1.balanceOf(owner);

        // Execute withdrawal
        vm.startPrank(owner);
        (uint256 amount0Withdrawn, uint256 amount1Withdrawn) = spot.withdrawFromFRLM(
            poolKey,
            sharesToWithdraw,
            0, // No minimum amounts
            0,
            owner
        );
        vm.stopPrank();

        // Get state after withdrawal
        (uint256 pendingFee0AfterWithdraw, uint256 pendingFee1AfterWithdraw) = liquidityManager.getPendingFees(poolId);
        uint256 ownerBalance0After = currency0.balanceOf(owner);
        uint256 ownerBalance1After = currency1.balanceOf(owner);

        // Verify balances increased by the withdrawn amounts
        assertEq(
            ownerBalance0After - ownerBalance0Before,
            amount0Withdrawn,
            "Owner balance0 did not increase by the withdrawn amount"
        );

        assertEq(
            ownerBalance1After - ownerBalance1Before,
            amount1Withdrawn,
            "Owner balance1 did not increase by the withdrawn amount"
        );
    }

    // - - - other test helpers - - -

    /**
     * @notice Helper function to ensure the owner has sufficient tokens for operations
     * @param amount0 Amount of token0 needed
     * @param amount1 Amount of token1 needed
     */
    function _ensureOwnerTokens(uint256 amount0, uint256 amount1) internal {
        vm.startPrank(owner);

        uint256 ownerBalance0 = currency0.balanceOf(owner);
        uint256 ownerBalance1 = currency1.balanceOf(owner);

        if (ownerBalance0 < amount0) {
            MockERC20(Currency.unwrap(currency0)).mint(owner, amount0 - ownerBalance0 + 1 ether);
        }
        if (ownerBalance1 < amount1) {
            MockERC20(Currency.unwrap(currency1)).mint(owner, amount1 - ownerBalance1 + 1 ether);
        }

        vm.stopPrank();
    }

    /**
     * @notice Helper function to perform deposit and withdrawal operations with verification
     * @param depositAmount0 Amount of token0 to deposit
     * @param depositAmount1 Amount of token1 to deposit
     * @param withdrawSharePercentage Percentage of shares to withdraw (in basis points, e.g. 5000 = 50%)
     * @param recipient Recipient of the withdrawn tokens
     * @return withdrawnAmount0 Amount of token0 withdrawn
     * @return withdrawnAmount1 Amount of token1 withdrawn
     * @return sharesWithdrawn Number of shares withdrawn
     */
    function _testDepositAndWithdraw(
        uint256 depositAmount0,
        uint256 depositAmount1,
        uint256 withdrawSharePercentage,
        address recipient
    ) internal returns (uint256 withdrawnAmount0, uint256 withdrawnAmount1, uint256 sharesWithdrawn) {
        // Ensure owner has sufficient tokens for deposit
        _ensureOwnerTokens(depositAmount0, depositAmount1);

        // Make initial deposit as owner to get shares
        vm.startPrank(owner);

        // Approve tokens to liquidityManager for the deposit
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), depositAmount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), depositAmount1);

        // Execute the deposit and get shares
        (uint256 sharesReceived, uint256 amount0Used, uint256 amount1Used) = spot.depositToFRLM(
            poolKey,
            depositAmount0,
            depositAmount1,
            0, // No minimum amounts for simplicity
            0,
            owner
        );

        // Verify deposit was successful
        assertGt(sharesReceived, 0, "No shares were received from deposit");

        // Calculate shares to withdraw based on percentage
        sharesWithdrawn = (sharesReceived * withdrawSharePercentage) / 10000;

        // Check initial state before withdrawal
        uint256 ownerSharesBefore = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));
        uint256 recipientBalance0Before = currency0.balanceOf(recipient);
        uint256 recipientBalance1Before = currency1.balanceOf(recipient);

        // Get position info before withdrawal
        (uint256 positionId, uint128 liquidityBefore,,) = liquidityManager.getPositionInfo(poolId);

        // Execute the withdrawal as owner
        (withdrawnAmount0, withdrawnAmount1) = spot.withdrawFromFRLM(
            poolKey,
            sharesWithdrawn,
            0, // No minimum amounts for simplicity
            0,
            recipient
        );
        vm.stopPrank();

        // Verify withdrawal amounts are proportional to shares
        assertApproxEqRel(
            withdrawnAmount0,
            (amount0Used * sharesWithdrawn) / sharesReceived,
            0.01e18, // 1% tolerance
            "Withdrawn amount0 not proportional to shares"
        );

        assertApproxEqRel(
            withdrawnAmount1,
            (amount1Used * sharesWithdrawn) / sharesReceived,
            0.01e18, // 1% tolerance
            "Withdrawn amount1 not proportional to shares"
        );

        // Verify shares were burned
        uint256 ownerSharesAfter = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));
        assertEq(ownerSharesAfter, ownerSharesBefore - sharesWithdrawn, "Shares not burned correctly");

        // Verify liquidity in the position decreased
        (, uint128 liquidityAfter,,) = liquidityManager.getPositionInfo(poolId);
        assertEq(
            liquidityAfter, liquidityBefore - uint128(sharesWithdrawn), "Position liquidity not decreased correctly"
        );

        // Verify token balances increased for the recipient
        uint256 recipientBalance0After = currency0.balanceOf(recipient);
        uint256 recipientBalance1After = currency1.balanceOf(recipient);

        assertEq(
            recipientBalance0After - recipientBalance0Before,
            withdrawnAmount0,
            "Recipient token0 balance did not increase by the withdrawn amount"
        );

        assertEq(
            recipientBalance1After - recipientBalance1Before,
            withdrawnAmount1,
            "Recipient token1 balance did not increase by the withdrawn amount"
        );

        // Verify the position ID didn't change
        (uint256 positionIdAfter,,,) = liquidityManager.getPositionInfo(poolId);
        assertEq(positionIdAfter, positionId, "Position ID changed unexpectedly");

        // Verify no tokens got stuck anywhere unexpected
        assertEq(currency0.balanceOf(address(spot)), 0, "Tokens got stuck in Spot contract");
        assertEq(currency1.balanceOf(address(spot)), 0, "Tokens got stuck in Spot contract");

        return (withdrawnAmount0, withdrawnAmount1, sharesWithdrawn);
    }

    // - - - withdrawFromFRLM tests - - -

    /**
     * @notice Tests basic withdrawal functionality as the policy owner
     * @dev Tests:
     * - Making a deposit to create shares
     * - Withdrawing a portion of the shares
     * - Verifying token receipt and share burn
     */
    function test_Withdraw_PolicyOwner_Basic() public {
        // Use the parameterized helper to test withdrawing 50% of shares
        _testDepositAndWithdraw(
            5 ether, // depositAmount0
            5 ether, // depositAmount1
            5000, // withdrawSharePercentage (50% = 5000 basis points)
            owner // recipient
        );
    }

    /**
     * @notice Tests withdrawal of all shares
     * @dev Tests:
     * - Making a deposit to create shares
     * - Withdrawing all shares
     * - Verifying position remains with locked liquidity
     */
    function test_Withdraw_AllShares() public {
        // Define deposit amounts for initial setup
        uint256 amount0Desired = 5 ether;
        uint256 amount1Desired = 5 ether;

        // Ensure owner has sufficient tokens for deposit
        _ensureOwnerTokens(amount0Desired, amount1Desired);

        // Make initial deposit as owner to get shares
        vm.startPrank(owner);

        // Approve tokens to liquidityManager for the deposit
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), amount0Desired);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), amount1Desired);

        // Execute the deposit and get shares
        (uint256 sharesReceived, uint256 amount0Used, uint256 amount1Used) = spot.depositToFRLM(
            poolKey,
            amount0Desired,
            amount1Desired,
            0, // No minimum amounts for simplicity
            0,
            owner
        );

        // Verify deposit was successful
        assertGt(sharesReceived, 0, "No shares were received from deposit");

        // Check initial state before withdrawal
        uint256 ownerSharesBefore = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));
        assertEq(ownerSharesBefore, sharesReceived, "Shares balance mismatch after deposit");

        uint256 ownerBalance0Before = currency0.balanceOf(owner);
        uint256 ownerBalance1Before = currency1.balanceOf(owner);

        // Get position info before withdrawal
        (uint256 positionId, uint128 liquidityBefore, uint256 reserves0Before, uint256 reserves1Before) =
            liquidityManager.getPositionInfo(poolId);

        // We expect liquidityBefore to be sharesReceived + MIN_LOCKED_LIQUIDITY
        assertEq(
            liquidityBefore,
            sharesReceived + MIN_LOCKED_LIQUIDITY,
            "Initial liquidity should be shares + MIN_LOCKED_LIQUIDITY"
        );

        // Execute the withdrawal of ALL shares
        (uint256 amount0Withdrawn, uint256 amount1Withdrawn) = spot.withdrawFromFRLM(
            poolKey,
            sharesReceived, // Withdraw all shares
            0, // No minimum amounts for simplicity
            0,
            owner // Withdraw to owner as recipient
        );
        vm.stopPrank();

        // Verify withdrawal amounts
        assertApproxEqRel(
            amount0Withdrawn,
            amount0Used,
            0.01e18, // 1% tolerance
            "Not all token0 was withdrawn"
        );

        assertApproxEqRel(
            amount1Withdrawn,
            amount1Used,
            0.01e18, // 1% tolerance
            "Not all token1 was withdrawn"
        );

        // Verify ALL shares were burned
        uint256 ownerSharesAfter = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));
        assertEq(ownerSharesAfter, 0, "Not all shares were burned");

        // Verify token balances increased by withdrawn amounts
        uint256 ownerBalance0After = currency0.balanceOf(owner);
        uint256 ownerBalance1After = currency1.balanceOf(owner);

        assertEq(
            ownerBalance0After - ownerBalance0Before,
            amount0Withdrawn,
            "Owner token0 balance did not increase by the withdrawn amount"
        );

        assertEq(
            ownerBalance1After - ownerBalance1Before,
            amount1Withdrawn,
            "Owner token1 balance did not increase by the withdrawn amount"
        );

        // CRITICAL: Verify position still exists with the locked liquidity
        (uint256 positionIdAfter, uint128 liquidityAfter, uint256 reserves0After, uint256 reserves1After) =
            liquidityManager.getPositionInfo(poolId);

        assertEq(positionIdAfter, positionId, "Position ID changed unexpectedly");
        assertEq(liquidityAfter, MIN_LOCKED_LIQUIDITY, "Position should retain exactly MIN_LOCKED_LIQUIDITY");

        // Verify that the position reserves decreased proportionally
        assertLt(reserves0After, reserves0Before, "Position reserves0 did not decrease");
        assertLt(reserves1After, reserves1Before, "Position reserves1 did not decrease");

        // Ratio of remaining liquidity to initial liquidity should match the ratio
        // of remaining reserves to initial reserves
        uint256 liquidityRatio = uint256(liquidityAfter) * 1e18 / uint256(liquidityBefore);
        uint256 reserves0Ratio = reserves0After * 1e18 / reserves0Before;
        uint256 reserves1Ratio = reserves1After * 1e18 / reserves1Before;

        assertApproxEqRel(
            liquidityRatio,
            reserves0Ratio,
            0.01e18, // 1% tolerance
            "Liquidity to reserves0 ratio mismatch"
        );

        assertApproxEqRel(
            liquidityRatio,
            reserves1Ratio,
            0.01e18, // 1% tolerance
            "Liquidity to reserves1 ratio mismatch"
        );

        // Verify no tokens got stuck anywhere unexpected
        assertEq(currency0.balanceOf(address(spot)), 0, "Tokens got stuck in Spot contract");
        assertEq(currency1.balanceOf(address(spot)), 0, "Tokens got stuck in Spot contract");
    }

    /**
     * @notice Tests withdrawal to a different recipient than the policy owner
     * @dev Tests:
     * - Withdrawing and specifying a different recipient
     * - Verifying tokens are sent to the correct recipient
     */
    function test_Withdraw_DifferentRecipient() public {
        // Use different addresses for owner (who has the shares) and recipient
        address differentRecipient = user1;

        // Define deposit and withdrawal amounts
        uint256 depositAmount0 = 5 ether;
        uint256 depositAmount1 = 5 ether;
        uint256 withdrawPercentage = 7500; // 75%

        // Use the parameterized helper to perform deposit and withdrawal
        // with a different recipient than the owner
        (uint256 amount0Withdrawn, uint256 amount1Withdrawn, uint256 sharesWithdrawn) = _testDepositAndWithdraw(
            depositAmount0,
            depositAmount1,
            withdrawPercentage,
            differentRecipient // user1 as the recipient instead of owner
        );

        // Verify the owner doesn't receive the tokens (they should go to the recipient)
        uint256 ownerBalance0 = currency0.balanceOf(owner);
        uint256 ownerBalance1 = currency1.balanceOf(owner);

        // Get remaining shares after first withdrawal
        uint256 remainingShares = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));

        // Calculate a smaller amount for a second withdrawal
        uint256 smallerWithdrawal = remainingShares / 2;

        // Execute another small withdrawal to the owner
        vm.startPrank(owner);
        (uint256 amount0WithdrawnToOwner, uint256 amount1WithdrawnToOwner) = spot.withdrawFromFRLM(
            poolKey,
            smallerWithdrawal,
            0, // No minimum amounts for simplicity
            0,
            owner // Owner as recipient this time
        );
        vm.stopPrank();

        // Verify the owner received these new tokens
        uint256 ownerBalance0After = currency0.balanceOf(owner);
        uint256 ownerBalance1After = currency1.balanceOf(owner);

        assertEq(
            ownerBalance0After - ownerBalance0,
            amount0WithdrawnToOwner,
            "Owner balance0 did not increase by the correct amount on second withdrawal"
        );

        assertEq(
            ownerBalance1After - ownerBalance1,
            amount1WithdrawnToOwner,
            "Owner balance1 did not increase by the correct amount on second withdrawal"
        );
    }

    /**
     * @notice Tests that only policy owner can call withdrawFromFRLM
     * @dev Tests:
     * - Non-owner trying to withdraw
     * - Verification that the call reverts with unauthorized error
     */
    function test_RevertWhen_NotPolicyOwner() public {
        // First, create some shares for the owner to ensure the test is realistic
        uint256 depositAmount0 = 5 ether;
        uint256 depositAmount1 = 5 ether;

        // Ensure owner has sufficient tokens for deposit
        _ensureOwnerTokens(depositAmount0, depositAmount1);

        // Make deposit as owner
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), depositAmount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), depositAmount1);

        (uint256 sharesReceived,,) = spot.depositToFRLM(poolKey, depositAmount0, depositAmount1, 0, 0, owner);
        vm.stopPrank();

        // Verify we have shares to potentially withdraw
        assertGt(sharesReceived, 0, "No shares were created for testing");

        // Now attempt to withdraw as user1 (not the policy owner)
        vm.startPrank(user1);

        // This should revert with UnauthorizedCaller error
        vm.expectRevert(abi.encodeWithSelector(Errors.UnauthorizedCaller.selector, user1));
        spot.withdrawFromFRLM(
            poolKey,
            sharesReceived / 2, // Try to withdraw half the shares
            0,
            0,
            user1
        );
        vm.stopPrank();

        // Try with user2 as well to ensure it's consistent
        vm.startPrank(user2);

        // This should also revert with UnauthorizedCaller error
        vm.expectRevert(abi.encodeWithSelector(Errors.UnauthorizedCaller.selector, user2));
        spot.withdrawFromFRLM(poolKey, sharesReceived / 2, 0, 0, user2);
        vm.stopPrank();

        // Finally, verify that the policy owner can still withdraw without issues
        vm.startPrank(owner);

        // This should not revert
        (uint256 amount0, uint256 amount1) = spot.withdrawFromFRLM(poolKey, sharesReceived / 2, 0, 0, owner);

        vm.stopPrank();

        // Verify withdrawal was successful by checking that amounts were returned
        assertGt(amount0, 0, "No token0 was withdrawn by owner");
        assertGt(amount1, 0, "No token1 was withdrawn by owner");
    }

    /**
     * @notice Tests fee accrual during withdrawal
     * @dev Tests:
     * - Generate fees on the position through swaps
     * - Withdraw shares
     * - Verify fee accounting
     */
    function test_Withdraw_FeeAccrual() public {
        // Test basic fee accrual with reinvestment paused
        _testWithdrawFeeAccrual(
            true, // reinvestmentPaused
            200000, // polShare (20%)
            10, // numPreSwaps
            1 ether, // swapAmount
            5 ether // sharesToWithdraw
        );
    }

    /**
     * @notice Tests fee accrual during withdrawal with reinvestment enabled
     */
    function test_Withdraw_FeeAccrual_WithReinvestment() public {
        // Test fee accrual with reinvestment enabled
        _testWithdrawFeeAccrual(
            false, // reinvestmentPaused (reinvestment enabled)
            200000, // polShare (20%)
            10, // numPreSwaps
            1 ether, // swapAmount
            5 ether // sharesToWithdraw
        );
    }

    /**
     * @notice Tests withdrawal with no prior fees
     */
    function test_Withdraw_FeeAccrual_NoPreSwaps() public {
        // Test withdrawal with no prior fees
        _testWithdrawFeeAccrual(
            true, // reinvestmentPaused
            200000, // polShare (20%)
            0, // numPreSwaps (no swaps to generate fees)
            0, // swapAmount (not used)
            5 ether // sharesToWithdraw
        );
    }

    /**
     * @notice Tests withdrawal with high POL share
     */
    function test_Withdraw_FeeAccrual_HighPolShare() public {
        // Test with high POL share (50%)
        _testWithdrawFeeAccrual(
            true, // reinvestmentPaused
            500000, // polShare (50%)
            10, // numPreSwaps
            1 ether, // swapAmount
            5 ether // sharesToWithdraw
        );
    }

    /**
     * @notice Tests withdrawal from a pool with no position (should revert)
     */
    function test_Withdraw_NoPosition() public {
        // Create a new pool that has no position in the FRLM
        // This is a pool that exists but has never had a position created for it

        // Create a new pool key with different fee
        PoolKey memory newPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10, // Different tick spacing
            hooks: IHooks(address(spot))
        });

        // Initialize the new pool
        manager.initialize(newPoolKey, SQRT_PRICE_1_1);
        PoolId newPoolId = newPoolKey.toId();

        // Verify that this pool has no position
        (uint256 positionId,,,) = liquidityManager.getPositionInfo(newPoolId);
        assertEq(positionId, 0, "Expected no position for this pool");

        // First, try to deposit to create shares - this should work
        uint256 depositAmount0 = 1 ether;
        uint256 depositAmount1 = 1 ether;

        _ensureOwnerTokens(depositAmount0, depositAmount1);

        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), depositAmount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), depositAmount1);

        (uint256 sharesReceived,,) = spot.depositToFRLM(newPoolKey, depositAmount0, depositAmount1, 0, 0, owner);

        // Verify shares were received (a position should have been created during deposit)
        assertGt(sharesReceived, 0, "No shares were received from deposit");

        // Now the pool has a position created by the deposit
        // Let's create another pool without doing a deposit to test the withdrawal error

        // Create a third pool key with yet another fee
        PoolKey memory noPositionPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 200, // Different tick spacing
            hooks: IHooks(address(spot))
        });

        // Initialize this pool too
        manager.initialize(noPositionPoolKey, SQRT_PRICE_1_1);
        PoolId noPositionPoolId = noPositionPoolKey.toId();

        // Verify that this pool has no position
        (positionId,,,) = liquidityManager.getPositionInfo(noPositionPoolId);
        assertEq(positionId, 0, "Expected no position for this pool");

        // Now try to withdraw from a pool with no position - this should revert
        vm.expectRevert(abi.encodeWithSelector(Errors.PositionNotFound.selector, noPositionPoolId));
        spot.withdrawFromFRLM(
            noPositionPoolKey,
            1 ether, // Amount doesn't matter, it should revert before checking
            0,
            0,
            owner
        );
        vm.stopPrank();

        // Additional test: try to withdraw from the first pool that now has a position
        // This should work since we created a position above
        vm.startPrank(owner);
        (uint256 amount0, uint256 amount1) = spot.withdrawFromFRLM(
            newPoolKey,
            sharesReceived / 2, // Withdraw half the shares
            0,
            0,
            owner
        );
        vm.stopPrank();

        // Verify withdrawal was successful
        assertGt(amount0, 0, "No token0 withdrawn");
        assertGt(amount1, 0, "No token1 withdrawn");
    }

    /**
     * @notice Tests withdrawal with insufficient shares (should revert)
     */
    function test_Withdraw_InsufficientShares() public {
        // Define deposit amounts for initial setup
        uint256 depositAmount0 = 5 ether;
        uint256 depositAmount1 = 5 ether;

        // Ensure owner has sufficient tokens for deposit
        _ensureOwnerTokens(depositAmount0, depositAmount1);

        // Make initial deposit as owner to get shares
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), depositAmount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), depositAmount1);

        (uint256 sharesReceived,,) = spot.depositToFRLM(
            poolKey,
            depositAmount0,
            depositAmount1,
            0, // No minimum amounts for simplicity
            0,
            owner
        );

        // Verify deposit was successful
        assertGt(sharesReceived, 0, "No shares were received from deposit");

        // Calculate slightly more shares than the owner has
        uint256 tooManyShares = sharesReceived + 1;

        // Verify that the owner indeed has fewer shares than we're trying to withdraw
        uint256 ownerShares = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));
        assertLt(ownerShares, tooManyShares, "Test setup issue: owner should have fewer shares than withdrawal amount");

        // Try to withdraw too many shares - should revert
        vm.expectRevert(); // This should revert with an insufficient shares/balance error
        spot.withdrawFromFRLM(
            poolKey,
            tooManyShares, // More shares than the owner has
            0,
            0,
            owner
        );

        // Now try with exactly the number of shares the owner has - this should work
        (uint256 amount0, uint256 amount1) = spot.withdrawFromFRLM(
            poolKey,
            ownerShares, // Exactly what the owner has
            0,
            0,
            owner
        );
        vm.stopPrank();

        // Verify the exact shares withdrawal was successful
        assertGt(amount0, 0, "No token0 withdrawn");
        assertGt(amount1, 0, "No token1 withdrawn");

        // Verify that now the owner has no shares left
        uint256 ownerSharesAfter = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));
        assertEq(ownerSharesAfter, 0, "Owner should have no shares remaining");
    }

    /**
     * @notice Tests withdrawal with native ETH as one of the tokens
     */
    function test_Withdraw_WithNativeETH() public {
        // Create a new pool with native ETH (address(0)) as currency0
        Currency ethCurrency = Currency.wrap(address(0)); // Native ETH is always currency0

        // Create a non-ETH token for the pair
        MockERC20 testToken = new MockERC20("Test Token", "TEST", 18);
        Currency testCurrency = Currency.wrap(address(testToken));

        // Create a PoolKey with native ETH as currency0
        PoolKey memory ethPoolKey = PoolKey({
            currency0: ethCurrency, // Native ETH is always currency0
            currency1: testCurrency, // Test token is currency1
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(spot))
        });

        // Initialize the pool
        manager.initialize(ethPoolKey, SQRT_PRICE_1_1);
        PoolId ethPoolId = ethPoolKey.toId();

        // Setup - make sure owner has tokens and ETH
        vm.startPrank(owner);

        // Define deposit amounts
        uint256 ethAmount = 2 ether;
        uint256 tokenAmount = 5 ether;

        // Ensure owner has a sufficient balance
        testToken.mint(owner, 100 ether);
        vm.deal(owner, ethAmount * 2); // Provide ETH to owner

        // Grant infinite token allowance to FRLM
        testToken.approve(address(liquidityManager), type(uint256).max);

        // Get initial balances for verification
        uint256 initialEthBalance = owner.balance;
        uint256 initialTokenBalance = testToken.balanceOf(owner);

        // Make the deposit with native ETH
        (uint256 sharesReceived, uint256 actualEthUsed, uint256 actualTokenUsed) = spot.depositToFRLM{value: ethAmount}(
            ethPoolKey,
            ethAmount, // ETH amount (currency0)
            tokenAmount, // Token amount (currency1)
            0, // No minimum amounts
            0,
            owner
        );

        // Verify deposit was successful
        assertGt(sharesReceived, 0, "No shares were received from deposit");

        // Store balances before withdrawal
        uint256 preWithdrawEthBalance = owner.balance;
        uint256 preWithdrawTokenBalance = testToken.balanceOf(owner);

        // Calculate shares to withdraw (75% of received shares)
        uint256 sharesToWithdraw = (sharesReceived * 75) / 100;

        // Execute the withdrawal
        (uint256 ethWithdrawn, uint256 tokenWithdrawn) = spot.withdrawFromFRLM(
            ethPoolKey,
            sharesToWithdraw,
            0, // No minimum amounts
            0,
            owner
        );
        vm.stopPrank();

        // Get final balances
        uint256 finalEthBalance = owner.balance;
        uint256 finalTokenBalance = testToken.balanceOf(owner);

        // Verify ETH was received correctly
        assertEq(
            finalEthBalance - preWithdrawEthBalance,
            ethWithdrawn,
            "ETH balance did not increase by the withdrawn amount"
        );

        // Verify token was received correctly
        assertEq(
            finalTokenBalance - preWithdrawTokenBalance,
            tokenWithdrawn,
            "Token balance did not increase by the withdrawn amount"
        );

        // Verify the withdrawn amounts are roughly proportional to the shares withdrawn
        assertApproxEqRel(
            ethWithdrawn,
            (actualEthUsed * sharesToWithdraw) / sharesReceived,
            0.01e18, // 1% tolerance
            "ETH withdrawn not proportional to shares"
        );

        assertApproxEqRel(
            tokenWithdrawn,
            (actualTokenUsed * sharesToWithdraw) / sharesReceived,
            0.01e18, // 1% tolerance
            "Token withdrawn not proportional to shares"
        );

        // Try withdrawing to a different recipient
        vm.startPrank(owner);

        // Get remaining shares
        uint256 remainingShares = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(ethPoolId)));

        // Track recipient balances before
        uint256 recipientEthBefore = user1.balance;
        uint256 recipientTokenBefore = testToken.balanceOf(user1);

        // Withdraw remaining shares to user1
        (uint256 ethWithdrawnToRecipient, uint256 tokenWithdrawnToRecipient) = spot.withdrawFromFRLM(
            ethPoolKey,
            remainingShares,
            0, // No minimum amounts
            0,
            user1 // Different recipient
        );
        vm.stopPrank();

        // Verify recipient received the tokens
        uint256 recipientEthAfter = user1.balance;
        uint256 recipientTokenAfter = testToken.balanceOf(user1);

        assertEq(
            recipientEthAfter - recipientEthBefore,
            ethWithdrawnToRecipient,
            "Recipient ETH balance did not increase by the withdrawn amount"
        );

        assertEq(
            recipientTokenAfter - recipientTokenBefore,
            tokenWithdrawnToRecipient,
            "Recipient token balance did not increase by the withdrawn amount"
        );

        // Verify owner has no shares left
        uint256 finalOwnerShares = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(ethPoolId)));
        assertEq(finalOwnerShares, 0, "Owner should have no shares remaining");
    }
}
