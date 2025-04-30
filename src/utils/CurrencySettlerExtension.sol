// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {Errors} from "../errors/Errors.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CurrencySettlerExtension
 * @notice Extension of the CurrencySettler library for use within FullRange.
 * @dev Provides helpers to interact with the PoolManager for settling balances directly.
 */
library CurrencySettlerExtension {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeERC20 for IERC20Minimal;

    /**
     * @notice Handle a balance delta for both currencies in a key
     * @param manager The pool manager
     * @param delta The balance delta to settle
     * @param cur0 The first currency
     * @param cur1 The second currency
     * @param caller The address calling this function (must have tokens/ETH to send)
     * @param recipient The recipient for positive deltas
     * @dev Assumes the caller has sufficient balance and has approved the manager for ERC20s if needed.
     */
    function handlePoolDelta(
        IPoolManager manager,
        BalanceDelta delta,
        Currency cur0,
        Currency cur1,
        address caller,
        address recipient
    ) internal {
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        // ────────────────────────────
        // 1) Handle NEGATIVE deltas (we owe the pool manager)
        //    - Pay *all* debts first
        // ────────────────────────────
        if (amount0 < 0) {
            uint256 amount0ToSettle = uint256(int256(-amount0));
            if (cur0.isAddressZero()) {
                revert("Native ETH settlement requires direct payable call");
            } else {
                IERC20Minimal token0 = IERC20Minimal(Currency.unwrap(cur0));
                require(
                    token0.transferFrom(caller, address(manager), amount0ToSettle), "CSE: token0 transferFrom failed"
                );
            }
        }
        if (amount1 < 0) {
            uint256 amount1ToSettle = uint256(int256(-amount1));
            if (cur1.isAddressZero()) {
                revert("Native ETH settlement requires direct payable call");
            } else {
                IERC20Minimal token1 = IERC20Minimal(Currency.unwrap(cur1));
                require(
                    token1.transferFrom(caller, address(manager), amount1ToSettle), "CSE: token1 transferFrom failed"
                );
            }
        }

        // ────────────────────────────
        // 2) Settle ONCE if any negative delta was paid
        // ────────────────────────────
        if (amount0 < 0 || amount1 < 0) {
            manager.settle(); // Call settle only after all transfers are done
        }

        // ────────────────────────────
        // 3) Handle POSITIVE deltas (pool owes us – pull via `take`)
        // ────────────────────────────
        if (amount0 > 0) {
            manager.take(cur0, recipient, uint128(uint256(int256(amount0))));
        }
        if (amount1 > 0) {
            manager.take(cur1, recipient, uint128(uint256(int256(amount1))));
        }
    }

    /**
     * @notice Take a currency owed by the pool manager
     * @param manager The pool manager instance
     * @param currency The currency to take
     * @param recipient The recipient of the tokens
     * @param amount The amount to take
     */
    function takeCurrency(IPoolManager manager, Currency currency, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        if (recipient == address(0)) revert Errors.ZeroAddress();
        // Direct call to manager.take
        manager.take(currency, recipient, amount.toUint128());
    }

    /**
     * @notice Settle a currency owed to the pool manager by the caller
     * @param manager The pool manager instance
     * @param currency The currency to settle
     * @param caller The address settling the currency (must have tokens/ETH)
     * @param amount The amount to settle
     * @dev Assumes caller has approved manager for ERC20s if needed.
     */
    function settleCurrency(IPoolManager manager, Currency currency, address caller, uint256 amount) internal {
        if (amount == 0) return;
        _settleOwed(manager, currency, caller, amount);
    }

    /**
     * @notice Internal helper to send/transfer currency owed to the manager and call settle
     * @param manager The pool manager instance
     * @param currency The currency to settle
     * @param caller The address sending the currency
     * @param amount The amount to settle
     */
    function _settleOwed(IPoolManager manager, Currency currency, address caller, uint256 amount) private {
        if (currency.isAddressZero()) {
            // native ETH → call payable overload (no args)
            manager.settle{value: amount}();
        } else {
            // For ERC20s, transfer from caller to PoolManager first
            IERC20Minimal token = IERC20Minimal(Currency.unwrap(currency));
            require(token.transferFrom(caller, address(manager), amount), "Transfer failed");
            manager.settle(); // Settle after transfer
        }
    }
}
