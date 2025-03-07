// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title FullRangeMathLib
/// @notice Provides share calculations and dust handling for FullRange.
library FullRangeMathLib {
    function calculateInitialShares(
        uint256 amount0,
        uint256 amount1,
        uint256 MINIMUM_LIQUIDITY
    ) internal pure returns (uint256 shares) {
        shares = sqrt(amount0 * amount1);
        if (shares > MINIMUM_LIQUIDITY) {
            shares -= MINIMUM_LIQUIDITY;
        }
    }

    function calculateProportionalShares(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 totalSupply,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (uint256) {
        uint256 share0 = (amount0Desired * totalSupply) / reserve0;
        uint256 share1 = (amount1Desired * totalSupply) / reserve1;
        return share0 < share1 ? share0 : share1;
    }

    /**
     * @notice Calculate the extra liquidity from fee amounts with price ratio consideration
     * @param amount0 The amount of token0 fees
     * @param amount1 The amount of token1 fees
     * @param sqrtPriceX96 The current sqrt price of the pool
     * @return extraLiquidity The calculated extra liquidity
     */
    function calculateExtraLiquidity(
        uint256 amount0, 
        uint256 amount1,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256 extraLiquidity) {
        // Handle edge cases
        if (amount0 == 0 && amount1 == 0) {
            return 0;
        }
        
        if (amount0 == 0) {
            return amount1;
        }
        
        if (amount1 == 0) {
            return amount0;
        }
        
        // Calculate the liquidity based on the current price
        // L = min(amount0 * sqrt(P), amount1 / sqrt(P))
        uint256 amount0Value = amount0 * sqrtPriceX96;
        uint256 amount1Value = (amount1 << 96) / sqrtPriceX96;
        
        // To prevent overflow in intermediary calculations
        if (amount0Value >= type(uint256).max / sqrtPriceX96) {
            amount0Value = type(uint256).max;
        } else {
            amount0Value = amount0Value * sqrtPriceX96 / (1 << 96);
        }
        
        // Return the minimum of the two values to ensure balanced liquidity
        return amount0Value < amount1Value ? amount0Value : amount1Value;
    }

    /**
     * @notice A simpler overload that uses geometric mean of amounts
     * @param amount0 The amount of token0 fees
     * @param amount1 The amount of token1 fees
     * @param poolId Unused parameter, kept for backward compatibility
     * @return extraLiquidity The calculated extra liquidity
     */
    function calculateExtraLiquidity(
        uint256 amount0, 
        uint256 amount1,
        PoolId poolId
    ) internal pure returns (uint256 extraLiquidity) {
        // Handle edge cases
        if (amount0 == 0 && amount1 == 0) {
            return 0;
        }
        
        if (amount0 == 0) {
            return amount1;
        }
        
        if (amount1 == 0) {
            return amount0;
        }
        
        // Use geometric mean (sqrt of product) to calculate liquidity
        // This approach gives a fair representation of the value of token pair
        return sqrt(amount0 * amount1);
    }

    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
} 