// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

// - - - external deps - - -

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

// - - - local deps - - -

import {Errors} from "./errors/Errors.sol";
import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";
import {PolicyValidator} from "./libraries/PolicyValidator.sol";
import {IPoolPolicyManager} from "./interfaces/IPoolPolicyManager.sol";

contract TruncGeoOracleMulti is ReentrancyGuard, Owned {
    using TruncatedOracle for TruncatedOracle.Observation[65535];
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;

    /* -------------------------------------------------------------------------- */
    /*                               Library constants                            */
    /* -------------------------------------------------------------------------- */

    /* parts-per-million constant */
    uint32 internal constant PPM = 1_000_000;
    /* pre-computed ONE_DAY × PPM to avoid a mul on every cap event            *
     * 86_400 * 1_000_000  ==  86 400 000 000  <  2¹²⁷ – safe for uint128      */
    uint64 internal constant ONE_DAY_PPM = 86_400 * 1_000_000;
    /* one add (ONE_DAY_PPM) short of uint64::max */
    uint64 internal constant CAP_FREQ_MAX = type(uint64).max - ONE_DAY_PPM + 1;
    /* maximum cardinality for oracle observations */
    uint16 internal constant MAX_CARDINALITY_TARGET = 1024;

    // Custom errors
    error OnlyHook();
    error OracleNotInitialized(PoolId poolId);

    event MaxTicksPerBlockUpdated(
        PoolId indexed poolId, uint24 oldMaxTicksPerBlock, uint24 newMaxTicksPerBlock, uint32 blockTimestamp
    );
    event PolicyCacheRefreshed(PoolId indexed poolId);
    /// emitted once per pool when the oracle is first enabled
    event OracleConfigured(PoolId indexed poolId, address indexed hook, address indexed owner, uint24 initialCap);

    /* ───────────────────── Emergency pause ────────────────────── */
    /// @notice Emitted when the governor toggles the auto-tune circuit-breaker.
    event AutoTunePaused(PoolId indexed poolId, bool paused, uint32 timestamp);

    /// @dev circuit-breaker flag per pool (default: false = auto-tune active)
    mapping(PoolId => bool) public autoTunePaused;

    /* ────────────────────── LIB-LEVEL HELPERS ─────────────────────── */

    /// @dev Shorthand wrapper that forwards storage-struct fields to the library
    ///      (keeps calling-site tidy without another memory copy).
    function _validatePolicy(CachedPolicy storage pc) internal view {
        PolicyValidator.validate(pc.minCap, pc.maxCap, pc.stepPpm, pc.budgetPpm, pc.decayWindow, pc.updateInterval);
    }

    /* ─────────────────── IMMUTABLE STATE ────────────────────── */
    IPoolManager public immutable poolManager;
    IPoolPolicyManager public immutable policy;
    // Hook address (mutable – allows test harness to wire cyclic deps).
    address public immutable hook;

    /* ───────────────────── MUTABLE STATE ────────────────────── */
    mapping(PoolId => uint24) public maxTicksPerBlock; // adaptive cap
    /* ppm-seconds never exceeds 8.64 e10 per event or 7.45 e15 per year  →
       well inside uint64.  Using uint64 halves slot gas / SLOAD cost.   */
    mapping(PoolId => uint64) private capFreq; // ***saturating*** counter
    mapping(PoolId => uint48) private lastFreqTs; // last decay update

    struct ObservationState {
        uint16 index;
        /**
         * @notice total number of populated observations.
         * Includes the bootstrap slot written by `initializeOracleForPool`,
         * so after N user pushes the value is **N + 1**.
         */
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    /* ─────────────── cached policy parameters ─────────────── */
    struct CachedPolicy {
        uint24 minCap;
        uint24 maxCap;
        uint32 stepPpm;
        uint32 budgetPpm;
        uint32 decayWindow;
        uint32 updateInterval;
    }

    mapping(PoolId => CachedPolicy) internal _policy;

    /* ──────────────────  OBSERVATION RING BUFFER  ──────────────────
       Each pool owns a single observation array (65535 slots available, capped at 1024).
       Uses the official TruncatedOracle library for core functionality. */
    /// pool ⇒ observation array (lazily created)
    mapping(PoolId => TruncatedOracle.Observation[65535]) public observations;

    mapping(PoolId => ObservationState) public states;

    // Store last max tick update time for rate limiting governance changes
    mapping(PoolId => uint32) private _lastMaxTickUpdate;

    /* ────────────────────── CONSTRUCTOR ─────────────────────── */
    /// -----------------------------------------------------------------------
    /// @notice Deploy the oracle and wire the immutable dependencies.
    /// @param _poolManager Canonical v4 `PoolManager` contract
    /// @param _policyContract Governance-controlled policy contract
    /// @param _hook Hook address (immutable)
    /// @param _owner Governor address that can refresh the cached policy
    /// -----------------------------------------------------------------------
    constructor(IPoolManager _poolManager, IPoolPolicyManager _policyContract, address _hook, address _owner) 
        Owned(_owner)
    {
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();
        if (address(_policyContract) == address(0)) revert Errors.ZeroAddress();
        if (_owner == address(0)) revert Errors.ZeroAddress();

        poolManager = _poolManager;
        policy = _policyContract;
        hook = _hook;
    }

    /* ────────────────────── MODIFIERS ─────────────────────── */
    
    /// @notice Modifier to restrict function access to only the hook address
    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    /**
     * @notice Refreshes the cached policy parameters for a pool.
     * @dev Can only be called by the owner (governance). Re-fetches and validates
     *      all policy parameters, ensuring they remain within acceptable ranges.
     * @param poolId The PoolId of the pool.
     */
    /// -----------------------------------------------------------------------
    /// @notice Sync the in-storage policy cache with the current policy
    ///         contract values and clamp the existing `maxTicksPerBlock`
    ///         into the new `[minCap, maxCap]` band.
    /// @dev    Callable only by `owner`. Emits `PolicyCacheRefreshed`.
    /// -----------------------------------------------------------------------
    function refreshPolicyCache(PoolId poolId) external onlyOwner {
        CachedPolicy storage pc = _policy[poolId];
        pc.minCap = SafeCast.toUint24(policy.getMinBaseFee(poolId) / 100);
        pc.maxCap = SafeCast.toUint24(policy.getMaxBaseFee(poolId) / 100);
        pc.stepPpm = policy.getBaseFeeStepPpm(poolId);
        pc.budgetPpm = policy.getDailyBudgetPpm(poolId);
        pc.decayWindow = policy.getCapBudgetDecayWindow(poolId);
        pc.updateInterval = policy.getBaseFeeUpdateIntervalSeconds(poolId);

        _validatePolicy(pc);

        // Clamp existing maxTicksPerBlock to new bounds
        uint24 currentCap = maxTicksPerBlock[poolId];
        maxTicksPerBlock[poolId] = currentCap < pc.minCap ? pc.minCap : 
                                   currentCap > pc.maxCap ? pc.maxCap : currentCap;

        emit PolicyCacheRefreshed(poolId);
    }

    /**
     * @notice Pause or un-pause the adaptive cap algorithm for a pool.
     * @param poolId       Target PoolId.
     * @param paused    True to disable auto-tune, false to resume.
     */
    function setAutoTunePaused(PoolId poolId, bool paused) external onlyOwner {
        autoTunePaused[poolId] = paused;
        emit AutoTunePaused(poolId, paused, uint32(block.timestamp));
    }

    /// -----------------------------------------------------------------------
    /// @notice Enable oracle for a pool and seed the observation history
    /// @dev    Callable only by the hook. Emits `OracleConfigured`.
    /// -----------------------------------------------------------------------
    function initializeOracleForPool(PoolKey calldata key, int24 initialTick) external onlyHook {
        PoolId poolId = key.toId();

        /* ------------------------------------------------------------------ *
         * Pull policy parameters once and *sanity-check* them               *
         * ------------------------------------------------------------------ */
        uint24 defaultCap = SafeCast.toUint24(policy.getDefaultMaxTicksPerBlock(poolId));
        CachedPolicy storage pc = _policy[poolId];
        pc.minCap = SafeCast.toUint24(policy.getMinBaseFee(poolId) / 100);
        pc.maxCap = SafeCast.toUint24(policy.getMaxBaseFee(poolId) / 100);
        pc.stepPpm = policy.getBaseFeeStepPpm(poolId);
        pc.budgetPpm = policy.getDailyBudgetPpm(poolId);
        pc.decayWindow = policy.getCapBudgetDecayWindow(poolId);
        pc.updateInterval = policy.getBaseFeeUpdateIntervalSeconds(poolId);

        _validatePolicy(pc);

        // ---------- external read last (reduces griefing surface) ----------
        (states[poolId].cardinality, states[poolId].cardinalityNext) = observations[poolId].initialize(uint32(block.timestamp), initialTick);

        // Clamp defaultCap inside the validated range
        if (defaultCap < pc.minCap) defaultCap = pc.minCap;
        if (defaultCap > pc.maxCap) defaultCap = pc.maxCap;
        maxTicksPerBlock[poolId] = defaultCap;

        // --- audit-aid event ----------------------------------------------------
        emit OracleConfigured(poolId, hook, owner, defaultCap);
    }

    /**
     * @notice Records a new observation for the given pool
     * @dev Called by the hook during swaps to update oracle data
     * @param poolId The pool identifier
     * @param tickToRecord The tick to record in the observation
     */
    function recordObservation(PoolId poolId, int24 tickToRecord) external nonReentrant onlyHook {

        ObservationState storage state = states[poolId];
        TruncatedOracle.Observation[65535] storage obs = observations[poolId];
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, poolId);

        // Auto-grow cardinality during swaps until reaching MAX_CARDINALITY_TARGET slots
        if (state.cardinalityNext < MAX_CARDINALITY_TARGET) {
            uint16 targetCardinality = uint16(Math.min(state.cardinalityNext + 1, MAX_CARDINALITY_TARGET));
            state.cardinalityNext = obs.grow(state.cardinalityNext, targetCardinality);
        }

        // Get maxTicks for capping
        uint24 maxTicks = maxTicksPerBlock[poolId];

        (uint16 newIndex, uint16 newCardinality) = obs.write(
            state.index,
            uint32(block.timestamp),
            tickToRecord,
            liquidity,
            state.cardinality,
            state.cardinalityNext,
            maxTicks // Apply tick capping to prevent oracle manipulation
        );

        // Update state
        state.index = newIndex;
        state.cardinality = newCardinality;
    }

    /* ─────────────────── VIEW FUNCTIONS ──────────────────────── */

    /**
     * @notice Checks if the oracle is enabled for a given pool.
     * @param poolId The PoolId to check.
     * @return True if the oracle is enabled, false otherwise.
     */
    function isOracleEnabled(PoolId poolId) external view returns (bool) {
        return states[poolId].cardinality > 0;
    }

    /**
     * @notice Gets the latest observation for a pool.
     * @param poolId The PoolId of the pool.
     * @return tick The tick from the latest observation.
     * @return blockTimestamp The timestamp of the latest observation.
     */
    /// @notice Return the most recent observation stored for `poolId`.
    /// @dev    - Gas optimisation -
    ///         We *do not* copy the whole `Observation` struct to memory.
    ///         Instead we keep a **storage** reference and read only the
    ///         timestamp field, then fetch the live tick directly from
    ///         the pool's `slot0`, avoiding any extra per-observation state.
    function getLatestObservation(PoolId poolId) external view returns (int24 tick, uint32 blockTimestamp) {
        if (states[poolId].cardinality == 0) {
            revert OracleNotInitialized(poolId);
        }

        ObservationState storage state = states[poolId];
        // ---- inline fast-path (no struct copy) ----------------------------
        TruncatedOracle.Observation storage o = observations[poolId][state.index];
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId); // fetch current tick
        return (currentTick, o.blockTimestamp);
    }

    /// -----------------------------------------------------------------------
    /// 👀  External helpers (kept tiny – unit tests only)
    /// -----------------------------------------------------------------------
    /// @notice View helper mirroring the public mapping but typed for tests.
    function getMaxTicksPerBlock(PoolId poolId) external view returns (uint24) {
        return maxTicksPerBlock[poolId];
    }

    /// -----------------------------------------------------------------------
    /// @notice Returns cumulative tick and seconds-per-liquidity for each `secondsAgo`.
    /// @dev Typed to mirror Uniswap V3 so off-the-shelf TWAP helpers "just work".
    /// -----------------------------------------------------------------------
    function observe(PoolKey calldata key, uint32[] memory secondsAgos)
        public
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        PoolId poolId = key.toId();

        if (states[poolId].cardinality == 0) {
            revert OracleNotInitialized(poolId);
        }

        ObservationState storage state = states[poolId];
        uint32 time = uint32(block.timestamp);
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, poolId);
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, poolId);

        return observations[poolId].observe(time, secondsAgos, tick, state.index, liquidity, state.cardinality);
    }

    /// -----------------------------------------------------------------------
    /// @notice Returns the arithmetic mean tick, weighted by time.
    /// @dev    Reverts if `secondsAgo` is 0 or if the oracle is not initialized.
    /// -----------------------------------------------------------------------
    function consult(PoolKey calldata key, uint32 secondsAgo)
        public
        view
        returns (int24 arithmeticMeanTick, uint128 harmonicMeanLiquidity)
    {
        require(secondsAgo != 0, "BP");

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) =
            observe(key, secondsAgos);

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        uint160 secondsPerLiquidityCumulativesDelta =
            secondsPerLiquidityCumulativeX128s[1] - secondsPerLiquidityCumulativeX128s[0];

        int56 secondsAgoI56 = int56(uint56(secondsAgo));

        arithmeticMeanTick = int24(tickCumulativesDelta / secondsAgoI56);
        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % secondsAgoI56 != 0)) arithmeticMeanTick--;

        // We are multiplying here instead of shifting to ensure that harmonicMeanLiquidity doesn't overflow uint128
        uint192 secondsAgoX160 = uint192(secondsAgo) * type(uint160).max;
        harmonicMeanLiquidity = uint128(secondsAgoX160 / (uint192(secondsPerLiquidityCumulativesDelta) << 32));
    }

    /**
     * @notice Increases the cardinality of the oracle observation array
     * @param key The pool key.
     * @param cardinalityNext The new cardinality to grow to.
     * @return cardinalityNextOld The previous cardinality.
     * @return cardinalityNextNew The new cardinality.
     */
    function increaseCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 cardinalityNextOld, uint16 cardinalityNextNew)
    {
        PoolId poolId = key.toId();
        ObservationState storage state = states[poolId];

        cardinalityNextOld = state.cardinalityNext;
        cardinalityNextNew = observations[poolId].grow(state.cardinalityNext, cardinalityNext);
        state.cardinalityNext = cardinalityNextNew;
    }




    /* ─────────────────── INTERNAL FUNCTIONS ────────────────────── */

    /**
     * @notice Updates the CAP frequency counter and potentially triggers auto-tuning.
     * @dev Decays the frequency counter based on time elapsed since the last update.
     *      Increments the counter if a CAP occurred.
     *      Triggers auto-tuning if the frequency exceeds the budget or is too low.
     * @param poolId The PoolId of the pool.
     * @param capOccurred True if a CAP event occurred in the current block.
     */
    function updateCapFrequency(PoolId poolId, bool capOccurred) external onlyHook {
        uint32 lastTs = uint32(lastFreqTs[poolId]);
        uint32 nowTs = uint32(block.timestamp);
        uint32 timeElapsed = nowTs - lastTs;

        /* FAST-PATH ────────────────────────────────────────────────────────
           No tick was capped *and* we're still in the same second ⇒ every
           state var is already correct, so we avoid **all** SSTOREs.      */
        if (!capOccurred && timeElapsed == 0) return;

        lastFreqTs[poolId] = uint48(nowTs); // single SSTORE only when needed

        // Load current frequency counter once. The earlier fast-path has already
        // returned when `timeElapsed == 0 && !capOccurred`, so the additional
        // bail-out previously here was unreachable. Removing it saves ~200 gas
        // on the hot path while preserving identical behaviour.
        uint64 currentFreq = capFreq[poolId];

        // --------------------------------------------------------------------- //
        //  1️⃣  Add this block's CAP contribution *first* and saturate.         //
        //      Doing so before decay guarantees a CAP can never be "erased"     //
        //      by an immediate decay step and lets the fuzz-test reach 2⁶⁴-1.   //
        // --------------------------------------------------------------------- //
        if (capOccurred) {
            unchecked {
                currentFreq += uint64(ONE_DAY_PPM);
            }
            if (currentFreq >= CAP_FREQ_MAX || currentFreq < ONE_DAY_PPM) {
                currentFreq = CAP_FREQ_MAX; // clamp one-step-early
            }
        }

        /* -------- cache policy once – each field is an external SLOAD -------- */
        CachedPolicy storage pc = _policy[poolId]; // 🔹 single SLOAD kept
        uint32 budgetPpm = pc.budgetPpm;
        uint32 decayWindow = pc.decayWindow;
        uint32 updateInterval = pc.updateInterval;

        // 2️⃣  Apply exponential decay *only when no CAP in this block*.
        if (!capOccurred && timeElapsed > 0 && currentFreq > 0) {
            // decay factor = (window - elapsed) / window = 1 - elapsed / window
            // We use ppm to avoid floating point: (1e6 - elapsed * 1e6 / window)
            if (timeElapsed >= decayWindow) {
                currentFreq = 0; // Fully decayed
            } else {
                uint64 decayFactorPpm = PPM - uint64(timeElapsed) * PPM / decayWindow;
                /* --------------------------------------------------------- *
                 *  Multiply in 128-bit space to avoid a 2⁶⁴ overflow:      *
                 *  currentFreq (≤ 2⁶⁴-1) × decayFactorPpm (≤ 1e6)          *
                 *  can exceed 2⁶⁴ during the intermediate product.         *
                 * --------------------------------------------------------- */
                uint128 decayed = uint128(currentFreq) * decayFactorPpm / PPM;
                // ----- overflow-safe down-cast (≤ 5 LOC) -------------------------
                if (decayed > type(uint64).max) {
                    currentFreq = CAP_FREQ_MAX;
                } else {
                    uint64 d64 = uint64(decayed);
                    currentFreq = d64 > CAP_FREQ_MAX ? CAP_FREQ_MAX : d64;
                }
            }
        }

        capFreq[poolId] = currentFreq; // single SSTORE

        // Only auto-tune if enough time has passed since last governance update
        // and auto-tune is not paused for this pool
        if (!autoTunePaused[poolId] && block.timestamp >= _lastMaxTickUpdate[poolId] + updateInterval) {
            // Target frequency = budgetPpm × 86 400 sec (computed only when needed)
            uint64 targetFreq = uint64(budgetPpm) * 86_400;
            if (currentFreq > targetFreq) {
                // Too frequent caps -> Increase maxTicksPerBlock (loosen cap)
                _autoTuneMaxTicks(poolId, pc, true); // re-use cached struct
            } else {
                // Caps too rare -> Decrease maxTicksPerBlock (tighten cap)
                _autoTuneMaxTicks(poolId, pc, false); // re-use cached struct
            }
        }
    }

    /**
     * @notice Auto-tunes the maximum ticks per block based on cap frequency
     * @param poolId The PoolId of the pool
     * @param pc The cached policy parameters
     * @param increase True if the cap should be increased, false if decreased
     */
    function _autoTuneMaxTicks(PoolId poolId, CachedPolicy storage pc, bool increase) internal {
        uint24 currentCap = maxTicksPerBlock[poolId];

        /* ------------------------------------------------------------------ *
         * ⚠️  Hot-path gas-saving:                                           *
         * The three invariants below                                         *
         *   – `stepPpm   != 0`                                               *
         *   – `minCap    != 0`                                               *
         *   – `maxCap    >= minCap`                                          *
         * are **already checked once** in `PolicyValidator.validate()`       *
         * (called from `initializeOracleForPool` and `refreshPolicyCache`).      *
         * After that, the cached `pc` struct can only change through the     *
         * same validated path, so repeating the `require`s here costs        *
         * ~500 gas per swap without adding security.                         *
         * ------------------------------------------------------------------ */

        uint32 stepPpm = pc.stepPpm; // safe: validated on write
        uint24 minCap = pc.minCap; // safe: validated on write
        uint24 maxCap = pc.maxCap; // safe: validated on write

        uint24 change = uint24(uint256(currentCap) * stepPpm / PPM);
        if (change == 0) change = 1; // Ensure minimum change of 1 tick

        uint24 newCap;
        if (increase) {
            newCap = currentCap + change > maxCap ? maxCap : currentCap + change;
        } else {
            newCap = currentCap > change + minCap ? currentCap - change : minCap;
        }

        uint24 diff = currentCap > newCap ? currentCap - newCap : newCap - currentCap;

        
        
            emit MaxTicksPerBlockUpdated(poolId, currentCap, newCap, uint32(block.timestamp));
            maxTicksPerBlock[poolId] = newCap;
        
    }
}
