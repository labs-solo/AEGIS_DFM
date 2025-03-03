// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ExtendedBaseHook} from "src/base/ExtendedBaseHook.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

/**
 * @title SoloVault
 * @notice This contract implements custom accounting and hook‑owned liquidity management,
 *         extended to support an infinite number of pools.
 *
 * @dev IMPLEMENTATION INSTRUCTIONS FOR INFINITE POOLS:
 *      1. Replace the single PoolKey variable with a mapping keyed by PoolId.
 *         Example: mapping(bytes32 => PoolKey) public poolKeys;
 *
 *      2. Update all liquidity functions (e.g., addLiquidity, removeLiquidity, unlockCallback)
 *         to derive and use a PoolId (using PoolKey.toId()) and operate on poolKeys[poolId].
 *
 *      3. Update pool-specific state variables (like liquidityShares) to be mappings keyed by PoolId.
 *         Example: mapping(address => mapping(bytes32 => uint256)) public liquidityShares;
 *
 *      4. Provide a helper function getPoolKey(bytes32 poolId) that returns the PoolKey for a given pool.
 *
 *      5. Minimal deposit functionality: A deposit function that accepts a poolId, token amounts, and updates
 *         liquidityShares for that pool.
 *
 * @dev SoloVault now inherits from ExtendedBaseHook, which implements the full IHooks interface.
 */
 
