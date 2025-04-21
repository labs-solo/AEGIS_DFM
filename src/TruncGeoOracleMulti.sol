// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Errors} from "./errors/Errors.sol";

/**
 * @title TruncGeoOracleMulti
 * @notice A non-hook contract that provides truncated geomean oracle data for multiple pools.
 *         Pools using Spot.sol must have their oracle updated by calling updateObservation(poolKey)
 *         on this contract. Each pool is set up via enableOracleForPool(), which initializes observation state
 *         and sets a pool-specific maximum tick movement (maxAbsTickMove).
 *
 * @dev SECURITY BY MUTUAL AUTHENTICATION:
 *      This contract implements a bilateral authentication pattern between Spot.sol and TruncGeoOracleMulti.
 *      1. During deployment, the TruncGeoOracleMulti is initialized with the known Spot address
 *      2. The Spot contract is then initialized with the TruncGeoOracleMulti address
 *      3. All sensitive oracle functions require the caller to be the trusted Spot contract
 *      4. This creates a secure mutual authentication loop that prevents:
 *         - Unauthorized oracle updates that could manipulate price data
 *         - Spoofed oracle observations from malicious contracts
 *         - Cross-contract manipulation attempts
 *      5. This forms a secure enclave of trusted contracts that cannot be manipulated by external actors
 *      6. The design avoids "hook stuffing" attacks where malicious code is injected into hooks
 */
