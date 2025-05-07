// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/*───────────────────────────────────────────────────────────────────────────
 *                            Core & Periphery
 *──────────────────────────────────────────────────────────────────────────*/
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {CurrencyDelta}            from "v4-core/src/libraries/CurrencyDelta.sol";
import {PoolKey}                  from "v4-core/src/types/PoolKey.sol";
import {PoolId}                   from "v4-core/src/types/PoolId.sol";
import {IPoolManager}             from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary}             from "v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts}         from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath}                 from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath}            from "v4-core/src/libraries/SqrtPriceMath.sol";

/**
 * @title ReinvestLib
 * @notice Pure/view helper that encapsulates the reinvest finite-state-machine logic
 *         formerly implemented inside the Spot hook. Extracting this logic into
 *         a library saves byte-code size while keeping the observable behaviour
 *         identical. The library never alters storage — it only computes the
 *         next action and returns all relevant interim values.
 */
library ReinvestLib {
    using CurrencyLibrary for Currency;
    using CurrencyDelta   for Currency;

    /*────────────────────────── Constants (reason codes) ───────────────────*/
    bytes4 internal constant GLOBAL_PAUSED  = bytes4(keccak256("GLOBAL_PAUSED"));
    bytes4 internal constant COOLDOWN       = bytes4(keccak256("COOLDOWN"));
    bytes4 internal constant THRESHOLD      = bytes4(keccak256("THRESHOLD"));
    bytes4 internal constant PRICE_ZERO     = bytes4(keccak256("PRICE_ZERO"));
    bytes4 internal constant LIQUIDITY_ZERO = bytes4(keccak256("LIQUIDITY_ZERO"));

    /*────────────────────────────── Data struct ────────────────────────────*/
    struct Locals {
        bytes4  reason;     // 0x0 if execution should continue, otherwise skip code
        uint256 bal0;       // internal credit of token0 (wei)
        uint256 bal1;       // internal credit of token1 (wei)
        uint256 use0;       // amount of token0 that will be transferred to the LM
        uint256 use1;       // amount of token1 that will be transferred to the LM
        uint128 liquidity;  // liquidity to mint full-range
    }

    /*───────────────────────────── Main compute ────────────────────────────*/
    function compute(
        PoolKey      memory key,
        PoolId              pid,
        IPoolManager        poolManager,
        bool                reinvestPaused,
        uint64              last,
        uint64              cooldown,
        uint256             minToken0,
        uint256             minToken1
    ) internal view returns (Locals memory r) {
        /*--------------------------------------------------------------
         * 1. Read internal balances (credit) using CurrencyDelta lib
         *-------------------------------------------------------------*/
        int256 d0 = key.currency0.getDelta(address(this));
        int256 d1 = key.currency1.getDelta(address(this));
        r.bal0    = d0 > 0 ? uint256(d0) : 0;
        r.bal1    = d1 > 0 ? uint256(d1) : 0;

        /* 0) global pause */
        if (reinvestPaused) {
            r.reason = GLOBAL_PAUSED;
            return r;
        }
        /* 1) cooldown */
        if (block.timestamp < uint256(last) + uint256(cooldown)) {
            r.reason = COOLDOWN;
            return r;
        }
        /* 2) threshold */
        if (r.bal0 < minToken0 && r.bal1 < minToken1) {
            r.reason = THRESHOLD;
            return r;
        }
        /* 3) price-check */
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, pid);
        if (sqrtP == 0) {
            r.reason = PRICE_ZERO;
            return r;
        }
        /* 4) maximise full-range liquidity */
        r.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.MIN_SQRT_PRICE,
            TickMath.MAX_SQRT_PRICE,
            r.bal0,
            r.bal1
        );

        if (r.liquidity == 0) {
            r.reason = LIQUIDITY_ZERO;
            return r;
        }

        /* 5) Derive exact token amounts to use (always rounding up) */
        r.use0 = SqrtPriceMath.getAmount0Delta(
            TickMath.MIN_SQRT_PRICE,
            TickMath.MAX_SQRT_PRICE,
            r.liquidity,
            true
        );
        r.use1 = SqrtPriceMath.getAmount1Delta(
            TickMath.MIN_SQRT_PRICE,
            TickMath.MAX_SQRT_PRICE,
            r.liquidity,
            true
        );

        // reason remains zero ⇒ success path
        return r;
    }
} 