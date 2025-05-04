// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";
import {SafeCast}        from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Errors} from "./errors/Errors.sol";

contract TruncGeoOracleMulti is ReentrancyGuard {
    using TruncatedOracle for TruncatedOracle.Observation[65535];
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;

    /* -------------------------------------------------------------------------- */
    /*                               Library constants                            */
    /* -------------------------------------------------------------------------- */
    uint32 internal constant ONE_DAY = 86_400;
    uint32 internal constant PPM     = 1_000_000;

    // Custom errors
    error OnlyHook();
    error ObservationOverflow(uint16 cardinality);
    error ObservationTooOld(uint32 time, uint32 target);

    event TickCapParamChanged(bytes32 indexed poolId, uint24 newMaxTicksPerBlock);
    event MaxTicksPerBlockUpdated(
        PoolId indexed poolId, uint24 oldMaxTicksPerBlock, uint24 newMaxTicksPerBlock, uint32 blockTimestamp
    );

    /* ─────────────────── IMMUTABLE STATE ────────────────────── */
    IPoolManager public immutable poolManager;
    IPoolPolicy public immutable policy;
    address public immutable hook; // The ONLY hook allowed to call `enableOracleForPool` & `pushObservation*`

    /* ───────────────────── MUTABLE STATE ────────────────────── */
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

    // Store last max tick update time for rate limiting governance changes
    mapping(PoolId => uint32) private _lastMaxTickUpdate;

    /* ────────────────────── CONSTRUCTOR ─────────────────────── */
    constructor(IPoolManager _poolManager, IPoolPolicy _policy, address _hook) {
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();
        if (address(_policy) == address(0)) revert Errors.ZeroAddress();
        if (_hook == address(0)) revert Errors.ZeroAddress();

        poolManager = _poolManager;
        policy      = _policy;
        hook        = _hook;          // Set immutable hook address
    }

    /**
     * @notice Enables the oracle for a given pool, initializing its state.
     * @dev Can only be called by the configured hook address.
     * @param key The PoolKey of the pool to enable.
     */
    function enableOracleForPool(PoolKey calldata key) external {
        if (msg.sender != hook) revert OnlyHook();
        bytes32 id = PoolId.unwrap(key.toId());
        if (states[id].cardinality > 0) revert Errors.OracleOperationFailed("enableOracleForPool", "Already enabled");

        /* ------------------------------------------------------------------ *
         * Pull policy parameters once and *sanity-check* them               *
         * ------------------------------------------------------------------ */
        uint24 defaultCap = SafeCast.toUint24(policy.getDefaultMaxTicksPerBlock(PoolId.wrap(id)));
        uint24 minCap     = SafeCast.toUint24(policy.getMinBaseFee(PoolId.wrap(id)) / 100);
        uint24 maxCap     = SafeCast.toUint24(policy.getMaxBaseFee(PoolId.wrap(id)) / 100);
        uint32 stepPpm    = policy.getBaseFeeStepPpm(PoolId.wrap(id));

        require(stepPpm != 0,      "TruncOracle: stepPpm=0");
        require(minCap  != 0,      "TruncOracle: minCap=0");
        require(maxCap  >= minCap, "TruncOracle: cap-bounds");

        // ---------- external read last (reduces griefing surface) ----------
        (, int24 initialTick,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(id));
        observations[id].initialize(uint32(block.timestamp), initialTick);
        states[id] = ObservationState({index: 0, cardinality: 1, cardinalityNext: 1});

        // Clamp defaultCap inside the validated range
        if (defaultCap < minCap)  defaultCap = minCap;
        if (defaultCap > maxCap)  defaultCap = maxCap;
        maxTicksPerBlock[id] = defaultCap;
    }

    /**
     * @notice Pushes a new observation and checks if the tick movement exceeds the cap.
     * @dev Can only be called by the configured hook address. The swap direction parameter
     *      is currently unused but kept for interface compatibility.
     * @param pid The PoolId of the pool.
     * @return tickWasCapped True if the tick movement was capped, false otherwise.
     */
    function pushObservationAndCheckCap(PoolId pid, bool /* _zeroForOne */)
        external
        nonReentrant
        returns (bool tickWasCapped)
    {
        if (msg.sender != hook) revert OnlyHook();
        bytes32 id = PoolId.unwrap(pid);
        if (states[id].cardinality == 0) {
            revert Errors.OracleOperationFailed("pushObservationAndCheckCap", "Pool not enabled");
        }

        ObservationState storage state = states[id];
        TruncatedOracle.Observation[65535] storage obs = observations[id];

        // Get current tick from PoolManager
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, pid);

        // Check against max ticks per block
        int24  prevTick      = obs[state.index].prevTick;
        uint24 cap           = maxTicksPerBlock[id];
        int256 tickDelta256 = int256(currentTick) - int256(prevTick);

        /* ------------------------------------------------------------
           Use the *absolute* delta while it is still int256 – no cast
        ------------------------------------------------------------ */
        uint256 absDelta     = tickDelta256 >= 0
            ? uint256(tickDelta256)
            : uint256(-tickDelta256);

        // Inclusive cap: hitting the limit counts as a capped move
        if (absDelta >= cap) {
            // Cap (and safe-cast) the tick movement
            int256 capped = tickDelta256 > 0
                ? int256(prevTick) + int256(uint256(cap))
                : int256(prevTick) - int256(uint256(cap));

            // guaranteed inside range by construction (prevTick ± cap)
            currentTick = capped.toInt24();
            tickWasCapped = true;
        }

        // Grow cardinality if needed
        if (state.index == state.cardinality - 1) {
            state.cardinalityNext = obs.grow(state.cardinality, state.cardinalityNext);
        }

        // Write the (potentially capped) observation
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, pid);
        (state.index, state.cardinality) = obs.write(
            state.index, uint32(block.timestamp), currentTick, liquidity, state.cardinality, state.cardinalityNext
        );

        // Update auto-tune frequency counter if capped
        if (tickWasCapped) {
            _updateCapFrequency(pid, true);
        } else {
            _updateCapFrequency(pid, false);
        }
    }

    /* ─────────────────── VIEW FUNCTIONS ──────────────────────── */

    /**
     * @notice Checks if the oracle is enabled for a given pool.
     * @param pid The PoolId to check.
     * @return True if the oracle is enabled, false otherwise.
     */
    function isOracleEnabled(PoolId pid) external view returns (bool) {
        return states[PoolId.unwrap(pid)].cardinality > 0;
    }

    /**
     * @notice Gets the latest observation for a pool.
     * @param pid The PoolId of the pool.
     * @return tick The tick from the latest observation.
     * @return blockTimestamp The timestamp of the latest observation.
     */
    function getLatestObservation(PoolId pid) external view returns (int24 tick, uint32 blockTimestamp) {
        bytes32 id = PoolId.unwrap(pid);
        if (states[id].cardinality == 0) {
            revert Errors.OracleOperationFailed("getLatestObservation", "Pool not enabled");
        }

        TruncatedOracle.Observation memory observation = observations[id][states[id].index];
        return (observation.prevTick, observation.blockTimestamp);
    }

    /**
     * @notice Returns the immutable hook address configured for this oracle.
     */
    function getHookAddress() external view returns (address) {
        return hook;
    }

    /// -----------------------------------------------------------------------
    /// 👀  External helpers (kept tiny – unit tests only)
    /// -----------------------------------------------------------------------
    /// @notice View helper mirroring the public mapping but typed for tests.
    function getMaxTicksPerBlock(bytes32 id) external view returns (uint24) {
        return maxTicksPerBlock[id];
    }

    /* ────────────────────── INTERNALS ──────────────────────── */

    /**
     * @notice Updates the CAP frequency counter and potentially triggers auto-tuning.
     * @dev Decays the frequency counter based on time elapsed since the last update.
     *      Increments the counter if a CAP occurred.
     *      Triggers auto-tuning if the frequency exceeds the budget or is too low.
     * @param pid The PoolId of the pool.
     * @param capOccurred True if a CAP event occurred in the current block.
     */
    function _updateCapFrequency(PoolId pid, bool capOccurred) internal {
        bytes32 id = PoolId.unwrap(pid);
        uint32 timeElapsed = uint32(block.timestamp) - uint32(lastFreqTs[id]);
        lastFreqTs[id] = uint48(block.timestamp);

        // -------- fast-exit: nothing to do ---------------------------------
        if (!capOccurred && timeElapsed == 0) return;

        uint128 currentFreq = capFreq[id];
        uint32  budgetPpm   = policy.getDailyBudgetPpm(pid);
        uint32  decayWindow = policy.getCapBudgetDecayWindow(pid);

        // Decay the frequency counter
        if (timeElapsed > 0 && currentFreq > 0) {
            // decay factor = (window - elapsed) / window = 1 - elapsed / window
            // We use ppm to avoid floating point: (1e6 - elapsed * 1e6 / window)
            if (timeElapsed >= decayWindow) {
                currentFreq = 0; // Fully decayed
            } else {
                uint128 decayFactorPpm = PPM - uint128(timeElapsed) * PPM / decayWindow;
                currentFreq = currentFreq * decayFactorPpm / PPM;
            }
        }

        // Add to frequency counter if CAP occurred
        if (capOccurred) {
            // Add 1 day's worth of frequency (scaled by ppm)
            currentFreq += uint128(ONE_DAY) * uint128(PPM);
        }

        capFreq[id] = currentFreq;

        // Check if auto-tuning is needed
        // Budget is per day, frequency counter is ppm-seconds
        // Target frequency = budgetPpm * (1 day / 1e6) = budgetPpm * 86.4 seconds
        uint128 targetFreq = uint128(budgetPpm) * uint128(ONE_DAY); // ppm-seconds target

        // Only auto-tune if enough time has passed since last governance update
        uint32 updateInterval = policy.getBaseFeeUpdateIntervalSeconds(pid);
        if (block.timestamp >= _lastMaxTickUpdate[pid] + updateInterval) {
            if (currentFreq > targetFreq) {
                // Too frequent caps -> Increase maxTicksPerBlock (loosen cap)
                _autoTuneMaxTicks(pid, true);
            } else {
                // Caps too rare -> Decrease maxTicksPerBlock (tighten cap)
                _autoTuneMaxTicks(pid, false);
            }
        }
    }

    /**
     * @notice Adjusts the maxTicksPerBlock based on CAP frequency.
     * @dev Increases the cap if caps are too frequent, decreases otherwise.
     *      Clamps the adjustment based on policy step size and min/max bounds.
     * @param pid The PoolId of the pool.
     * @param increase True to increase the cap, false to decrease.
     */
    function _autoTuneMaxTicks(PoolId pid, bool increase) internal {
        bytes32 id = PoolId.unwrap(pid);
        uint24 currentCap = maxTicksPerBlock[id];
        uint32 stepPpm = policy.getBaseFeeStepPpm(pid);
        uint24 minCap  = SafeCast.toUint24(policy.getMinBaseFee(pid) / 100);
        uint24 maxCap  = SafeCast.toUint24(policy.getMaxBaseFee(pid) / 100);

        // ── validate policy params on every tune to avoid DoS vectors ──────
        require(stepPpm != 0,      "TruncOracle: stepPpm=0");
        require(minCap  != 0,      "TruncOracle: minCap=0");
        require(maxCap  >= minCap, "TruncOracle: cap-bounds");

        uint24 change = uint24(uint256(currentCap) * stepPpm / PPM);
        if (change == 0) change = 1; // Ensure minimum change of 1 tick

        uint24 newCap;
        if (increase) {
            newCap = currentCap + change > maxCap ? maxCap : currentCap + change;
        } else {
            newCap = currentCap > change + minCap ? currentCap - change : minCap;
        }

        if (newCap != currentCap) {
            maxTicksPerBlock[id] = newCap;
            _lastMaxTickUpdate[pid] = uint32(block.timestamp); // Record auto-tune time
            emit MaxTicksPerBlockUpdated(pid, currentCap, newCap, uint32(block.timestamp));
        }
    }
}
