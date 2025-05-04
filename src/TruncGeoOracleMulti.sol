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
    /* ========== paged ring – each "leaf" holds 512 observations ========== */
    uint16  internal constant PAGE_SIZE = 512;
    using TruncatedOracle for TruncatedOracle.Observation[PAGE_SIZE];
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;

    /* -------------------------------------------------------------------------- */
    /*                               Library constants                            */
    /* -------------------------------------------------------------------------- */
    /* seconds in one day (for readability) */
    uint32  internal constant ONE_DAY_SEC  = 86_400;
    /* parts-per-million constant */
    uint32  internal constant PPM          = 1_000_000;
    /* pre-computed ONE_DAY × PPM to avoid a mul on every cap event            *
     * 86_400 * 1_000_000  ==  86 400 000 000  <  2¹²⁷ – safe for uint128      */
    uint64  internal constant ONE_DAY_PPM  = 86_400 * 1_000_000;
    /* one add (ONE_DAY_PPM) short of uint64::max */
    uint64  internal constant CAP_FREQ_MAX = type(uint64).max - ONE_DAY_PPM + 1;
    /* minimum change required to emit MaxTicksPerBlockUpdated event */
    uint24 internal constant EVENT_DIFF = 5;

    // Custom errors
    error OnlyHook();
    error OnlyOwner();
    error ObservationOverflow(uint16 cardinality);
    error ObservationTooOld(uint32 time, uint32 target);

    event TickCapParamChanged(bytes32 indexed poolId, uint24 newMaxTicksPerBlock);
    event MaxTicksPerBlockUpdated(
        PoolId indexed poolId, uint24 oldMaxTicksPerBlock, uint24 newMaxTicksPerBlock, uint32 blockTimestamp
    );
    event PolicyCacheRefreshed(PoolId indexed poolId);
    /// emitted once per pool when the oracle is first enabled
    event OracleConfigured(
        PoolId indexed poolId,
        address indexed hook,
        address indexed owner,
        uint24 initialCap
    );

    /* ────────────────────── LIB-LEVEL HELPERS ─────────────────────── */

    /// @dev Centralised validator for policy parameters – prevents code drift.
    function _validatePolicy(CachedPolicy storage pc) internal view {
        require(pc.stepPpm        != 0 && pc.stepPpm   <= PPM, "stepPpm-range");
        require(pc.budgetPpm      != 0 && pc.budgetPpm <= PPM, "budgetPpm-range");
        require(pc.minCap         != 0,                     "minCap=0");
        require(pc.maxCap         >= pc.minCap,             "cap-bounds");
        require(pc.decayWindow    >  0,                     "decayWindow=0");
        require(pc.updateInterval >  0,                     "updateInterval=0");
    }

    /* ─────────────────── IMMUTABLE STATE ────────────────────── */
    IPoolManager public immutable poolManager;
    IPoolPolicy public immutable policy;
    address public immutable hook; // The ONLY hook allowed to call `enableOracleForPool` & `pushObservation*`
    address public immutable owner; // Governance address that can refresh policy cache

    /* ───────────────────── MUTABLE STATE ────────────────────── */
    mapping(bytes32 => uint24) public maxTicksPerBlock; // adaptive cap
    /* ppm-seconds never exceeds 8.64 e10 per event or 7.45 e15 per year  →
       well inside uint64.  Using uint64 halves slot gas / SLOAD cost.   */
    mapping(bytes32 => uint64) private capFreq;   // ***saturating*** counter
    mapping(bytes32 => uint48) private lastFreqTs; // last decay update

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
    mapping(bytes32 => CachedPolicy) internal _policy;

    /* ──────────────────  CHUNKED OBSERVATION RING  ──────────────────
       Each pool owns *pages* (index ⇒ Observation[PAGE_SIZE]).
       A page is allocated lazily the first time it is touched, so the
       storage footprint grows with `grow()` instead of pre-allocating
       65 k slots (≈ 4 MiB) per pool.                                        */
    /// pool ⇒ page# ⇒ 512-slot chunk (lazily created)
    mapping(bytes32 => mapping(uint16 => TruncatedOracle.Observation[PAGE_SIZE])) internal _pages;

    function _leaf(bytes32 id, uint16 globalIdx)
        internal
        view
        returns (TruncatedOracle.Observation[PAGE_SIZE] storage)
    {
        return _pages[id][globalIdx / PAGE_SIZE];
    }

    mapping(bytes32 => ObservationState) public states;

    // Store last max tick update time for rate limiting governance changes
    mapping(PoolId => uint32) private _lastMaxTickUpdate;

    /* ────────────────────── CONSTRUCTOR ─────────────────────── */
    constructor(IPoolManager _poolManager, IPoolPolicy _policyContract, address _hook, address _owner) {
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();
        if (address(_policyContract) == address(0)) revert Errors.ZeroAddress();
        if (_hook == address(0)) revert Errors.ZeroAddress();
        if (_owner == address(0)) revert Errors.ZeroAddress();

        poolManager = _poolManager;
        policy      = _policyContract;
        hook        = _hook;          // Set immutable hook address
        owner       = _owner;         // Set immutable owner address
    }

    /**
     * @notice Refreshes the cached policy parameters for a pool.
     * @dev Can only be called by the owner (governance). Re-fetches and validates
     *      all policy parameters, ensuring they remain within acceptable ranges.
     * @param pid The PoolId of the pool.
     */
    function refreshPolicyCache(PoolId pid) external {
        if (msg.sender != owner) revert OnlyOwner();
        
        bytes32 id = PoolId.unwrap(pid);
        if (states[id].cardinality == 0) {
            revert Errors.OracleOperationFailed("refreshPolicyCache", "Pool not enabled");
        }
        
        CachedPolicy storage pc = _policy[id];
        
        // Re-fetch all policy parameters
        pc.minCap         = SafeCast.toUint24(policy.getMinBaseFee(pid) / 100);
        pc.maxCap         = SafeCast.toUint24(policy.getMaxBaseFee(pid) / 100);
        pc.stepPpm        = policy.getBaseFeeStepPpm(pid);
        pc.budgetPpm      = policy.getDailyBudgetPpm(pid);
        pc.decayWindow    = policy.getCapBudgetDecayWindow(pid);
        pc.updateInterval = policy.getBaseFeeUpdateIntervalSeconds(pid);
        
        _validatePolicy(pc);
        
        // Ensure current maxTicksPerBlock is within new min/max bounds
        uint24 currentCap = maxTicksPerBlock[id];
        if (currentCap < pc.minCap) {
            maxTicksPerBlock[id] = pc.minCap;
            emit MaxTicksPerBlockUpdated(pid, currentCap, pc.minCap, uint32(block.timestamp));
        } else if (currentCap > pc.maxCap) {
            maxTicksPerBlock[id] = pc.maxCap;
            emit MaxTicksPerBlockUpdated(pid, currentCap, pc.maxCap, uint32(block.timestamp));
        }
        
        emit PolicyCacheRefreshed(pid);
    }

    /**
     * @notice Enables the oracle for a given pool, initializing its state.
     * @dev Can only be called by the configured hook address.
     * @param key The PoolKey of the pool to enable.
     */
    function enableOracleForPool(PoolKey calldata key) external {
        if (msg.sender != hook) revert OnlyHook();
        bytes32 id = PoolId.unwrap(key.toId());   // explicit unwrap
        if (states[id].cardinality > 0) revert Errors.OracleOperationFailed("enableOracleForPool", "Already enabled");

        /* ------------------------------------------------------------------ *
         * Pull policy parameters once and *sanity-check* them               *
         * ------------------------------------------------------------------ */
        uint24 defaultCap = SafeCast.toUint24(policy.getDefaultMaxTicksPerBlock(PoolId.wrap(id)));
        CachedPolicy storage pc = _policy[id];
        pc.minCap         = SafeCast.toUint24(policy.getMinBaseFee(PoolId.wrap(id)) / 100);
        pc.maxCap         = SafeCast.toUint24(policy.getMaxBaseFee(PoolId.wrap(id)) / 100);
        pc.stepPpm        = policy.getBaseFeeStepPpm(PoolId.wrap(id));
        pc.budgetPpm      = policy.getDailyBudgetPpm(PoolId.wrap(id));
        pc.decayWindow    = policy.getCapBudgetDecayWindow(PoolId.wrap(id));
        pc.updateInterval = policy.getBaseFeeUpdateIntervalSeconds(PoolId.wrap(id));

        _validatePolicy(pc);

        // ---------- external read last (reduces griefing surface) ----------
        (, int24 initialTick,,) = StateLibrary.getSlot0(poolManager, PoolId.wrap(id));
        TruncatedOracle.Observation[PAGE_SIZE] storage first = _pages[id][0];
        first.initialize(uint32(block.timestamp), initialTick);
        states[id] = ObservationState({index: 0, cardinality: 1, cardinalityNext: 1});

        // Clamp defaultCap inside the validated range
        if (defaultCap < pc.minCap)  defaultCap = pc.minCap;
        if (defaultCap > pc.maxCap)  defaultCap = pc.maxCap;
        maxTicksPerBlock[id] = defaultCap;

        // --- audit-aid event ----------------------------------------------------
        emit OracleConfigured(PoolId.wrap(id), hook, owner, defaultCap);
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
        bytes32 id = PoolId.unwrap(pid);   // single unwrap for the whole call
        if (states[id].cardinality == 0) {
            revert Errors.OracleOperationFailed("pushObservationAndCheckCap", "Pool not enabled");
        }

        ObservationState storage state = states[id];
        TruncatedOracle.Observation[PAGE_SIZE] storage obs = _leaf(id, state.index);
        uint16 localIdx = state.index % PAGE_SIZE;     // offset inside the 512-slot page
        uint16 pageBase = state.index - localIdx;      // first global index of this page

        // Get current tick from PoolManager
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, pid);

        // Check against max ticks per block
        int24  prevTick      = obs[localIdx].prevTick;
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

            // safe-cast with explicit range-check
            currentTick = _toInt24(capped);
            tickWasCapped = true;
        }

        // -------------------------------------------------- //
        //  ❖ Write the (potentially capped) observation     //
        //  Preserve the library's returned page-index and   //
        //  translate it back to a *global* cursor.          //
        // -------------------------------------------------- //
        uint128 liquidity = StateLibrary.getLiquidity(poolManager, pid);

        /* --------------------------------------------------------------- *
         *  Page-local lengths                                             *
         *  - pageCardinality      = populated slots in this 512-slot leaf *
         *  - pageCardinalityNext  = "room for one more", capped at 512    *
         * --------------------------------------------------------------- */
        uint16 pageCardinality = state.cardinality > pageBase
            ? state.cardinality - pageBase
            : 1;                           // bootstrap slot

        uint16 pageCardinalityNext = pageCardinality < PAGE_SIZE
            ? pageCardinality + 1          // open the next empty slot
            : pageCardinality;             // page already full

        (uint16 newLocalIdx, uint16 newPageCard) = obs.write(
            localIdx,
            uint32(block.timestamp),
            currentTick,
            liquidity,
            pageCardinality,
            pageCardinalityNext
        );

        // Translate the page-local index back to the global cursor.
        // If we just wrote the last slot of a page and the library wrapped
        // to 0, jump to the **first slot of the next page** so subsequent
        // observations fill fresh storage instead of overwriting the old page.
        if (localIdx == PAGE_SIZE - 1 && newLocalIdx == 0) {
            unchecked { state.index = pageBase + PAGE_SIZE; } // next leaf
        } else {
            unchecked { state.index = pageBase + newLocalIdx; }
        }

        // ----------- bump global counters (bootstrap slot included) --------------
        uint32 newGlobalCard;
        unchecked { newGlobalCard = uint32(pageBase) + uint32(newPageCard); }
        if (newGlobalCard > state.cardinality) {
            state.cardinality = uint16(newGlobalCard);
        }

        // keep `cardinalityNext` one ahead, bounded by the hard limit
        if (state.cardinalityNext < state.cardinality + 1
            && state.cardinalityNext < TruncatedOracle.MAX_CARDINALITY_ALLOWED)
        {
            state.cardinalityNext = state.cardinality + 1;
        }

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

        ObservationState storage state = states[id];
        TruncatedOracle.Observation memory observation =
            _leaf(id, state.index)[state.index % PAGE_SIZE];
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

    /**
     * @notice Returns the saturation threshold for the capFreq counter.
     * @return The maximum value for the capFreq counter before it saturates.
     */
    function getCapFreqMax() external pure returns (uint64) {
        return CAP_FREQ_MAX;
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
        bytes32 id      = PoolId.unwrap(pid);
        uint32 lastTs   = uint32(lastFreqTs[id]);
        uint32 nowTs    = uint32(block.timestamp);
        uint32 timeElapsed = nowTs - lastTs;

        /* FAST-PATH ────────────────────────────────────────────────────────
           No tick was capped *and* we're still in the same second ⇒ every
           state var is already correct, so we avoid **all** SSTOREs.      */
        if (!capOccurred && timeElapsed == 0) return;

        lastFreqTs[id] = uint48(nowTs); // single SSTORE only when needed

        uint64 currentFreq = capFreq[id];    // 🔹 cached early SLOAD

        // --------------------------------------------------------------------- //
        //  1️⃣  Add this block's CAP contribution *first* and saturate.         //
        //      Doing so before decay guarantees a CAP can never be "erased"     //
        //      by an immediate decay step and lets the fuzz-test reach 2⁶⁴-1.   //
        // --------------------------------------------------------------------- //
        if (capOccurred) {
            unchecked { currentFreq += uint64(ONE_DAY_PPM); }
            if (currentFreq >= CAP_FREQ_MAX || currentFreq < ONE_DAY_PPM) {
                currentFreq = CAP_FREQ_MAX;             // clamp one-step-early
            }
        }

        // --- nothing to do if counter is still zero and no time elapsed ---------
        if (currentFreq == 0 && timeElapsed == 0) return;

        /* -------- cache policy once – each field is an external SLOAD -------- */
        CachedPolicy storage pc = _policy[id];              // 🔹 single SLOAD kept
        uint32  budgetPpm      = pc.budgetPpm;
        uint32  decayWindow    = pc.decayWindow;
        uint32  updateInterval = pc.updateInterval;

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

        capFreq[id] = currentFreq;            // single SSTORE

        // Check if auto-tuning is needed
        // Budget is per day, frequency counter is ppm-seconds
        // Target frequency = budgetPpm * (1 day / 1e6) = budgetPpm * 86.4 seconds
        uint64 targetFreq = uint64(budgetPpm) * ONE_DAY_SEC; // ppm-seconds target

        // Only auto-tune if enough time has passed since last governance update
        if (block.timestamp >= _lastMaxTickUpdate[pid] + updateInterval) {
            if (currentFreq > targetFreq) {
                // Too frequent caps -> Increase maxTicksPerBlock (loosen cap)
                _autoTuneMaxTicks(pid, pc, true);  // re-use cached struct
            } else {
                // Caps too rare -> Decrease maxTicksPerBlock (tighten cap)
                _autoTuneMaxTicks(pid, pc, false); // re-use cached struct
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
    /// @dev caller passes `pc` to avoid an extra SLOAD
    function _autoTuneMaxTicks(
        PoolId pid,
        CachedPolicy storage pc,
        bool increase
    ) internal {
        bytes32 id       = PoolId.unwrap(pid);
        uint24 currentCap= maxTicksPerBlock[id];

        uint32 stepPpm   = pc.stepPpm;
        uint24 minCap    = pc.minCap;
        uint24 maxCap    = pc.maxCap;

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

        uint24 diff = currentCap > newCap ? currentCap - newCap : newCap - currentCap;
        
        if (newCap != currentCap) {
            maxTicksPerBlock[id] = newCap;
            _lastMaxTickUpdate[pid] = uint32(block.timestamp);
            if (diff >= EVENT_DIFF) {
                emit MaxTicksPerBlockUpdated(pid, currentCap, newCap, uint32(block.timestamp));
            }
        }
    }

    /* ────────────────────── INTERNAL HELPERS ───────────────────────── */

    /// @dev bounded cast; reverts on overflow instead of truncating.
    function _toInt24(int256 v) internal pure returns (int24) {
        require(v >= type(int24).min && v <= type(int24).max, "Tick overflow");
        return int24(v);
    }
}
