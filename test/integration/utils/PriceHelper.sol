// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

// Remove unused Math and IERC20Metadata imports later if confirmed okay
// import {Math}             from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
// import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

library PriceHelper {
    // using FullMath for uint256; // Not needed with static calls

    /*──────────────────────────────────────────────────────────────────────────
        Internal sqrt with **round‑up** semantics (v3 parity)
    ──────────────────────────────────────────────────────────────────────────*/
    function _sqrtRoundingUp(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x >> 1) + 1;
        while (z < y) {
            y = z;
            z = (x / z + z) >> 1;
        }
        unchecked {
            if (y * y < x) ++y;
        }
    }

    /*──────────────────────────────────────────────────────────────────────────
        encodePriceSqrt
        -----------------------------------------------------------------------
        * `amount0` & `amount1` MUST be expressed with the **same decimal scale**
        * `token0.address < token1.address`
        * returns Q64.96 price, **rounded up** (v3 behaviour)
    ──────────────────────────────────────────────────────────────────────────*/
    function encodePriceSqrt(
        uint256 amount1, // Corresponds to token1 (address > token0 address)
        uint256 amount0 // Corresponds to token0 (address < token1 address)
    ) internal pure returns (uint160 sqrtPriceX96) {
        require(amount0 != 0, "PriceHelper: amount0=0");

        uint256 ratioX192 = FullMath.mulDiv(amount1, 1 << 192, amount0);

        sqrtPriceX96 = uint160(_sqrtRoundingUp(ratioX192));

        require(
            sqrtPriceX96 >= TickMath.MIN_SQRT_PRICE && sqrtPriceX96 < TickMath.MAX_SQRT_PRICE,
            "PriceHelper: sqrtPrice out of bounds"
        );
    }

    /*──────────────────────────────────────────────────────────────────────────
        priceToSqrtX96
        -----------------------------------------------------------------------
        * `tokenA`, `tokenB`  – any order
        * `priceBperAScaled` – human price of B per A, **scaled by 10^decB**
          (e.g. 3000 USDC/WETH => 3_000 * 10^6)
    ──────────────────────────────────────────────────────────────────────────*/
    function priceToSqrtX96(address tokenA, address tokenB, uint256 priceBperAScaled, uint8 decA, uint8 decB)
        internal
        pure
        returns (uint160)
    {
        require(tokenA != tokenB, "same tokens");
        require(priceBperAScaled > 0, "price=0");

        bool aIsToken0 = tokenA < tokenB;

        uint256 powA = 10 ** decA;
        uint256 powB = 10 ** decB;

        uint256 amount0; // base‑units of token0
        uint256 amount1; // base‑units of token1

        if (aIsToken0) {
            amount0 = powA; // 1 A  (base units)
            // convert "B per 1 A scaled by 10^decB" into base‑units of B
            amount1 = FullMath.mulDiv(priceBperAScaled, powA, powB);
        } else {
            // token0 = B, token1 = A
            amount0 = FullMath.mulDiv(priceBperAScaled, powA, powB); // base‑units of B
            amount1 = powA; // base‑units of A
        }

        return encodePriceSqrt(amount1, amount0);
    }
}
