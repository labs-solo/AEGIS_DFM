// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

/**
 * @title TokenSafetyWrapper
 * @notice Provides consistent interface for safe token operations
 */
library TokenSafetyWrapper {
    using SafeTransferLib for ERC20;

    /**
     * @notice Safely transfer tokens from one address to another
     * @param token The token to transfer
     * @param from The sender address
     * @param to The recipient address
     * @param amount The amount to transfer
     */
    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return; // Gas optimization
        SafeTransferLib.safeTransferFrom(ERC20(token), from, to, amount);
    }

    /**
     * @notice Safely transfer tokens to an address
     * @param token The token to transfer
     * @param to The recipient address
     * @param amount The amount to transfer
     */
    function safeTransfer(address token, address to, uint256 amount) internal {
        if (amount == 0) return; // Gas optimization
        SafeTransferLib.safeTransfer(ERC20(token), to, amount);
    }

    /**
     * @notice Safely approve token spending
     * @param token The token to approve
     * @param spender The address to approve
     * @param amount The amount to approve
     */
    function safeApprove(address token, address spender, uint256 amount) internal {
        // Skip 0 amount approvals to save gas
        if (amount == 0) return;

        // Reset approval first if non-zero to avoid issues with certain tokens
        uint256 currentAllowance = ERC20(token).allowance(address(this), spender);
        if (currentAllowance > 0) {
            SafeTransferLib.safeApprove(ERC20(token), spender, 0);
        }

        SafeTransferLib.safeApprove(ERC20(token), spender, amount);
    }

    /**
     * @notice Get token balance safely
     * @param token The token to query balance for
     * @param account The account to check balance of
     * @return balance The token balance
     */
    function safeBalanceOf(address token, address account) internal view returns (uint256 balance) {
        return ERC20(token).balanceOf(account);
    }

    /**
     * @notice Revoke approval completely
     * @param token The token to revoke approval for
     * @param spender The spender to revoke approval from
     */
    function safeRevokeApproval(address token, address spender) internal {
        // Only call if current allowance is non-zero to save gas
        uint256 currentAllowance = ERC20(token).allowance(address(this), spender);
        if (currentAllowance > 0) {
            SafeTransferLib.safeApprove(ERC20(token), spender, 0);
        }
    }
}
