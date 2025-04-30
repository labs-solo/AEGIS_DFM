// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/**
 * @title ISpotHooks
 * @notice Extended interface for Spot hooks including additional helper methods
 */
interface ISpotHooks is IHooks {
    /**
     * @notice The hook called before a swap that returns a delta
     * @param sender The initial msg.sender for the swap call
     * @param key The key for the pool
     * @param params The parameters for the swap
     * @param hookData Arbitrary data handed into the PoolManager by the swapper to be passed on to the hook
     * @return bytes4 The function selector for the hook
     * @return BeforeSwapDelta The hook's delta in specified and unspecified currencies
     */
    function beforeSwapReturnDelta(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta);

    /**
     * @notice The hook called after a swap that returns a delta
     * @param sender The initial msg.sender for the swap call
     * @param key The key for the pool
     * @param params The parameters for the swap
     * @param delta The amount owed to the caller (positive) or owed to the pool (negative)
     * @param hookData Arbitrary data handed into the PoolManager by the swapper to be passed on to the hook
     * @return bytes4 The function selector for the hook
     * @return BalanceDelta The hook's delta in token0 and token1
     */
    function afterSwapReturnDelta(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta);

    /**
     * @notice The hook called after liquidity is added that returns a delta
     * @param sender The initial msg.sender for the add liquidity call
     * @param key The key for the pool
     * @param params The parameters for adding liquidity
     * @param delta The caller's balance delta after adding liquidity
     * @param hookData Arbitrary data handed into the PoolManager by the liquidity provider
     * @return bytes4 The function selector for the hook
     * @return BalanceDelta The hook's delta in token0 and token1
     */
    function afterAddLiquidityReturnDelta(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta);

    /**
     * @notice The hook called after liquidity is removed that returns a delta
     * @param sender The initial msg.sender for the remove liquidity call
     * @param key The key for the pool
     * @param params The parameters for removing liquidity
     * @param delta The caller's balance delta after removing liquidity
     * @param feesAccrued The fees accrued during the operation
     * @param hookData Arbitrary data handed into the PoolManager by the liquidity provider
     * @return bytes4 The function selector for the hook
     * @return BalanceDelta The hook's delta in token0 and token1
     */
    function afterRemoveLiquidityReturnDelta(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta);

    // NOTE: do **not** declare `beforeSwap` here – BaseHook already implements
    // it and is non-virtual, so redeclaring would create an override clash.
}
