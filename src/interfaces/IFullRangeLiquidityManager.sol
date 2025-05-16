// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @title IFullRangeLiquidityManager
/// @notice Interface for the FullRangeLiquidityManager contract that handles liquidity and fee management
/// @dev Manages fee collection, accounting, reinvestment, and full-range liquidity positions
interface IFullRangeLiquidityManager {
    /// @notice Emitted when fees are reinvested into the pool
    /// @param poolId The ID of the pool
    /// @param amount0 The amount of token0 reinvested
    /// @param amount1 The amount of token1 reinvested
    /// @param liquidity The liquidity added to the pool
    event FeesReinvested(PoolId indexed poolId, uint256 amount0, uint256 amount1, uint256 liquidity);

    /// @notice Emitted when a user deposits liquidity
    /// @param poolId The ID of the pool
    /// @param user The address of the depositor
    /// @param shares The amount of shares minted to represent the liquidity
    /// @param amount0 The amount of token0 deposited
    /// @param amount1 The amount of token1 deposited
    event Deposit(PoolId indexed poolId, address indexed user, uint256 shares, uint256 amount0, uint256 amount1);

    /// @notice Emitted when a user withdraws liquidity
    /// @param poolId The ID of the pool
    /// @param user The address of the withdrawer
    /// @param recipient The address receiving the withdrawn assets
    /// @param amount0 The amount of token0 withdrawn
    /// @param amount1 The amount of token1 withdrawn
    /// @param shares The amount of shares burned
    event Withdraw(
        PoolId indexed poolId, address indexed user, address recipient, uint256 amount0, uint256 amount1, uint256 shares
    );

    /// @notice Emitted when protocol-owned liquidity is withdrawn
    /// @param poolId The ID of the pool
    /// @param recipient The address that received the withdrawn tokens
    /// @param shares The amount of protocol-owned shares that were burned
    /// @param amount0 The amount of token0 withdrawn
    /// @param amount1 The amount of token1 withdrawn
    event WithdrawProtocolLiquidity(
        PoolId indexed poolId, address indexed recipient, uint256 shares, uint256 amount0, uint256 amount1
    );

    /// @notice Notifies the LiquidityManager of collected fees
    /// @dev Called by the authorized hook to record fees collected from swaps
    /// @param key The pool key identifying the pool that generated the fees
    /// @param fee0 The amount of token0 fees collected
    /// @param fee1 The amount of token1 fees collected
    function notifyFee(PoolKey calldata key, uint256 fee0, uint256 fee1) external;

    /// @notice Manually triggers reinvestment of accumulated fees into liquidity
    /// @dev Converts pending fees into additional liquidity if thresholds and cooldown are met
    /// @param key The pool key for the pool where fees should be reinvested
    /// @return success Boolean indicating whether the reinvestment was successfully executed
    function reinvest(PoolKey calldata key) external returns (bool success);

    /// @notice Allows users to deposit tokens to add liquidity to the full range position
    /// @dev Mints ERC6909 shares in proportion to the contributed liquidity
    /// @param key The pool key for the pool where liquidity will be added
    /// @param amount0Desired The desired amount of token0 to deposit
    /// @param amount1Desired The desired amount of token1 to deposit
    /// @param amount0Min The minimum amount of token0 that must be used to prevent slippage
    /// @param amount1Min The minimum amount of token1 that must be used to prevent slippage
    /// @param recipient The address to receive share tokens
    /// @param payer The address of the payer whose allowance the FRLM will try spend
    /// @return liquidityAdded The amount of share tokens minted, corresponding 1:1 with liquidity
    /// @return amount0 The amount of token0 actually deposited
    /// @return amount1 The amount of token1 actually deposited
    /// @return unusedAmount0 The amount of token0 not used in the deposit
    /// @return unusedAmount1 The amount of token1 not used in the deposit
    function deposit(
        PoolKey calldata key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        address payer
    )
        external
        payable
        returns (uint256 liquidityAdded, uint256 amount0, uint256 amount1, uint256 unusedAmount0, uint256 unusedAmount1);

