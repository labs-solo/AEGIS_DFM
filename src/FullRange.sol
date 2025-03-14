// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title FullRange
 * @notice A production-worthy contract that unifies all submodules into a single
 *         Uniswap V4 Hook, inheriting ExtendedBaseHook. It implements:
 *         - Dynamic-fee pool creation (via FullRangePoolManager)
 *         - Liquidity deposit/withdraw logic (via FullRangeLiquidityManager)
 *         - Oracle updates (via FullRangeOracleManager)
 *         - Utility helpers (via FullRangeUtils)
 *         - Dynamic fee adjustments (via FullRangeDynamicFeeManager)
 *         - Full hook callbacks from ExtendedBaseHook with default or custom logic.
 *
 * Phase 7 Requirements:
 *   - Must inherit ExtendedBaseHook, implementing Uniswap V4 Hook.
 *   - Must unify all submodules, referencing them for a complete E2E system.
 *   - Must pass final integration tests with 90%+ coverage.
 */

import {IFullRange, DepositParams, WithdrawParams, CallbackData, ModifyLiquidityParams} from "./interfaces/IFullRange.sol";
import {ExtendedBaseHook} from "./base/ExtendedBaseHook.sol"; // The extended hook contract
import {FullRangePoolManager} from "./FullRangePoolManager.sol";
import {FullRangeLiquidityManager} from "./FullRangeLiquidityManager.sol";
import {FullRangeOracleManager} from "./FullRangeOracleManager.sol";
import {FullRangeUtils} from "./FullRangeUtils.sol";
import {FullRangeDynamicFeeManager} from "./FullRangeDynamicFeeManager.sol";

// v4-core references
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/**
 * @dev The final integrated contract. Inherits `ExtendedBaseHook` so it's recognized as a hook
 *      by Uniswap V4. We override the default hook callbacks with minimal or custom logic,
 *      but we also delegate pool creation, deposit/withdraw, and oracle updates to submodules.
 */
