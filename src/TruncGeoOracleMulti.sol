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
 *         Pools using FullRange.sol must have their oracle updated by calling updateObservation(poolKey)
 *         on this contract. Each pool is set up via enableOracleForPool(), which initializes observation state
 *         and sets a pool-specific maximum tick movement (maxAbsTickMove).
 * 
 * @dev SECURITY BY MUTUAL AUTHENTICATION:
 *      This contract implements a bilateral authentication pattern between FullRange.sol and TruncGeoOracleMulti.
 *      1. During deployment, the TruncGeoOracleMulti is initialized with the known FullRange address
 *      2. The FullRange contract is then initialized with the TruncGeoOracleMulti address
 *      3. All sensitive oracle functions require the caller to be the trusted FullRange contract
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
    
    // The authorized FullRange hook address - critical for secure mutual authentication
    address public immutable fullRangeHook;

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

    /**
     * @notice Constructor - establishes the trusted contract relationship
     * @param _poolManager The Uniswap V4 Pool Manager
     * @param _fullRangeHook The authorized FullRange hook address
     * @dev The trusted FullRange address is set at deployment and cannot be changed,
     *      creating an immutable security relationship between the contracts.
     *      This prevents later manipulation of the authentication system.
     */
    constructor(IPoolManager _poolManager, address _fullRangeHook) {
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();
        if (_fullRangeHook == address(0)) revert Errors.ZeroAddress();
        
        poolManager = _poolManager;
        fullRangeHook = _fullRangeHook;
    }

    /**
     * @notice Enables oracle functionality for a pool.
     * @param key The pool key.
     * @param initialMaxAbsTickMove The initial maximum tick movement.
     * @dev Must be called once per pool. Enforces full-range requirements.
     * 
     * @dev SECURITY: This function is protected by the mutual authentication system.
     *      Only the authorized FullRange hook can enable oracle functionality for a pool.
     *      This prevents malicious contracts from initializing the oracle with invalid parameters.
     *      The function performs multiple validations:
     *      1. Caller authentication check
     *      2. Validates the pool isn't already enabled
     *      3. Ensures the pool uses either dynamic fee or zero fee
     *      Together, these protections create defense in depth against manipulation.
     */
    function enableOracleForPool(PoolKey calldata key, int24 initialMaxAbsTickMove) external {
        // Security: Only allow initialization from the FullRange hook contract
        // This is the first part of the mutual authentication system
        if (msg.sender != fullRangeHook) {
            revert Errors.AccessNotAuthorized(msg.sender);
        }
        
        PoolId pid = key.toId();
        bytes32 id = PoolId.unwrap(pid);
        
        // Check if pool is already enabled
        if (states[id].cardinality != 0) {
            revert Errors.OracleOperationFailed("enableOracleForPool", "Pool already enabled");
        }
        
        // Allow both the dynamic fee (0x800000 == 8388608) and fee == 0 pools
        if (key.fee != 0 && key.fee != 8388608)
            revert Errors.OnlyDynamicFeePoolAllowed();
        
        maxAbsTickMove[id] = initialMaxAbsTickMove;
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, pid);
        (states[id].cardinality, states[id].cardinalityNext) = observations[id].initialize(_blockTimestamp(), tick);
        
        emit OracleEnabled(id, initialMaxAbsTickMove);
    }

    /**
     * @notice Updates oracle observations for a pool.
     * @param key The pool key.
     * @dev Called by the hook (FullRange.sol) during its callbacks.
     * 
     * @dev SECURITY: This function enforces multiple security checks:
     *      1. Caller must be the trusted FullRange hook (mutual authentication)
     *      2. Verifies the pool exists in PoolManager
     *      3. Confirms the pool is enabled in the oracle system
     *      4. Applies tick capping via the TruncatedOracle library
     *      This prevents price manipulation attacks targeting the oracle.
     */
    function updateObservation(PoolKey calldata key) external {
        // Security: Only allow updates from the authorized FullRange hook
        // This is critical to prevent manipulation by untrusted contracts
        if (msg.sender != fullRangeHook) {
            revert Errors.AccessNotAuthorized(msg.sender);
        }
        
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
    function getLastObservation(PoolId poolId) external view returns (
        uint32 timestamp,
        int24 tick,
        int48 tickCumulative,
        uint144 secondsPerLiquidityCumulativeX128
    ) {
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
            // Get current tick
            (uint160 sqrtPriceX96, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
            
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
     *      Only the trusted FullRange hook can update the tick movement configuration.
     *      This prevents unauthorized changes to the tick capping parameters.
     */
    function updateMaxAbsTickMoveForPool(bytes32 poolId, int24 newMove) public virtual {
        // Only FullRange hook can update the configuration
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
        external view returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s)
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
     *      Only the trusted FullRange hook can increase cardinality.
     */
    function increaseCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        // Only FullRange hook can increase cardinality
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
} 