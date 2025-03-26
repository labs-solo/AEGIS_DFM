// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {Errors} from "../errors/Errors.sol";

/**
 * @title CurrencySettlerExtension
 * @notice Extension of Uniswap V4's CurrencySettler with additional convenience methods
 * @dev Provides simplified wrappers around the core CurrencySettler functionality
 */
library CurrencySettlerExtension {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using SafeCast for int256;
    
    // Events for better traceability
    event CurrencyTaken(address indexed currency, address indexed recipient, uint256 amount);
    event CurrencySettled(address indexed currency, uint256 amount, bool isNative);
    event PoolDeltaHandled(
        address indexed currency0, 
        address indexed currency1, 
        int128 amount0,
        int128 amount1,
        address recipient
    );
    
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
        
        try CurrencySettler.take(currency, manager, recipient, amount, false) {
            // Success - emit event for better traceability
            emit CurrencyTaken(Currency.unwrap(currency), recipient, amount);
        } catch {
            revert Errors.TokenTransferFailed();
        }
    }
    
    /**
     * @notice Settle an ERC20 currency with the pool manager
     * @param manager The pool manager instance
     * @param currency The currency to settle (must be ERC20)
     * @param amount The amount to settle
     */
    function settleCurrency(
        IPoolManager manager,
        Currency currency,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        
        // Ensure we're not trying to settle native ETH with this method
        if (currency.isAddressZero()) {
            revert Errors.TokenEthNotAccepted();
        }
        
        try CurrencySettler.settle(currency, manager, address(this), amount, false) {
            // Success - emit event for better traceability
            emit CurrencySettled(Currency.unwrap(currency), amount, false);
        } catch {
            revert Errors.TokenTransferFailed();
        }
    }
    
    /**
     * @notice Settle native ETH with the pool manager
     * @param manager The pool manager instance
     * @param currency The currency to settle (must be address(0))
     * @param amount The amount of ETH to settle
     */
    function settleCurrencyWithNative(
        IPoolManager manager,
        Currency currency,
        uint256 amount
    ) internal {
        if (amount == 0) return;
        
        // Ensure we're trying to settle native ETH
        if (!currency.isAddressZero()) {
            revert Errors.TokenEthNotAccepted();
        }
        
        // Check if contract has enough ETH balance
        if (address(this).balance < amount) {
            revert Errors.InsufficientContractBalance(amount, address(this).balance);
        }
        
        try CurrencySettler.settle(currency, manager, address(this), amount, false) {
            // Success - emit event for better traceability
            emit CurrencySettled(Currency.unwrap(currency), amount, true);
        } catch {
            revert Errors.TokenEthTransferFailed(address(manager), amount);
        }
    }
    
    /**
     * @notice Handle a balance delta for both currencies in a key with optimized gas usage
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
        // Optimize by extracting values once
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        
        // Handle currency0 - positive delta (take from pool)
        if (amount0 > 0) {
            uint256 takeAmount = uint256(uint128(amount0));
            if (takeAmount > 0) {
                takeCurrency(manager, currency0, recipient, takeAmount);
            }
        } 
        // Handle currency0 - negative delta (pay to pool)
        else if (amount0 < 0) {
            uint256 payAmount = uint256(uint128(-amount0));
            if (payAmount > 0) {
                // Single sync call followed by conditional logic
                manager.sync(currency0);
                
                if (currency0.isAddressZero()) {
                    try manager.settle{value: payAmount}() {
                        // Success - emit event
                        emit CurrencySettled(Currency.unwrap(currency0), payAmount, true);
                    } catch {
                        revert Errors.TokenEthTransferFailed(address(manager), payAmount);
                    }
                } else {
                    address token0 = Currency.unwrap(currency0);
                    // Verify balance before attempting transfer
                    if (IERC20Minimal(token0).balanceOf(address(this)) < payAmount) {
                        revert Errors.InsufficientBalance(payAmount, IERC20Minimal(token0).balanceOf(address(this)));
                    }
                    
                    try IERC20Minimal(token0).transfer(address(manager), payAmount) {
                        try manager.settle() {
                            // Success - emit event
                            emit CurrencySettled(token0, payAmount, false);
                        } catch {
                            revert Errors.TokenTransferFailed();
                        }
                    } catch {
                        revert Errors.TokenTransferFailed();
                    }
                }
            }
        }
        
        // Handle currency1 - positive delta (take from pool)
        if (amount1 > 0) {
            uint256 takeAmount = uint256(uint128(amount1));
            if (takeAmount > 0) {
                takeCurrency(manager, currency1, recipient, takeAmount);
            }
        }
        // Handle currency1 - negative delta (pay to pool)
        else if (amount1 < 0) {
            uint256 payAmount = uint256(uint128(-amount1));
            if (payAmount > 0) {
                // Single sync call followed by conditional logic
                manager.sync(currency1);
                
                if (currency1.isAddressZero()) {
                    try manager.settle{value: payAmount}() {
                        // Success - emit event
                        emit CurrencySettled(Currency.unwrap(currency1), payAmount, true);
                    } catch {
                        revert Errors.TokenEthTransferFailed(address(manager), payAmount);
                    }
                } else {
                    address token1 = Currency.unwrap(currency1);
                    // Verify balance before attempting transfer
                    if (IERC20Minimal(token1).balanceOf(address(this)) < payAmount) {
                        revert Errors.InsufficientBalance(payAmount, IERC20Minimal(token1).balanceOf(address(this)));
                    }
                    
                    try IERC20Minimal(token1).transfer(address(manager), payAmount) {
                        try manager.settle() {
                            // Success - emit event
                            emit CurrencySettled(token1, payAmount, false);
                        } catch {
                            revert Errors.TokenTransferFailed();
                        }
                    } catch {
                        revert Errors.TokenTransferFailed();
                    }
                }
            }
        }
        
        // Emit summary event for the entire delta handling operation
        emit PoolDeltaHandled(
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            amount0,
            amount1,
            recipient
        );
    }
} 