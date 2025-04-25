// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IDynamicFeeManager} from "./interfaces/IDynamicFeeManager.sol";
import {TruncGeoOracleMulti} from "./TruncGeoOracleMulti.sol";

/*═══════════════════════════════════════╗
║  DynamicFeeManager – single slot      ║
║  ═══════════════════════════════════  ║
║  [0   ..  95]  freq                  ║
║  [96  .. 127]  ⟂ (deprecated)        ║
║  [128 .. 167]  freqL                 ║
║  [168 .. 207]  capSt                 ║
║  [208 .. 239]  lastF                 ║
║  [255]         C                     ║
╚═══════════════════════════════════════*/

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
         │     freq      │  ⟂   │freqL │capSt │lastF │ C │
         └────────────────────────────────────────────────┘
         - 15 spare bits (240…254) keep slot <256 bits
         - ⟂ = deprecated field, kept for storage compatibility
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
    function freq(uint256 w)      internal pure returns (uint32) { return uint32(w & MASK_FREQ);                              }
    function freqL(uint256 w)     internal pure returns (uint48) { return uint48((w & MASK_FREQ_LAST) >> FREQ_LAST_OFFSET);     }
    function capStart(uint256 w)  internal pure returns (uint48) { return uint48((w & MASK_CAP_START) >> CAP_START_OFFSET);     }
    function lastFee(uint256 w)   internal pure returns (uint32) { return uint32((w & MASK_LAST_FEE)  >> LAST_FEE_OFFSET);      }
    function inCap(uint256 w)     internal pure returns (bool)   { return (w & MASK_IN_CAP) != 0;                               }

    /* -------- setters (internal only) -------- */
    function _set(uint256 w, uint256 mask, uint256 v, uint256 shift) private pure returns (uint256) {
        return (w & ~mask) | (v << shift);
    }
    function setFreq  (uint256 w, uint32  v) internal pure returns (uint256){ return _set(w, MASK_FREQ,      v, 0);                  }
    function setFreqL (uint256 w, uint40  v) internal pure returns (uint256){ return _set(w, MASK_FREQ_LAST, v, FREQ_LAST_OFFSET);   }
    function setCapSt (uint256 w, uint40  v) internal pure returns (uint256){ return _set(w, MASK_CAP_START, v, CAP_START_OFFSET);   }
    function setInCap (uint256 w, bool   y) internal pure returns (uint256){ return y ? w | MASK_IN_CAP : w & ~MASK_IN_CAP;         }
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

    /// direct handle to the oracle (for cap → fee mapping)
    TruncGeoOracleMulti public immutable oracle;

    /// @dev per‑pool state word
    mapping(PoolId => uint256) private _s;

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
     * @notice Constructor
     * @param _policyManager Address of the policy manager contract
     * @param _oracle Address of the oracle contract for deriving base fees
     * @param _authorizedHook Address of the single hook authorized to call `notifyOracleUpdate`
     */
    constructor(
        IPoolPolicy _policyManager,
        address _oracle,
        address _authorizedHook
    ) {
        require(address(_policyManager) != address(0), "DFM: policy 0");
        require(_oracle != address(0), "DFM: oracle 0");
        require(_authorizedHook != address(0), "DFM: hook 0");
        policy = _policyManager;
        policyManager = _policyManager;
        oracle = TruncGeoOracleMulti(_oracle);
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
        // base-fee is now derived from the oracle → no need to persist it;
        // we only store the frequency accumulator and its timestamp.
        w = w.setFreq(def).setFreqL(uint40(ts));
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
    function notifyOracleUpdate(PoolId id, bool capped) external override onlyHook {
        uint256 w1 = _s[id];
        require(w1 != 0, "DFM: not init");
        uint256 initialW = w1;
        uint48 nowTs = uint48(block.timestamp);

        // --- Apply frequency decay (for surge logic only) -------------
        uint32 window = _policy().getCapBudgetDecayWindow(PoolId.unwrap(id));
        if (window > 0) {
            uint32 freq = w1.freq();
            uint32 lastTs = w1.lastFee();
            if (lastTs < nowTs) {
                uint32 elapsed = uint32(nowTs - lastTs);
                freq = _decayFreq(freq, elapsed, window);
                w1 = w1.setFreq(freq);
            }
            if (capped) {
                w1 = w1.setFreq(freq + 1);
            }
        }

        /* derive base-fee from current cap (no storage write required) */
        uint24 cap = oracle.getMaxTicksPerBlock(PoolId.unwrap(id));
        uint32 newBase = uint32(uint256(cap) * 100); // 100 ppm per tick

        // --- Emit event if externally-visible state changed -----------
        uint256 maskIgnoreTime = ~(_P.MASK_FREQ_LAST | _P.MASK_LAST_FEE);
        if ((w1 & maskIgnoreTime) != (initialW & maskIgnoreTime)) {
            uint256 baseNow = uint256(
                TruncGeoOracleMulti(address(oracle))
                    .getMaxTicksPerBlock(PoolId.unwrap(id))
            ) * 100;
            uint256 finalSurge = _surge(id, w1);
            emit FeeStateChanged(id, uint24(baseNow), finalSurge, w1.inCap());
        }

        _s[id] = w1; // Final single SSTORE
    }

    /// @notice View function for monitoring tools to track last fee update time
    /// @dev This replaces direct storage reads of lastF which is now deprecated
    function getLastFeeUpdate() external view returns (uint64) {
        return lastFeeUpdate;
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

        // -------- logic: fee = cap × 100 ppm   (1 tick ≃ 0.01 %) -------
        uint24 cap = TruncGeoOracleMulti(address(oracle))
                        .getMaxTicksPerBlock(PoolId.unwrap(id));
        baseFee = uint256(cap) * 100;                      // safe: < 2³²
        //-----------------------------------------------------------------

        surgeFee = _surge(id, w);
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

    /* ─── internal helpers ─────────────────────────────────── */

    function _surge(PoolId id, uint256 w) private view returns (uint256) {
        uint48 start = w.capStart();
        if (start == 0) return 0;

        uint32 nowTs = uint32(block.timestamp);
        uint32 decay = uint32(policy.getSurgeDecayPeriodSeconds(id));

        // Handle zero decay period
        if (decay == 0) {
            return 0;
        }

        // Avoid underflow if clock skewed
        uint32 dt = nowTs > start ? nowTs - uint32(start) : 0;
        // No surge if decay period has passed
        if (dt >= decay) return 0;

        // base-fee is derived live from oracle cap
        uint256 base = uint256(
            TruncGeoOracleMulti(address(oracle))
                .getMaxTicksPerBlock(PoolId.unwrap(id))
        ) * 100;

        // Linear decay calculation
        uint256 mult = policy.getSurgeFeeMultiplierPpm(PoolId.unwrap(id));
        uint256 maxSurge = base * mult / 1e6;
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

    /**
     * @dev Applies linear decay to frequency counter based on elapsed time and window
     * @param freq Current frequency value
     * @param elapsed Time elapsed since last update
     * @param window Decay window period
     * @return Decayed frequency value
     */
    function _decayFreq(uint32 freq, uint32 elapsed, uint32 window) private pure returns (uint32) {
        if (elapsed >= window) return 0;
        return uint32((uint256(freq) * (window - elapsed)) / window);
    }

    /// @notice Convenience view used *only* by unit tests.
    function baseFeeFromCap(PoolId id) external view returns (uint256) {
        uint24 cap = oracle.getMaxTicksPerBlock(PoolId.unwrap(id));
        return uint256(cap) * 100;       // 100 ppm per tick
    }

    /*  
     * Base fee is derived directly from oracle cap (cap × 100 ppm)
     * The base field in storage is deprecated and kept only for backwards compatibility
     * TODO: Remove base field in next storage-breaking version
     */
}
