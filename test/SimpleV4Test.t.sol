// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "./LocalUniswapV4TestBase.t.sol";
import "forge-std/console2.sol";

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
        console2.log("Alice token0 balance before:", token0.balanceOf(alice));
        console2.log("Alice token1 balance before:", token1.balanceOf(alice));
        
        // Approve the PoolManager to transfer tokens on Alice's behalf
        vm.startPrank(alice);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        vm.stopPrank();
        
        // ======================= ACT =======================
        // Add liquidity across the full range using our hook
        addFullRangeLiquidity(alice, liquidityAmount);
        
        // ======================= ASSERT =======================
        // Record Alice's token balances after adding liquidity
        console2.log("Alice token0 balance after:", token0.balanceOf(alice));
        console2.log("Alice token1 balance after:", token1.balanceOf(alice));
        
        // Verify liquidity was added by confirming token balances decreased
        // This ensures tokens were transferred from Alice to the pool
        assertTrue(token0.balanceOf(alice) < INITIAL_TOKEN_BALANCE, "Token0 balance should decrease after adding liquidity");
        assertTrue(token1.balanceOf(alice) < INITIAL_TOKEN_BALANCE, "Token1 balance should decrease after adding liquidity");
    }
    
    /**
     * @notice Tests that a user can perform a token swap in a Uniswap V4 pool with the FullRange hook
     * @dev This test verifies swap execution, token transfers, and balance updates after a swap
     */
    function test_swap() public {
        // ======================= ARRANGE =======================
        // Set a small liquidity amount to avoid arithmetic overflow
        uint128 liquidityAmount = 1e9;
        
        // Approve tokens for both liquidity provider (Alice) and swapper (Bob)
        vm.startPrank(alice);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(bob);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        vm.stopPrank();
        
        // First add liquidity to enable swapping - a pool needs liquidity to facilitate swaps
        addFullRangeLiquidity(alice, liquidityAmount);
        
        // Record Bob's initial token balances before the swap
        uint256 bobToken0Before = token0.balanceOf(bob);
        uint256 bobToken1Before = token1.balanceOf(bob);
        console2.log("Bob token0 balance before swap:", bobToken0Before);
        console2.log("Bob token1 balance before swap:", bobToken1Before);
        
        // ======================= ACT =======================
        // Perform a swap: Bob trades token0 for token1
        // Use a very small amount to avoid overflow issues
        uint256 swapAmount = 1e8;
        swapExactInput(bob, true, swapAmount);
        
        // ======================= ASSERT =======================
        // Record Bob's token balances after the swap
        uint256 bobToken0After = token0.balanceOf(bob);
        uint256 bobToken1After = token1.balanceOf(bob);
        console2.log("Bob token0 balance after swap:", bobToken0After);
        console2.log("Bob token1 balance after swap:", bobToken1After);
        
        // Verify the swap executed correctly:
        // 1. Bob should have spent exactly the specified amount of token0
        assertEq(bobToken0Before - bobToken0After, swapAmount, "Bob should have spent exactly the swap amount of token0");
        // 2. Bob should have received some amount of token1 in return
        assertTrue(bobToken1After > bobToken1Before, "Bob should have received some token1 in exchange");
    }
} 