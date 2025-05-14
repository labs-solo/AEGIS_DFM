// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/**
 * @title IFullRangeLiquidityManager
 * @notice Interface for the FullRangeLiquidityManager contract that handles Spot hook fees
 * @dev Manages fee collection, accounting, reinvestment, and liquidity contributions
 */
interface IFullRangeLiquidityManager {
    /**
     * @notice Emitted when fees are notified to the manager
     * @param poolId The ID of the pool where the fees were collected
     * @param fee0 The amount of token0 fees
     * @param fee1 The amount of token1 fees
     */
    event FeeNotified(PoolId indexed poolId, uint256 fee0, uint256 fee1);

    /**
     * @notice Emitted when fees are reinvested into the pool
     * @param poolId The ID of the pool
     * @param amount0 The amount of token0 reinvested
     * @param amount1 The amount of token1 reinvested
     * @param liquidity The liquidity added to the pool
     */
    event FeesReinvested(PoolId indexed poolId, uint256 amount0, uint256 amount1, uint128 liquidity);

    /**
     * @notice Emitted when a reinvestment is skipped
     * @param poolId The ID of the pool
     * @param reasonCode The reasonCode for skipping
     */
    event ReinvestmentSkipped(PoolId indexed poolId, uint256 reasonCode);

    /**
     * @notice Emitted when a user deposits liquidity
     * @param poolId The ID of the pool
     * @param user The address of the depositor
     * @param amount0 The amount of token0 deposited
     * @param amount1 The amount of token1 deposited
     * @param shares The amount of shares minted
     */
    event Deposit(PoolId indexed poolId, address indexed user, uint256 amount0, uint256 amount1, uint256 shares);

    /**
     * @notice Emitted when a user withdraws liquidity
     * @param poolId The ID of the pool
     * @param user The address of the withdrawer
     * @param amount0 The amount of token0 withdrawn
     * @param amount1 The amount of token1 withdrawn
     * @param shares The amount of shares burned
     */
    event Withdraw(PoolId indexed poolId, address indexed user, uint256 amount0, uint256 amount1, uint256 shares);

    /**
     * @notice Notifies the LiquidityManager of collected fees
     * @param key The pool key
     * @param fee0 The amount of token0 fees
     * @param fee1 The amount of token1 fees
     */
    function notifyFee(PoolKey calldata key, uint256 fee0, uint256 fee1) external;

    /**
     * @notice Manually triggers reinvestment for a pool
     * @param key The pool key for the pool
     * @return success Whether the reinvestment was successful
     */
    function reinvest(PoolKey calldata key) external returns (bool success);

    /**
     * @notice Allows users to deposit tokens to add liquidity to the full range position
     * @param key The pool key for the pool
     * @param amount0Desired The desired amount of token0 to deposit
     * @param amount1Desired The desired amount of token1 to deposit
     * @param amount0Min The minimum amount of token0 that must be used
     * @param amount1Min The minimum amount of token1 that must be used
     * @param recipient The address to receive share tokens
     * @return shares The amount of share tokens minted
     * @return amount0 The amount of token0 actually deposited
     * @return amount1 The amount of token1 actually deposited
     */
    function deposit(
        PoolKey calldata key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external payable returns (uint256 shares, uint256 amount0, uint256 amount1);

    /**
     * @notice Allows users to withdraw liquidity by burning share tokens
     * @param key The pool key for the pool
     * @param sharesToBurn The amount of share tokens to burn
     * @param amount0Min The minimum amount of token0 to receive
     * @param amount1Min The minimum amount of token1 to receive
     * @param recipient The address to receive the tokens
     * @return amount0 The amount of token0 received
     * @return amount1 The amount of token1 received
     */
    function withdraw(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Emergency withdrawal of tokens in case of issues
     * @param token The token to withdraw
     * @param to The recipient address
     * @param amount The amount to withdraw
     * @dev Only callable by the contract owner
     */
    function emergencyWithdraw(Currency token, address to, uint256 amount) external;

    // TODO: add natspec comments and any other functions

    function authorizedHookAddress() external view returns (address);

    /**
     * @notice Gets the pending fees for a pool
     * @param poolId The ID of the pool
     * @return amount0 Pending amount of token0
     * @return amount1 Pending amount of token1
     */
    function getPendingFees(PoolId poolId) external view returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Gets the next reinvestment timestamp for a pool
     * @param poolId The ID of the pool
     * @return timestamp The timestamp when the next reinvestment is allowed
     */
    function getNextReinvestmentTime(PoolId poolId) external view returns (uint256 timestamp);

    /**
     * @notice Gets the reserves of a pool
     * @param poolId The ID of the pool
     * @return reserve0 The reserve of token0
     * @return reserve1 The reserve of token1
     */
    function getPoolReserves(PoolId poolId) external view returns (uint256 reserve0, uint256 reserve1);
}
