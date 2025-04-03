// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/**
 * @title IFullRangeLiquidityManager
 * @notice Interface for the FullRangeLiquidityManager contract
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

    /**
     * @notice Deposit tokens into a pool with native ETH support
     */
    function deposit(
        PoolId poolId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external payable returns (
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );

    function withdraw(
        PoolId poolId,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external returns (
        uint256 amount0,
        uint256 amount1
    );
    
    /**
     * @notice Handles delta settlement from Spot's unlockCallback
     * @param key The pool key
     * @param delta The balance delta to settle
     */
    function handlePoolDelta(PoolKey memory key, BalanceDelta delta) external;
        
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

    /**
     * @notice Reinvests fees for protocol-owned liquidity
     * @param poolId The pool ID
     * @param polAmount0 Amount of token0 for protocol-owned liquidity
     * @param polAmount1 Amount of token1 for protocol-owned liquidity
     * @return shares The number of POL shares minted
     */
    function reinvestFees(
        PoolId poolId,
        uint256 polAmount0,
        uint256 polAmount1
    ) external returns (uint256 shares);

    function getAccountPosition(PoolId poolId, address account) external view returns (bool initialized, uint256 shares);
    
    function getShareValue(PoolId poolId, uint256 shares) external view returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Get pool information 
     * @param poolId The pool ID
     */
    function poolInfo(PoolId poolId) external view returns (
        uint128 totalShares,
        uint256 reserve0,
        uint256 reserve1
    );

    /**
     * @notice Pool keys mapping
     */
    function poolKeys(PoolId poolId) external view returns (PoolKey memory);

    /**
     * @notice Gets the current reserves for a pool
     * @param poolId The pool ID
     * @return reserve0 The amount of token0 in the pool
     * @return reserve1 The amount of token1 in the pool
     */
    function getPoolReserves(PoolId poolId) external view returns (uint256 reserve0, uint256 reserve1);

    /**
     * @notice Updates the position cache for a pool
     * @param poolId The pool ID
     * @return success Whether the update was successful
     */
    function updatePositionCache(PoolId poolId) external returns (bool success);
} 