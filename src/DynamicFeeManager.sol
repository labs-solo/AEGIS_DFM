// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26; // Consistent pragma

import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IDynamicFeeManager} from "./interfaces/IDynamicFeeManager.sol";

/*═══════════════════════════════════════╗
║  DynamicFeeManager – single slot      ║ // Renamed title
╚═══════════════════════════════════════╝*/

/* -------------------------------------------------------------------------- */
/*  *TickCheck* helper was moved to the hook repo – it is no longer referenced
    inside the manager, so it is deleted here to avoid dead code clutter.     */
/* -------------------------------------------------------------------------- */

/* ───── packed word ──── */
/**
 * @dev Library for packing/unpacking pool state into a single uint256 slot.
 * Layout:
 *   ┌─────────────────────────────────────────────────────────────────────────┐
 *   │   1   │    32     │     48     │      48     │    32    │     108    │
 *   │ inCap │  lastFee  │  capStart  │  freqLast   │  baseFee │    freq    │
 *   │ (bool)│ (uint32)  │  (uint48)  │  (uint48)   │ (uint32) │  (uint128) │
 *   └─────────────────────────────────────────────────────────────────────────┘
 */
library _P {
    /* -----------------------------------------------------------
                NEW COMPACT LAYOUT   (total bits = 241)
         ┌───────96──────┬──32──┬──40──┬──40──┬──32──┬─1─┐
         │     freq      │ base │freqL │capSt │lastF │ C │
         └────────────────────────────────────────────────┘
         - 15 spare bits (240…254) keep slot <256 bits
    ----------------------------------------------------------- */

    // bit offsets
    uint256 constant BASE_OFFSET        = 96;
    uint256 constant FREQ_LAST_OFFSET   = BASE_OFFSET + 32;      // 128
    uint256 constant CAP_START_OFFSET   = FREQ_LAST_OFFSET + 40; // 168
    uint256 constant LAST_FEE_OFFSET    = CAP_START_OFFSET + 40; // 208
    uint256 constant IN_CAP_OFFSET      = 255;                   // fits

    // bit masks
    uint256 constant MASK_FREQ      = (uint256(1) << BASE_OFFSET) - 1;                    // 96-bit
    uint256 constant MASK_BASE      = ((uint256(1) << 32) - 1) << BASE_OFFSET;            // 32-bit
    uint256 constant MASK_FREQ_LAST = ((uint256(1) << 40) - 1) << FREQ_LAST_OFFSET;       // 40-bit
    uint256 constant MASK_CAP_START = ((uint256(1) << 40) - 1) << CAP_START_OFFSET;       // 40-bit
    uint256 constant MASK_LAST_FEE  = ((uint256(1) << 32) - 1) << LAST_FEE_OFFSET;        // 32-bit
    uint256 constant MASK_IN_CAP    = uint256(1) << IN_CAP_OFFSET;                        // 1-bit

    /* -------- accessors (return sizes kept for ABI stability) -------- */
    function base(uint256 w)      internal pure returns (uint32) { return uint32((w & MASK_BASE)      >> BASE_OFFSET);        }
    function freq(uint256 w)      internal pure returns (uint128){ return uint128( w & MASK_FREQ);                              }
    function inCap(uint256 w)     internal pure returns (bool)   { return (w & MASK_IN_CAP) != 0;                               }
    function lastFee(uint256 w)   internal pure returns (uint32) { return uint32((w & MASK_LAST_FEE)  >> LAST_FEE_OFFSET);      }
    function freqL(uint256 w)     internal pure returns (uint48) { return uint48((w & MASK_FREQ_LAST) >> FREQ_LAST_OFFSET);     }
    function capStart(uint256 w)  internal pure returns (uint48) { return uint48((w & MASK_CAP_START) >> CAP_START_OFFSET);     }

    /* -------- setters -------- */
    function _set(uint256 w, uint256 mask, uint256 v, uint256 shift) private pure returns (uint256) {
        return (w & ~mask) | (v << shift);
    }
    function setBase  (uint256 w, uint32  v) internal pure returns (uint256){ return _set(w, MASK_BASE,      v, BASE_OFFSET);        }
    function setFreq  (uint256 w, uint128 v) internal pure returns (uint256){ return _set(w, MASK_FREQ,      v, 0);                  }
    function setInCap (uint256 w, bool   y) internal pure returns (uint256){ return y ? w | MASK_IN_CAP : w & ~MASK_IN_CAP;         }
    function setLastF (uint256 w, uint32  v) internal pure returns (uint256){ return _set(w, MASK_LAST_FEE,  v, LAST_FEE_OFFSET);    }
    function setFreqL (uint256 w, uint40  v) internal pure returns (uint256){ return _set(w, MASK_FREQ_LAST, v, FREQ_LAST_OFFSET);   }
    function setCapSt (uint256 w, uint40  v) internal pure returns (uint256){ return _set(w, MASK_CAP_START, v, CAP_START_OFFSET);   }
}

