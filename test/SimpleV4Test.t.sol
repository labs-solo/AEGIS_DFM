// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "./LocalUniswapV4TestBase.t.sol";
import "forge-std/console2.sol";
// Import the necessary structs from FullRange interfaces
import {DepositParams, WithdrawParams} from "../src/interfaces/IFullRange.sol";

/**
 * @title SimpleV4Test
 * @notice A simple test suite that verifies basic Uniswap V4 operations with our hook
 * @dev This file MUST be compiled with Solidity 0.8.26 to ensure hook address validation works correctly
 */
contract SimpleV4Test is LocalUniswapV4TestBase {
    function setUp() public override {
        console2.log("SimpleV4Test: Beginning setup");
        
        // Call the parent setUp to initialize the environment
        super.setUp();
    }
    
    /**
     * @notice Tests that a user can add liquidity to a Uniswap V4 pool through the FullRange hook
     * @dev This test ensures the hook correctly handles liquidity provision and updates token balances
     */
    function test_addLiquidity() public {
        // ======================= ARRANGE =======================
        // Set a small liquidity amount to avoid arithmetic overflow in token transfers
        uint128 liquidityAmount = 1e9;
        
        // Record Alice's initial token balances for later comparison
        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceToken1Before = token1.balanceOf(alice);
        console2.log("Alice token0 balance before:", aliceToken0Before);
        console2.log("Alice token1 balance before:", aliceToken1Before);
        
        // Approve tokens for the FullRange hook to transfer
        vm.startPrank(alice);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        
        // ======================= ACT =======================
        // Use the proper deposit flow to add liquidity
        DepositParams memory params = DepositParams({
            poolId: poolId,
            amount0Desired: liquidityAmount,
            amount1Desired: liquidityAmount,
            minShares: 0,  // No slippage protection for this test
            deadline: block.timestamp + 1 hours
        });
        
        // Call deposit which will pull tokens and add liquidity
        (uint256 shares, uint256 amount0, uint256 amount1) = fullRange.deposit(params);
        vm.stopPrank();
        
        console2.log("Deposit successful - shares:", shares);
        console2.log("Amount0 used:", amount0);
        console2.log("Amount1 used:", amount1);
        
        // ======================= ASSERT =======================
        // Record Alice's token balances after adding liquidity
        uint256 aliceToken0After = token0.balanceOf(alice);
        uint256 aliceToken1After = token1.balanceOf(alice);
        console2.log("Alice token0 balance after:", aliceToken0After);
        console2.log("Alice token1 balance after:", aliceToken1After);
        
        // Verify that Alice's tokens were transferred
        assertEq(aliceToken0Before - aliceToken0After, amount0, "Alice's token0 balance should decrease by the exact deposit amount");
        assertEq(aliceToken1Before - aliceToken1After, amount1, "Alice's token1 balance should decrease by the exact deposit amount");
        
        // Verify shares were created
        assertGt(shares, 0, "Alice should have received shares");
        
        // Verify the hook has reserves
        (uint256 reserve0, uint256 reserve1, ) = fullRange.getPoolReservesAndShares(poolId);
        assertEq(reserve0, amount0, "Hook reserves should match deposit amount for token0");
        assertEq(reserve1, amount1, "Hook reserves should match deposit amount for token1");
    }
    
    /**
     * @notice Tests that a user can perform a token swap in a Uniswap V4 pool with the FullRange hook
     * @dev This test verifies swap execution, token transfers, and balance updates after a swap
     */
    function test_swap() public {
        // ======================= ARRANGE =======================
        // First add liquidity to enable swapping - a pool needs liquidity to facilitate swaps
        uint128 liquidityAmount = 1e9;
        
        // Approve tokens for the FullRange hook and deposit
        vm.startPrank(alice);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        
        // Use proper deposit flow
        DepositParams memory params = DepositParams({
            poolId: poolId,
            amount0Desired: liquidityAmount,
            amount1Desired: liquidityAmount,
            minShares: 0,  // No slippage protection for this test
            deadline: block.timestamp + 1 hours
        });
        
        // Deposit tokens to add liquidity
        (uint256 shares, , ) = fullRange.deposit(params);
        console2.log("Liquidity added, shares minted:", shares);
        vm.stopPrank();
        
        // Approve tokens for Bob (the swapper)
        vm.startPrank(bob);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        // Also approve tokens to the swapRouter (PoolSwapTest) since it calls transferFrom directly
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        
        // Record Bob's initial token balances before the swap
        uint256 bobToken0Before = token0.balanceOf(bob);
        uint256 bobToken1Before = token1.balanceOf(bob);
        console2.log("Bob token0 balance before swap:", bobToken0Before);
        console2.log("Bob token1 balance before swap:", bobToken1Before);
        
        // ======================= ACT =======================
        // Perform a swap: Bob trades token0 for token1
        // Use a small amount to avoid overflow issues
        uint256 swapAmount = 1e8;
        
        swapExactInput(bob, true, swapAmount);
        
        // ======================= ASSERT =======================
        // Record Bob's token balances after the swap
        uint256 bobToken0After = token0.balanceOf(bob);
        uint256 bobToken1After = token1.balanceOf(bob);
        console2.log("Bob token0 balance after swap:", bobToken0After);
        console2.log("Bob token1 balance after swap:", bobToken1After);
        
        // Verify the swap executed correctly:
        // 1. Bob should have spent some amount of token0 (which includes the swap fee)
        assertTrue(bobToken0Before > bobToken0After, "Bob should have spent some token0");
        // 2. Bob should have received some amount of token1 in return
        assertTrue(bobToken1After > bobToken1Before, "Bob should have received some token1 in exchange");
        // 3. Verify Bob received exactly the specified amount of token1
        assertEq(bobToken1After - bobToken1Before, swapAmount, "Bob should have received exactly the swap amount of token1");
    }
} 