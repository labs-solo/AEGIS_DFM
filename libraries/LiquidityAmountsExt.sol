// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath}        from "v4-core/src/libraries/TickMath.sol";

library LiquidityAmountsExt {
    /**
     * @notice Calculates the maximum liquidity that can be added for the given amounts across the full range,
     *         and the amounts required to achieve that liquidity.
     * @dev Identical to LiquidityAmounts.getLiquidityForAmounts but returns (use0, use1, liq).
     * @param sqrtPriceX96 The current price sqrt ratio
     * @param tickSpacing The pool tick spacing
     * @param bal0 The available amount of token0
     * @param bal1 The available amount of token1
     * @return use0 The amount of token0 to use for max liquidity
     * @return use1 The amount of token1 to use for max liquidity
     * @return liq The maximum liquidity that can be added
     */
    function getAmountsToMaxFullRange(
        uint160 sqrtPriceX96,
        int24  tickSpacing,
        uint256 bal0,
        uint256 bal1
    )
        internal
        pure
        returns (uint256 use0, uint256 use1, uint128 liq)
    {
        (uint160 sqrtA, uint160 sqrtB) = (
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(tickSpacing)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(tickSpacing))
        );

        liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtA, sqrtB, bal0, bal1
        );
        if (liq == 0) return (0,0,0);

        // Re-calculate amounts based on the derived liquidity to ensure consistency
        use0 = LiquidityAmounts.getAmount0ForLiquidity(sqrtPriceX96, sqrtB, liq);
        use1 = LiquidityAmounts.getAmount1ForLiquidity(sqrtA, sqrtPriceX96, liq);
    }
} 