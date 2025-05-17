// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.0;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

abstract contract MainUtils {
    function permissionsToFlags(Hooks.Permissions memory permissions) internal pure returns (uint160) {
        uint160 flags = 0;

        if (permissions.beforeInitialize) flags |= uint160(Hooks.BEFORE_INITIALIZE_FLAG);
        if (permissions.afterInitialize) flags |= uint160(Hooks.AFTER_INITIALIZE_FLAG);
        if (permissions.beforeAddLiquidity) flags |= uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        if (permissions.afterAddLiquidity) flags |= uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG);
        if (permissions.beforeRemoveLiquidity) flags |= uint160(Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        if (permissions.afterRemoveLiquidity) flags |= uint160(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        if (permissions.beforeSwap) flags |= uint160(Hooks.BEFORE_SWAP_FLAG);
        if (permissions.afterSwap) flags |= uint160(Hooks.AFTER_SWAP_FLAG);
        if (permissions.beforeDonate) flags |= uint160(Hooks.BEFORE_DONATE_FLAG);
        if (permissions.afterDonate) flags |= uint160(Hooks.AFTER_DONATE_FLAG);
        if (permissions.beforeSwapReturnDelta) flags |= uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        if (permissions.afterSwapReturnDelta) flags |= uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        if (permissions.afterAddLiquidityReturnDelta) flags |= uint160(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG);
        if (permissions.afterRemoveLiquidityReturnDelta) {
            flags |= uint160(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);
        }

        return flags;
    }
}