using _P for uint256;   // Enable freqL(), setFreqL(), and other helpers

/* ───────────────────────────────────────────────────────────── */

// Renamed contract, implements the NEW interface
contract DynamicFeeManager is IDynamicFeeManager {
    using _P for uint256;
    using PoolIdLibrary for PoolId;

    /* ─── config / state ─────────────────────────────────────── */
    IPoolPolicy public immutable policy;
    address public immutable owner;
    /// @notice address allowed to call `notifyOracleUpdate` – owner may rotate
    address public authorizedHook;

    /// @dev per‑pool cache of `maxStepPpm`; 0 ⇒ not cached yet
    mapping(PoolId => uint32) private _cachedStepPpm;

    mapping(PoolId => uint256) private _s; // packed state word

    /// @dev Timestamp of last fee update
    uint64 private lastFeeUpdate;

    /// @dev Reference to the policy manager contract
    IPoolPolicy private immutable policyManager;

    struct FeeState {
        uint24 baseFeePpm;
        uint24 surgeFeePpm;         // snapshot at (re)start of cap‑event
        uint32 surgeStartTimestamp; // 0 ⇢ no active event
    }

    /// -------------------------------------------------------------------
    ///  Budget‑counter state (see README‑caps.md)
    /// -------------------------------------------------------------------

    /// @dev Linearly‑decaying accumulator of "cap weight" (ppm‑seconds).  One
    ///      complete cap‑event adds capWeightEventPpm (1 M) to the counter.
    uint128 private capWeightCum;

    /// @dev Timestamp of last capWeightCum update.
    uint64  private lastCapWeightUpdate;

    /* ─── events (from interface) ────────────────────────────── */
    // Event definition is inherited from IDynamicFeeManager
    // event FeeStateChanged(...);

    /* ─── modifier for access control ────────────────────────── */
    modifier onlyHook() {
        require(msg.sender == authorizedHook, "DFM: unauthorized");
        _;
    }

    /* ─── constructor / init ─────────────────────────────────── */
    /**
     * @param _policyManager Address of the policy manager contract.
     * @param _authorizedHook Address of the single hook authorized to call `notifyOracleUpdate`.
     */
    constructor(IPoolPolicy _policyManager, address _authorizedHook) {
        require(address(_policyManager) != address(0), "DFM: policy 0");
        require(_authorizedHook != address(0), "DFM: hook 0");
        policy = _policyManager;
        policyManager = _policyManager;
        owner = msg.sender;
        authorizedHook = _authorizedHook;
        lastFeeUpdate = uint64(block.timestamp);
    }

    /* ─── admin ─────────────────────────────────────────────────────────── */
    /// @notice rotate the hook without redeploying the manager.
    function setAuthorizedHook(address newHook) external {
        require(msg.sender == owner, "DFM:owner");
        require(newHook != address(0), "DFM:0");
        authorizedHook = newHook;
    }

    /**
     * @notice Initializes fee state. MUST be called once by owner before swaps.
     * @param id PoolId to initialize.
     */
    function initialize(PoolId id, int24 /*initialTick*/ ) external override {
        require(msg.sender == owner, "DFM:auth"); // Keep owner auth for init
        require(_s[id] == 0, "DFM:initialized");

        uint32 ts = uint32(block.timestamp);
        uint256 def256 = policy.getDefaultDynamicFee();
        require(def256 <= type(uint32).max, "DFM:def>u32");
        uint32 def = uint32(def256);

        uint256 w = 0;
        w = w.setBase(def).setLastF(ts).setFreqL(uint40(ts));
        _s[id] = w;

        capWeightCum = 0;
        lastCapWeightUpdate = uint64(block.timestamp);
        lastFeeUpdate = uint64(block.timestamp);

        // Emit initial state
        emit FeeStateChanged(id, def, 0, false);
    }

    /* ─── hook hot‑path ──────────────────────────────────────── */
    /**
     * @notice Updates fee state based on capping determined by hook. Only callable by authorized hook.
     * @param id PoolId being updated.
     * @param capped True if hook capped the tick movement.
     */
    // Added access control modifier
    function notifyOracleUpdate(PoolId id, bool capped) external override onlyHook {
        uint256 w0 = _s[id];                  // 1. load
        require(w0 != 0, "DFM: not init");

        uint32 nowTs = uint32(block.timestamp);
        bool wasCap = w0.inCap();
        uint256 initialW = w0;

        // --- Handle surge fee weight decay -------------------------------
        (uint32 budgetPerDay, uint32 decayWindow) = _policy().getBudgetAndWindow(id);
        uint256 dt = block.timestamp - lastCapWeightUpdate;
        if (dt > 0) {
            uint256 decay = (uint256(capWeightCum) * dt) / decayWindow;
            capWeightCum -= uint128(decay > capWeightCum ? capWeightCum : decay);
            lastCapWeightUpdate = uint64(block.timestamp);
        }

        // --- Update cap weight for surge fee ---------------------------
        if (capped) capWeightCum += 1e6; // one full event = 1 M ppm

        // --- Update frequency accumulator for base fee -----------------
        uint256 w1 = w0;
        if (capped) {
            // always mark CAP active **and reset the surge timer**
            w1 = w1.setInCap(true).setCapSt(uint40(nowTs));
            // one event == 1 M ppm, then apply the policy scaling (usually 1×)
            uint256 increment = uint256(_policy().getFreqScaling(id)) * 1e6;
            uint128 f        = uint128(w1.freq());
            unchecked {
                w1 = w1.setFreq(
                    type(uint128).max - f >= increment
                        ? f + uint128(increment)
                        : type(uint128).max     // saturate on overflow
                );
            }
        } else if (wasCap) {
            w1 = w1.setInCap(false);
        }

        // --- Compute fees with updated frequency ----------------------
        uint32 window = _policy().getCapBudgetDecayWindow(PoolId.unwrap(id));
        uint32 updateInterval = uint32(_policy().getBaseFeeUpdateIntervalSeconds(id));

        if (updateInterval > 0 && nowTs >= w1.lastFee() + updateInterval) {
            (, uint256 w2) = _recomputeFees(id, w1, window, nowTs);
            w1 = w2;
        }

        // --- Apply frequency decay -----------------------------------
        if (window > 0) {
            uint32 lastFreqTs = uint32(w1.freqL());
            if (nowTs > lastFreqTs) {
                uint32 decayTime = nowTs - lastFreqTs;
                if (decayTime >= window) {
                    w1 = w1.setFreq(0);
                } else {
                    uint128 f = w1.freq();
                    uint128 decayAmount = uint128(uint256(f) * decayTime / window);
                    w1 = w1.setFreq(f > decayAmount ? f - decayAmount : 0);
                }
            }
        }
        // stamp decay time
        w1 = w1.setFreqL(uint40(nowTs));

        // --- Emit event if state changed (ignoring timestamps) --------
        uint256 maskIgnoreTime = ~(_P.MASK_FREQ_LAST | _P.MASK_LAST_FEE);
        if ((w1 & maskIgnoreTime) != (initialW & maskIgnoreTime)) {
            uint256 finalSurge = _surge(w1, id);
            emit FeeStateChanged(id, w1.base(), finalSurge, w1.inCap());
        }

        _s[id] = w1; // Final single SSTORE
    }

    /* ─── public views ───────────────────────────────────────── */
    /**
     * @notice Returns current base and surge fee.
     * @param id PoolId to query.
     * @return baseFee Current base fee (PPM).
     * @return surgeFee Current surge fee (PPM).
     */
    function getFeeState(PoolId id) external view override returns (uint256 baseFee, uint256 surgeFee) {
        uint256 w = _s[id];
        require(w != 0, "DFM: not init");
        baseFee = w.base();
        surgeFee = _surge(w, id);
    }

    /**
     * @notice Checks if pool is in a CAP event.
     * @param id PoolId to query.
     * @return True if in CAP event.
     */
    function isCAPEventActive(PoolId id) external view override returns (bool) {
        uint256 w = _s[id];
        require(w != 0, "DFM: not init");
        return w.inCap();
    }

    /// @return cachedStepPpm The cached maximum step size in ppm, or 0 if not cached.
    function getCachedStepPpm(PoolId id) external view returns (uint32) {
        return _cachedStepPpm[id];
    }

    /* ─── internal helpers ─────────────────────────────────── */

    /**
     * @dev Calculates new base fee based on frequency, clamps, and returns updated state word.
     * Does NOT emit events. Updates lastFee timestamp in the returned word.
     */
    function _recomputeFees(
        PoolId id,
        uint256 w, // Current packed state word
        uint32 window, // Decay window (passed in to avoid reading again)
        uint32 nowTs // Current timestamp (passed in)
    )
        private
        returns (
            uint32 newBase,
            uint256 updatedWord // Simplified return values
        )
    {
        uint32 base = w.base(); // Current base fee
        uint256 minBase = policy.getMinBaseFee(id);
        uint256 maxBase = policy.getMaxBaseFee(id);
        uint256 target = policy.getTargetCapsPerDay(PoolId.unwrap(id));
        if (target == 0) target = 1; // Avoid division by zero

        /* -------------------------------------------------------------
         *  Frequency → caps/day   (now in fixed-point, 1e18 = 1 cap)
         * ---------------------------------------------------------- */
        uint32  effWindow      = window == 0 ? 1 : window;  // avoid /0
        uint256 scaleUnits     = policy.getFreqScaling(id);       // 1e18 by default

        // freq (integer) → 18-dec fixed-point caps
        uint256 capsInWindowFp = uint256(w.freq()) * 1e18 / scaleUnits;  // ✅

        // caps/day (1e18-FP):   freq × 86 400  /  window
        uint256 perDayFp = capsInWindowFp * 86400 / effWindow;
        uint256 targetFp = uint256(target)   * 1e18;        // target in 1e18

        // deviation (PPM) = (perDay / target – 1)   (all fixed-point)
        int256 deviation;
        unchecked {
            deviation = int256(perDayFp * 1e6 / targetFp) - int256(1e6);
        }

        /* maxStepPpm via low‑level static‑call */
        // 1) try cached
        uint32 cached = _cachedStepPpm[id];
        if (cached == 0) {
            // 2) first‑time: static‑call policy then cache
            bytes memory cd = abi.encodeWithSignature(
                "getMaxStepPpm(bytes32)",
                PoolId.unwrap(id)
            );
            (bool ok, bytes memory ret) = address(policy).staticcall(cd);
            if (ok && ret.length == 32) {
                cached = uint32(uint256(bytes32(ret)));
                if (cached == 0) cached = 30_000; // policy returned 0 ⇒ default
            } else {
                cached = 30_000; // fallback default
            }
            _cachedStepPpm[id] = cached;
        }
        uint256 stepPpm = cached;

        /* ------------------------------------------------------------------ *
         *   Ignore very small deviations (|Δ| < stepPpm)  → leave fee as-is  *
         * ------------------------------------------------------------------ */
        if (deviation > -int256(stepPpm) && deviation < int256(stepPpm)) {
            newBase     = base;                 // unchanged
            updatedWord = w.setLastF(nowTs);    // just refresh timestamp
            return (newBase, updatedWord);
        }

        // ── dynamic step‑cap: ±(stepPpm ‰) of the *current* base‑fee ──
        uint256 stepCap = uint256(base) * stepPpm / 1e6;
        // ensure we always move at least 1 PPM if there's any positive deviation
        if (stepCap == 0) {
            stepCap = 1;
        }

        // Calculate desired step based on deviation
        int256 step = int256(uint256(base)) * deviation / 1e6;   // <<< two‑step cast
        // Clamp step
        if (step > int256(stepCap)) step = int256(stepCap);
        if (step < -int256(stepCap)) step = -int256(stepCap);

        // Apply step and clamp to min/max base fee
        int256 nb = int256(uint256(base)) + step;                // <<< two-step cast
        require(minBase <= type(uint32).max, "DFM:minBase>uint32");
        require(maxBase <= type(uint32).max, "DFM:maxBase>uint32");
        if (nb < int256(minBase)) nb = int256(minBase);
        if (nb > int256(maxBase)) nb = int256(maxBase);

        // Prepare return values
        newBase = uint32(uint256(nb));
        // Return the updated word with new base fee and updated lastFee timestamp
        updatedWord = w.setBase(newBase).setLastF(nowTs);
        // No need to return surge/inCap - caller uses final `w`
    }

    /**
     * @dev Calculates current surge fee based on cap start time and decay period.
     */
    function _surge(uint256 w, PoolId id) private view returns (uint256) {
        uint48 start = w.capStart();
        if (start == 0) return 0;

        uint32 nowTs = uint32(block.timestamp);                  
        uint32 decay = uint32(policy.getSurgeDecayPeriodSeconds(id));
        // Handle zero decay period
        if (decay == 0) {
            // Surge only exists exactly at start time if decay is zero
            uint256 multPpm = policy.getSurgeFeeMultiplierPpm(PoolId.unwrap(id));
            return (nowTs == start) ? (w.base() * multPpm / 1e6) : 0;
        }

        // Avoid underflow if clock skewed
        uint32 dt = nowTs > start ? nowTs - uint32(start) : 0;   
        // No surge if decay period has passed
        if (dt >= decay) return 0;

        // Linear decay calculation
        uint256 mult = policy.getSurgeFeeMultiplierPpm(PoolId.unwrap(id));
        //   surge(t) = base × mult × (1 – t/decay)
        uint256 maxSurge = w.base() * mult / 1e6;
        return maxSurge * (uint256(decay) - dt) / decay;
    }

    function _startCapEvent(bytes32 poolId, FeeState storage f) internal {
        uint24 mult = policy.getSurgeFeeMultiplierPpm(poolId);
        require(mult != 0, "mult 0");
        unchecked {
            // overflow‑safe: base × mult ≤ 16 777 215
            require(uint256(f.baseFeePpm) * mult <= 16_777_215 * 1e6, "overflow");
        }
        uint24 maxSurge = uint24(uint256(f.baseFeePpm) * mult / 1e6);

        f.surgeFeePpm         = maxSurge;                 // reset to max
        f.surgeStartTimestamp = uint32(block.timestamp);  // restart decay
    }

    function _currentSurge(bytes32 poolId, FeeState storage f)
        internal
        view
        returns (uint24)
    {
        if (f.surgeStartTimestamp == 0) return 0;
        uint32 decay = policy.getSurgeDecaySeconds(poolId);
        // Prevent division by zero
        if (decay == 0) return 0;
        uint32 elapsed = uint32(block.timestamp) - f.surgeStartTimestamp;
        if (elapsed >= decay) return 0;
        return uint24(uint256(f.surgeFeePpm) * (decay - elapsed) / decay);
    }

    // helper to interact with policy manager while minimizing external calls/gas
    function _policy() private view returns (IPoolPolicy p) {
        p = IPoolPolicy(policyManager);
    }

    // Helper methods for fee adjustment
    function _increaseBaseFee(PoolId id) private {
        uint256 w = _s[id];
        
        // Get constraints from policy
        uint256 maxBaseFee = _policy().getMaxBaseFee(id);
        uint32 maxStepPpm = _policy().getMaxStepPpm(PoolId.unwrap(id));
        
        // Calculate current base fee and max step
        uint32 currentBase = w.base();
        uint256 step = (uint256(currentBase) * maxStepPpm) / 1e6;
        if (step == 0) step = 1; // ensure at least 1 PPM increase
        
        // Apply increase with max bound
        uint256 newBase = currentBase + step;
        if (newBase > maxBaseFee) newBase = maxBaseFee;
        
        // Update state
        _s[id] = w.setBase(uint32(newBase)).setLastF(uint32(block.timestamp));
        lastFeeUpdate = uint64(block.timestamp);
    }
    
    function _decreaseBaseFee(PoolId id) private {
        uint256 w = _s[id];
        
        // Get constraints from policy
        uint256 minBaseFee = _policy().getMinBaseFee(id);
        uint32 maxStepPpm = _policy().getMaxStepPpm(PoolId.unwrap(id));
        
        // Calculate current base fee and max step
        uint32 currentBase = w.base();
        uint256 step = (uint256(currentBase) * maxStepPpm) / 1e6;
        if (step == 0) step = 1; // ensure at least 1 PPM decrease
        
        // Apply decrease with min bound
        uint256 newBase = currentBase > step ? currentBase - step : minBaseFee;
        if (newBase < minBaseFee) newBase = minBaseFee;
        
        // Update state
        _s[id] = w.setBase(uint32(newBase)).setLastF(uint32(block.timestamp));
        lastFeeUpdate = uint64(block.timestamp);
    }
}
