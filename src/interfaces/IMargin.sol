// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { PoolId } from "v4-core/src/types/PoolId.sol";
import { IMarginData } from "./IMarginData.sol"; // Import needed for Vault
import { IInterestRateModel } from "./IInterestRateModel.sol"; // Add import

/**
 * @title IMargin
 * @notice Interface for the Margin contract
 * @dev Defines the main structures and future functions for margin positions
 */
interface IMargin {
    // Using Vault defined in IMarginData
    // struct Vault { ... }

    /**
     * @notice Get vault information
     * @param poolId The pool ID
     * @param user The user address
     * @return The vault data
     */
    function getVault(PoolId poolId, address user) external view returns (IMarginData.Vault memory);
    
    /**
     * @notice Check if a vault is solvent (placeholder for Phase 2)
     * @param poolId The pool ID
     * @param user The user address
     * @return True if the vault is solvent
     */
    // function isVaultSolvent(PoolId poolId, address user) external view returns (bool);
    
    /**
     * @notice Get vault loan-to-value ratio (placeholder for Phase 2)
     * @param poolId The pool ID
     * @param user The user address
     * @return LTV ratio (scaled by PRECISION)
     */
    // function getVaultLTV(PoolId poolId, address user) external view returns (uint256);

    /**
     * @notice View function called by FeeReinvestmentManager to check pending interest fees.
     * @param poolId The pool ID.
     * @return amount0 Estimated token0 value of pending fees.
     * @return amount1 Estimated token1 value of pending fees.
     */
    function getPendingProtocolInterestTokens(PoolId poolId)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Called by FeeReinvestmentManager after successfully processing interest fees.
     * @param poolId The pool ID.
     * @return previousValue The amount of fee shares that were just cleared.
     */
    function resetAccumulatedFees(PoolId poolId) external returns (uint256 previousValue);

    /**
     * @notice View function to get the current accumulated protocol fees for a pool.
     * @param poolId The pool ID.
     * @return The amount of accumulated fees, denominated in share value.
     */
    function accumulatedFees(PoolId poolId) external view returns (uint256);

    /**
     * @notice View function to get the current borrow interest rate per second for a pool.
     * @param poolId The pool ID.
     * @return rate The interest rate per second (PRECISION scaled).
     */
    function getInterestRatePerSecond(PoolId poolId) external view returns (uint256 rate);

    /**
     * @notice Extract protocol fees from the liquidity pool and send them to the recipient.
     * @dev Called by FeeReinvestmentManager.
     * @param poolId The pool ID to extract fees from.
     * @param amount0ToWithdraw Amount of token0 to extract.
     * @param amount1ToWithdraw Amount of token1 to extract.
     * @param recipient The address to receive the extracted fees.
     * @return success Boolean indicating if the extraction call succeeded.
     */
    function reinvestProtocolFees(
        PoolId poolId,
        uint256 amount0ToWithdraw,
        uint256 amount1ToWithdraw,
        address recipient
    ) external returns (bool success);

    // Precision constant (required by Margin.sol override)
    function PRECISION() external view returns (uint256);

    function getInterestRateModel() external view returns (IInterestRateModel);

    // Events would typically be here or in a more specific event interface
    // event VaultUpdated(...);
    // event ETHClaimed(...);
    // ... other events ...
} 