// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { Currency } from "v4-core/src/types/Currency.sol";

/**
 * @title IMarginData
 * @notice Defines shared data structures, enums, and constants for the Margin protocol.
 */
interface IMarginData {
    // =========================================================================
    // Enums
    // =========================================================================

    /**
     * @notice Types of actions that can be performed in a batch.
     */
    enum ActionType {
        DepositCollateral,    // asset = token addr or 0 for Native, amount = value
        WithdrawCollateral,   // asset = token addr or 0 for Native, amount = value
        Borrow,               // amount = shares to borrow (uint256), asset ignored
        Repay,                // amount = shares target to repay (uint256), asset ignored
        Swap                  // Details in data (SwapRequest), asset/amount ignored
    }

    // =========================================================================
    // Structs
    // =========================================================================

    /**
     * @notice Parameters for a swap action within a batch.
     */
    struct SwapRequest {
        Currency currencyIn;   // V4 Currency type (token address or NATIVE)
        Currency currencyOut;  // V4 Currency type
        uint256 amountIn;      // Amount of currencyIn to swap
        uint256 amountOutMin; // Slippage control for currencyOut
        // bytes path; // Optional for multi-hop routers if needed
    }

    /**
     * @notice Represents a single action within a batch operation.
     */
    struct BatchAction {
        ActionType actionType;    // The type of action to perform.
        address asset;            // Token address for Deposit/Withdraw Collateral (address(0) for Native ETH). Not used for Borrow/Repay/Swap.
        uint256 amount;           // Value for Deposit/Withdraw Collateral; Shares for Borrow/Repay. Not used for Swap.
        address recipient;        // For WithdrawCollateral or destination of borrowed funds. Defaults to msg.sender if address(0).
        uint256 flags;            // Bitmask for options (e.g., FLAG_USE_VAULT_BALANCE_FOR_REPAY).
        bytes data;               // Auxiliary data (e.g., abi.encode(SwapRequest) for Swap action).
    }

    /**
     * @notice Represents a user's vault state within a specific pool.
     * @dev Balances include collateral deposited and potentially tokens held from borrows (BAMM).
     *      Native ETH balance is included in token0Balance or token1Balance if applicable for the pool.
     */
    struct Vault {
        uint128 token0Balance;        // Balance of the pool's token0 (or Native ETH if token0 is NATIVE)
        uint128 token1Balance;        // Balance of the pool's token1 (or Native ETH if token1 is NATIVE)
        uint256 debtShares;           // Debt balance denominated in ERC6909 shares of the managed position
        uint64 lastAccrualTimestamp; // Timestamp of the last interest accrual affecting this vault (relative to global multiplier)
    }

    // =========================================================================
    // Constants
    // =========================================================================

    /**
     * @notice Flag for the `repay` action indicating funds should be taken from the vault balance.
     */
    uint256 constant FLAG_USE_VAULT_BALANCE_FOR_REPAY = 1;
}
