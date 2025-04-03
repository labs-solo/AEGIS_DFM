// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { PoolId } from "v4-core/src/types/PoolId.sol";

/**
 * @title IMargin
 * @notice Interface for the Margin contract
 * @dev Defines the main structures and future functions for margin positions
 */
interface IMargin {
    /**
     * @notice Information about a user's position in a pool
     * @param token0Balance Amount of token0 in the vault
     * @param token1Balance Amount of token1 in the vault
     * @param debtShare LP-equivalent debt in share units (will be used in Phase 2)
     * @param lastAccrual Last time interest was accrued (will be used in Phase 2)
     * @param flags Bitwise flags for future extensions
     */
    struct Vault {
        uint128 token0Balance;
        uint128 token1Balance;
        uint128 debtShare;
        uint64 lastAccrual;
        uint32 flags;
    }
    
    /**
     * @notice Get vault information
     * @param poolId The pool ID
     * @param user The user address
     * @return The vault data
     */
    function getVault(PoolId poolId, address user) external view returns (Vault memory);
    
    /**
     * @notice Check if a vault is solvent (placeholder for Phase 2)
     * @param poolId The pool ID
     * @param user The user address
     * @return True if the vault is solvent
     */
    function isVaultSolvent(PoolId poolId, address user) external view returns (bool);
    
    /**
     * @notice Get vault loan-to-value ratio (placeholder for Phase 2)
     * @param poolId The pool ID
     * @param user The user address
     * @return LTV ratio (scaled by PRECISION)
     */
    function getVaultLTV(PoolId poolId, address user) external view returns (uint256);

    // Events (included in Phase 1 but most will be emitted in future phases)
    event Deposit(
        PoolId indexed poolId,
        address indexed user,
        uint256 amount0,
        uint256 amount1,
        uint256 shares
    );
    
    event Withdraw(
        PoolId indexed poolId,
        address indexed user,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );
    
    event Borrow(
        PoolId indexed poolId,
        address indexed user,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );
    
    event Repay(
        PoolId indexed poolId,
        address indexed user,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );
    
    event InterestAccrued(
        PoolId indexed poolId,
        address indexed user,
        uint256 interestRate,
        uint256 oldDebt,
        uint256 newDebt
    );
    
    event VaultUpdated(
        PoolId indexed poolId,
        address indexed user,
        uint256 token0Balance,
        uint256 token1Balance,
        uint256 debtShare,
        uint256 timestamp
    );
    
    event PauseStatusChanged(bool paused);
    
    event InterestRateModelUpdated(address indexed newModel);
} 