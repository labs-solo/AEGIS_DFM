// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TruncatedOracle} from "../libraries/TruncatedOracle.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Errors} from "../errors/Errors.sol";

/**
 * @title TruncGeoOracleMulti
 * @notice A non-hook contract that provides truncated geomean oracle data for multiple pools.
 *         Pools using Solo.sol must have their oracle updated by calling updateObservation(poolKey)
 *         on this contract. Each pool is set up via enableOracleForPool(), which initializes observation state
 *         and sets a pool-specific maximum tick movement (maxAbsTickMove). A virtual function, updateMaxAbsTickMoveForPool(),
 *         is provided for governance.
 */
contract TruncGeoOracleMulti {
    using TruncatedOracle for TruncatedOracle.Observation[65535];
    using PoolIdLibrary for PoolKey;

    // The Uniswap V4 Pool Manager
    IPoolManager public immutable poolManager;

    // Number of historic observations to keep (roughly 24h at 1h sample rate)
    uint32 internal constant SAMPLE_CAPACITY = 24;

    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    // Observations for each pool keyed by PoolId.
    mapping(bytes32 => TruncatedOracle.Observation[65535]) public observations;
    mapping(bytes32 => ObservationState) public states;
    // Pool-specific maximum absolute tick movement.
    mapping(bytes32 => int24) public maxAbsTickMove;

    /**
     * @notice Constructor
     * @param _poolManager The Uniswap V4 Pool Manager
     */
    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    /**
     * @notice Enables oracle functionality for a pool.
     * @param key The pool key.
     * @param initialMaxAbsTickMove The initial maximum tick movement.
     * @dev Must be called once per pool. Enforces full-range requirements.
     */
    function enableOracleForPool(PoolKey calldata key, int24 initialMaxAbsTickMove) external {
        PoolId pid = key.toId();
        bytes32 id = PoolId.unwrap(pid);

        // Check if pool is already enabled
        if (states[id].cardinality != 0) {
            revert Errors.OracleOperationFailed("enableOracleForPool", "Pool already enabled");
        }

        // Allow both the dynamic fee (0x800000 == 8388608) and fee == 0 pools
        // Support any valid tick spacing (removed the tick spacing constraint)
        if (key.fee != 0 && key.fee != 8388608) {
            revert Errors.OnlyDynamicFeePoolAllowed();
        }

        maxAbsTickMove[id] = initialMaxAbsTickMove;
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, pid);
        (states[id].cardinality, states[id].cardinalityNext) = observations[id].initialize(_blockTimestamp(), tick);
    }

    /**
     * @notice Updates oracle observations for a pool.
     * @param key The pool key.
     * @dev Called by the hook (Solo.sol) during its callbacks.
     */
    function updateObservation(PoolKey calldata key) external {
        PoolId pid = key.toId();
        bytes32 id = PoolId.unwrap(pid);

        // Check if pool is enabled
        if (states[id].cardinality == 0) {
            revert Errors.OracleOperationFailed("updateObservation", "Pool not enabled in oracle");
        }

        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, pid);
        int24 localMaxAbsTickMove = maxAbsTickMove[id];
        (states[id].index, states[id].cardinality) = observations[id].write(
            states[id].index,
            _blockTimestamp(),
            tick,
            0, // liquidity is not used in this implementation
            states[id].cardinality,
            states[id].cardinalityNext,
            localMaxAbsTickMove
        );
    }

    /**
     * @notice Virtual function to update the maximum tick movement for a pool.
     * @param poolId The pool identifier.
     * @param newMove The new maximum tick movement.
     */
    function updateMaxAbsTickMoveForPool(bytes32 poolId, int24 newMove) public virtual {
        maxAbsTickMove[poolId] = newMove;
    }

    /**
     * @notice Observes oracle data for a pool.
     * @param key The pool key.
     * @param secondsAgos Array of time offsets.
     * @return tickCumulatives The tick cumulative values.
     * @return secondsPerLiquidityCumulativeX128s The seconds per liquidity cumulative values.
     */
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        view
        returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s)
    {
        PoolId pid = key.toId();
        bytes32 id = PoolId.unwrap(pid);
        ObservationState memory state = states[id];
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, pid);

        // Get the pool-specific maximum tick movement
        int24 localMaxAbsTickMove = maxAbsTickMove[id];

        // If the pool doesn't have a specific value, use the default
        if (localMaxAbsTickMove == 0) {
            localMaxAbsTickMove = TruncatedOracle.MAX_ABS_TICK_MOVE;
        }

        return observations[id].observe(
            _blockTimestamp(),
            secondsAgos,
            tick,
            state.index,
            0, // Liquidity is not used in time-weighted calculations
            state.cardinality,
            localMaxAbsTickMove
        );
    }

    function increaseCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        PoolId pid = key.toId();
        bytes32 id = PoolId.unwrap(pid);
        ObservationState storage state = states[id];
        cardinalityNextOld = state.cardinalityNext;
        cardinalityNextNew = observations[id].grow(cardinalityNextOld, cardinalityNext);
        state.cardinalityNext = cardinalityNextNew;
    }

    function _blockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp);
    }

    /**
     * @notice Checks if oracle is enabled for a pool
     * @param poolId The ID of the pool
     * @return True if the oracle is enabled for this pool
     */
    function isOracleEnabled(PoolId poolId) external view returns (bool) {
        bytes32 id = PoolId.unwrap(poolId);
        return states[id].cardinality > 0;
    }

    /**
     * @notice Gets the latest observation for a pool
     * @param poolId The ID of the pool
     * @return _tick The latest observed tick
     * @return blockTimestampResult The block timestamp of the observation
     */
    function getLatestObservation(PoolId poolId) external view returns (int24 _tick, uint32 blockTimestampResult) {
        bytes32 id = PoolId.unwrap(poolId);
        if (states[id].cardinality == 0) {
            revert Errors.OracleOperationFailed("getLatestObservation", "Pool not enabled in oracle");
        }

        // Get the most recent observation
        TruncatedOracle.Observation memory observation = observations[id][states[id].index];
        return (observation.prevTick, observation.blockTimestamp);
    }
}
