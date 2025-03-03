// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @title SoloVault
 * @notice This contract implements custom accounting and hook‑owned liquidity management.
 *
 * @dev IMPLEMENTATION INSTRUCTIONS FOR INFINITE POOLS:
 *
 *      The current design supports a single pool by storing a global PoolKey in the state variable `poolKey`.
 *      To extend this contract to support an infinite number of pools with minimal changes, please follow these steps:
 *
 *      1. **Pool Identification:**
 *         - Replace the single PoolKey variable with a mapping keyed by a unique PoolId.
 *         - For example, change:
 *             PoolKey public poolKey;
 *           to:
 *             mapping(bytes32 => PoolKey) public poolKeys;
 *         - Use Uniswap V4’s PoolIdLibrary (or the `toId()` function on PoolKey) to derive a unique identifier:
 *             bytes32 poolId = poolKey.toId();
 *
 *      2. **Function Signature Adjustments:**
 *         - Update every function that currently references `poolKey` (e.g., addLiquidity, removeLiquidity, unlockCallback)
 *           so that it accepts (or derives) a PoolId and uses poolKeys[poolId] instead of a single poolKey.
 *
 *      3. **State Variables:**
 *         - Convert any global state variables that are pool-specific (e.g., hookManagedLiquidity, poolInitialized, liquidityShares)
 *           into mappings keyed by PoolId.
 *           For example:
 *             mapping(bytes32 => bool) public hookManagedLiquidity;
 *             mapping(address => mapping(bytes32 => mapping(ShareType => uint256))) public liquidityShares;
 *
 *      4. **PoolManager Integration:**
 *         - Ensure that all interactions with PoolManager (e.g., calls to getSlot0, modifyLiquidity, unlockCallback)
 *           correctly pass the pool-specific information (using the derived PoolId or PoolKey from the mapping).
 *
 *      5. **Atomic Updates and Data Consistency:**
 *         - When modifying state for a pool (e.g., deposits, withdrawals, lending/borrowing), update all relevant mappings
 *           using the same PoolId within the same transaction to maintain consistency.
 *
 *      These changes will allow a single deployment of SoloVault (and by extension Solo.sol) to support an infinite number
 *      of pools while leveraging the existing PoolManager for state tracking and ensuring gas efficiency.
 *
 * @dev SoloVault inherits from ExtendedBaseHook, which already implements the complete IHooks interface with enhanced
 *      state tracking and robust access control. This file implements the liquidity accounting and custom liquidity operations.
 */

import {ExtendedBaseHook} from "src/base/ExtendedBaseHook.sol";
import {CurrencySettler} from "src/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/**
 * @dev Base implementation for custom accounting and hook‑owned liquidity.
 *
 * To enable hook‑owned liquidity, tokens must be deposited via the hook to allow control and flexibility
 * over the liquidity. The implementation inheriting this hook must implement the respective functions
 * to calculate the liquidity modification parameters and the amount of liquidity shares to mint or burn.
 *
 * Additionally, the implementer must consider that the hook is the sole owner of the liquidity and
 * manage fees over liquidity shares accordingly.
 *
 * NOTE: This contract was originally designed to work with a single pool key. To upgrade this contract
 *       to support an infinite number of pools, please refer to the implementation instructions above.
 *
 * _Available since v0.1.0_
 */
abstract contract SoloVault is ExtendedBaseHook {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;

    error ExpiredPastDeadline();
    error PoolNotInitialized();
    error TooMuchSlippage();
    error LiquidityOnlyViaHook();
    error InvalidNativeValue();
    error AlreadyInitialized();

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

    struct CallbackData {
        address sender;
        IPoolManager.ModifyLiquidityParams params;
    }

    /**
     * @notice The hook's pool key.
     * @dev NOTE: This contract currently supports a single pool.
     *      To support an infinite number of pools, replace the single variable with a mapping,
     *      for example:
     *          mapping(bytes32 => PoolKey) public poolKeys;
     *      and update all functions to use the appropriate pool configuration based on a passed PoolId.
     */
    PoolKey public poolKey;

    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) revert ExpiredPastDeadline();
        _;
    }

    constructor(IPoolManager _poolManager) ExtendedBaseHook(_poolManager) {}

    function addLiquidity(AddLiquidityParams calldata params)
        external
        payable
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        if (poolKey.currency0 == CurrencyLibrary.ADDRESS_ZERO && msg.value != params.amount0Desired) {
            revert InvalidNativeValue();
        }

        (bytes memory modifyParams, uint256 shares) = _getAddLiquidity(sqrtPriceX96, params);
        delta = _modifyLiquidity(modifyParams);
        _mint(params, delta, shares);

        if (uint128(-delta.amount0()) < params.amount0Min || uint128(-delta.amount1()) < params.amount1Min) {
            revert TooMuchSlippage();
        }
    }

    function removeLiquidity(RemoveLiquidityParams calldata params)
        external
        virtual
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());

        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        (bytes memory modifyParams, uint256 shares) = _getRemoveLiquidity(params);
        delta = _modifyLiquidity(modifyParams);
        _burn(params, delta, shares);

        uint128 amount0 = delta.amount0() < 0 ? uint128(-delta.amount0()) : uint128(delta.amount0());
        uint128 amount1 = delta.amount1() < 0 ? uint128(-delta.amount1()) : uint128(delta.amount1());
        if (amount0 < params.amount0Min || amount1 < params.amount1Min) {
            revert TooMuchSlippage();
        }
    }

    // slither-disable-next-line dead-code
    function _modifyLiquidity(bytes memory params) internal virtual returns (BalanceDelta delta) {
        delta = abi.decode(
            poolManager.unlock(
                abi.encode(CallbackData(msg.sender, abi.decode(params, (IPoolManager.ModifyLiquidityParams))))
            ),
            (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata rawData)
        external
        virtual
        onlyPoolManager
        returns (bytes memory returnData)
    {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        PoolKey memory key = poolKey;

        (BalanceDelta delta, BalanceDelta feeDelta) = poolManager.modifyLiquidity(key, data.params, "");
        delta = delta - feeDelta;

        if (delta.amount0() < 0) {
            key.currency0.settle(poolManager, data.sender, uint256(int256(-delta.amount0())), false);
        } else {
            key.currency0.take(poolManager, data.sender, uint256(int256(delta.amount0())), false);
        }

        if (delta.amount1() < 0) {
            key.currency1.settle(poolManager, data.sender, uint256(int256(-delta.amount1())), false);
        } else {
            key.currency1.take(poolManager, data.sender, uint256(int256(delta.amount1())), false);
        }

        return abi.encode(delta);
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (address(poolKey.hooks) != address(0)) revert AlreadyInitialized();
        poolKey = key;
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
    ) internal virtual override returns (bytes4) {
        revert LiquidityOnlyViaHook();
    }

    function _getAddLiquidity(uint160 sqrtPriceX96, AddLiquidityParams memory params)
        internal
        virtual
        returns (bytes memory modify, uint256 shares);

    function _getRemoveLiquidity(RemoveLiquidityParams memory params)
        internal
        virtual
        returns (bytes memory modify, uint256 shares);

    function _mint(AddLiquidityParams memory params, BalanceDelta delta, uint256 shares) internal virtual;

    function _burn(RemoveLiquidityParams memory params, BalanceDelta delta, uint256 shares) internal virtual;

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}