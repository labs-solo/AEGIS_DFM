// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/**
 * @title Extended CoreHookLayer Requirements with Business Source License
 * @notice This document outlines the additional requirements for an extended base hook contract,
 *         implemented in this file (src/base/ExtendedBaseHook.sol), that implements all callback 
 *         functions defined in the IHooks interface with default behavior, and is subject to a 
 *         Business Source License with conversion to MIT in 2031.
 *
 * @dev The extended base hook contract (e.g., ExtendedBaseHook) must fulfill the following additional requirements:
 *
 * === Access Control ===
 * 1. All external callback functions (before/after initialization, before/after add/remove liquidity,
 *    before/after swap, before/after donate) MUST be restricted to calls from the PoolManager contract.
 *    - Enforce this using a modifier (e.g., onlyPoolManager) that reverts with a custom error NotPoolManager()
 *      when violated. Test stubs MUST use error selector matching (via abi.encodeWithSelector) to verify this.
 *
 * === Hook Address Validation ===
 * 2. The constructor MUST validate the hook address by invoking a function (e.g., validateHookAddress)
 *    that verifies the deployed hook's least significant bits match the expected hook permissions as defined
 *    by the Hooks library.
 *    - A contract that returns mismatched permissions (e.g., one flag set incorrectly) MUST revert during deployment.
 *    - IMPORTANT: Derived contracts MUST override validateHookAddress to call Hooks.validateHookPermissions with
 *      the correct permissions from getHookPermissions().
 *    - CAUTION: The validateHookAddress function MUST be declared as internal view, not pure, since it interacts
 *      with getHookPermissions() which reads state.
 *
 * === State Mutability Requirements ===
 * 3. The getHookPermissions() function MUST be declared as view (not pure), since it is typically used to return
 *    configuration values that may be stored in state or derived from state.
 *    - COMMON ERROR: Incorrectly marking getHookPermissions() as pure will cause state mutability errors when
 *      the function is used in contexts where it interacts with state variables.
 *
 * === Complete Implementation of IHooks ===
 * 4. The contract MUST implement all callback functions from the IHooks interface, including:
 *    - beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
 *    - afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
 *    - beforeAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata hookData)
 *    - afterAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata hookData)
 *    - beforeRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata hookData)
 *    - afterRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata hookData)
 *    - beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
 *    - afterSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
 *    - beforeDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
 *    - afterDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
 *
 * === Default Behavior and Internal Overrides ===
 * 5. For each external callback function, an internal function (prefixed with an underscore) MUST be provided,
 *    which returns a default value (typically the function selector or a zeroed balance delta).
 *    - Derived contracts MUST override these internal functions to implement custom logic as needed.
 *
 * === Extended Hook Permissions ===
 * 6. The getHookPermissions() function MUST return true for all hooks, including additional ones such as:
 *    - beforeSwapReturnDelta, afterSwapReturnDelta, afterAddLiquidityReturnDelta, afterRemoveLiquidityReturnDelta.
 *    - If these additional hooks are intended for use, their corresponding logic MUST be implemented in derived contracts.
 *
 * === Minimal State and Error Handling ===
 * 7. The contract MUST maintain minimal state, with only essential variables (e.g., an immutable PoolManager reference).
 *    - Tests SHOULD verify that no extra storage is used beyond the immutable poolManager.
 * 8. The contract MUST define appropriate custom error types (e.g., NotPoolManager, HookNotImplemented) and use them
 *    to revert execution when access control or implementation expectations are not met.
 *
 * === Default Return Values ===
 * 9. Each internal hook implementation MUST return a default value:
 *    - For initialization and liquidity hooks, return the function selector from IHooks.
 *    - For swap hooks, return a tuple containing the selector, a wrapped zero BeforeSwapDelta, and a fee override of 0,
 *      or a zeroed integer for afterSwap.
 *
 * === PoolManager Interaction Guidelines ===
 * 10. When interacting with the PoolManager for state-modifying operations:
 *    - REQUIRED: Implement the IUnlockCallback interface to receive callbacks from PoolManager.unlock().
 *    - CRITICAL: State-modifying operations (like modifyLiquidity) MUST be called within the unlockCallback function.
 *    - Use the CurrencySettler library to properly handle balance deltas returned from operations:
 *      a. For negative amounts (tokens owed by your contract): use CurrencySettler.settle()
 *      b. For positive amounts (tokens owed to your contract): use CurrencySettler.take()
 *    - When converting between int128 and uint256, use proper casting techniques to avoid underflow/overflow.
 *    - IMPORTANT: Ensure your contract has sufficient tokens minted and approved before operations.
 *
 * === Imports and Dependencies ===
 * 11. The contract MUST import the following dependencies:
 *    - {Hooks} from "v4-core/src/libraries/Hooks.sol"
 *    - {IHooks} from "v4-core/src/interfaces/IHooks.sol"
 *    - {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol"
 *    - {PoolKey} from "v4-core/src/types/PoolKey.sol"
 *    - {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol"
 *    - {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol"
 *
 * === License Requirements ===
 * 12. This software is provided under a Business Source License (BSL) 1.1, under which commercial usage
 *     is restricted until the conversion date.
 *     - The BSL conversion date is set for January 1, 2031, at which point the software will automatically
 *       convert to the MIT License, making it fully open source.
 *
 */

/// @title ExtendedBaseHook
/// @notice Base contract for Uniswap V4 Hooks with extended functionality
abstract contract ExtendedBaseHook is IHooks {
    /// @notice The Uniswap V4 Pool Manager
    IPoolManager public immutable poolManager;

    /// @notice Thrown when the caller is not PoolManager
    error NotPoolManager();

    /// @notice Thrown when a hook is not implemented
    error HookNotImplemented();

    /// @notice Only allow calls from the PoolManager contract
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        validateHookAddress(this);
    }

    /// @dev Sets up hook permissions
    function getHookPermissions() public view virtual returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: true,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /// @notice Validates the deployed hook address agrees with the expected permissions of the hook
    function validateHookAddress(ExtendedBaseHook _this) internal view virtual {
        Hooks.validateHookPermissions(_this, getHookPermissions());
    }

    /// @notice Implementation for beforeInitialize
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) 
        external 
        virtual
        onlyPoolManager
        returns (bytes4) 
    {
        return _beforeInitialize(sender, key, sqrtPriceX96);
    }

    /// @notice Internal implementation for beforeInitialize
    function _beforeInitialize(address, PoolKey calldata, uint160) 
        internal 
        virtual 
        returns (bytes4) 
    {
        return IHooks.beforeInitialize.selector;
    }

    /// @notice Implementation for afterInitialize
    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick) 
        external 
        virtual
        onlyPoolManager
        returns (bytes4) 
    {
        return _afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    /// @notice Internal implementation for afterInitialize
    function _afterInitialize(address, PoolKey calldata, uint160, int24) 
        internal 
        virtual 
        returns (bytes4) 
    {
        return IHooks.afterInitialize.selector;
    }

    /// @notice Implementation for beforeAddLiquidity
    function beforeAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata hookData)
        external
        virtual
        onlyPoolManager
        returns (bytes4)
    {
        return _beforeAddLiquidity(sender, key, params, hookData);
    }

    /// @notice Internal implementation for beforeAddLiquidity
    function _beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @notice Implementation for beforeRemoveLiquidity
    function beforeRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata hookData)
        external
        virtual
        onlyPoolManager
        returns (bytes4)
    {
        return _beforeRemoveLiquidity(sender, key, params, hookData);
    }

    /// @notice Internal implementation for beforeRemoveLiquidity
    function _beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @notice Implementation for beforeDonate
    function beforeDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        virtual
        onlyPoolManager
        returns (bytes4)
    {
        return _beforeDonate(sender, key, amount0, amount1, hookData);
    }

    /// @notice Internal implementation for beforeDonate
    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    /// @notice Implementation for afterDonate
    function afterDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        virtual
        onlyPoolManager
        returns (bytes4)
    {
        return _afterDonate(sender, key, amount0, amount1, hookData);
    }

    /// @notice Internal implementation for afterDonate
    function _afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    /// @notice Implementation for beforeSwap
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
        external
        virtual
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return _beforeSwap(sender, key, params, hookData);
    }

    /// @notice Internal implementation for beforeSwap
    function _beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    /// @notice Implementation for afterSwap
    function afterSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        external
        virtual
        onlyPoolManager
        returns (bytes4, int128)
    {
        return _afterSwap(sender, key, params, delta, hookData);
    }

    /// @notice Internal implementation for afterSwap
    function _afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        virtual
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    /// @notice Implementation for afterAddLiquidity
    function afterAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta fees, bytes calldata hookData)
        external
        virtual
        onlyPoolManager
        returns (bytes4, BalanceDelta)
    {
        return _afterAddLiquidity(sender, key, params, delta, fees, hookData);
    }

    /// @notice Internal implementation for afterAddLiquidity
    function _afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        internal
        virtual
        returns (bytes4, BalanceDelta)
    {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice Implementation for afterRemoveLiquidity
    function afterRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta fees, bytes calldata hookData)
        external
        virtual
        onlyPoolManager
        returns (bytes4, BalanceDelta)
    {
        return _afterRemoveLiquidity(sender, key, params, delta, fees, hookData);
    }

    /// @notice Internal implementation for afterRemoveLiquidity
    function _afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        internal
        virtual
        returns (bytes4, BalanceDelta)
    {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}