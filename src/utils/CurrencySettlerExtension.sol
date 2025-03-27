// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {CurrencySettler} from "uniswap-hooks/src/utils/CurrencySettler.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {Errors} from "../errors/Errors.sol";

/**
 * @title CurrencySettlerExtension
 * @notice Minimal extension of Uniswap V4's CurrencySettler for vault pattern usage
 * @dev Provides a thin adapter layer between FullRange's vault pattern and Uniswap V4 settlement
 */
library CurrencySettlerExtension {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using SafeCast for int256;
    
    /**
     * @notice Take a currency from the pool manager
     * @param manager The pool manager instance
     * @param currency The currency to take
     * @param recipient The recipient of the tokens
     * @param amount The amount to take
     */
    function takeCurrency(
        IPoolManager manager,
        Currency currency,
        address recipient,
        uint256 amount
    ) internal {
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
    function settleCurrency(
        IPoolManager manager,
        Currency currency,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        
        if (currency.isAddressZero()) {
            // Use Uniswap's standard CurrencySettler with native ETH
            CurrencySettler.settle(currency, manager, address(this), amount, false);
        } else {
            // For ERC20 tokens
            CurrencySettler.settle(currency, manager, address(this), amount, false);
        }
    }
    
    /**
     * @notice Handle a balance delta for both currencies in a key
     * @param manager The pool manager
     * @param delta The balance delta to settle
     * @param currency0 The first currency
     * @param currency1 The second currency
     * @param recipient The recipient for positive deltas
     */
    function handlePoolDelta(
        IPoolManager manager,
        BalanceDelta delta,
        Currency currency0,
        Currency currency1,
        address recipient
    ) internal {
        // Handle currency0
        _handleSingleCurrency(manager, delta.amount0(), currency0, recipient);
        
        // Handle currency1
        _handleSingleCurrency(manager, delta.amount1(), currency1, recipient);
    }
    
    /**
     * @notice Handle a single currency delta
     * @dev Internal helper to reduce code duplication
     * @param manager The pool manager
     * @param amount The delta amount (positive or negative)
     * @param currency The currency to handle
     * @param recipient The recipient for positive deltas
     */
    function _handleSingleCurrency(
        IPoolManager manager,
        int128 amount,
        Currency currency,
        address recipient
    ) private {
        if (amount > 0) {
            // Take from pool (positive delta)
            takeCurrency(manager, currency, recipient, uint256(uint128(amount)));
        } else if (amount < 0) {
            // Pay to pool (negative delta)
            settleCurrency(manager, currency, uint256(uint128(-amount)));
        }
    }
} 