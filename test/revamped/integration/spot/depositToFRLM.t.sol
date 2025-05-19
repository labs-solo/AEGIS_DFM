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

contract Spot_DepositToFRLM_Test is Base_Test {
    function setUp() public override {
        Base_Test.setUp();
    }

    // - - - parametrized test helpers - - -

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
            fee: 3000, // 0.3% fee
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
     * @notice Tests deposit using a payer different from the recipient
     * @dev Should test:
     * - Policy owner initiating deposit but tokens coming from another account
     * - Verification that shares are minted to the recipient (not the payer)
     * - Proper refund of unused tokens to the payer
     */
    function test_Deposit_SeparatePayerAndRecipient() public {
        // Implementation to be added
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
     * @dev Should test:
     * - Non-owner trying to deposit
     * - Verification that the call reverts with unauthorized error
     */
    function test_Deposit_OnlyPolicyOwner() public {
        // Implementation to be added
    }

    /**
     * @notice Tests multiple deposits to the same position
     * @dev Should test:
     * - Making multiple deposits
     * - Verifying cumulative shares issuance
     * - Check position growth over multiple deposits
     */
    function test_Deposit_Multiple() public {
        // Implementation to be added
    }

    /**
     * @notice Tests deposit with exact amounts from price calculation
     * @dev Should test:
     * - Calculating exact balanced amounts based on current price
     * - Depositing with those precise amounts
     * - Verifying maximum utilization of tokens
     */
    function test_Deposit_ExactAmounts() public {
        // Implementation to be added
    }
}
