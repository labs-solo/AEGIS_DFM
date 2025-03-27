// This file will be moved to the old-tests directory

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "./base/LocalUniswapV4TestBase.t.sol";
import "../src/interfaces/IFullRange.sol";

/**
 * @title FullRangeLocalTest
 * @notice Test suite for the FullRange contract using local deployments
 * This demonstrates how to leverage the LocalUniswapV4TestBase for clean, fast tests
 */
contract FullRangeLocalTest is LocalUniswapV4TestBase {
    // Additional setup specific to this test suite
    function setUp() public override {
        // Call the base setup first
        super.setUp();
        
        // Any additional setup specific to this test file
    }
    
    /**
     * @notice Test depositing into the FullRange hook
     */
    function test_deposit() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 10 ether;
        
        // Approve tokens for alice
        approveTokens(alice);
        
        // Deposit tokens into the hook
        vm.startPrank(alice);
        
        uint256 balanceBefore0 = token0.balanceOf(alice);
        uint256 balanceBefore1 = token1.balanceOf(alice);
        
        // Get initial shares - should be 0
        uint256 sharesBefore = fullRange.balanceOf(poolId, alice);
        assertEq(sharesBefore, 0, "Initial shares should be 0");
        
        // Deposit
        IFullRange.DepositParams memory params = IFullRange.DepositParams({
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: alice,
            deadline: block.timestamp + 100
        });
        
        fullRange.deposit(poolKey, params);
        
        // Verify balances changed
        uint256 balanceAfter0 = token0.balanceOf(alice);
        uint256 balanceAfter1 = token1.balanceOf(alice);
        
        assertEq(balanceBefore0 - balanceAfter0, amount0, "Token0 balance should decrease by deposit amount");
        assertEq(balanceBefore1 - balanceAfter1, amount1, "Token1 balance should decrease by deposit amount");
        
        // Verify shares were minted
        uint256 sharesAfter = fullRange.balanceOf(poolId, alice);
        assertTrue(sharesAfter > 0, "Shares should be minted");
        
        vm.stopPrank();
    }
    
    /**
     * @notice Test withdrawing from the FullRange hook
     */
    function test_withdraw() public {
        // First deposit
        test_deposit();
        
        // Get shares balance
        uint256 aliceShares = fullRange.balanceOf(poolId, alice);
        assertTrue(aliceShares > 0, "Alice should have shares");
        
        // Withdraw half of the shares
        uint256 sharesToWithdraw = aliceShares / 2;
        
        vm.startPrank(alice);
        
        uint256 balanceBefore0 = token0.balanceOf(alice);
        uint256 balanceBefore1 = token1.balanceOf(alice);
        
        // Withdraw
        IFullRange.WithdrawParams memory params = IFullRange.WithdrawParams({
            shares: sharesToWithdraw,
            amount0Min: 0,
            amount1Min: 0,
            recipient: alice,
            deadline: block.timestamp + 100
        });
        
        fullRange.withdraw(poolKey, params);
        
        // Verify balances changed
        uint256 balanceAfter0 = token0.balanceOf(alice);
        uint256 balanceAfter1 = token1.balanceOf(alice);
        
        assertTrue(balanceAfter0 > balanceBefore0, "Token0 balance should increase after withdrawal");
        assertTrue(balanceAfter1 > balanceBefore1, "Token1 balance should increase after withdrawal");
        
        // Verify shares were burned
        uint256 sharesAfter = fullRange.balanceOf(poolId, alice);
        assertEq(sharesAfter, aliceShares - sharesToWithdraw, "Shares should be burned");
        
        vm.stopPrank();
    }
    
    /**
     * @notice Test swapping through the pool and checking fee accrual
     */
    function test_swapAndFeeAccrual() public {
        // First deposit to provide liquidity
        test_deposit();
        
        // Track the initial fees for the pool
        uint256 feesBeforeToken0 = fullRange.getFeeGrowth0(poolId);
        uint256 feesBeforeToken1 = fullRange.getFeeGrowth1(poolId);
        
        // Bob performs a swap
        vm.startPrank(bob);
        approveTokens(bob);
        
        uint256 swapAmount = 1 ether;
        swapExactInput(bob, true, swapAmount); // Swap token0 for token1
        
        vm.stopPrank();
        
        // Check that fees have accrued
        uint256 feesAfterToken0 = fullRange.getFeeGrowth0(poolId);
        uint256 feesAfterToken1 = fullRange.getFeeGrowth1(poolId);
        
        assertTrue(feesAfterToken0 > feesBeforeToken0 || feesAfterToken1 > feesBeforeToken1, 
            "Fees should have accrued after swap");
    }
    
    /**
     * @notice Test reinvesting fees back into the pool
     */
    function test_reinvestFees() public {
        // Setup: Deposit and perform swaps to generate fees
        test_deposit();
        
        // Multiple swaps to generate fees
        for (uint256 i = 0; i < 5; i++) {
            // Alternate swap directions
            bool zeroForOne = i % 2 == 0;
            swapExactInput(bob, zeroForOne, 1 ether);
        }
        
        // Get initial position details
        uint128 liquidityBefore = fullRange.getLiquidity(poolId);
        
        // Reinvest fees
        vm.prank(governance);
        fullRange.reinvestFees(poolKey);
        
        // Verify liquidity increased due to fee reinvestment
        uint128 liquidityAfter = fullRange.getLiquidity(poolId);
        assertTrue(liquidityAfter > liquidityBefore, "Liquidity should increase after fee reinvestment");
    }
    
    /**
     * @notice Test multiple users depositing and withdrawing
     */
    function test_multiUserDepositsAndWithdraws() public {
        // Alice deposits
        uint256 aliceAmount = 10 ether;
        vm.startPrank(alice);
        approveTokens(alice);
        
        IFullRange.DepositParams memory aliceParams = IFullRange.DepositParams({
            amount0Desired: aliceAmount,
            amount1Desired: aliceAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: alice,
            deadline: block.timestamp + 100
        });
        
        fullRange.deposit(poolKey, aliceParams);
        vm.stopPrank();
        
        uint256 aliceShares = fullRange.balanceOf(poolId, alice);
        
        // Bob deposits twice as much
        uint256 bobAmount = 20 ether;
        vm.startPrank(bob);
        approveTokens(bob);
        
        IFullRange.DepositParams memory bobParams = IFullRange.DepositParams({
            amount0Desired: bobAmount,
            amount1Desired: bobAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: bob,
            deadline: block.timestamp + 100
        });
        
        fullRange.deposit(poolKey, bobParams);
        vm.stopPrank();
        
        uint256 bobShares = fullRange.balanceOf(poolId, bob);
        
        // Verify Bob got approximately 2x the shares (allowing for rounding)
        assertApproxEqRel(bobShares, aliceShares * 2, 0.01e18, "Bob should get ~2x Alice's shares");
        
        // Both withdraw all shares
        vm.startPrank(alice);
        IFullRange.WithdrawParams memory aliceWithdrawParams = IFullRange.WithdrawParams({
            shares: aliceShares,
            amount0Min: 0,
            amount1Min: 0,
            recipient: alice,
            deadline: block.timestamp + 100
        });
        
        fullRange.withdraw(poolKey, aliceWithdrawParams);
        vm.stopPrank();
        
        vm.startPrank(bob);
        IFullRange.WithdrawParams memory bobWithdrawParams = IFullRange.WithdrawParams({
            shares: bobShares,
            amount0Min: 0,
            amount1Min: 0,
            recipient: bob,
            deadline: block.timestamp + 100
        });
        
        fullRange.withdraw(poolKey, bobWithdrawParams);
        vm.stopPrank();
        
        // Verify both have withdrawn completely
        assertEq(fullRange.balanceOf(poolId, alice), 0, "Alice should have no shares left");
        assertEq(fullRange.balanceOf(poolId, bob), 0, "Bob should have no shares left");
    }
} 