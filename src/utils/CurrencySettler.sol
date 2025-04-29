// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

/**
 * @title CurrencySettler
 * @notice Utility functions for settling currencies with the PoolManager
 */
library CurrencySettler {
    using CurrencyLibrary for Currency;

    /**
     * @notice Take a currency from the pool manager
     * @param currency The currency to take
     * @param manager The pool manager instance
     * @param recipient The recipient of the tokens
     * @param amount The amount to take
     * @param unwrap Whether to unwrap native tokens
     */
    function take(Currency currency, IPoolManager manager, address recipient, uint256 amount, bool unwrap) internal {
        if (amount == 0) return;

        // Simplified: Always take the currency (WETH or ERC20) to the recipient.
        // The recipient is responsible for unwrapping WETH if needed.
        unwrap; // Silence unused variable warning
        manager.take(currency, recipient, amount);
    }

    /**
     * @notice Settle a currency with the pool manager
     * @param currency The currency to settle
     * @param manager The pool manager instance
     * @param payer The address paying the tokens
     * @param amount The amount to settle
     * @param wrap Whether to wrap native tokens
     */
    function settle(Currency currency, IPoolManager manager, address payer, uint256 amount, bool wrap) internal {
        if (amount == 0) return;

        if (currency.isAddressZero()) {
            // Native ETH settlement: Must be done via msg.value
            // The `wrap` parameter is now irrelevant for PoolManager interaction.
            wrap; // Silence unused variable warning
            // Caller must send ETH via msg.value when calling PoolManager.settle()
            // This library cannot directly handle the msg.value part.
            // We assume the caller handles sending ETH correctly.
            manager.settle{value: amount}();
        } else {
            IERC20Minimal tokenMinimal = IERC20Minimal(Currency.unwrap(currency));
            ERC20 tokenSolmate = ERC20(Currency.unwrap(currency));
            // Transfer ERC20 from payer to PoolManager first
            // Note: Using safeTransferFrom requires payer approval
            SafeTransferLib.safeTransferFrom(tokenSolmate, payer, address(manager), amount);
            // Settle the ERC20 token (no value needed)
            manager.settle();
        }
    }
}
