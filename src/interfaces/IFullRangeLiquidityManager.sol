// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/**
 * @title IFullRangeLiquidityManager
 * @notice Interface for FullRangeLiquidityManager contract
 */
interface IFullRangeLiquidityManager {
    struct DepositParams {
        PoolId poolId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct WithdrawParams {
        PoolId poolId;
        uint256 shares;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    
    // Events for share accounting operations
    event UserSharesAdded(PoolId indexed poolId, address indexed user, uint256 shares);
    event UserSharesRemoved(PoolId indexed poolId, address indexed user, uint256 shares);
    event PoolTotalSharesUpdated(PoolId indexed poolId, uint128 oldShares, uint128 newShares);

    function deposit(
        DepositParams calldata params,
        address recipient
    ) external returns (BalanceDelta delta, uint256 sharesMinted);

    function withdraw(
        WithdrawParams calldata params,
        address recipient
    ) external returns (BalanceDelta delta, uint256 amount0Out, uint256 amount1Out);
    
    /**
     * @notice Adds user share accounting (no token transfers)
     * @param poolId The pool ID
     * @param user The user address
     * @param shares Amount of shares to add
     */
    function addUserShares(PoolId poolId, address user, uint256 shares) external;

    /**
     * @notice Removes user share accounting (no token transfers)
     * @param poolId The pool ID
     * @param user The user address
     * @param shares Amount of shares to remove
     */
    function removeUserShares(PoolId poolId, address user, uint256 shares) external;

    /**
     * @notice Retrieves user share balance
     * @param poolId The pool ID
     * @param user The user address
     * @return User's share balance
     */
    function getUserShares(PoolId poolId, address user) external view returns (uint256);

    /**
     * @notice Updates pool total shares
     * @param poolId The pool ID
     * @param newTotalShares The new total shares amount
     */
    function updateTotalShares(PoolId poolId, uint128 newTotalShares) external;
    
    /**
     * @notice Atomic operation for processing withdrawal share accounting
     * @dev Combines share burning and total share update in one call for atomicity
     * @param poolId The pool ID
     * @param user The user address
     * @param sharesToBurn Shares to burn
     * @param currentTotalShares Current total shares (for validation)
     * @return newTotalShares The new total shares amount
     */
    function processWithdrawShares(
        PoolId poolId, 
        address user, 
        uint256 sharesToBurn, 
        uint128 currentTotalShares
    ) external returns (uint128 newTotalShares);
    
    /**
     * @notice Atomic operation for processing deposit share accounting
     * @dev Combines share minting and total share update in one call for atomicity
     * @param poolId The pool ID
     * @param user The user address
     * @param sharesToMint Shares to mint
     * @param currentTotalShares Current total shares (for validation)
     * @return newTotalShares The new total shares amount
     */
    function processDepositShares(
        PoolId poolId, 
        address user, 
        uint256 sharesToMint, 
        uint128 currentTotalShares
    ) external returns (uint128 newTotalShares);
} 