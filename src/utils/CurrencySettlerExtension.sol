// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "uniswap-hooks/utils/CurrencySettler.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {Errors} from "../errors/Errors.sol";

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
     * @notice Handles the settlement of balance deltas using the PoolManager.
     * @param manager The IPoolManager instance.
     * @param delta The balance delta to settle.
     * @param currency0 The first currency.
     * @param currency1 The second currency.
     * @param recipient The recipient of any settled funds.
     */
    function handlePoolDelta(
        IPoolManager manager,
        BalanceDelta delta,
        Currency currency0,
        Currency currency1,
        address recipient
    ) internal {
        if (delta.amount0() < 0) {
            // Pool owes token0
            CurrencySettler.settle(
                currency0,
                manager,
                recipient,
                uint256(-int256(delta.amount0())),
                false
            );
        } else if (delta.amount0() > 0) {
            // Pool is owed token0
            CurrencySettler.take(
                currency0,
                manager,
                recipient,
                uint256(int256(delta.amount0())),
                false
            );
        }

        if (delta.amount1() < 0) {
            // Pool owes token1
            CurrencySettler.settle(
                currency1,
                manager,
                recipient,
                uint256(-int256(delta.amount1())),
                false
            );
        } else if (delta.amount1() > 0) {
            // Pool is owed token1
            CurrencySettler.take(
                currency1,
                manager,
                recipient,
                uint256(int256(delta.amount1())),
                false
            );
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
