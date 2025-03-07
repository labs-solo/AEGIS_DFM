// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title LiquidityMath
/// @notice Provides math functions for calculating token amounts from liquidity
library LiquidityMath {
    /// @notice Gets the amount of token0 for a given amount of liquidity and price range
    /// @param sqrtRatioAX96 The sqrt ratio of the lower tick boundary
    /// @param sqrtRatioBX96 The sqrt ratio of the upper tick boundary
    /// @param liquidity The amount of liquidity
    /// @return amount0 The amount of token0
    function getAmount0Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        int128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (liquidity < 0) {
            return 0; // Cannot have negative liquidity
        }
        
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        
        // Calculate amount0 = L * (1/sqrtRatioA - 1/sqrtRatioB)
        // = L * (sqrtRatioB - sqrtRatioA) / (sqrtRatioA * sqrtRatioB)
        uint256 numerator1 = uint256(uint128(liquidity)) << 96;
        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;
        
        return 
            (numerator1 * numerator2) / sqrtRatioBX96 / sqrtRatioAX96;
    }
    
    /// @notice Gets the amount of token1 for a given amount of liquidity and price range
    /// @param sqrtRatioAX96 The sqrt ratio of the lower tick boundary
    /// @param sqrtRatioBX96 The sqrt ratio of the upper tick boundary
    /// @param liquidity The amount of liquidity
    /// @return amount1 The amount of token1
    function getAmount1Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        int128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (liquidity < 0) {
            return 0; // Cannot have negative liquidity
        }
        
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }
        
        // Calculate amount1 = L * (sqrtRatioB - sqrtRatioA)
        return 
            (uint256(uint128(liquidity)) * (sqrtRatioBX96 - sqrtRatioAX96)) >> 96;
    }
} 