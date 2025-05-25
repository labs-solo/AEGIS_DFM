// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {PositionManager} from "v4-periphery/src/PositionManager.sol";

import {PoolPolicyManager} from "../PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "../TruncGeoOracleMulti.sol";

/// @title IFullRangeLiquidityManager
/// @notice Interface for the FullRangeLiquidityManager contract that handles liquidity and fee management
/// @dev Manages fee collection, accounting, reinvestment, and full-range liquidity positions
interface IFullRangeLiquidityManager is IUnlockCallback {
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

    /// @notice Emitted when excess tokens are swept
    /// @param currency The currency that was swept
    /// @param recipient The address that received the tokens
    /// @param amount The amount of tokens swept
    event ExcessTokensSwept(Currency indexed currency, address indexed recipient, uint256 amount);

    /// @dev emitted in notifyModifyLiquidity whenever an NFT's liquidity is modified
    event PositionFeeAccrued(uint256 indexed tokenId, PoolId indexed poolId, int128 fees0, int128 fees1);

    event Donation(PoolId indexed poolId, address indexed donor, uint256 amount0, uint256 amount1);

    /// @notice Emitted when the reinvestment TWAP period is updated
    /// @param newTwapPeriod The new TWAP period in seconds
    event ReinvestmentTwapUpdated(uint32 newTwapPeriod);

    /// @notice Emitted when the tick range tolerance is updated
    /// @param newTickTolerance The new tick range tolerance (maximum allowed deviation from TWAP)
    event TickRangeToleranceUpdated(int24 newTickTolerance);

    enum CallbackAction {
        TAKE_TOKENS,
        SWEEP_TOKEN
    }

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

    /// @notice Sweeps excess tokens accidentally sent to the contract
    /// @param currency The currency to sweep
    /// @param recipient The address to send the excess tokens to
    /// @return amountSwept The amount of tokens swept
    function sweepExcessTokens(Currency currency, address recipient) external returns (uint256 amountSwept);

    /// @notice Sweeps excess ERC6909 tokens accidentally minted to the contract
    /// @param currency The currency to sweep
    /// @param recipient The address to send the excess tokens to
    /// @return amountSwept The amount of tokens swept
    function sweepExcessERC6909(Currency currency, address recipient) external returns (uint256 amountSwept);

    /// @notice Allows anyone to donate tokens to the pending fees of a specific pool
    /// @param key The PoolKey of the pool to donate to
    /// @param amount0 The amount of currency0 to donate
    /// @param amount1 The amount of currency1 to donate
    /// @return donated0 The actual amount of currency0 donated
    /// @return donated1 The actual amount of currency1 donated
    function donate(PoolKey calldata key, uint256 amount0, uint256 amount1)
        external
        payable
        returns (uint256 donated0, uint256 donated1);

    /// @notice Sets the TWAP period used for reinvestment price validation
    /// @param _reinvestmentTwap The TWAP period in seconds (must be > 0 and <= 7200)
    /// @dev Only callable by policy owner. Used to prevent MEV attacks during reinvestment
    function setReinvestmentTwap(uint32 _reinvestmentTwap) external;

    /// @notice Sets the tick range tolerance for reinvestment price validation
    /// @param _tickRangeTolerance Maximum allowed deviation from TWAP tick (must be >= 0 and <= 500)
    /// @dev Only callable by policy owner. Used to prevent MEV attacks during reinvestment
    function setTickRangeTolerance(int24 _tickRangeTolerance) external;

    // - - - immutable views - - -

    /// @notice The Uniswap V4 PoolManager
    function poolManager() external view returns (IPoolManager);

    /// @notice The Uniswap V4 PositionManager for adding liquidity
    function positionManager() external view returns (PositionManager);

    /// @notice The policy manager contract that determines ownership
    function policyManager() external view returns (PoolPolicyManager);

    /// @notice The oracle contract
    function oracle() external view returns (TruncGeoOracleMulti);

    /// @notice The "constant" Spot hook contract address that can notify fees
    function authorizedHookAddress() external view returns (address);

    // - - - variable views - - -

    /// @notice Tracks accounted balances of tokens per currency custodied directly by this contract
    function accountedBalances(Currency currency) external view returns (uint256);

    /// @notice Tracks accounted balances of ERC6909 tokens per currency ID custodied directly by this contract
    function accountedERC6909Balances(Currency currency) external view returns (uint256);

    /// @notice Time window for TWAP calculation (e.g., 600 seconds = 10 minutes)
    function reinvestmentTwap() external view returns (uint32);

    /// @notice Allowed deviation from TWAP (e.g., ±50 ticks)
    function tickRangeTolerance() external view returns (int24);

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
