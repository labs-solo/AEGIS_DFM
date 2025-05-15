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
     * @notice Emitted when fees are reinvested into the pool
     * @param poolId The ID of the pool
     * @param amount0 The amount of token0 reinvested
     * @param amount1 The amount of token1 reinvested
     * @param liquidity The liquidity added to the pool
     */
    event FeesReinvested(PoolId indexed poolId, uint256 amount0, uint256 amount1, uint256 liquidity);

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
     * @param recipient The address of the recipient
     * @param amount0 The amount of token0 withdrawn
     * @param amount1 The amount of token1 withdrawn
     * @param shares The amount of shares burned
     */
    event Withdraw(
        PoolId indexed poolId, address indexed user, address recipient, uint256 amount0, uint256 amount1, uint256 shares
    );

    /**
     * @notice Emitted when protocol-owned liquidity is withdrawn
     * @param poolId The ID of the pool
     * @param recipient The address that received the withdrawn tokens
     * @param shares The amount of protocol-owned shares that were burned
     * @param amount0 The amount of token0 withdrawn
     * @param amount1 The amount of token1 withdrawn
     */
    event WithdrawProtocolLiquidity(
        PoolId indexed poolId, address indexed recipient, uint256 shares, uint256 amount0, uint256 amount1
    );

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
     * @dev Only callable by the policy manager owner
     */
    function emergencyWithdraw(Currency token, address to, uint256 amount) external;

    /**
     * @notice Withdraws protocol-owned liquidity from a pool's NFT position
     * @dev Only callable by policy manager owner
     * @dev Decreases liquidity on the NFT position based on protocol-owned ERC6909 shares
     * @dev Transfers the resulting tokens to the specified recipient
     * @param key The pool key for the position
     * @param sharesToBurn The amount of protocol owned ERC6909Claims shares to burn
     * which corresponds 1:1 with the amount of liquidity to decrease on the NFT
     * @param amount0Min The minimum amount of token0 that must be received
     * @param amount1Min The minimum amount of token1 that must be received
     * @param recipient The address to receive the withdrawn tokens
     * @return amount0 The amount of token0 received
     * @return amount1 The amount of token1 received
     */
    function withdrawProtocolLiquidity(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external returns (uint256 amount0, uint256 amount1);

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
     * @notice Gets the token amounts for a specified pool's NFT position
     * @param poolId The ID of the pool
     * @return positionId The full range NFT position ID for the pool
     * @return liquidity The total liquidity in the position; also equal to the FRLM ERC6909Claims total supply
     * @return amount0 The amount of token0 in the position
     * @return amount1 The amount of token1 in the position
     */
    function getPositionInfo(PoolId poolId)
        external
        view
        returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /**
     * @notice Gets the amount of liquidity a specified number of shares represents
     * @param poolId The ID of the pool
     * @param shares The number of ERC6909 shares
     * @return amount0 The estimated amount of token0
     * @return amount1 The estimated amount of token1
     */
    function getLiquidityForShares(PoolId poolId, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Gets the protocol-owned shares and corresponding liquidity/amounts
     * @param poolId The ID of the pool
     * @return shares The number of shares owned by the protocol; which is also equal to the liquidity owned on the NFT
     * @return amount0 The estimated amount of token0
     * @return amount1 The estimated amount of token1
     */
    function getProtocolOwnedLiquidity(PoolId poolId)
        external
        view
        returns (uint256 shares, uint256 amount0, uint256 amount1);
}
