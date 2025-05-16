// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

import {IDynamicFeeManager} from "./IDynamicFeeManager.sol";
import {IFullRangeLiquidityManager} from "./IFullRangeLiquidityManager.sol";

import {PoolPolicyManager} from "../PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "../TruncGeoOracleMulti.sol";

/// @title ISpot
/// @notice Interface for the Spot hook contract that implements dynamic fees and oracle integration
interface ISpot is IHooks {
    /// @notice Emitted when a price oracle is successfully initialized for a pool
    /// @param poolId The ID of the pool that had its oracle initialized
    /// @param initialTick The initial tick value recorded at oracle initialization
    /// @param maxAbsTickMove The maximum absolute tick movement allowed before triggering surge pricing
    event OracleInitialized(PoolId indexed poolId, int24 initialTick, int24 maxAbsTickMove);

    /// @notice Emitted when policy initialization fails for a pool
    /// @param poolId The ID of the pool where policy initialization was attempted
    /// @param reason The string explanation of why initialization failed
    event PolicyInitializationFailed(PoolId indexed poolId, string reason);

    /// @notice Emitted when hook fees are collected from a swap but not automatically reinvested
    /// @dev This event is emitted when reinvestment is paused
    /// @param id The pool ID from which fees were collected
    /// @param sender The address that executed the swap, triggering fee collection
    /// @param feeAmount0 The amount of token0 collected as fee
    /// @param feeAmount1 The amount of token1 collected as fee
    event HookFee(PoolId indexed id, address indexed sender, uint128 feeAmount0, uint128 feeAmount1);

    /// @notice Emitted when hook fees are collected from a swap and queued for reinvestment
    /// @dev This event is emitted when reinvestment is active (not paused)
    /// @param id The pool ID from which fees were collected
    /// @param sender The address that executed the swap, triggering fee collection
    /// @param feeAmount0 The amount of token0 collected as fee and queued for reinvestment
    /// @param feeAmount1 The amount of token1 collected as fee and queued for reinvestment
    event HookFeeReinvested(PoolId indexed id, address indexed sender, uint128 feeAmount0, uint128 feeAmount1);

    /// @notice Emitted when the reinvestment status changes
    /// @param paused Boolean indicating whether fee reinvestment is now paused (true) or active (false)
    event ReinvestmentPausedChanged(bool paused);

    /// @notice Proxy function to deposit liquidity into the FullRangeLiquidityManager through Spot
    /// @dev NOT RECOMMENDED: Users should interact with FRLM directly when possible to avoid
    /// additional token transfers and approvals. This function exists for specific integration needs.
    /// @param key The pool key for the pool
    /// @param amount0Desired The desired amount of token0 to deposit
    /// @param amount1Desired The desired amount of token1 to deposit
    /// @param amount0Min The minimum amount of token0 that must be used
    /// @param amount1Min The minimum amount of token1 that must be used
    /// @param recipient The address to receive share tokens
    /// @return shares The amount of share tokens minted
    /// @return amount0 The amount of token0 actually deposited
    /// @return amount1 The amount of token1 actually deposited
    function depositToFRLM(
        PoolKey calldata key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external payable returns (uint256 shares, uint256 amount0, uint256 amount1);

    /// @notice Proxy function to withdraw liquidity from the FullRangeLiquidityManager through Spot
    /// @dev NOT RECOMMENDED: Users should interact with FRLM directly when possible to avoid
    /// additional token transfers and approvals. This function exists for specific integration needs.
    /// @param key The pool key for the pool
    /// @param sharesToBurn The amount of share tokens to burn
    /// @param amount0Min The minimum amount of token0 to receive
    /// @param amount1Min The minimum amount of token1 to receive
    /// @param recipient The address to receive the tokens
    /// @return amount0 The amount of token0 received
    /// @return amount1 The amount of token1 received
    function withdrawFromFRLM(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Sets whether automatic reinvestment of collected fees is paused
    /// @dev When paused, fees are still collected but not automatically converted to liquidity
    /// @dev Can only be called by the policy manager owner
    /// @param paused True to pause reinvestment, false to enable automatic reinvestment
    function setReinvestmentPaused(bool paused) external;

    /// @notice Returns the current reinvestment status
    /// @dev Used to check if fees are being automatically reinvested
    function reinvestmentPaused() external view returns (bool);

    /// @notice Gets the dynamic fee manager contract address
    /// @dev The dynamic fee manager calculates and adjusts fee rates based on market conditions
    function dynamicFeeManager() external view returns (IDynamicFeeManager);

    /// @notice Gets the liquidity manager contract address
    /// @dev The liquidity manager handles fee reinvestment and liquidity positions
    function liquidityManager() external view returns (IFullRangeLiquidityManager);

    /// @notice Gets the policy manager contract address
    /// @dev The policy manager determines fee distribution and access controls
    function policyManager() external view returns (PoolPolicyManager);

    /// @notice Gets the oracle contract address
    /// @dev The oracle tracks price movements and informs dynamic fee adjustments
    function truncGeoOracle() external view returns (TruncGeoOracleMulti);
}
