// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { PoolId } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta } from "v4-core/src/types/BeforeSwapDelta.sol";

/**
 * @title ISpot
 * @notice Interface for the Spot Uniswap V4 hook.
 * @dev Defines core data structures and functions for interacting with Spot liquidity positions.
 */

/**
 * @notice Parameters for depositing liquidity into a pool
 * @param poolId The identifier of the pool to deposit into
 * @param amount0Desired The desired amount of token0 to deposit
 * @param amount1Desired The desired amount of token1 to deposit
 * @param amount0Min The minimum amount of token0 to deposit (slippage protection)
 * @param amount1Min The minimum amount of token1 to deposit (slippage protection)
 * @param deadline The deadline by which the transaction must be executed
 */
struct DepositParams {
    PoolId poolId;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
}

/**
 * @notice Parameters for withdrawing liquidity from a pool
 * @param poolId The identifier of the pool to withdraw from
 * @param sharesToBurn The amount of LP shares to burn
 * @param amount0Min The minimum amount of token0 to receive (slippage protection)
 * @param amount1Min The minimum amount of token1 to receive (slippage protection)
 * @param deadline The deadline by which the transaction must be executed
 */
struct WithdrawParams {
    PoolId poolId;
    uint256 sharesToBurn;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
}

/**
 * @notice Data for hook callbacks
 * @param sender The original sender of the transaction
 * @param key The pool key for the operation
 * @param params The liquidity modification parameters
 * @param isHookOp Whether this is a hook operation
 */
struct CallbackData {
    address sender;
    PoolKey key;
    ModifyLiquidityParams params;
    bool isHookOp;
}

/**
 * @notice Parameters for modifying liquidity
 * @param tickLower The lower tick of the position
 * @param tickUpper The upper tick of the position
 * @param liquidityDelta The change in liquidity
 * @param salt A unique salt for the operation
 */
struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

/**
 * @notice Interface for the Spot system
 * @dev Provides functions for depositing/withdrawing liquidity and managing the hook
 */
interface ISpot is IHooks {
    /**
     * @notice Returns the address of this hook for use in pool initialization
     * @return The address of this contract
     */
    function getHookAddress() external view returns (address);

    /**
     * @notice Sets the emergency state for a specific pool
     * @param poolId The pool ID to modify
     * @param isEmergency Whether to enable or disable emergency state
     */
    function setPoolEmergencyState(PoolId poolId, bool isEmergency) external;

    /**
     * @notice Get the pool key for a pool ID
     * @param poolId The pool ID to get the key for
     * @return The pool key
     */
    function getPoolKey(PoolId poolId) external view returns (PoolKey memory);

    /**
     * @notice Get pool info
     * @param poolId The pool ID to get info for
     * @return isInitialized Whether the pool is initialized
     * @return reserves Array of pool reserves [reserve0, reserve1]
     * @return totalShares Total shares in the pool
     * @return tokenId Token ID for the pool
     */
    function getPoolInfo(PoolId poolId) 
        external 
        view 
        returns (
            bool isInitialized,
            uint256[2] memory reserves,
            uint128 totalShares,
            uint256 tokenId
        );

    /**
     * @notice Get oracle data for a specific pool
     * @dev Used by DynamicFeeManager to pull data instead of receiving updates
     * @param poolId The ID of the pool to get oracle data for
     * @return tick The latest recorded tick
     * @return blockNumber The block number when the tick was last updated
     */
    function getOracleData(PoolId poolId) external view returns (int24 tick, uint32 blockNumber);

    /**
     * @notice Deposits liquidity into a pool.
     * @param params The parameters for the deposit operation.
     * @return shares The amount of LP shares minted.
     * @return amount0 The actual amount of token0 deposited.
     * @return amount1 The actual amount of token1 deposited.
     */
    function deposit(DepositParams calldata params) 
        external 
        payable 
        returns (uint256 shares, uint256 amount0, uint256 amount1);

    /**
     * @notice Withdraws liquidity from a pool.
     * @param params The parameters for the withdrawal operation.
     * @return amount0 The actual amount of token0 withdrawn.
     * @return amount1 The actual amount of token1 withdrawn.
     */
    function withdraw(WithdrawParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Checks if a specific pool is initialized.
     * @param poolId The PoolId to check.
     * @return True if the pool is initialized, false otherwise.
     */
    function isPoolInitialized(PoolId poolId) external view returns (bool);

    /**
     * @notice Gets the current reserves and total liquidity shares for a pool.
     * @param poolId The PoolId of the target pool.
     * @return reserve0 The reserve amount of token0.
     * @return reserve1 The reserve amount of token1.
     * @return totalShares The total liquidity shares outstanding for the pool.
     */
    function getPoolReservesAndShares(PoolId poolId) external view returns (uint256 reserve0, uint256 reserve1, uint128 totalShares);

    /**
     * @notice Gets the token ID associated with a specific pool.
     * @param poolId The PoolId of the target pool.
     * @return The ERC1155 token ID representing the pool's LP shares.
     */
    function getPoolTokenId(PoolId poolId) external view returns (uint256);
} 