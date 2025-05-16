// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {CurrencySettler} from "uniswap-hooks/utils/CurrencySettler.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {Errors} from "../errors/Errors.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/**
 * @title CurrencySettlerExtension
 * @notice Extension of the CurrencySettler library for use within FullRange.
 * @dev Provides helpers to interact with the PoolManager for settling balances.
 */
library CurrencySettlerExtension {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using SafeCast for int256;

    /**
     * @notice Handle a balance delta for both currencies in a key
     * @param manager The pool manager
     * @param delta The balance delta to settle
     * @param cur0 The first currency
     * @param cur1 The second currency
     * @param recipient The recipient for positive deltas
     */
    function handlePoolDelta(IPoolManager manager, BalanceDelta delta, Currency cur0, Currency cur1, address recipient)
        internal
    {
        // ────────────────────────────
        // 1) Handle NEGATIVE deltas
        //    (we owe the pool manager)
        //    – use canonical CurrencySettler
        // ────────────────────────────
        if (delta.amount0() < 0) {
            uint256 amt0 = uint256(int256(-delta.amount0()));
            CurrencySettler.settle(cur0, manager, address(this), amt0, /*burn*/ false);
        }
        if (delta.amount1() < 0) {
            uint256 amt1 = uint256(int256(-delta.amount1()));
            CurrencySettler.settle(cur1, manager, address(this), amt1, /*burn*/ false);
        }

        // ────────────────────────────
        // 2) Handle POSITIVE deltas
        //    (pool owes us – pull via `take`)
        // ────────────────────────────
        if (delta.amount0() > 0) {
            manager.take(cur0, recipient, uint256(int256(delta.amount0())));
        }
        if (delta.amount1() > 0) {
            manager.take(cur1, recipient, uint256(int256(delta.amount1())));
        }
    }

    /**
     * @notice Take a currency from the pool manager
     * @param manager The pool manager instance
     * @param currency The currency to take
     * @param recipient The recipient of the tokens
     * @param amount The amount to take
     */
    function takeCurrency(IPoolManager manager, Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        if (recipient == address(0)) revert Errors.ZeroAddress();

        // Use Uniswap's standard CurrencySettler directly
        CurrencySettler.take(currency, manager, recipient, amount, false);
    }

    /**
     * @notice Settle a currency with the pool manager
     * @param manager The pool manager instance
     * @param currency The currency to settle
     * @param amount The amount to settle
     */
    function settleCurrency(IPoolManager manager, Currency currency, uint256 amount) internal {
        if (amount == 0) return;

        if (currency.isAddressZero()) {
            // Use Uniswap's standard CurrencySettler with native ETH
            CurrencySettler.settle(currency, manager, address(this), amount, false);
        } else {
            // For ERC20 tokens
            CurrencySettler.settle(currency, manager, address(this), amount, false);
        }
    }
}
