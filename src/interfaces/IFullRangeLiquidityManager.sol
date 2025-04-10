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
    
    // Event for borrowing tokens (no share burning, just token extraction)
    event TokensBorrowed(PoolId indexed poolId, address indexed recipient, uint256 amount0, uint256 amount1, uint256 shares);
    
    // Event for protocol fee reinvestment
    event ProtocolFeesReinvested(PoolId indexed poolId, address indexed recipient, uint256 amount0, uint256 amount1);

    /**
     * @notice Deposit tokens into a pool with native ETH support
     * @param poolId The ID of the pool to deposit into
     * @param amount0Desired Desired amount of token0
     * @param amount1Desired Desired amount of token1
     * @param amount0Min Minimum amount of token0
     * @param amount1Min Minimum amount of token1
     * @param recipient Address to receive the LP shares
     * @return shares The amount of LP shares minted
     * @return amount0 The actual amount of token0 deposited
     * @return amount1 The actual amount of token1 deposited
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

    /**
     * @notice Withdraw tokens from a pool
     * @param poolId The ID of the pool to withdraw from
     * @param sharesToBurn The amount of LP shares to burn
     * @param amount0Min Minimum amount of token0 to receive
     * @param amount1Min Minimum amount of token1 to receive
     * @param recipient Address to receive the withdrawn tokens
     * @return amount0 The actual amount of token0 withdrawn
     * @return amount1 The actual amount of token1 withdrawn
     */
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

    /**
     * @notice Gets the total shares for a pool
     * @param poolId The pool ID
     * @return The total shares for the pool
     */
    function poolTotalShares(PoolId poolId) external view returns (uint128);
    
    /**
     * @notice Special internal function for Margin contract to borrow liquidity without burning LP tokens
     * @param poolId The pool ID to borrow from
     * @param sharesToBorrow Amount of shares to borrow (determines token amounts)
     * @param recipient Address to receive the tokens (typically the Margin contract)
     * @return amount0 Amount of token0 received
     * @return amount1 Amount of token1 received
     */
    function borrowImpl(
        PoolId poolId,
        uint256 sharesToBorrow,
        address recipient
    ) external returns (
        uint256 amount0,
        uint256 amount1
    );

    /**
     * @notice Stores the PoolKey associated with a PoolId.
     * @dev Typically called by the hook during its afterInitialize phase.
     * @param poolId The Pool ID.
     * @param key The PoolKey corresponding to the Pool ID.
     */
    function storePoolKey(PoolId poolId, PoolKey calldata key) external;
} 