// Abstract implementation pattern following V4 interfaces
// Reference: lib/uniswap-hooks/lib/v4-core/src/interfaces/IHooks.sol:10-141
abstract contract SoloVault is ExtendedBaseHook {
    // Library usage patterns match V4 core standards
    // Reference: lib/v4-core/src/libraries/StateLibrary.sol
    using StateLibrary for IPoolManager;
    // Reference: lib/v4-core/src/types/PoolId.sol:4-10 - Global usage pattern for PoolIdLibrary
    using PoolIdLibrary for PoolKey;
    // Reference: lib/v4-core/src/types/Currency.sol:8 - Global usage of CurrencyLibrary for Currency type
    using CurrencyLibrary for Currency;

    // Share type constants for position accounting
    // Reference: lib/v4-periphery/src/libraries/PositionInfoLibrary.sol:10-12
    uint8 public constant ShareTypeAB = 0; // Both tokens
    
    // --- Custom Errors ---
    error ExpiredPastDeadline();
    error PoolNotInitialized();
    error TooMuchSlippage();
    error LiquidityOnlyViaHook();
    error InvalidNativeValue();
    error AlreadyInitialized();

    // --- Structs ---
    struct AddLiquidityParams {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address to;
        uint256 deadline;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
    }

    struct RemoveLiquidityParams {
        uint256 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
    }

    // Proper Callback Data Structure
    // Reference: lib/v4-core/test/utils/Fixtures.sol:67-78 - Standard callback data pattern
    struct CallbackData {
        address sender;
        bytes32 poolId;
        IPoolManager.ModifyLiquidityParams params;
    }

    // --- State Variables for Multi-Pool Support ---
    // Mapping of poolId to its PoolKey 
    // Reference: lib/v4-core/src/PoolManager.sol:107-109 - Key storage pattern
    mapping(bytes32 => PoolKey) public poolKeys;

    // Properly Segmented Liquidity Shares
    // Reference: lib/v4-periphery/src/libraries/PositionInfoLibrary.sol:8-15 - Multi-level mapping pattern
    mapping(address => mapping(bytes32 => mapping(uint8 => uint256))) public liquidityShares;

    // --- Constructor ---
    constructor(IPoolManager _poolManager) ExtendedBaseHook(_poolManager) {}

    // --- PoolKey Management ---
    /**
     * @notice Initializes a pool by storing its PoolKey.
     * @param key The PoolKey for the pool.
     * @return selector The function selector from beforeInitialize.
     */
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        // Proper Pool ID Type Conversion
        // Reference: lib/v4-core/src/types/PoolId.sol:24-27 - Type conversion pattern
        bytes32 poolId = PoolId.unwrap(key.toId());
        
        // Proper Hook Address Validation
        // Reference: lib/v4-periphery/src/utils/HookMiner.sol:40-43 - Validation pattern
        if (address(poolKeys[poolId].hooks) != address(0)) revert AlreadyInitialized();
        poolKeys[poolId] = key;
        return this.beforeInitialize.selector;
    }

    /**
     * @notice Returns the PoolKey for a given poolId.
     * @param poolId The pool identifier.
     * @return The PoolKey.
     */
    function getPoolKey(bytes32 poolId) external view returns (PoolKey memory) {
        return poolKeys[poolId];
    }

    /**
     * @notice Simple deposit function that updates liquidityShares for a pool.
     * @param poolId The unique identifier for the pool
     * @param amount0 Amount of token0 to deposit
     * @param amount1 Amount of token1 to deposit
     * @param useHook Whether to use the hook for liquidity management
     */
    function deposit(bytes32 poolId, uint256 amount0, uint256 amount1, bool useHook) external {
        // In a real implementation, tokens would be transferred here
        if (useHook) {
            // Record hook-managed liquidity shares for the sender
            liquidityShares[msg.sender][poolId][ShareTypeAB] += (amount0 + amount1);
        }
    }

    // --- Liquidity Operations ---
    /**
     * @notice Adds liquidity to a specific pool.
     * @param poolId The unique identifier for the pool.
     * @param params The liquidity addition parameters.
     * @return delta The balance delta from the PoolManager.
     */
    function addLiquidity(bytes32 poolId, AddLiquidityParams calldata params)
        external
        payable
        returns (BalanceDelta delta)
    {
        // Retrieve the pool configuration
        PoolKey memory key = poolKeys[poolId];
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // Native token handling pattern from CurrencyLibrary
        // Reference: lib/v4-core/src/types/Currency.sol:100-115
        if (key.currency0 == CurrencyLibrary.ADDRESS_ZERO && msg.value != params.amount0Desired) {
            revert InvalidNativeValue();
        }

        (bytes memory modifyParams, uint256 shares) = _getAddLiquidity(sqrtPriceX96, params);
        delta = _modifyLiquidity(modifyParams);
        _mint(params, delta, shares);

        // Slippage check pattern
        // Reference: lib/v4-periphery/src/base/LiquidityManagement.sol:77-80
        if (uint128(-delta.amount0()) < params.amount0Min || uint128(-delta.amount1()) < params.amount1Min) {
            revert TooMuchSlippage();
        }

        // Record liquidity shares for the depositor
        liquidityShares[params.to][poolId][ShareTypeAB] += shares;
    }

    /**
     * @notice Removes liquidity from a specific pool.
     * @param poolId The unique identifier for the pool.
     * @param params The liquidity removal parameters.
     * @return delta The balance delta from the PoolManager.
     */
    function removeLiquidity(bytes32 poolId, RemoveLiquidityParams calldata params)
        external
        returns (BalanceDelta delta)
    {
        PoolKey memory key = poolKeys[poolId];
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        (bytes memory modifyParams, uint256 shares) = _getRemoveLiquidity(params);
        delta = _modifyLiquidity(modifyParams);
        _burn(params, delta, shares);

        // Safe amount extraction pattern
        // Reference: lib/v4-core/src/types/BalanceDelta.sol:58-68
        uint128 amount0 = delta.amount0() < 0 ? uint128(-delta.amount0()) : uint128(delta.amount0());
        uint128 amount1 = delta.amount1() < 0 ? uint128(-delta.amount1()) : uint128(delta.amount1());
        if (amount0 < params.amount0Min || amount1 < params.amount1Min) {
            revert TooMuchSlippage();
        }

        // Deduct liquidity shares for the caller
        liquidityShares[msg.sender][poolId][ShareTypeAB] -= shares;
    }

    // --- Unlock Callback ---
    function unlockCallback(bytes calldata rawData)
        external
        onlyPoolManager
        returns (bytes memory returnData)
    {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        // Retrieve pool key directly from our mapping using the poolId from CallbackData
        bytes32 poolId = data.poolId;
        PoolKey memory key = poolKeys[poolId];

        (BalanceDelta delta, BalanceDelta feeDelta) = poolManager.modifyLiquidity(key, data.params, "");
        
        // Balance Delta Handling - operator pattern
        // Reference: lib/v4-core/src/types/BalanceDelta.sol:35-47
        delta = delta - feeDelta;

        // Currency Settlement For Deltas - conditional pattern
        // Reference: lib/v4-core/test/utils/CurrencySettler.sol:29-32
        if (delta.amount0() < 0) {
            // Standard Currency Settlement Pattern
            // Reference: lib/v4-core/test/utils/CurrencySettler.sol:13-27
            CurrencySettler.settle(key.currency0, poolManager, data.sender, uint256(int256(-delta.amount0())), false);
        } else {
            CurrencySettler.take(key.currency0, poolManager, data.sender, uint256(int256(delta.amount0())), false);
        }

        if (delta.amount1() < 0) {
            CurrencySettler.settle(key.currency1, poolManager, data.sender, uint256(int256(-delta.amount1())), false);
        } else {
            CurrencySettler.take(key.currency1, poolManager, data.sender, uint256(int256(delta.amount1())), false);
        }

        return abi.encode(delta);
    }

    // --- Inherited from BaseCustomAccounting (modified for multi-pool) ---
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        // Pool Initialization Pattern
        // Reference: lib/v4-core/src/PoolManager.sol:286-290
        bytes32 poolId = PoolId.unwrap(key.toId());
        if (address(poolKeys[poolId].hooks) != address(0)) revert AlreadyInitialized();
        poolKeys[poolId] = key;
        return this.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        internal
        virtual
        override
        returns (bytes4)
    {
        revert LiquidityOnlyViaHook();
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    )
        internal
        virtual
        override
        returns (bytes4)
    {
        revert LiquidityOnlyViaHook();
    }

    // --- Abstract Functions (to be implemented in derived contracts) ---
    function _getAddLiquidity(uint160 sqrtPriceX96, AddLiquidityParams memory params)
        internal
        virtual
        returns (bytes memory modify, uint256 shares)
    {
        // Default implementation for testing purposes
        modify = "";
        shares = 1;
    }

    function _getRemoveLiquidity(RemoveLiquidityParams memory params)
        internal
        virtual
        returns (bytes memory modify, uint256 shares)
    {
        // Default implementation for testing purposes
        modify = "";
        shares = 1;
    }

    function _mint(AddLiquidityParams memory params, BalanceDelta delta, uint256 shares)
        internal
        virtual
    {
        // Default implementation for testing purposes
        // No-op
    }

    function _burn(RemoveLiquidityParams memory params, BalanceDelta delta, uint256 shares)
        internal
        virtual
    {
        // Default implementation for testing purposes  
        // No-op
    }

    // Default Implementation For Testing
    // Reference: lib/v4-core/test/PoolManager.t.sol:200-205
    function _modifyLiquidity(bytes memory modifyParams)
        internal
        virtual
        returns (BalanceDelta)
    {
        // Default implementation for testing purposes
        // In a real implementation, this would decode the params and call poolManager.modifyLiquidity
        return toBalanceDelta(0, 0); // Return zero delta as a placeholder
    }
}