contract TruncGeoOracleMulti {
    using TruncatedOracle for TruncatedOracle.Observation[65535];
    using PoolIdLibrary for PoolKey;

    // The Uniswap V4 Pool Manager
    IPoolManager public immutable poolManager;

    // The authorized Spot hook address - critical for secure mutual authentication
    address public fullRangeHook;

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

    // Events for observability and debugging
    event OracleEnabled(bytes32 indexed poolId, int24 initialMaxAbsTickMove);
    event ObservationUpdated(bytes32 indexed poolId, int24 newTick, uint32 timestamp);
    event MaxTickMoveUpdated(bytes32 indexed poolId, int24 oldMove, int24 newMove);
    event CardinalityIncreased(bytes32 indexed poolId, uint16 oldCardinality, uint16 newCardinality);

    address public governance; // Need governance address for setter

    /**
     * @notice Constructor - MODIFIED: Removed _fullRangeHook
     * @param _poolManager The Uniswap V4 Pool Manager
     * @param _governance The initial governance address for setting the hook
     */
    constructor(IPoolManager _poolManager, address _governance) {
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();
        if (_governance == address(0)) revert Errors.ZeroAddress();

        poolManager = _poolManager;
        governance = _governance;
        // fullRangeHook = _fullRangeHook; // REMOVED
    }

    // NEW FUNCTION: Setter for Spot hook address
    /**
     * @notice Sets the trusted Spot hook address after deployment.
     * @param _hook The address of the Spot hook contract.
     */
    function setFullRangeHook(address _hook) external {
        // Only allow governance to set this once
        if (msg.sender != governance) revert Errors.AccessOnlyGovernance(msg.sender);
        if (fullRangeHook != address(0)) revert Errors.AlreadyInitialized("FullRangeHook");
        if (_hook == address(0)) revert Errors.ZeroAddress();
        fullRangeHook = _hook;
    }

    modifier onlyFullRangeHook() {
        // ADDED Check: Ensure hook address is set before checking msg.sender
        if (fullRangeHook == address(0)) {
            revert Errors.NotInitialized("FullRangeHook");
        }
        if (msg.sender != fullRangeHook) {
            revert Errors.AccessNotAuthorized(msg.sender);
        }
        _;
    }

    /**
     * @notice Enables oracle functionality for a pool.
     * MODIFIED: Uses modifier, added check
     */
    function enableOracleForPool(PoolKey calldata key, int24 initialMaxAbsTickMove) external onlyFullRangeHook {
        // Check moved to modifier
        // if (msg.sender != fullRangeHook) { ... }

        PoolId pid = key.toId();
        bytes32 id = PoolId.unwrap(pid);

        // Check if pool is already enabled
        if (states[id].cardinality != 0) {
            revert Errors.OracleOperationFailed("enableOracleForPool", "Pool already enabled");
        }

        // Allow both the dynamic fee (0x800000 == 8388608) and fee == 0 pools
        if (key.fee != 0 && key.fee != 8388608) {
            revert Errors.OnlyDynamicFeePoolAllowed();
        }

        maxAbsTickMove[id] = initialMaxAbsTickMove;
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, pid);
        (states[id].cardinality, states[id].cardinalityNext) = observations[id].initialize(_blockTimestamp(), tick);

        emit OracleEnabled(id, initialMaxAbsTickMove);
    }

    /**
     * @notice Updates oracle observations for a pool.
     * MODIFIED: Uses modifier, added check
     */
    function updateObservation(PoolKey calldata key) external onlyFullRangeHook {
        // Check moved to modifier
        // if (msg.sender != fullRangeHook) { ... }

        PoolId pid = key.toId();
        bytes32 id = PoolId.unwrap(pid);

        // Double check pool exists in PoolManager
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, pid);

        // Check if pool is enabled in oracle
        if (states[id].cardinality == 0) {
            revert Errors.OracleOperationFailed("updateObservation", "Pool not enabled in oracle");
        }

        // Get current tick from pool manager
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, pid);

        // Get the pool-specific maximum tick movement
        int24 localMaxAbsTickMove = maxAbsTickMove[id];

        // Update observation with truncated oracle logic
        // This applies tick capping to prevent oracle manipulation
        (states[id].index, states[id].cardinality) = observations[id].write(
            states[id].index,
            _blockTimestamp(),
            tick,
            liquidity,
            states[id].cardinality,
            states[id].cardinalityNext,
            localMaxAbsTickMove
        );

        emit ObservationUpdated(id, tick, _blockTimestamp());
    }

    /**
     * @notice Checks if an oracle update is needed based on time thresholds
     * @dev Gas optimization to avoid unnecessary updates
     * @param poolId The unique identifier for the pool
     * @return shouldUpdate Whether the oracle should be updated
     *
     * @dev This function is a key gas optimization that reduces the frequency of oracle updates.
     *      It can be safely called by any contract since it's a view function that doesn't modify state.
     *      The function helps minimize the gas overhead of oracle updates during swaps.
     */
    function shouldUpdateOracle(PoolId poolId) external view returns (bool shouldUpdate) {
        bytes32 id = PoolId.unwrap(poolId);

        // If pool isn't initialized, no update needed
        if (states[id].cardinality == 0) return false;

        // Check time threshold (default: update every 15 seconds)
        uint32 timeThreshold = 15;
        uint32 lastUpdateTime = 0;

        // Get the most recent observation
        if (states[id].cardinality > 0) {
            TruncatedOracle.Observation memory lastObs = observations[id][states[id].index];
            lastUpdateTime = lastObs.blockTimestamp;
        }

        // Only update if enough time has passed
        return (_blockTimestamp() >= lastUpdateTime + timeThreshold);
    }

    /**
     * @notice Gets the most recent observation for a pool
     * @param poolId The ID of the pool
     * @return timestamp The timestamp of the observation
     * @return tick The tick value at the observation
     * @return tickCumulative The cumulative tick value
     * @return secondsPerLiquidityCumulativeX128 The cumulative seconds per liquidity value
     */
    function getLastObservation(PoolId poolId)
        external
        view
        returns (uint32 timestamp, int24 tick, int48 tickCumulative, uint144 secondsPerLiquidityCumulativeX128)
    {
        bytes32 id = PoolId.unwrap(poolId);
        ObservationState memory state = states[id];
        if (state.cardinality == 0) revert Errors.OracleOperationFailed("getLastObservation", "Pool not enabled");

        TruncatedOracle.Observation memory observation = observations[id][state.index];

        // Get the pool-specific maximum tick movement for consistent tick capping
        int24 localMaxAbsTickMove = maxAbsTickMove[id];
        if (localMaxAbsTickMove == 0) {
            localMaxAbsTickMove = TruncatedOracle.MAX_ABS_TICK_MOVE;
        }

        // If the observation is not from the current timestamp, we may need to transform it
        // However, since this is view-only, we don't actually update storage
        uint32 currentTime = _blockTimestamp();
        if (observation.blockTimestamp < currentTime) {
            // Get current tick, ignore others
            (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);

            // This doesn't update storage, just gives us the expected value after tick capping
            TruncatedOracle.Observation memory transformedObservation = TruncatedOracle.transform(
                observation,
                currentTime,
                currentTick,
                0, // Liquidity not used
                localMaxAbsTickMove
            );

            return (
                transformedObservation.blockTimestamp,
                transformedObservation.prevTick,
                transformedObservation.tickCumulative,
                transformedObservation.secondsPerLiquidityCumulativeX128
            );
        }

        return (
            observation.blockTimestamp,
            observation.prevTick,
            observation.tickCumulative,
            observation.secondsPerLiquidityCumulativeX128
        );
    }

    /**
     * @notice Updates the maximum tick movement for a pool.
     * @param poolId The pool identifier.
     * @param newMove The new maximum tick movement.
     *
     * @dev SECURITY: This is a governance function protected by the mutual authentication system.
     *      Only the trusted Spot hook can update the tick movement configuration.
     *      This prevents unauthorized changes to the tick capping parameters.
     */
    function updateMaxAbsTickMoveForPool(bytes32 poolId, int24 newMove) public virtual {
        // Only Spot hook can update the configuration
        // Part of the mutual authentication security system
        if (msg.sender != fullRangeHook) {
            revert Errors.AccessNotAuthorized(msg.sender);
        }

        int24 oldMove = maxAbsTickMove[poolId];
        maxAbsTickMove[poolId] = newMove;

        emit MaxTickMoveUpdated(poolId, oldMove, newMove);
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

    /**
     * @notice Increases the cardinality of the oracle observation array
     * @param key The pool key.
     * @param cardinalityNext The new cardinality to grow to.
     * @return cardinalityNextOld The previous cardinality.
     * @return cardinalityNextNew The new cardinality.
     *
     * @dev SECURITY: Protected by the mutual authentication system.
     *      Only the trusted Spot hook can increase cardinality.
     */
    function increaseCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        // Only Spot hook can increase cardinality
        // Part of the mutual authentication security system
        if (msg.sender != fullRangeHook) {
            revert Errors.AccessNotAuthorized(msg.sender);
        }

        PoolId pid = key.toId();
        bytes32 id = PoolId.unwrap(pid);
        ObservationState storage state = states[id];
        cardinalityNextOld = state.cardinalityNext;
        cardinalityNextNew = observations[id].grow(cardinalityNextOld, cardinalityNext);
        state.cardinalityNext = cardinalityNextNew;

        emit CardinalityIncreased(id, cardinalityNextOld, cardinalityNextNew);
    }

    /**
     * @notice Helper function to get the current block timestamp as uint32
     * @return The current block timestamp truncated to uint32
     */
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
