// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { Currency } from "lib/v4-core/src/types/Currency.sol";
import { CurrencyLibrary } from "lib/v4-core/src/types/Currency.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { Errors } from "../errors/Errors.sol";

/**
 * @title TransferUtils
 * @notice Utility functions for handling ETH and ERC20 token transfers based on PoolKey.
 */
library TransferUtils {
    using CurrencyLibrary for Currency;

    /**
     * @notice Transfers specified amounts of token0 and token1 FROM a given address TO the calling contract.
     * @dev Handles native ETH via msg.value. Requires caller (e.g., Margin) to check msg.value and handle refunds.
     * @param key The PoolKey containing currency information.
     * @param from The address to transfer tokens from.
     * @param amount0 The amount of token0 to transfer.
     * @param amount1 The amount of token1 to transfer.
     * @param ethValueSent The msg.value sent with the transaction.
     * @return ethAmountRequired The amount of ETH that was required based on the PoolKey and amounts.
     */
    function transferTokensIn(
        PoolKey memory key,
        address from,
        uint256 amount0,
        uint256 amount1,
        uint256 ethValueSent
    ) internal returns (uint256 ethAmountRequired) {
        address recipient = address(this);
        ethAmountRequired = 0;

        // Transfer token0 if needed
        if (amount0 > 0) {
            if (key.currency0.isAddressZero()) {
                ethAmountRequired += amount0;
            } else {
                SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(key.currency0)), from, recipient, amount0);
            }
        }

        // Transfer token1 if needed
        if (amount1 > 0) {
            if (key.currency1.isAddressZero()) {
                ethAmountRequired += amount1;
            } else {
                SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(key.currency1)), from, recipient, amount1);
            }
        }

        // Check if enough ETH was sent (caller should handle revert/refund based on this)
        if (ethValueSent < ethAmountRequired) {
            revert Errors.InsufficientETH(ethAmountRequired, ethValueSent);
        }
        // Note: Caller is responsible for refunding excess ETH (ethValueSent - ethAmountRequired)

        return ethAmountRequired;
    }

    /**
     * @notice Transfers specified amounts of token0 and token1 FROM the calling contract TO a given address.
     * @dev Handles native ETH via direct call. Does NOT handle the fallback payment mechanism.
     * @param key The PoolKey containing currency information.
     * @param to The address to transfer tokens to.
     * @param amount0 The amount of token0 to transfer.
     * @param amount1 The amount of token1 to transfer.
     * @return eth0Success Returns true if ETH transfer for token0 was not needed or succeeded, false if attempted and failed.
     * @return eth1Success Returns true if ETH transfer for token1 was not needed or succeeded, false if attempted and failed.
     */
    function transferTokensOut(
        PoolKey memory key,
        address to,
        uint256 amount0,
        uint256 amount1
    ) internal returns (bool eth0Success, bool eth1Success) {
        eth0Success = true; // Assume success unless ETH transfer fails
        eth1Success = true;

        if (amount0 > 0) {
            if (key.currency0.isAddressZero()) {
                // Attempt direct ETH transfer
                (bool success, ) = to.call{value: amount0, gas: 50000}("");
                if (!success) {
                    eth0Success = false;
                    // NOTE: Caller (Margin) needs to handle the fallback (pendingETHPayments)
                }
            } else {
                SafeTransferLib.safeTransfer(ERC20(Currency.unwrap(key.currency0)), to, amount0);
            }
        }

        // Only proceed with token1 if token0 ETH transfer didn't fail (or wasn't needed)
        // NOTE: This logic is removed, we attempt both transfers regardless and report individual success
        if (amount1 > 0) {
            if (key.currency1.isAddressZero()) {
                // Attempt direct ETH transfer
                (bool success, ) = to.call{value: amount1, gas: 50000}("");
                if (!success) {
                    eth1Success = false;
                    // NOTE: Caller (Margin) needs to handle the fallback (pendingETHPayments)
                }
            } else {
                SafeTransferLib.safeTransfer(ERC20(Currency.unwrap(key.currency1)), to, amount1);
            }
        }

        return (eth0Success, eth1Success);
    }
} 