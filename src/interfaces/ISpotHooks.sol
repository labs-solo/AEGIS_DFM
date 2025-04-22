// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

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
        IPoolManager.SwapParams calldata params,
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
        IPoolManager.SwapParams calldata params,
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
        IPoolManager.ModifyLiquidityParams calldata params,
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
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta);
}