contract FullRange is ExtendedBaseHook, IFullRange {
    // Submodules references
    FullRangePoolManager public fullRangePoolManager;
    FullRangeLiquidityManager public liquidityManager;
    FullRangeOracleManager public oracleManager;
    FullRangeDynamicFeeManager public dynamicFeeManager;

    // Optional: We track governance for gating pool creation, etc.
    address public governance;

    /// @dev salt constant for verifying callback - from FullRangeHooks
    bytes32 public constant FULL_RANGE_SALT = keccak256("FullRangeHook");

    /// @dev Emitted when oracle is updated
    event OracleUpdated(PoolKey key);

    /// @dev Emitted when dynamic fee is updated
    event DynamicFeeUpdated(PoolId poolId, uint256 newFeePpm, bool capEventOccurred);

    /// @dev Revert if caller is not governance
    modifier onlyGovernance() {
        require(msg.sender == governance, "Not authorized");
        _;
    }

    /// @dev Ensures a transaction doesn't execute after its deadline
    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "Transaction too old");
        _;
    }

    /**
     * @notice Constructor for the FullRange hook.
     * @param _manager The Uniswap V4 PoolManager reference (passed to ExtendedBaseHook).
     * @param _poolManager The FullRangePoolManager submodule
     * @param _liquidityManager The FullRangeLiquidityManager submodule
     * @param _oracleManager The FullRangeOracleManager submodule
     * @param _dynamicFeeManager The FullRangeDynamicFeeManager submodule
     * @param _governance The address with permission for certain ops, e.g. new pool creation
     */
    constructor(
        IPoolManager _manager,
        FullRangePoolManager _poolManager,
        FullRangeLiquidityManager _liquidityManager,
        FullRangeOracleManager _oracleManager,
        FullRangeDynamicFeeManager _dynamicFeeManager,
        address _governance
    ) ExtendedBaseHook(_manager) {
        fullRangePoolManager = _poolManager;
        liquidityManager = _liquidityManager;
        oracleManager = _oracleManager;
        dynamicFeeManager = _dynamicFeeManager;
        governance = _governance;
    }

    /**
     * @notice Implementation for required ExtendedBaseHook function.
     *         Overriding the default to confirm the correct set of hook permissions.
     */
    function getHookPermissions() public view virtual override returns (Hooks.Permissions memory) {
        // Return true for all hooks, including beforeSwapReturnDelta, afterSwapReturnDelta, etc.
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

    // --------------------------------------
    // IFullRange Functions (Public/External)
    // --------------------------------------

    /**
     * @notice Creates a dynamic-fee Uniswap V4 pool, referencing FullRangePoolManager
     */
    function initializeNewPool(
        PoolKey calldata key,
        uint160 initialSqrtPriceX96
    ) external override onlyGovernance returns (PoolId poolId) {
        poolId = fullRangePoolManager.initializeNewPool(key, initialSqrtPriceX96);
        return poolId;
    }

    /**
     * @notice Deposits liquidity using FullRangeLiquidityManager. Updates dynamic fee before deposit.
     */
    function deposit(DepositParams calldata params)
        external
        override
        ensure(params.deadline)
        returns (BalanceDelta delta)
    {
        // Update dynamic fee before deposit
        PoolId pid = params.poolId;
        bytes32 pidBytes = PoolId.unwrap(pid);
        
        // Check if cap event occurred since last update by comparing current tick to last oracle tick
        bool capEventOccurred = _detectCapEventForPool(pid);
        
        // Update dynamic fee with current volatility information
        uint256 newFeePpm = dynamicFeeManager.updateDynamicFee(pidBytes, capEventOccurred);
        emit DynamicFeeUpdated(pid, newFeePpm, capEventOccurred);

        // delegate to liquidityManager
        delta = liquidityManager.deposit(params, msg.sender);
        return delta;
    }

    /**
     * @notice Withdraws liquidity using FullRangeLiquidityManager. Updates dynamic fee before withdrawal.
     */
    function withdraw(WithdrawParams calldata params)
        external
        override
        ensure(params.deadline)
        returns (BalanceDelta delta, uint256 amount0Out, uint256 amount1Out)
    {
        // Update dynamic fee before withdrawal
        PoolId pid = params.poolId;
        bytes32 pidBytes = PoolId.unwrap(pid);
        
        // Check if cap event occurred since last update
        bool capEventOccurred = _detectCapEventForPool(pid);
        
        // Update dynamic fee with current volatility information
        uint256 newFeePpm = dynamicFeeManager.updateDynamicFee(pidBytes, capEventOccurred);
        emit DynamicFeeUpdated(pid, newFeePpm, capEventOccurred);

        (delta, amount0Out, amount1Out) = liquidityManager.withdraw(params, msg.sender);
        return (delta, amount0Out, amount1Out);
    }

    /**
     * @notice Claims/Reinvests fees via FullRangeLiquidityManager
     */
    function claimAndReinvestFees() external override {
        liquidityManager.claimAndReinvestFees();
    }

    /**
     * @notice Additional function to update oracle with throttle
     */
    function updateOracle(PoolKey calldata key) external {
        oracleManager.updateOracleWithThrottle(key);
        emit OracleUpdated(key);
    }

    /**
     * @notice Helper to detect if a cap event has occurred for a pool
     * @param pid The pool ID
     * @return capEventOccurred True if a cap event was detected
     */
    function _detectCapEventForPool(PoolId pid) internal view returns (bool capEventOccurred) {
        // Get current tick from the pool
        (uint160 sqrtPriceX96, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, pid);
        
        // Get the last recorded oracle tick
        bytes32 idHash = PoolId.unwrap(pid);
        int24 lastTick = oracleManager.lastOracleTick(idHash);
        
        // If this is the first check, there's no cap event
        if (lastTick == 0) {
            return false;
        }

        // Calculate absolute difference between current tick and last oracle tick
        uint24 tickDiff;
        if (currentTick >= lastTick) {
            tickDiff = uint24(uint24(currentTick) - uint24(lastTick));
        } else {
            tickDiff = uint24(uint24(lastTick) - uint24(currentTick));
        }
        
        // Check if the tick difference is greater than the cap threshold
        // We consider it a cap event if the move exceeds the maximum allowed (as defined in TruncatedOracle)
        // Note: This should be consistent with the MAX_ABS_TICK_MOVE in TruncatedOracle.sol
        int24 MAX_ABS_TICK_MOVE = 9116; // Same as defined in TruncatedOracle library
        return tickDiff > uint24(MAX_ABS_TICK_MOVE);
    }

    // ------------------------------------------
    // Overriding ExtendedBaseHook's default hooks
    // ------------------------------------------

    // ~~~~~~ Initialize Hooks ~~~~~~

    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) internal virtual override returns (bytes4) {
        // Verify dynamic fee in initialization
        if (!DynamicFeeCheckInternal.isDynamicFee(key.fee)) {
            revert("NotDynamicFee");
        }
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    function _afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal virtual override returns (bytes4) {
        // Update oracle after initialization
        oracleManager.updateOracleWithThrottle(key);
        return super._afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    // ~~~~~~ Liquidity Hooks ~~~~~~

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata data
    ) internal virtual override returns (bytes4) {
        // Any pre-check logic for liquidity additions
        return super._beforeAddLiquidity(sender, key, params, data);
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata data
    ) internal virtual override returns (bytes4, BalanceDelta) {
        // After liquidity is added, we can update the oracle
        if (params.liquidityDelta > 0) {
            oracleManager.updateOracleWithThrottle(key);
        }
        return super._afterAddLiquidity(sender, key, params, delta, feesAccrued, data);
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata data
    ) internal virtual override returns (bytes4) {
        return super._beforeRemoveLiquidity(sender, key, params, data);
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata data
    ) internal virtual override returns (bytes4, BalanceDelta) {
        // After liquidity is removed, we can update the oracle
        if (params.liquidityDelta < 0) {
            oracleManager.updateOracleWithThrottle(key);
        }
        return super._afterRemoveLiquidity(sender, key, params, delta, feesAccrued, data);
    }

    // ~~~~~~ Donate Hooks ~~~~~~

    function _beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) internal virtual override returns (bytes4) {
        return super._beforeDonate(sender, key, amount0, amount1, data);
    }

    function _afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) internal virtual override returns (bytes4) {
        // After donation, we can update the oracle
        oracleManager.updateOracleWithThrottle(key);
        return super._afterDonate(sender, key, amount0, amount1, data);
    }

    // ~~~~~~ Swap Hooks ~~~~~~

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) internal virtual override returns (bytes4, BeforeSwapDelta, uint24) {
        return super._beforeSwap(sender, key, params, data);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) internal virtual override returns (bytes4, int128) {
        // After swap, we can update the oracle
        oracleManager.updateOracleWithThrottle(key);
        
        // Check if a cap event occurred during this swap and update dynamic fee if needed
        PoolId pid = PoolIdLibrary.toId(key);
        bytes32 pidBytes = PoolId.unwrap(pid);
        bool capEventOccurred = _detectCapEventForPool(pid);
        
        // Only update the dynamic fee if the swap was large enough to potentially cause a cap event
        if (capEventOccurred) {
            uint256 newFeePpm = dynamicFeeManager.updateDynamicFee(pidBytes, true);
            emit DynamicFeeUpdated(pid, newFeePpm, true);
        }
        
        return super._afterSwap(sender, key, params, delta, data);
    }
}

/**
 * @dev Re-export DynamicFeeCheck library for convenience
 */
library DynamicFeeCheckInternal {
    function isDynamicFee(uint24 fee) internal pure returns (bool) {
        // Dynamic fee is signaled by 0x800000 (the highest bit set in a uint24)
        return (fee == 0x800000);
    }
} 