    /// @notice Allows users to withdraw liquidity by burning share tokens
    /// @dev Burns ERC6909 shares and returns the proportional amount of underlying assets
    /// @param key The pool key for the pool where liquidity will be withdrawn
    /// @param sharesToBurn The amount of share tokens to burn
    /// @param amount0Min The minimum amount of token0 to receive to prevent slippage
    /// @param amount1Min The minimum amount of token1 to receive to prevent slippage
    /// @param recipient The address to receive the withdrawn tokens
    /// @param sharesOwner The address to owner whose shares will be burned
    /// @return amount0 The amount of token0 received
    /// @return amount1 The amount of token1 received
    function withdraw(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        address sharesOwner
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Emergency withdrawal function for handling unexpected scenarios
    /// @dev Allows policy owner to directly withdraw tokens from the pool manager
    /// @param token The token currency to withdraw
    /// @param to The recipient address to receive the withdrawn tokens
    /// @param amount The amount of tokens to withdraw
    function emergencyWithdraw(Currency token, address to, uint256 amount) external;

    /// @notice Withdraws protocol-owned liquidity from a pool's NFT position
    /// @dev Burns protocol-owned ERC6909 shares and withdraws proportional assets from the position
    /// @dev Only callable by policy manager owner
    /// @param key The pool key for the position
    /// @param sharesToBurn The amount of protocol-owned ERC6909 shares to burn (1:1 with liquidity)
    /// @param amount0Min The minimum amount of token0 that must be received to prevent slippage
    /// @param amount1Min The minimum amount of token1 that must be received to prevent slippage
    /// @param recipient The address to receive the withdrawn tokens
    /// @return amount0 The amount of token0 received
    /// @return amount1 The amount of token1 received
    function withdrawProtocolLiquidity(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Allows the policy owner to withdraw any tokens accidentally sent to this contract
    /// @dev Excludes ERC6909 tokens minted by this contract that represent protocol-owned liquidity
    /// @param token The address of the token to sweep (address(0) for native ETH)
    /// @param recipient The address to receive the tokens
    /// @param amount The amount of tokens to sweep (0 for the entire balance)
    /// @return amountSwept The actual amount swept
    function sweepToken(address token, address recipient, uint256 amount) external returns (uint256 amountSwept);

    /// @notice Returns the authorized hook address that can notify fees
    function authorizedHookAddress() external view returns (address);

    /// @notice Gets the pending fees for a pool that haven't been reinvested yet
    /// @dev These fees accrue until reinvestment conditions are met
    /// @param poolId The ID of the pool
    /// @return amount0 Pending amount of token0 fees
    /// @return amount1 Pending amount of token1 fees
    function getPendingFees(PoolId poolId) external view returns (uint256 amount0, uint256 amount1);

    /// @notice Gets the timestamp when the next reinvestment is allowed for a pool
    /// @dev Based on the cooldown period after the last reinvestment
    /// @param poolId The ID of the pool
    /// @return timestamp The timestamp when the next reinvestment is allowed
    function getNextReinvestmentTime(PoolId poolId) external view returns (uint256 timestamp);

    /// @notice Gets the token amounts and liquidity for a specified pool's NFT position
    /// @dev Returns all relevant information about the full-range position
    /// @param poolId The ID of the pool
    /// @return positionId The full range NFT position ID for the pool
    /// @return liquidity The total liquidity in the position; equals the FRLM ERC6909 total supply
    /// @return amount0 The amount of token0 in the position at current price
    /// @return amount1 The amount of token1 in the position at current price
    function getPositionInfo(PoolId poolId)
        external
        view
        returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Gets the token amounts a specified number of shares represents
    /// @dev Calculates the proportional amount of underlying assets for a given share amount
    /// @param poolId The ID of the pool
    /// @param shares The number of ERC6909 shares to query
    /// @return amount0 The estimated amount of token0 the shares represent at current price
    /// @return amount1 The estimated amount of token1 the shares represent at current price
    function getLiquidityForShares(PoolId poolId, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    /// @notice Gets the protocol-owned shares and corresponding liquidity/token amounts
    /// @dev Used to track protocol revenue from reinvested fees
    /// @param poolId The ID of the pool
    /// @return shares The number of shares owned by the protocol; equal to protocol-owned liquidity on the NFT
    /// @return amount0 The estimated amount of token0 the protocol owns at current price
    /// @return amount1 The estimated amount of token1 the protocol owns at current price
    function getProtocolOwnedLiquidity(PoolId poolId)
        external
        view
        returns (uint256 shares, uint256 amount0, uint256 amount1);
}
