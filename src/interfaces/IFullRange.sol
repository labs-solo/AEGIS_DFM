// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/**
 * @title IFullRange
 * @notice Base interface for the FullRange multi-file architecture.
 * @dev Defines core data structures and minimal interface functions for the FullRange system.
 */

/**
 * @notice Parameters for depositing liquidity into a pool
 * @param poolId The identifier of the pool to deposit into
 * @param amount0Desired The desired amount of token0 to deposit
 * @param amount1Desired The desired amount of token1 to deposit
 * @param amount0Min The minimum amount of token0 to deposit (slippage protection)
 * @param amount1Min The minimum amount of token1 to deposit (slippage protection)
 * @param to The address that will receive any LP tokens or position NFTs
 * @param deadline The deadline by which the transaction must be executed
 */
struct DepositParams {
    PoolId poolId;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    address to;
    uint256 deadline;
}

/**
 * @notice Parameters for withdrawing liquidity from a pool
 * @param poolId The identifier of the pool to withdraw from
 * @param sharesBurn The amount of LP shares to burn
 * @param amount0Min The minimum amount of token0 to receive (slippage protection)
 * @param amount1Min The minimum amount of token1 to receive (slippage protection)
 * @param deadline The deadline by which the transaction must be executed
 */
struct WithdrawParams {
    PoolId poolId;
    uint256 sharesBurn;
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
 * @notice Interface for the FullRange system
 * @dev Minimal interface for external integrations
 */
interface IFullRange {
    /**
     * @notice Initializes a new pool with a dynamic fee
     * @param key The pool key containing currency pair, fee, tickSpacing, and hooks
     * @param initialSqrtPriceX96 The initial square root price of the pool
     * @return poolId The ID of the created pool
     */
    function initializeNewPool(
        PoolKey calldata key,
        uint160 initialSqrtPriceX96
    ) external returns (PoolId poolId);

    /**
     * @notice Deposits liquidity into a pool
     * @param params The deposit parameters
     * @return delta The balance delta resulting from the deposit
     */
    function deposit(DepositParams calldata params) external returns (BalanceDelta delta);

    /**
     * @notice Withdraws liquidity from a pool
     * @param params The withdrawal parameters
     * @return delta The balance delta resulting from the withdrawal
     * @return amount0Out The amount of token0 received
     * @return amount1Out The amount of token1 received
     */
    function withdraw(WithdrawParams calldata params) 
        external 
        returns (BalanceDelta delta, uint256 amount0Out, uint256 amount1Out);

    /**
     * @notice Claims and reinvests any accrued fees
     */
    function claimAndReinvestFees() external;
} 