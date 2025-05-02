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
import {TickMoveGuard} from "./libraries/TickMoveGuard.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";

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

    // The policy manager for getting configuration
    IPoolPolicy public immutable policyManager;

    // Number of historic observations to keep (roughly 24h at 1h sample rate)
    uint32 internal constant SAMPLE_CAPACITY = 24;

    // Track which pools have been enabled
    mapping(bytes32 => bool) public isEnabled;

    // dynamic capping -------------------------------------------------------
    mapping(bytes32 => uint24) public maxTicksPerBlock; // adaptive cap
    mapping(bytes32 => uint128) private capFreq; // ppm-seconds accumulator
    mapping(bytes32 => uint48) private lastFreqTs; // last decay update

    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    // Observations for each pool keyed by PoolId.
    mapping(bytes32 => TruncatedOracle.Observation[65535]) public observations;
    mapping(bytes32 => ObservationState) public states;

    // Events for observability and debugging
    event OracleEnabled(bytes32 indexed poolId, int24 initialMaxAbsTickMove);
    event ObservationUpdated(bytes32 indexed poolId, int24 tick, uint32 timestamp);
    event TickCapped(bytes32 indexed poolId, int24 truncatedTo);
    event TickCapParamChanged(bytes32 indexed poolId, uint24 newMaxTicksPerBlock);

    address public governance; // Need governance address for setter

    /// last time `maxTicksPerBlock` was *actually* changed
    mapping(PoolId => uint32) private _lastMaxTickUpdate;

    event MaxTicksPerBlockUpdated(
        PoolId indexed poolId,
        uint32 oldValue,
        uint32 newValue,
        uint32 timestamp
    );

    event MaxTicksUpdateSkipped(
        PoolId indexed poolId,
        uint32 candidate,
        string reason,
        uint32 timestamp
    );

    /* ---------------- modifiers -------------------- */
    modifier onlyHook() {
        require(msg.sender == fullRangeHook, "Oracle: not hook");
        _;
    }

    /**
     * @notice Constructor - MODIFIED: Removed _fullRangeHook
     * @param _poolManager The Uniswap V4 Pool Manager
     * @param _governance The initial governance address for setting the hook
     * @param _policyManager The policy manager contract
     */
    constructor(IPoolManager _poolManager, address _governance, IPoolPolicy _policyManager) {
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();
        if (_governance == address(0)) revert Errors.ZeroAddress();
        if (address(_policyManager) == address(0)) revert Errors.ZeroAddress();

        poolManager = _poolManager;
        governance = _governance;
        policyManager = _policyManager;
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

    /* ─────────────────── external API ─────────────────── */
    /// @notice Push a new observation and immediately know whether the tick
    ///         move had to be capped.  Designed for the Spot hook hot-path.
    /// @param id         PoolId (bytes32) of the pool
    /// @param zeroForOne Direction of the swap (needed for cap logic)
    /// @return tick      The truncated/stored tick
    /// @return capped    True if the tick move exceeded the policy cap
    function pushObservationAndCheckCap(PoolId id, bool zeroForOne)
        external
        onlyHook
        returns (int24 tick, bool capped)
    {
        // reuse existing internal routine to avoid code duplication
        return _pushObservation(id, zeroForOne);
    }

    /* ─────────────── internal logic for observation pushing ───────────── */
    function _pushObservation(PoolId id, bool zeroForOne) internal returns (int24 tick, bool capped) {
        bytes32 poolId = PoolId.unwrap(id);

        // Check if pool is enabled in oracle
        if (states[poolId].cardinality == 0) {
            revert Errors.OracleOperationFailed("pushObservation", "Pool not enabled in oracle");
        }

        // Get current tick from pool manager
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, id);

        // Get the most recent observation for comparison
        TruncatedOracle.Observation memory lastObs = observations[poolId][states[poolId].index];

        // Apply adaptive cap
        uint24 cap = maxTicksPerBlock[poolId];
        (capped, tick) = TickMoveGuard.truncate(lastObs.prevTick, currentTick, cap);

        // Update frequency accumulator and maybe rebalance cap
        _updateFreq(poolId, capped);
        _maybeRebalanceCap(poolId);

        // Update the observation with the potentially capped tick
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, id);
        (states[poolId].index, states[poolId].cardinality) = observations[poolId].write(
            states[poolId].index,
            _blockTimestamp(),
            tick,
            liquidity,
            states[poolId].cardinality,
            states[poolId].cardinalityNext
        );

        if (capped) emit TickCapped(poolId, tick);
        emit ObservationUpdated(poolId, tick, _blockTimestamp());

        return (tick, capped);
    }

    /* ───────────── adaptive-cap helpers ───────────── */
    function _updateFreq(bytes32 pid, bool capped_) private {
        uint48 nowTs = uint48(block.timestamp);
        uint48 last = lastFreqTs[pid];
        if (nowTs == last) {
            if (capped_) capFreq[pid] += 1e6;
            return;
        }
        uint32 window = IPoolPolicy(policyManager).getCapBudgetDecayWindow(PoolId.wrap(pid));
        uint128 f = capFreq[pid];
        if (window > 0) {
            uint256 decay = uint256(f) * (nowTs - last) / window;
            f -= uint128(decay > f ? f : decay);
        }
        if (capped_) f += 1e6;
        capFreq[pid] = f;
        lastFreqTs[pid] = nowTs;
    }

    function _maybeRebalanceCap(bytes32 pid) private {
        uint256 target = IPoolPolicy(policyManager).getTargetCapsPerDay(PoolId.wrap(pid));
        if (target == 0) return;

        uint32 window = IPoolPolicy(policyManager).getCapBudgetDecayWindow(PoolId.wrap(pid));
        uint256 perDay = window == 0 ? 0 : uint256(capFreq[pid]) * 1 days / uint256(window);

        uint24 cap = maxTicksPerBlock[pid];
        bool changed;
        uint32 newCandidate = cap;
        
        if (perDay > target * 115 / 100 && cap < 250_000) {
            // too many caps → loosen cap
            newCandidate = uint32(uint256(cap) * 125 / 100);
            changed = true;
        } else if (perDay < target * 85 / 100 && cap > 1) {
            // too quiet → tighten cap
            newCandidate = uint32(uint256(cap) * 80 / 100);
            if (newCandidate == 0) newCandidate = 1;
            changed = true;
        }
        
        if (changed) {
            // Use rate-limited update instead of direct assignment
            _maybeUpdateMaxTicks(PoolId.wrap(pid), newCandidate);
        }
    }

    /**
     * @notice Enables oracle functionality for a pool.
     * MODIFIED: Uses modifier, added check
     */
    function enableOracleForPool(PoolKey calldata key) external onlyFullRangeHook {
        bytes32 id = PoolId.unwrap(key.toId());
        require(!isEnabled[id], "Oracle already enabled");
        isEnabled[id] = true;

        /* -------------------------------------------------------------
         *  Initialise cap
         *     – if policy gives a per-pool override → use it
         *     – else:   cap = defaultFeePPM ÷ 100  (ppm/tick)
         *       e.g. 3 000 ppm ÷ 100 = **30 ticks**  (0 .30 %)
         * ---------------------------------------------------------- */
        uint24 initCap = IPoolPolicy(policyManager).getDefaultMaxTicksPerBlock(PoolId.wrap(id));
        if (initCap == 0) {
            uint256 defFee = IPoolPolicy(policyManager).getDefaultDynamicFee(); // ppm
            initCap = uint24(defFee / 100); // 1 tick ≃ 100 ppm
            if (initCap == 0) initCap = 1; // never zero
        }
        
        // Set initial maxTicksPerBlock value directly (skipping rate limit for initialization)
        // Note: We don't use _maybeUpdateMaxTicks here as this is the initial value
        maxTicksPerBlock[id] = initCap;
        // Mark the update time to start the clock for future rate-limiting
        _lastMaxTickUpdate[PoolId.wrap(id)] = uint32(block.timestamp);
        
        lastFreqTs[id] = uint48(block.timestamp);

        // Initialize observation slot and cardinality
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, key.toId());
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, key.toId());

        // Initialize first observation
        observations[id][0] = TruncatedOracle.Observation({
            blockTimestamp: _blockTimestamp(),
            prevTick: currentTick,
            tickCumulative: 0,
            secondsPerLiquidityCumulativeX128: 0,
            initialized: true
        });

        // Set initial cardinality to 1 and target to 1
        states[id].index = 0;
        states[id].cardinality = 1;
        states[id].cardinalityNext = 1;

        emit ObservationUpdated(id, currentTick, _blockTimestamp());
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

        // Update observation with truncated oracle logic
        // This applies tick capping to prevent oracle manipulation
        (bool capped, int24 newTick) = TickMoveGuard.checkHardCapOnly(observations[id][states[id].index].prevTick, tick);

        (states[id].index, states[id].cardinality) = observations[id].write(
            states[id].index, _blockTimestamp(), newTick, liquidity, states[id].cardinality, states[id].cardinalityNext
        );

        if (capped) emit TickCapped(id, newTick);
        emit ObservationUpdated(id, newTick, _blockTimestamp());
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
        returns (uint32 timestamp, int24 tick, int48 tickCumulative, uint144 secondsPerLiquidityCumulativeX128)
    {
        bytes32 id = PoolId.unwrap(poolId);
        ObservationState memory state = states[id];
        if (state.cardinality == 0) revert Errors.OracleOperationFailed("getLastObservation", "Pool not enabled");

        TruncatedOracle.Observation memory observation = observations[id][state.index];

        // Retrieve current tick from pool state
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);

        // If the observation is not from the current timestamp, we may need to transform it
        // However, since this is view-only, we don't actually update storage
        uint32 currentTime = _blockTimestamp();
        if (observation.blockTimestamp < currentTime) {
            // This doesn't update storage, just gives us the expected value after tick capping
            TruncatedOracle.Observation memory transformedObservation = TruncatedOracle.transform(
                observation,
                currentTime,
                currentTick,
                0 // liquidity ignored
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
     * @notice Observes oracle data for a pool.
     * @param key The pool key.
     * @param secondsAgos Array of time offsets.
     * @return tickCumulatives The tick cumulative values.
     * @return secondsPerLiquidityCumulativeX128s The seconds per liquidity cumulative values.
     */
    function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
        external
        returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s)
    {
        PoolId pid = key.toId();
        bytes32 id = PoolId.unwrap(pid);
        ObservationState memory state = states[id];
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, pid);

        return observations[id].observe(
            _blockTimestamp(),
            secondsAgos,
            tick,
            state.index,
            0, // liquidity ignored
            state.cardinality
        );
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

    /// ------------------------------------------------------------------
    ///  Exposed for DynamicFeeManager → simple cap-to-fee mapping
    /// ------------------------------------------------------------------
    /// @notice Public getter so <DynamicFeeManager> can derive the base-fee
    function getMaxTicksPerBlock(bytes32 poolId) external view returns (uint24) {
        return maxTicksPerBlock[poolId];
    }

    /* ────────────────── governance / test helper ────────────────── */

    /**
     * @notice **Governance-only** override for the adaptive tick-cap.
     *         Added to support unit-tests that need deterministic caps.
     *         Production systems should rarely (if ever) call this,
     *         because it bypasses the automatic feedback loop.
     *
     * @param pid  PoolId whose cap is being set
     * @param cap  New max tick movement per block (must fit in uint24)
     */
    function setMaxTicksPerBlock(PoolId pid, uint24 cap) external {
        if (msg.sender != governance) revert Errors.AccessOnlyGovernance(msg.sender);
        
        // For governance changes, directly update without rate limiting
        // This is needed for testing and emergency interventions
        bytes32 id = PoolId.unwrap(pid);
        uint24 oldValue = maxTicksPerBlock[id];
        maxTicksPerBlock[id] = cap;
        
        // Record the update time for future rate-limiting
        _lastMaxTickUpdate[pid] = uint32(block.timestamp);
        
        // Emit both events for consistency
        emit TickCapParamChanged(id, cap);
        emit MaxTicksPerBlockUpdated(pid, oldValue, cap, uint32(block.timestamp));
    }

    function _maybeUpdateMaxTicks(PoolId poolId, uint32 newCandidate) private {
        bytes32 id = PoolId.unwrap(poolId);
        uint32 oldValue = maxTicksPerBlock[id];

        // ── 1. 24 h rate-limit ───────────────────────────────────────────────
        uint32 minInterval = IPoolPolicy(policyManager).getBaseFeeUpdateIntervalSeconds(poolId);
        
        // Skip rate-limiting if this is the first update (_lastMaxTickUpdate is 0)
        // or if the minimum interval is not set, or if enough time has passed
        if (minInterval != 0 && _lastMaxTickUpdate[poolId] != 0 && block.timestamp < _lastMaxTickUpdate[poolId] + minInterval) {
            emit MaxTicksUpdateSkipped(poolId, newCandidate, "too-early", uint32(block.timestamp));
            return;
        }

        // ── 2. Step-size clamp (ppm) ─────────────────────────────────────────
        uint32 stepPpm   = IPoolPolicy(policyManager).getBaseFeeStepPpm(poolId);  // default 2 %/day
        uint32 maxDelta  = (oldValue * stepPpm) / 1_000_000;
        uint32 upperBand = oldValue + maxDelta;
        uint32 lowerBand = oldValue > maxDelta ? oldValue - maxDelta : 0;

        uint32 adjusted = newCandidate;
        if (newCandidate > upperBand)       adjusted = upperBand;
        else if (newCandidate < lowerBand)  adjusted = lowerBand;

        if (adjusted == oldValue) {
            emit MaxTicksUpdateSkipped(poolId, newCandidate, "inside-band", uint32(block.timestamp));
            return;
        }

        // ── 3. Persist & log ────────────────────────────────────────────────
        maxTicksPerBlock[id] = uint24(adjusted);
        _lastMaxTickUpdate[poolId] = uint32(block.timestamp);

        emit MaxTicksPerBlockUpdated(poolId, oldValue, adjusted, uint32(block.timestamp));
        // Also emit the legacy event for backward compatibility
        emit TickCapParamChanged(id, uint24(adjusted));
    }
}
