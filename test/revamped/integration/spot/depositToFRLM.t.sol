// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

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

contract Spot_DepositToFRLM_Test is Base_Test {
    function setUp() public override {
        Base_Test.setUp();
    }

    // - - - parametrized test helpers - - -

    /**
     * @notice Helper function to test fee accrual during deposit
     * @param reinvestmentPaused Whether reinvestment is paused
     * @param polShare The protocol-owned liquidity share (e.g., 200000 = 20%)
     * @param numPreSwaps Number of swaps to execute before deposit to generate fees
     * @param swapAmount Amount to use for each swap
     * @param depositAmount0 Amount of token0 to deposit
     * @param depositAmount1 Amount of token1 to deposit
     */
    function _testDepositFeeAccrual(
        bool reinvestmentPaused,
        uint256 polShare,
        uint256 numPreSwaps,
        uint256 swapAmount,
        uint256 depositAmount0,
        uint256 depositAmount1
    ) internal {
        // Setup - configure fee parameters
        vm.startPrank(owner);
        policyManager.setPoolPOLShare(poolId, polShare);
        spot.setReinvestmentPaused(reinvestmentPaused);

        // Donate and do initial reinvestment to setup the NFT and subscribe to notifications
        liquidityManager.donate(poolKey, 1e10, 1e10);
        vm.warp(block.timestamp + REINVEST_COOLDOWN);
        liquidityManager.reinvest(poolKey);

        vm.stopPrank();

        // Execute swaps to generate fees on the pool
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

        // Store initial state
        (uint256 pendingFee0Before, uint256 pendingFee1Before) = liquidityManager.getPendingFees(poolId);
        (uint256 positionIdBefore, uint128 liquidityBefore,,) = liquidityManager.getPositionInfo(poolId);

        // Track accounted balances before deposit
        uint256 accountedBalance0Before = liquidityManager.accountedBalances(currency0);
        uint256 accountedBalance1Before = liquidityManager.accountedBalances(currency1);

        // Prepare for deposit
        vm.startPrank(owner);

        // Ensure owner has sufficient token balances
        uint256 ownerBalance0Before = currency0.balanceOf(owner);
        uint256 ownerBalance1Before = currency1.balanceOf(owner);

        if (ownerBalance0Before < depositAmount0) {
            MockERC20(Currency.unwrap(currency0)).mint(owner, depositAmount0 - ownerBalance0Before + 1 ether);
        }
        if (ownerBalance1Before < depositAmount1) {
            MockERC20(Currency.unwrap(currency1)).mint(owner, depositAmount1 - ownerBalance1Before + 1 ether);
        }

        // Approve tokens to liquidityManager
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), depositAmount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), depositAmount1);

        // Execute deposit
        (uint256 sharesReceived, uint256 amount0Used, uint256 amount1Used) = spot.depositToFRLM(
            poolKey,
            depositAmount0,
            depositAmount1,
            0, // No minimum amounts for simplicity
            0,
            owner
        );

        vm.stopPrank();

        // Verify deposit was successful
        assertGt(sharesReceived, 0, "No shares were issued");

        // Get final state
        (uint256 pendingFee0After, uint256 pendingFee1After) = liquidityManager.getPendingFees(poolId);
        (uint256 positionIdAfter, uint128 liquidityAfter,,) = liquidityManager.getPositionInfo(poolId);

        // Track accounted balances after deposit
        uint256 accountedBalance0After = liquidityManager.accountedBalances(currency0);
        uint256 accountedBalance1After = liquidityManager.accountedBalances(currency1);

        // Calculate fee increases
        uint256 fee0Increase = pendingFee0After - pendingFee0Before;
        uint256 fee1Increase = pendingFee1After - pendingFee1Before;

        // Calculate accounted balance increases
        uint256 accountedBalance0Increase = accountedBalance0After - accountedBalance0Before;
        uint256 accountedBalance1Increase = accountedBalance1After - accountedBalance1Before;

        // Verify position state
        if (positionIdBefore == 0) {
            assertGt(positionIdAfter, 0, "Position should have been created");
            assertEq(
                liquidityAfter,
                sharesReceived + MIN_LOCKED_LIQUIDITY,
                "Liquidity should match shares + locked amount for new position"
            );
        } else {
            assertEq(positionIdAfter, positionIdBefore, "Position ID should not change");
            assertEq(
                liquidityAfter,
                liquidityBefore + sharesReceived,
                "Liquidity should increase by shares amount for existing position"
            );
        }

        // Key verification: check that fee accounting was done correctly

        // 1. Verify that the amounts used in the deposit are properly accounted for
        assertApproxEqAbs(
            accountedBalance0Increase,
            fee0Increase,
            1,
            "Accounted balance0 should only increase by the fees(since rest is deployed to NFT or refunded)"
        );

        assertApproxEqAbs(
            accountedBalance1Increase,
            fee1Increase,
            1,
            "Accounted balance1 should only increase by the fees(since rest is deployed to NFT or refunded)"
        );
    }

    // - - - other test helpers - - -

    /**
     * @notice Helper function to perform a deposit and reduce stack depth
     * @param amount0Desired The amount of token0 to deposit
     * @param amount1Desired The amount of token1 to deposit
     * @param amount0Min The minimum amount of token0 to accept
     * @param amount1Min The minimum amount of token1 to accept
     * @return shares The number of shares received
     * @return amount0Used The amount of token0 used
     * @return amount1Used The amount of token1 used
     */
    function _performDeposit(uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min)
        internal
        returns (uint256 shares, uint256 amount0Used, uint256 amount1Used)
    {
        (shares, amount0Used, amount1Used) = spot.depositToFRLM(
            poolKey,
            amount0Desired,
            amount1Desired,
            amount0Min,
            amount1Min,
            owner // Deposit to owner as recipient
        );

        return (shares, amount0Used, amount1Used);
    }

    // - - - depositToFRLM tests - - -

    /**
     * @notice Tests basic deposit functionality as the policy owner
     */
    function test_Deposit_PolicyOwner_Basic() public {
        // Setup - make sure owner has tokens and approvals
        vm.startPrank(owner);

        // Define deposit amounts
        uint256 amount0Desired = 5 ether;
        uint256 amount1Desired = 5 ether;
        uint256 amount0Min = 4.9 ether; // 2% slippage tolerance
        uint256 amount1Min = 4.9 ether; // 2% slippage tolerance

        // Ensure owner has sufficient token balances
        uint256 ownerBalance0Before = currency0.balanceOf(owner);
        uint256 ownerBalance1Before = currency1.balanceOf(owner);

        if (ownerBalance0Before < amount0Desired) {
            MockERC20(Currency.unwrap(currency0)).mint(owner, amount0Desired - ownerBalance0Before + 1 ether);
        }
        if (ownerBalance1Before < amount1Desired) {
            MockERC20(Currency.unwrap(currency1)).mint(owner, amount1Desired - ownerBalance1Before + 1 ether);
        }

        // Ensure tokens are approved to the FRLM contract for transfer(NOT the Spot)
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), amount0Desired);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), amount1Desired);

        // Get initial state for comparisons
        uint256 initialShares = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));
        uint256 initialLiquidityManagerBalance0 = currency0.balanceOf(address(liquidityManager));
        uint256 initialLiquidityManagerBalance1 = currency1.balanceOf(address(liquidityManager));

        // Get position info before deposit
        (uint256 positionId, uint128 liquidityBefore,,) = liquidityManager.getPositionInfo(poolId);
        assertEq(positionId, 0, "Since no FRLM NFT has yet been minted id should default to 0");
        uint256 nextTokenId = lpm.nextTokenId();

        // Execute deposit
        (uint256 sharesReceived, uint256 amount0Used, uint256 amount1Used) = spot.depositToFRLM(
            poolKey,
            amount0Desired,
            amount1Desired,
            amount0Min,
            amount1Min,
            owner // Deposit to owner as recipient
        );

        // Verify shares were received
        assertGt(sharesReceived, 0, "No shares were issued for deposit");

        // Verify shares were minted to the owner
        uint256 newShares = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));
        assertEq(newShares - initialShares, sharesReceived, "Shares balance didn't increase by expected amount");

        // Verify amounts used are within expected range
        assertGe(amount0Used, amount0Min, "Amount0 used is less than minimum");
        assertLe(amount0Used, amount0Desired, "Amount0 used is more than desired");
        assertGe(amount1Used, amount1Min, "Amount1 used is less than minimum");
        assertLe(amount1Used, amount1Desired, "Amount1 used is more than desired");

        // Verify owner balances decreased by the amounts used
        uint256 ownerBalance0After = currency0.balanceOf(owner);
        uint256 ownerBalance1After = currency1.balanceOf(owner);

        assertApproxEqAbs(
            ownerBalance0Before - ownerBalance0After,
            amount0Used,
            1,
            "Owner token0 balance did not decrease by the exact amount used"
        );
        assertApproxEqAbs(
            ownerBalance1Before - ownerBalance1After,
            amount1Used,
            1,
            "Owner token1 balance did not decrease by the exact amount used"
        );

        // Verify that ERC6909 shares correspond to increased position liquidity
        (, uint128 liquidityAfter,,) = liquidityManager.getPositionInfo(poolId);
        assertEq(
            liquidityAfter,
            liquidityBefore + sharesReceived + MIN_LOCKED_LIQUIDITY,
            "Position liquidity did not increase as expected"
        );

        // Verify that refunds are handled correctly for unused tokens
        uint256 refund0 = amount0Desired - amount0Used;
        uint256 refund1 = amount1Desired - amount1Used;

        // If there were refunds, verify they went back to the owner
        if (refund0 > 0) {
            assertApproxEqAbs(
                ownerBalance0After, ownerBalance0Before - amount0Used, 1, "Unused token0 not properly refunded"
            );
        }

        if (refund1 > 0) {
            assertApproxEqAbs(
                ownerBalance1After, ownerBalance1Before - amount1Used, 1, "Unused token1 not properly refunded"
            );
        }

        (uint256 finalPositionId,,,) = liquidityManager.getPositionInfo(poolId);

        // Verify that the position NFT exists
        assertEq(nextTokenId, finalPositionId, "Position ID is as expected");

        // Validate that tokens didn't get stuck in the Spot contract
        assertEq(currency0.balanceOf(address(spot)), 0, "Tokens got stuck in Spot contract");
        assertEq(currency1.balanceOf(address(spot)), 0, "Tokens got stuck in Spot contract");

        vm.stopPrank();
    }

    /**
     * @notice Tests deposit with unbalanced token amounts
     * @dev Tests depositing significantly more of token0 than token1
     */
    function test_Deposit_PolicyOwner_Unbalanced() public {
        // Setup - make sure owner has tokens and approvals
        vm.startPrank(owner);

        // Define UNBALANCED deposit amounts - much more token0 than token1
        uint256 amount0Desired = 10 ether; // More token0
        uint256 amount1Desired = 2 ether; // Less token1

        // Set very low minimums to prevent slippage errors
        // With highly unbalanced ratios, actual usage can be hard to predict
        uint256 amount0Min = 1 ether; // Much lower minimum
        uint256 amount1Min = 1 ether; // Much lower minimum

        // Ensure owner has sufficient token balances
        uint256 ownerBalance0Before = currency0.balanceOf(owner);
        uint256 ownerBalance1Before = currency1.balanceOf(owner);

        if (ownerBalance0Before < amount0Desired) {
            MockERC20(Currency.unwrap(currency0)).mint(owner, amount0Desired - ownerBalance0Before + 1 ether);
        }
        if (ownerBalance1Before < amount1Desired) {
            MockERC20(Currency.unwrap(currency1)).mint(owner, amount1Desired - ownerBalance1Before + 1 ether);
        }

        // Update balances after minting
        ownerBalance0Before = currency0.balanceOf(owner);
        ownerBalance1Before = currency1.balanceOf(owner);

        // Ensure tokens are approved to the FRLM contract for transfer
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), amount0Desired);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), amount1Desired);

        // Get initial state for comparisons
        uint256 initialShares = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));
        (uint256 positionIdBefore, uint128 liquidityBefore,,) = liquidityManager.getPositionInfo(poolId);

        // If this is the first deposit, positionId should be 0
        if (initialShares == 0) {
            assertEq(positionIdBefore, 0, "Since no FRLM NFT has yet been minted id should default to 0");
        }

        uint256 nextTokenId = lpm.nextTokenId();

        // Execute deposit with unbalanced amounts
        (uint256 sharesReceived, uint256 amount0Used, uint256 amount1Used) = spot.depositToFRLM(
            poolKey,
            amount0Desired,
            amount1Desired,
            amount0Min,
            amount1Min,
            owner // Deposit to owner as recipient
        );

        // Log the actual amounts used for debugging
        console.log("Amount0 used:", amount0Used);
        console.log("Amount1 used:", amount1Used);
        console.log("Refund0:", amount0Desired - amount0Used);
        console.log("Refund1:", amount1Desired - amount1Used);

        // Verify shares were received
        assertGt(sharesReceived, 0, "No shares were issued for deposit");

        // Verify shares were minted to the owner
        uint256 newShares = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));
        assertEq(newShares - initialShares, sharesReceived, "Shares balance didn't increase by expected amount");

        // Verify amounts used are within expected range
        assertGe(amount0Used, amount0Min, "Amount0 used is less than minimum");
        assertLe(amount0Used, amount0Desired, "Amount0 used is more than desired");
        assertGe(amount1Used, amount1Min, "Amount1 used is less than minimum");
        assertLe(amount1Used, amount1Desired, "Amount1 used is more than desired");

        // With unbalanced deposit, we expect some refund
        uint256 refund0 = amount0Desired - amount0Used;
        uint256 refund1 = amount1Desired - amount1Used;

        // At least one token should have significant refund in an unbalanced deposit
        assertGt(refund0 + refund1, 0, "Expected some refund with unbalanced deposit");

        // Verify owner balances decreased by the correct amounts (accounting for refunds)
        uint256 ownerBalance0After = currency0.balanceOf(owner);
        uint256 ownerBalance1After = currency1.balanceOf(owner);

        assertApproxEqAbs(
            ownerBalance0Before - ownerBalance0After,
            amount0Used,
            1,
            "Owner token0 balance did not decrease by the exact amount used"
        );
        assertApproxEqAbs(
            ownerBalance1Before - ownerBalance1After,
            amount1Used,
            1,
            "Owner token1 balance did not decrease by the exact amount used"
        );

        // Verify refunds were properly sent back to owner
        assertApproxEqAbs(
            ownerBalance0After, ownerBalance0Before - amount0Used, 1, "Unused token0 not properly refunded"
        );
        assertApproxEqAbs(
            ownerBalance1After, ownerBalance1Before - amount1Used, 1, "Unused token1 not properly refunded"
        );

        // Verify that ERC6909 shares correspond to increased position liquidity
        (uint256 finalPositionId, uint128 liquidityAfter,,) = liquidityManager.getPositionInfo(poolId);

        // If this is the first deposit, verify that the position NFT was created with expected ID
        if (positionIdBefore == 0) {
            assertEq(nextTokenId, finalPositionId, "Position ID is not as expected");
        } else {
            assertEq(positionIdBefore, finalPositionId, "Position ID changed unexpectedly");
        }

        assertEq(
            liquidityAfter,
            liquidityBefore + sharesReceived + (positionIdBefore == 0 ? MIN_LOCKED_LIQUIDITY : 0),
            "Position liquidity did not increase as expected"
        );

        // Validate that tokens didn't get stuck in the Spot contract
        assertEq(currency0.balanceOf(address(spot)), 0, "Tokens got stuck in Spot contract");
        assertEq(currency1.balanceOf(address(spot)), 0, "Tokens got stuck in Spot contract");

        vm.stopPrank();
    }

    /**
     * @notice Tests deposit with native ETH as one of the tokens
     * @dev Tests depositing into a pool where currency0 is native ETH (address(0))
     */
    function test_Deposit_WithNativeETH() public {
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
        uint256 ethMin = 0.5 ether;
        uint256 tokenMin = 1 ether;

        // Ensure owner has a more than enough balance
        testToken.mint(owner, 100 ether);
        vm.deal(owner, ethAmount * 3); // Enough for initial deposit and excess test

        // Grant infinite token allowance to FRLM
        testToken.approve(address(liquidityManager), type(uint256).max);

        // Get initial balances for verification
        uint256 initialTokenBalance = testToken.balanceOf(owner);
        uint256 initialEthBalance = owner.balance;

        // Get initial position state
        (uint256 positionIdBefore, uint128 liquidityBefore,,) = liquidityManager.getPositionInfo(ethPoolId);
        uint256 initialShares = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(ethPoolId)));
        assertEq(positionIdBefore, 0, "No position should exist yet");

        // Expected next position ID
        uint256 nextTokenId = lpm.nextTokenId();

        // Execute deposit with native ETH
        (uint256 sharesReceived, uint256 amount0Used, uint256 amount1Used) = spot.depositToFRLM{value: ethAmount}(
            ethPoolKey,
            ethAmount, // ETH amount (currency0)
            tokenAmount, // Token amount (currency1)
            ethMin, // ETH min
            tokenMin, // Token min
            owner
        );

        // Verify shares received
        assertGt(sharesReceived, 0, "No shares issued for ETH deposit");

        // Verify token balances changed correctly
        uint256 finalTokenBalance = testToken.balanceOf(owner);
        uint256 finalEthBalance = owner.balance;

        // Since ETH is currency0, amount0Used is ETH and amount1Used is token
        uint256 ethUsed = amount0Used;
        uint256 tokenUsed = amount1Used;

        // Verify ETH used - since we're in a test environment, we can check exact amount
        assertApproxEqAbs(
            initialEthBalance - finalEthBalance, ethUsed, 1, "ETH balance did not decrease by the exact amount used"
        );

        // Verify token spent
        assertApproxEqAbs(
            initialTokenBalance - finalTokenBalance,
            tokenUsed,
            1,
            "Token balance did not decrease by the exact amount used"
        );

        // Verify position was created correctly
        (uint256 positionIdAfter, uint128 liquidityAfter,,) = liquidityManager.getPositionInfo(ethPoolId);
        assertEq(positionIdAfter, nextTokenId, "Position ID is not as expected");
        assertEq(
            liquidityAfter,
            liquidityBefore + sharesReceived + MIN_LOCKED_LIQUIDITY,
            "Position liquidity did not increase as expected"
        );

        // Verify shares were minted correctly
        uint256 newShares = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(ethPoolId)));
        assertEq(newShares - initialShares, sharesReceived, "Shares not minted correctly");

        // Test ETH refund mechanism by sending excess ETH
        uint256 excessEthAmount = ethAmount * 2;
        uint256 balanceBeforeExcess = owner.balance;

        // Call with excess ETH to test refund
        (, uint256 amount0UsedFinal, uint256 amount1UsedFinal) = spot.depositToFRLM{value: excessEthAmount}(
            ethPoolKey,
            ethAmount, // Less than what we're sending
            tokenAmount,
            ethMin,
            tokenMin,
            owner
        );

        // Verify ETH was refunded exactly
        uint256 balanceAfterExcess = owner.balance;
        uint256 ownerBalanceChange = balanceBeforeExcess - balanceAfterExcess;

        // Since we're in a test environment with no gas costs, the ETH spent should be exactly what was used
        assertApproxEqAbs(
            ethAmount, amount0UsedFinal, 1, "ETH spent should match exactly what was used (no gas costs in test)"
        );

        // Verify the excess was refunded (sent amount - used amount)
        assertEq(
            ownerBalanceChange, excessEthAmount - (excessEthAmount - ethAmount), "Excess ETH was not refunded correctly"
        );

        // Test minimum amount enforcement
        // Try to deposit with a minimum ETH requirement that can't be met
        uint256 impossibleEthMin = ethAmount * 2; // Minimum higher than what we're providing

        // This should revert with a "too little" error
        vm.expectRevert(abi.encodeWithSelector(Errors.TooLittleAmount0.selector, impossibleEthMin, ethAmount - 1));
        spot.depositToFRLM{value: ethAmount}(
            ethPoolKey,
            ethAmount,
            tokenAmount,
            impossibleEthMin, // Impossible minimum
            tokenMin,
            owner
        );

        vm.stopPrank();
    }

    /**
     * @notice Tests deposit specifying a recipient different from the policy owner
     * @dev Tests:
     * - Policy owner initiating deposit and paying for it
     * - Verification that shares are minted to a different recipient
     * - Proper refund of unused tokens to the policy owner
     */
    function test_Deposit_DifferentRecipient() public {
        // Setup - prepare the policy owner with tokens and approvals
        vm.startPrank(owner);

        // Define deposit amounts
        uint256 amount0Desired = 5 ether;
        uint256 amount1Desired = 5 ether;
        uint256 amount0Min = 4.9 ether; // 2% slippage tolerance
        uint256 amount1Min = 4.9 ether; // 2% slippage tolerance

        // Ensure owner has sufficient token balances
        uint256 ownerBalance0Before = currency0.balanceOf(owner);
        uint256 ownerBalance1Before = currency1.balanceOf(owner);

        if (ownerBalance0Before < amount0Desired) {
            MockERC20(Currency.unwrap(currency0)).mint(owner, amount0Desired - ownerBalance0Before + 1 ether);
        }
        if (ownerBalance1Before < amount1Desired) {
            MockERC20(Currency.unwrap(currency1)).mint(owner, amount1Desired - ownerBalance1Before + 1 ether);
        }

        // Update balances after potential minting
        ownerBalance0Before = currency0.balanceOf(owner);
        ownerBalance1Before = currency1.balanceOf(owner);

        // Ensure tokens are approved to the FRLM contract for transfer
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), amount0Desired);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), amount1Desired);

        // Setup recipient (user1) to receive shares
        address recipient = user1;
        uint256 recipientSharesBefore = liquidityManager.balanceOf(recipient, uint256(PoolId.unwrap(poolId)));

        // Check initial position state
        (uint256 positionIdBefore, uint128 liquidityBefore,,) = liquidityManager.getPositionInfo(poolId);
        if (positionIdBefore == 0) {
            // If no position exists yet, record next token ID
            // as we expect a new NFT to be minted
            positionIdBefore = lpm.nextTokenId();
        }

        // Execute deposit as policy owner, specifying user1 as recipient
        (uint256 sharesReceived, uint256 amount0Used, uint256 amount1Used) = spot.depositToFRLM(
            poolKey,
            amount0Desired,
            amount1Desired,
            amount0Min,
            amount1Min,
            recipient // User1 receives the shares
        );

        // Verify shares were received
        assertGt(sharesReceived, 0, "No shares were issued for deposit");

        // Verify shares were minted to the recipient (user1), not the caller/payer (owner)
        uint256 recipientSharesAfter = liquidityManager.balanceOf(recipient, uint256(PoolId.unwrap(poolId)));
        assertEq(
            recipientSharesAfter - recipientSharesBefore, sharesReceived, "Recipient did not receive correct shares"
        );

        // Verify owner (payer) balances decreased by the amounts used
        uint256 ownerBalance0After = currency0.balanceOf(owner);
        uint256 ownerBalance1After = currency1.balanceOf(owner);

        assertApproxEqAbs(
            ownerBalance0Before - ownerBalance0After,
            amount0Used,
            1,
            "Owner token0 balance did not decrease by the exact amount used"
        );
        assertApproxEqAbs(
            ownerBalance1Before - ownerBalance1After,
            amount1Used,
            1,
            "Owner token1 balance did not decrease by the exact amount used"
        );

        // Verify that unused tokens were refunded to the owner (payer)
        uint256 refund0 = amount0Desired - amount0Used;
        uint256 refund1 = amount1Desired - amount1Used;

        if (refund0 > 0) {
            assertApproxEqAbs(
                ownerBalance0After, ownerBalance0Before - amount0Used, 1, "Unused token0 not properly refunded to owner"
            );
        }

        if (refund1 > 0) {
            assertApproxEqAbs(
                ownerBalance1After, ownerBalance1Before - amount1Used, 1, "Unused token1 not properly refunded to owner"
            );
        }

        // Verify position state updates
        (uint256 positionIdAfter, uint128 liquidityAfter,,) = liquidityManager.getPositionInfo(poolId);

        if (positionIdBefore == 0 || positionIdBefore == lpm.nextTokenId() - 1) {
            // If this was a new position, verify NFT was created correctly
            assertGt(positionIdAfter, 0, "Position was not created");
        } else {
            // If adding to existing position, verify ID didn't change
            assertEq(positionIdAfter, positionIdBefore, "Position ID changed unexpectedly");
        }

        // Verify liquidity increased
        uint256 expectedLiquidityIncrease = sharesReceived;
        if (liquidityBefore == 0) {
            expectedLiquidityIncrease += MIN_LOCKED_LIQUIDITY; // Account for locked liquidity on first deposit
        }

        assertApproxEqAbs(
            liquidityAfter,
            liquidityBefore + expectedLiquidityIncrease,
            1,
            "Position liquidity did not increase as expected"
        );

        // Verify no tokens got stuck anywhere unexpected
        assertEq(currency0.balanceOf(address(spot)), 0, "Tokens got stuck in Spot contract");
        assertEq(currency1.balanceOf(address(spot)), 0, "Tokens got stuck in Spot contract");

        // Verify owner did not receive any shares
        uint256 ownerShares = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));
        assertEq(ownerShares, 0, "Owner incorrectly received shares when specifying different recipient");

        vm.stopPrank();
    }

    /**
     * @notice Tests deposit with minimum amount enforcement
     * @dev Should test:
     * - Setting minimum amounts above what will be used
     * - Verification that the transaction reverts with expected error
     */
    function test_Deposit_MinimumAmountEnforcement() public {
        // Implementation to be added
    }

    /**
     * @notice Tests deposit with a very small amount
     * @dev Should test:
     * - Deposit with minimal token amounts
     * - Ensuring the position still functions correctly
     * - Check for any dust-related issues
     */
    function test_Deposit_SmallAmount() public {
        // Implementation to be added
    }

    /**
     * @notice Tests that only policy owner can call depositToFRLM
     * @dev Tests:
     * - Non-owner trying to deposit
     * - Verification that the call reverts with unauthorized error
     */
    function test_Deposit_OnlyPolicyOwner() public {
        // Setup - prepare a non-owner account (user1)
        vm.startPrank(user1);

        // Define some deposit parameters
        uint256 amount0Desired = 1 ether;
        uint256 amount1Desired = 1 ether;
        uint256 amount0Min = 0.5 ether;
        uint256 amount1Min = 0.5 ether;

        // Ensure user1 has sufficient token balances (though the call should revert before using them)
        MockERC20(Currency.unwrap(currency0)).mint(user1, amount0Desired);
        MockERC20(Currency.unwrap(currency1)).mint(user1, amount1Desired);

        // Approve tokens to the FRLM contract (though the call should revert before using them)
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), amount0Desired);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), amount1Desired);

        // Attempt to call depositToFRLM as non-owner (user1)
        // This should revert with UnauthorizedCaller error
        vm.expectRevert(abi.encodeWithSelector(Errors.UnauthorizedCaller.selector, user1));
        spot.depositToFRLM(
            poolKey,
            amount0Desired,
            amount1Desired,
            amount0Min,
            amount1Min,
            user1 // Recipient is also user1
        );

        vm.stopPrank();

        // Now try with user2 as well to verify it's not just user1 that's restricted
        vm.startPrank(user2);

        // Attempt to call depositToFRLM as another non-owner (user2)
        vm.expectRevert(abi.encodeWithSelector(Errors.UnauthorizedCaller.selector, user2));
        spot.depositToFRLM(
            poolKey,
            amount0Desired,
            amount1Desired,
            amount0Min,
            amount1Min,
            user2 // Recipient is also user2
        );

        vm.stopPrank();

        // Finally, verify that the policy owner can call this function without reverting
        vm.startPrank(owner);

        // Ensure owner has tokens and approvals
        MockERC20(Currency.unwrap(currency0)).mint(owner, amount0Desired);
        MockERC20(Currency.unwrap(currency1)).mint(owner, amount1Desired);
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), amount0Desired);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), amount1Desired);

        // This should not revert
        spot.depositToFRLM(poolKey, amount0Desired, amount1Desired, amount0Min, amount1Min, owner);

        vm.stopPrank();
    }

    /**
     * @notice Tests multiple deposits to the same position
     * @dev Tests:
     * - Making multiple deposits
     * - Verifying cumulative shares issuance
     * - Check position growth over multiple deposits
     */
    function test_Deposit_Multiple() public {
        // Setup - make sure owner has tokens and approvals
        vm.startPrank(owner);

        // Ensure owner has sufficient token balances for all deposits (15 ether total for each token)
        uint256 totalAmountDesired = 15 ether;

        uint256 ownerBalance0 = currency0.balanceOf(owner);
        uint256 ownerBalance1 = currency1.balanceOf(owner);

        if (ownerBalance0 < totalAmountDesired) {
            MockERC20(Currency.unwrap(currency0)).mint(owner, totalAmountDesired - ownerBalance0 + 1 ether);
        }
        if (ownerBalance1 < totalAmountDesired) {
            MockERC20(Currency.unwrap(currency1)).mint(owner, totalAmountDesired - ownerBalance1 + 1 ether);
        }

        // Ensure tokens are approved to the FRLM contract for transfer
        MockERC20(Currency.unwrap(currency0)).approve(address(liquidityManager), totalAmountDesired);
        MockERC20(Currency.unwrap(currency1)).approve(address(liquidityManager), totalAmountDesired);

        // Record initial position state
        (uint256 initialPositionId, uint128 initialLiquidity,,) = liquidityManager.getPositionInfo(poolId);
        uint256 initialShares = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));

        bool firstDeposit = (initialPositionId == 0);
        uint256 expectedPositionId = firstDeposit ? lpm.nextTokenId() : initialPositionId;

        // --- FIRST DEPOSIT ---
        (uint256 sharesFirst, uint256 amount0UsedFirst, uint256 amount1UsedFirst) =
            _performDeposit(3 ether, 3 ether, 2.9 ether, 2.9 ether);

        // Verify shares were received for first deposit
        assertGt(sharesFirst, 0, "No shares were issued for first deposit");

        // Get position info after first deposit
        (uint256 positionIdAfterFirst, uint128 liquidityAfterFirst,,) = liquidityManager.getPositionInfo(poolId);
        uint256 sharesAfterFirst = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));

        // Verify position ID
        assertEq(positionIdAfterFirst, expectedPositionId, "Position ID not as expected after first deposit");

        // Verify shares and liquidity after first deposit
        uint256 expectedLiquidityIncreaseFirst = sharesFirst;
        if (firstDeposit) {
            expectedLiquidityIncreaseFirst += MIN_LOCKED_LIQUIDITY; // Account for locked liquidity on first deposit
        }

        assertEq(
            liquidityAfterFirst,
            initialLiquidity + expectedLiquidityIncreaseFirst,
            "Position liquidity incorrect after first deposit"
        );
        assertEq(sharesAfterFirst, initialShares + sharesFirst, "Shares balance incorrect after first deposit");

        // --- SECOND DEPOSIT ---
        (uint256 sharesSecond, uint256 amount0UsedSecond, uint256 amount1UsedSecond) =
            _performDeposit(5 ether, 5 ether, 4.9 ether, 4.9 ether);

        // Verify shares were received for second deposit
        assertGt(sharesSecond, 0, "No shares were issued for second deposit");

        // Get position info after second deposit
        (uint256 positionIdAfterSecond, uint128 liquidityAfterSecond,,) = liquidityManager.getPositionInfo(poolId);
        uint256 sharesAfterSecond = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));

        // Verify position ID remains the same
        assertEq(positionIdAfterSecond, positionIdAfterFirst, "Position ID changed after second deposit");

        // Verify shares and liquidity after second deposit
        assertEq(
            liquidityAfterSecond,
            liquidityAfterFirst + sharesSecond,
            "Position liquidity incorrect after second deposit"
        );
        assertEq(sharesAfterSecond, sharesAfterFirst + sharesSecond, "Shares balance incorrect after second deposit");

        // --- THIRD DEPOSIT ---
        (uint256 sharesThird, uint256 amount0UsedThird, uint256 amount1UsedThird) =
            _performDeposit(2 ether, 2 ether, 1.9 ether, 1.9 ether);

        // Verify shares were received for third deposit
        assertGt(sharesThird, 0, "No shares were issued for third deposit");

        // Get position info after third deposit
        (uint256 positionIdAfterThird, uint128 liquidityAfterThird,,) = liquidityManager.getPositionInfo(poolId);
        uint256 sharesAfterThird = liquidityManager.balanceOf(owner, uint256(PoolId.unwrap(poolId)));

        // Verify position ID remains the same
        assertEq(positionIdAfterThird, positionIdAfterSecond, "Position ID changed after third deposit");

        // Verify shares and liquidity after third deposit
        assertEq(
            liquidityAfterThird, liquidityAfterSecond + sharesThird, "Position liquidity incorrect after third deposit"
        );
        assertEq(sharesAfterThird, sharesAfterSecond + sharesThird, "Shares balance incorrect after third deposit");

        // --- FINAL VERIFICATION ---

        // Verify total shares issued matches the difference between final and initial shares
        uint256 totalSharesIssued = sharesFirst + sharesSecond + sharesThird;
        assertEq(
            sharesAfterThird - initialShares, totalSharesIssued, "Total shares issued incorrect after all deposits"
        );

        // Verify total liquidity increase matches total shares plus any locked liquidity
        uint256 totalLiquidityIncrease = totalSharesIssued;
        if (firstDeposit) {
            totalLiquidityIncrease += MIN_LOCKED_LIQUIDITY; // Account for locked liquidity on first deposit
        }

        assertEq(
            liquidityAfterThird - initialLiquidity,
            totalLiquidityIncrease,
            "Total liquidity increase incorrect after all deposits"
        );

        // Verify we have a full range NFT position with the correct ID
        assertEq(positionIdAfterThird, expectedPositionId, "Final position ID not as expected");

        vm.stopPrank();
    }

    /**
     * @notice Tests fee accrual during deposit from position operations
     * @dev Tests that any fees earned during position operations are correctly captured
     * This is particularly important as the notification system is a critical component
     */
    function test_Deposit_FeeAccrual() public {
        // Test basic fee accrual with reinvestment paused
        _testDepositFeeAccrual(
            true, // reinvestmentPaused
            200000, // polShare (20%)
            5, // numPreSwaps
            1 ether, // swapAmount
            3 ether, // depositAmount0
            3 ether // depositAmount1
        );
    }

    /**
     * @notice Tests fee accrual during deposit with reinvestment enabled
     */
    function test_Deposit_FeeAccrual_WithReinvestment() public {
        // Test fee accrual with reinvestment enabled
        _testDepositFeeAccrual(
            false, // reinvestmentPaused (reinvestment enabled)
            200000, // polShare (20%)
            5, // numPreSwaps
            1 ether, // swapAmount
            3 ether, // depositAmount0
            3 ether // depositAmount1
        );
    }

    /**
     * @notice Tests fee accrual during deposit with no prior fees
     */
    function test_Deposit_FeeAccrual_NoPreSwaps() public {
        // Test deposit with no prior fees to collect
        _testDepositFeeAccrual(
            true, // reinvestmentPaused
            200000, // polShare (20%)
            0, // numPreSwaps (no swaps to generate fees)
            0, // swapAmount (not used)
            3 ether, // depositAmount0
            3 ether // depositAmount1
        );
    }

    /**
     * @notice Tests fee accrual during deposit with high POL share
     */
    function test_Deposit_FeeAccrual_HighPolShare() public {
        // Test with high POL share (50%)
        _testDepositFeeAccrual(
            true, // reinvestmentPaused
            500000, // polShare (50%)
            5, // numPreSwaps
            1 ether, // swapAmount
            3 ether, // depositAmount0
            3 ether // depositAmount1
        );
    }

    /**
     * @notice Tests fee accrual during deposit with zero POL share
     */
    function test_Deposit_FeeAccrual_ZeroPolShare() public {
        // Test with zero POL share (no hook fees)
        _testDepositFeeAccrual(
            true, // reinvestmentPaused
            0, // polShare (0%)
            5, // numPreSwaps
            1 ether, // swapAmount
            3 ether, // depositAmount0
            3 ether // depositAmount1
        );
    }
}
