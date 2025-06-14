// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// - - - external deps - - -

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

// - - - local deps - - -

import {Errors} from "./errors/Errors.sol";
import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";
import {PolicyValidator} from "./libraries/PolicyValidator.sol";
import {IPoolPolicyManager} from "./interfaces/IPoolPolicyManager.sol";

contract TruncGeoOracleMulti is ReentrancyGuard {
    /* ========== paged ring – each "leaf" holds 512 observations ========== */
    uint16 internal constant PAGE_SIZE = 512;

    using TruncatedOracle for TruncatedOracle.Observation[PAGE_SIZE];
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;

    /* -------------------------------------------------------------------------- */
    /*                               Library constants                            */
    /* -------------------------------------------------------------------------- */
    /* seconds in one day (for readability) */
    uint32 internal constant ONE_DAY_SEC = 86_400;
    /* parts-per-million constant */
    uint32 internal constant PPM = 1_000_000;
    /* pre-computed ONE_DAY × PPM to avoid a mul on every cap event            *
     * 86_400 * 1_000_000  ==  86 400 000 000  <  2¹²⁷ – safe for uint128      */
    uint64 internal constant ONE_DAY_PPM = 86_400 * 1_000_000;
    /* one add (ONE_DAY_PPM) short of uint64::max */
    uint64 internal constant CAP_FREQ_MAX = type(uint64).max - ONE_DAY_PPM + 1;
    /* minimum change required to emit MaxTicksPerBlockUpdated event */
    uint24 internal constant EVENT_DIFF = 5;

    // Custom errors
    error OnlyHook();
    error OnlyOwner();
    error ObservationOverflow(uint16 cardinality);
    error ObservationTooOld(uint32 time, uint32 target);
    error TooManyObservationsRequested();

    event TickCapParamChanged(PoolId indexed poolId, uint24 newMaxTicksPerBlock);
    event MaxTicksPerBlockUpdated(
        PoolId indexed poolId, uint24 oldMaxTicksPerBlock, uint24 newMaxTicksPerBlock, uint32 blockTimestamp
    );
    event PolicyCacheRefreshed(PoolId indexed poolId);
    /// emitted once per pool when the oracle is first enabled
    event OracleConfigured(PoolId indexed poolId, address indexed hook, address indexed owner, uint24 initialCap);

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
    address public immutable owner; // Governance address that can refresh policy cache

    /* ───────────────────── MUTABLE STATE ────────────────────── */
    mapping(PoolId => uint24) public maxTicksPerBlock; // adaptive cap
    /* ppm-seconds never exceeds 8.64 e10 per event or 7.45 e15 per year  →
       well inside uint64.  Using uint64 halves slot gas / SLOAD cost.   */
    mapping(PoolId => uint64) private capFreq; // ***saturating*** counter
    mapping(PoolId => uint48) private lastFreqTs; // last decay update

    /* ────────────────────── LATEST TICK CACHE ─────────────────────── */
    // (latest-tick cache removed – callers can query pool slot0 directly)

    struct ObservationState {
        uint16 index;
        /**
         * @notice total number of populated observations.
         * Includes the bootstrap slot written by `enableOracleForPool`,
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

    /* ──────────────────  CHUNKED OBSERVATION RING  ──────────────────
       Each pool owns *pages* (index ⇒ Observation[PAGE_SIZE]).
       A page is allocated lazily the first time it is touched, so the
       storage footprint grows with `grow()` instead of pre-allocating
       65 k slots (≈ 4 MiB) per pool.                                        */
    /// pool ⇒ page# ⇒ 512-slot chunk (lazily created)
    mapping(PoolId => mapping(uint16 => TruncatedOracle.Observation[PAGE_SIZE])) internal _pages;

    function _leaf(PoolId poolId, uint16 globalIdx)
        internal
        view
        returns (TruncatedOracle.Observation[PAGE_SIZE] storage)
    {
        return _pages[poolId][globalIdx / PAGE_SIZE];
    }

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
    constructor(IPoolManager _poolManager, IPoolPolicyManager _policyContract, address _hook, address _owner) {
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();
        if (address(_policyContract) == address(0)) revert Errors.ZeroAddress();
        if (_owner == address(0)) revert Errors.ZeroAddress();

        poolManager = _poolManager;
        policy = _policyContract;
        hook = _hook;
        owner = _owner;
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
    function refreshPolicyCache(PoolId poolId) external {
        if (msg.sender != owner) revert OnlyOwner();

        if (states[poolId].cardinality == 0) {
            revert Errors.OracleOperationFailed("refreshPolicyCache", "Pool not enabled");
        }

        CachedPolicy storage pc = _policy[poolId];

        // Re-fetch all policy parameters
        pc.minCap = SafeCast.toUint24(policy.getMinBaseFee(poolId) / 100);
        pc.maxCap = SafeCast.toUint24(policy.getMaxBaseFee(poolId) / 100);
        pc.stepPpm = policy.getBaseFeeStepPpm(poolId);
        pc.budgetPpm = policy.getDailyBudgetPpm(poolId);
        pc.decayWindow = policy.getCapBudgetDecayWindow(poolId);
        pc.updateInterval = policy.getBaseFeeUpdateIntervalSeconds(poolId);

        _validatePolicy(pc);

        // Ensure current maxTicksPerBlock is within new min/max bounds
        uint24 currentCap = maxTicksPerBlock[poolId];
        if (currentCap < pc.minCap) {
            maxTicksPerBlock[poolId] = pc.minCap;
            emit MaxTicksPerBlockUpdated(poolId, currentCap, pc.minCap, uint32(block.timestamp));
        } else if (currentCap > pc.maxCap) {
            maxTicksPerBlock[poolId] = pc.maxCap;
            emit MaxTicksPerBlockUpdated(poolId, currentCap, pc.maxCap, uint32(block.timestamp));
        }

        emit PolicyCacheRefreshed(poolId);
    }

    /**
     * @notice Enables the oracle for a given pool, initializing its state.
     * @dev Can only be called by the configured hook address.
     * @param key The PoolKey of the pool to enable.
     */
    /// -----------------------------------------------------------------------
    /// @notice One-time bootstrap that allocates the first observation page
    ///         and persists all policy parameters for `poolId`.
    /// @dev    Must be invoked through the authorised `hook`.
    /// -----------------------------------------------------------------------
    function enableOracleForPool(PoolKey calldata key) external {
        if (msg.sender != hook) revert OnlyHook();
        PoolId poolId = key.toId();
        if (states[poolId].cardinality > 0) {
            revert Errors.OracleOperationFailed("enableOracleForPool", "Already enabled");
        }

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
        (, int24 initialTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        TruncatedOracle.Observation[PAGE_SIZE] storage first = _pages[poolId][0];
        first.initialize(uint32(block.timestamp), initialTick);
        states[poolId] = ObservationState({index: 0, cardinality: 1, cardinalityNext: 1});

        // Clamp defaultCap inside the validated range
        if (defaultCap < pc.minCap) defaultCap = pc.minCap;
        if (defaultCap > pc.maxCap) defaultCap = pc.maxCap;
        maxTicksPerBlock[poolId] = defaultCap;

        // --- audit-aid event ----------------------------------------------------
        emit OracleConfigured(poolId, hook, owner, defaultCap);
    }

    // Internal workhorse
    function _recordObservation(PoolId poolId, int24 preSwapTick) internal returns (bool tickWasCapped) {
        ObservationState storage state = states[poolId];
        TruncatedOracle.Observation[PAGE_SIZE] storage obs = _leaf(poolId, state.index);
        uint16 localIdx = state.index % PAGE_SIZE; // offset inside the 512-slot page
        uint16 pageBase = state.index - localIdx; // first global index of this page

        // Get current tick from PoolManager
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Check against max ticks per block
        int24 prevTick = preSwapTick;
        uint24 cap = maxTicksPerBlock[poolId];
        int256 tickDelta256 = int256(currentTick) - int256(prevTick);

        /* ------------------------------------------------------------
           Use the *absolute* delta while it is still int256 – no cast
        ------------------------------------------------------------ */
        uint256 absDelta = tickDelta256 >= 0 ? uint256(tickDelta256) : uint256(-tickDelta256);

        // Inclusive cap: hitting the limit counts as a capped move
        if (absDelta >= cap) {
            // Cap (and safe-cast) the tick movement
            int256 capped =
                tickDelta256 > 0 ? int256(prevTick) + int256(uint256(cap)) : int256(prevTick) - int256(uint256(cap));

            // safe-cast with explicit range-check
            currentTick = _toInt24(capped);
            tickWasCapped = true;
        }

        // -------------------------------------------------- //
        //  ❖ Write the (potentially capped) observation     //
        //  Preserve the library's returned page-index and   //
        //  translate it back to a *global* cursor.          //
        // -------------------------------------------------- //
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, poolId);

        /* --------------------------------------------------------------- *
         *  Page-local lengths                                             *
         *  - pageCardinality      = populated slots in this 512-slot leaf *
         *  - pageCardinalityNext  = "room for one more", capped at 512    *
         * --------------------------------------------------------------- */
        uint16 pageCardinality = state.cardinality > pageBase ? state.cardinality - pageBase : 1; // bootstrap slot

        uint16 pageCardinalityNext = pageCardinality < PAGE_SIZE
            ? pageCardinality + 1 // open the next empty slot
            : pageCardinality; // page already full

        (uint16 newLocalIdx, uint16 newPageCard) =
            obs.write(localIdx, uint32(block.timestamp), currentTick, liquidity, pageCardinality, pageCardinalityNext);

        // Detect if the library actually wrote a *new* slot. The `write` function
        // early-returns (leaving the index unchanged) when it is invoked twice in
        // the same second. In that scenario, we must *not* bump the global cursor
        // nor the cardinality counter, otherwise the book-keeping diverges from
        // reality and downstream reads (e.g. observe()) will revert.
        bool wroteNewSlot = (newLocalIdx != localIdx) || (newPageCard != pageCardinality);

        // If we received an early-return (same-second update), we still want to
        // reflect the latest tick value for downstream reads.  Mutate the
        // in-place observation rather than creating a brand new slot – this
        // mirrors the behaviour of Uniswap-V3ʼs oracle and preserves gas.
        if (!wroteNewSlot) {
            // Same-second update path – no additional storage writes now that
            // the latest-tick cache has been removed.
        }

        if (wroteNewSlot) {
            // Translate the page-local index back to the global cursor.
            // If we just wrote the last slot of a page and the library wrapped
            // to 0, jump to the **first slot of the next page** so subsequent
            // observations fill fresh storage instead of overwriting the old page.
            if (localIdx == PAGE_SIZE - 1 && newLocalIdx == 0) {
                unchecked {
                    state.index = pageBase + PAGE_SIZE;
                } // next leaf
            } else {
                unchecked {
                    state.index = pageBase + newLocalIdx;
                }
            }

            // ----------- bump global counters (bootstrap slot included) --------------
            unchecked {
                if (state.cardinality < TruncatedOracle.MAX_CARDINALITY_ALLOWED) {
                    state.cardinality += 1;
                }
            }

            // Keep `cardinalityNext` one element ahead, subject to the hard upper bound.
            if (
                state.cardinalityNext < state.cardinality + 1
                    && state.cardinalityNext < TruncatedOracle.MAX_CARDINALITY_ALLOWED
            ) {
                state.cardinalityNext = state.cardinality + 1;
            }

            // latest-tick cache removed – nothing to update here.
        }

        // Update auto-tune frequency counter if capped
        _updateCapFrequency(poolId, tickWasCapped);
    }

    /// -----------------------------------------------------------------------
    /// @notice Record a new observation using the actual pre-swap tick.
    /// -----------------------------------------------------------------------
    function pushObservationAndCheckCap(PoolId poolId, int24 preSwapTick)
        external
        nonReentrant
        returns (bool tickWasCapped)
    {
        if (msg.sender != hook) revert OnlyHook();
        if (states[poolId].cardinality == 0) {
            revert Errors.OracleOperationFailed("pushObservationAndCheckCap", "Pool not enabled");
        }
        return _recordObservation(poolId, preSwapTick);
    }

    /* ─────────────────── VIEW FUNCTIONS ──────────────────────── */

    /**
     * @notice Checks if the oracle is enabled for a given pool.
     * @param poolId The PoolId to check.
     * @return True if the oracle is enabled, false otherwise.
     */
    /// @notice Read-only helper: check if the oracle has been enabled for `poolId`.
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
            revert Errors.OracleOperationFailed("getLatestObservation", "Pool not enabled");
        }

        ObservationState storage state = states[poolId];
        // ---- inline fast-path (no struct copy) ----------------------------
        TruncatedOracle.Observation storage o = _leaf(poolId, state.index)[state.index % PAGE_SIZE];
        (, int24 liveTick,,) = StateLibrary.getSlot0(poolManager, poolId); // fetch current tick
        return (liveTick, o.blockTimestamp);
    }

    /// -----------------------------------------------------------------------
    /// 👀  External helpers (kept tiny – unit tests only)
    /// -----------------------------------------------------------------------
    /// @notice View helper mirroring the public mapping but typed for tests.
    function getMaxTicksPerBlock(PoolId poolId) external view returns (uint24) {
        return maxTicksPerBlock[poolId];
    }

    /**
     * @notice Returns the saturation threshold for the capFreq counter.
     * @return The maximum value for the capFreq counter before it saturates.
     */
    /// @notice Hard-coded saturation threshold used by the frequency counter.
    function getCapFreqMax() external pure returns (uint64) {
        return CAP_FREQ_MAX;
    }

    /// @notice Calculates time-weighted means of tick and liquidity for a given Uniswap V3 pool
    /// copied from v3-periphery OracleLibrary
    /// @param key the key of the pool to consult
    /// @param secondsAgo Number of seconds in the past from which to calculate the time-weighted means
    /// @return arithmeticMeanTick The arithmetic mean tick from (block.timestamp - secondsAgo) to block.timestamp
    /// @return harmonicMeanLiquidity The harmonic mean liquidity from (block.timestamp - secondsAgo) to block.timestamp
    function consult(PoolKey calldata key, uint32 secondsAgo)
        external
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
     * @notice Observe oracle values at specific secondsAgos from the current block timestamp
     * @dev Reverts if observation at or before the desired observation timestamp does not exist
     * @param key The pool key to observe
     * @param secondsAgos The array of seconds ago to observe
     * @return tickCumulatives The tick * time elapsed since the pool was first initialized, as of each secondsAgo
     * @return secondsPerLiquidityCumulativeX128s The cumulative seconds / max(1, liquidity) since pool initialized
     */
    function observe(PoolKey calldata key, uint32[] memory secondsAgos)
        public
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        PoolId poolId = key.toId();

        // Length guard removed – timestamp validation ensures safety even for multi-page history
        if (states[poolId].cardinality == 0) {
            revert Errors.OracleOperationFailed("observe", "Pool not enabled");
        }

        ObservationState storage state = states[poolId];
        // --- Resolve leaf dynamically – supports TWAP windows spanning multiple pages ---
        uint16 gIdx = state.index; // global index of newest obs
        uint32 time = uint32(block.timestamp);

        // Determine oldest timestamp the caller cares about (largest secondsAgo)
        uint32 oldestWanted;
        if (secondsAgos.length != 0) {
            uint32 sa = secondsAgos[secondsAgos.length - 1];
            // Same wrap-around logic used by TruncatedOracle.observeSingle
            oldestWanted = time >= sa ? time - sa : time + (type(uint32).max - sa) + 1;
        }

        uint16 leafCursor = gIdx;

        // Walk pages backwards until the first timestamp inside the leaf is <= oldestWanted
        while (true) {
            TruncatedOracle.Observation[PAGE_SIZE] storage page = _leaf(poolId, leafCursor);
            uint16 localIdx = uint16(leafCursor % PAGE_SIZE);
            uint16 pageBase = leafCursor - localIdx;
            uint16 pageCardinality = state.cardinality > pageBase ? state.cardinality - pageBase : 1;

            // slot 0 may be uninitialised if page not yet full; choose first initialised slot
            uint16 firstSlot = pageCardinality == PAGE_SIZE ? (localIdx + 1) % PAGE_SIZE : 0;
            uint32 firstTs = page[firstSlot].blockTimestamp;

            if (oldestWanted >= firstTs || leafCursor < PAGE_SIZE) break;
            leafCursor -= PAGE_SIZE;
        }

        // Fetch the resolved leaf *after* the loop to guarantee initialization
        TruncatedOracle.Observation[PAGE_SIZE] storage obs = _leaf(poolId, leafCursor);

        uint16 idx = uint16(leafCursor % PAGE_SIZE);

        // Cardinality of *this* leaf (cannot exceed PAGE_SIZE)
        uint16 card = state.cardinality > leafCursor - idx ? state.cardinality - (leafCursor - idx) : 1;

        if (card == 0) revert("empty-page-card");
        if (card > PAGE_SIZE) {
            card = PAGE_SIZE;
        }

        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, poolId);

        (tickCumulatives, secondsPerLiquidityCumulativeX128s) =
            obs.observe(time, secondsAgos, currentTick, idx, liquidity, card);

        return (tickCumulatives, secondsPerLiquidityCumulativeX128s);
    }


    /* ────────────────────── INTERNALS ──────────────────────── */

    /**
     * @notice Updates the CAP frequency counter and potentially triggers auto-tuning.
     * @dev Decays the frequency counter based on time elapsed since the last update.
     *      Increments the counter if a CAP occurred.
     *      Triggers auto-tuning if the frequency exceeds the budget or is too low.
     * @param poolId The PoolId of the pool.
     * @param capOccurred True if a CAP event occurred in the current block.
     */
    function _updateCapFrequency(PoolId poolId, bool capOccurred) internal {
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
        if (!_autoTunePaused[poolId] && block.timestamp >= _lastMaxTickUpdate[poolId] + updateInterval) {
            // Target frequency = budgetPpm × 86 400 sec (computed only when needed)
            uint64 targetFreq = uint64(budgetPpm) * ONE_DAY_SEC;
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
     * @notice Adjusts the maxTicksPerBlock based on CAP frequency.
     * @dev Increases the cap if caps are too frequent, decreases otherwise.
     *      Clamps the adjustment based on policy step size and min/max bounds.
     * @param poolId The PoolId of the pool.
     * @param increase True to increase the cap, false to decrease.
     */
    /// @dev caller passes `pc` to avoid an extra SLOAD
    function _autoTuneMaxTicks(PoolId poolId, CachedPolicy storage pc, bool increase) internal {
        uint24 currentCap = maxTicksPerBlock[poolId];

        /* ------------------------------------------------------------------ *
         * ⚠️  Hot-path gas-saving:                                           *
         * The three invariants below                                         *
         *   – `stepPpm   != 0`                                               *
         *   – `minCap    != 0`                                               *
         *   – `maxCap    >= minCap`                                          *
         * are **already checked once** in `PolicyValidator.validate()`       *
         * (called from `enableOracleForPool` and `refreshPolicyCache`).      *
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

        if (newCap != currentCap) {
            maxTicksPerBlock[poolId] = newCap;
            _lastMaxTickUpdate[poolId] = uint32(block.timestamp);
            if (diff >= EVENT_DIFF) {
                emit MaxTicksPerBlockUpdated(poolId, currentCap, newCap, uint32(block.timestamp));
            }
        }
    }

    /* ────────────────────── INTERNAL HELPERS ───────────────────────── */

    /// @dev bounded cast; reverts on overflow instead of truncating.
    function _toInt24(int256 v) internal pure returns (int24) {
        require(v >= type(int24).min && v <= type(int24).max, "Tick overflow");
        return int24(v);
    }

    /* ───────────────────── Emergency pause ────────────────────── */
    /// @notice Emitted when the governor toggles the auto-tune circuit-breaker.
    event AutoTunePaused(PoolId indexed poolId, bool paused, uint32 timestamp);

    /// @dev circuit-breaker flag per pool (default: false = auto-tune active)
    mapping(PoolId => bool) private _autoTunePaused;

    /**
     * @notice Pause or un-pause the adaptive cap algorithm for a pool.
     * @param poolId       Target PoolId.
     * @param paused    True to disable auto-tune, false to resume.
     */
    function setAutoTunePaused(PoolId poolId, bool paused) external {
        if (msg.sender != owner) revert OnlyOwner();
        _autoTunePaused[poolId] = paused;
        emit AutoTunePaused(poolId, paused, uint32(block.timestamp));
    }

    /* ─────────────────────── public cardinality grow ─────────────────────── */
    /**
     * @notice Requests the ring buffer to grow to `cardinalityNext` slots.
     * @dev Mirrors Uniswap-V3 behaviour. Callable by anyone; growth is capped
     *      by the TruncatedOracle library's internal MAX_CARDINALITY_ALLOWED.
     * @param key Encoded PoolKey.
     * @param cardinalityNext Desired new cardinality.
     * @return oldNext Previous next-size.
     * @return newNext Updated next-size after grow.
     */
    function increaseCardinalityNext(PoolKey calldata key, uint16 cardinalityNext)
        external
        returns (uint16 oldNext, uint16 newNext)
    {
        if (msg.sender != owner) revert OnlyOwner();
        PoolId poolId = key.toId();

        ObservationState storage state = states[poolId];
        if (state.cardinality == 0) {
            revert Errors.OracleOperationFailed("increaseCardinalityNext", "Pool not enabled");
        }

        oldNext = state.cardinalityNext;
        if (cardinalityNext <= oldNext) {
            return (oldNext, oldNext);
        }

        state.cardinalityNext = TruncatedOracle.grow(
            _leaf(poolId, state.cardinalityNext), // leaf storage slot
            oldNext,
            cardinalityNext
        );

        newNext = state.cardinalityNext;
    }
}
