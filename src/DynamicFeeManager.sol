// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
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
    uint256 constant BASE_OFFSET = 96;
    uint256 constant FREQ_LAST_OFFSET = BASE_OFFSET + 32; // 128
    uint256 constant CAP_START_OFFSET = FREQ_LAST_OFFSET + 40; // 168
    uint256 constant LAST_FEE_OFFSET = CAP_START_OFFSET + 40; // 208
    uint256 constant IN_CAP_OFFSET = 255; // fits

    // bit masks
    uint256 constant MASK_FREQ = (uint256(1) << BASE_OFFSET) - 1; // 96-bit
    uint256 constant MASK_BASE = ((uint256(1) << 32) - 1) << BASE_OFFSET; // 32-bit
    uint256 constant MASK_FREQ_LAST = ((uint256(1) << 40) - 1) << FREQ_LAST_OFFSET; // 40-bit
    uint256 constant MASK_CAP_START = ((uint256(1) << 40) - 1) << CAP_START_OFFSET; // 40-bit
    uint256 constant MASK_LAST_FEE = ((uint256(1) << 32) - 1) << LAST_FEE_OFFSET; // 32-bit
    uint256 constant MASK_IN_CAP = uint256(1) << IN_CAP_OFFSET; // 1-bit

    /* -------- accessors (return sizes kept for ABI stability) -------- */
    function freq(uint256 w) internal pure returns (uint96) {
        return uint96(w & MASK_FREQ);
    }

    function freqL(uint256 w) internal pure returns (uint48) {
        return uint48((w & MASK_FREQ_LAST) >> FREQ_LAST_OFFSET);
    }

    function capStart(uint256 w) internal pure returns (uint48) {
        return uint48((w & MASK_CAP_START) >> CAP_START_OFFSET);
    }

    function lastFee(uint256 w) internal pure returns (uint32) {
        return uint32((w & MASK_LAST_FEE) >> LAST_FEE_OFFSET);
    }

    function inCap(uint256 w) internal pure returns (bool) {
        return (w & MASK_IN_CAP) != 0;
    }

    /* -------- setters (internal only) -------- */
    function _set(uint256 w, uint256 mask, uint256 v, uint256 shift) private pure returns (uint256) {
        return (w & ~mask) | (v << shift);
    }

    function setFreq(uint256 w, uint96 v) internal pure returns (uint256) {
        return _set(w, MASK_FREQ, v, 0);
    }

    function setFreqL(uint256 w, uint40 v) internal pure returns (uint256) {
        return _set(w, MASK_FREQ_LAST, v, FREQ_LAST_OFFSET);
    }

    function setCapSt(uint256 w, uint40 v) internal pure returns (uint256) {
        return _set(w, MASK_CAP_START, v, CAP_START_OFFSET);
    }

    function setInCap(uint256 w, bool y) internal pure returns (uint256) {
        return y ? w | MASK_IN_CAP : w & ~MASK_IN_CAP;
    }
}

using _P for uint256; // Enable freqL(), setFreqL(), and other helpers

/* ───────────────────────────────────────────────────────────── */

// Renamed contract, implements the NEW interface
contract DynamicFeeManager is IDynamicFeeManager {
    using _P for uint256;
    using PoolIdLibrary for PoolId;

    /* ─── constants ─────────────────────────────────────────── */
    /// @dev fallback base-fee when the oracle has no data yet (0.5 %)
    uint32 internal constant DEFAULT_BASE_FEE_PPM = 5_000;

    /// @notice emitted when `initialize` is called on an already-initialized pool
    event AlreadyInitialized(PoolId indexed id);

    /// @notice emitted when a pool is successfully initialized
    event PoolInitialized(PoolId indexed id);

    /* ─── config / state ─────────────────────────────────────── */
    IPoolPolicy public immutable policy;
    address public immutable owner;
    /// @notice address allowed to call `notifyOracleUpdate` – owner may rotate
    address public authorizedHook;

    /// direct handle to the oracle (for cap → fee mapping)
    TruncGeoOracleMulti public immutable oracle;

    /// @dev per-pool state word – we only use `capStart` + `inCap`
    mapping(PoolId => uint256) private _s;

    /* ─── constructor / init ─────────────────────────────────── */
    constructor(IPoolPolicy _policyManager, address _oracle, address _authorizedHook) {
        require(address(_policyManager) != address(0), "DFM: policy 0");
        require(_oracle != address(0), "DFM: oracle 0");
        require(_authorizedHook != address(0), "DFM: hook 0");
        policy = _policyManager; // immutable handle for surge-knobs
        oracle = TruncGeoOracleMulti(_oracle);
        owner = msg.sender;
        authorizedHook = _authorizedHook;
    }

    function initialize(PoolId id, int24 /*initialTick*/ ) external override {
        // Allow either the protocol owner **or** the hook we explicitly trust
        // (owner set `authorizedHook` in the constructor).
        require(msg.sender == owner || msg.sender == authorizedHook, "DFM:auth");
        if (_s[id] != 0) {
            emit AlreadyInitialized(id);
            return;
        }

        // Get the initial base fee (`maxTicks * 100`) or fall back to the default
        uint256 baseFee = uint256(oracle.getMaxTicksPerBlock(PoolId.unwrap(id))) * 100;
        if (baseFee == 0) baseFee = DEFAULT_BASE_FEE_PPM;

        // Initialize state with the base fee
        uint32 ts = uint32(block.timestamp);
        uint256 w = _s[id]; // Read existing state in case freq decay happened
        w = w.setFreqL(uint40(ts)); // Use freqLastUpdate as non-zero marker
        w = w.setFreq(uint96(baseFee)); // Set initial base fee
        _s[id] = w;

        emit PoolInitialized(id);
    }

    function notifyOracleUpdate(PoolId poolId, bool tickWasCapped) external override {
        _requireHookAuth(); // Ensure only authorized hook can call

        uint256  w  = _s[poolId];
        require(w != 0, "DFM: not init");

        uint32   nowTs    = uint32(block.timestamp);
        uint256  w1       = w;              // scratch copy (cheaper mutations)

        // ── cache fee snapshot *before* state mutation ───────────────────────
        uint256 oldBase  = _baseFee(poolId);
        uint256 oldSurge = _surge(poolId, w1);

        // ---- CAP-event handling ---------------------------------------
        if (tickWasCapped) {
            /**
             * OPTION B – Every capped-swap **resets** the surge-timer.
             * `inCap` stays true; we simply stamp a fresh `capStart`
             * so `_surge()` returns the full surge again.
             */
            w1 = w1.setInCap(true).setCapSt(uint40(nowTs));
        } else if (w1.inCap()) {
            /**
             * Only clear `inCap` once the surge component has fully
             * decayed to zero.  This prevents premature exit while a
             * residual fee bump is still active.
             */
            if (_surge(poolId, w1) == 0) {
                w1 = w1.setInCap(false);
            }
        }

        // ── persist + emit only when *fee* actually changed ─────────────
        if (w1 != w) {
            _s[poolId] = w1;                              // single SSTORE

            uint256 newBase  = _baseFee(poolId);
            uint256 newSurge = _surge(poolId, w1);

            if (newBase != oldBase || newSurge != oldSurge) {
                emit FeeStateChanged(poolId, newBase, newSurge, w1.inCap());
            }
        }
    }

    /* ── stateless base-fee helper ───────────────────────────────────── */
    function _baseFee(PoolId id) private view returns (uint256) {
        uint256 fee = uint256(oracle.getMaxTicksPerBlock(PoolId.unwrap(id))) * 100;
        return fee == 0 ? DEFAULT_BASE_FEE_PPM : fee;
    }

    /* ─── public views ───────────────────────────────────────── */
    function getFeeState(PoolId id) external view override returns (uint256 baseFee, uint256 surgeFee) {
        uint256 w = _s[id];
        require(w != 0, "DFM: not init");

        baseFee = _baseFee(id);
        surgeFee = _surge(id, w);
    }

    function isCAPEventActive(PoolId id) external view override returns (bool) {
        uint256 w = _s[id];
        require(w != 0, "DFM: not init");
        return w.inCap();
    }

    /// @notice convenience view (used by unit-tests)
    function baseFeeFromCap(PoolId id) external view returns (uint32) {
        return uint32(_baseFee(id));
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

        uint256 base = _baseFee(id);

        // Linear decay calculation
        uint256 mult = policy.getSurgeFeeMultiplierPpm(id);
        uint256 maxSurge = base * mult / 1e6;
        return maxSurge * (uint256(decay) - dt) / decay;
    }

    /* base-fee is *always* cap × 100 ppm – no step-engine state */

    /// @notice governance-only: rotate the authorized hook
    function setAuthorizedHook(address newHook) external {
        require(msg.sender == owner, "DFM:!owner");
        require(newHook != address(0), "DFM:hook 0");
        authorizedHook = newHook;
    }

    function _requireHookAuth() internal view {
        require(msg.sender == authorizedHook, "DFM:!auth");
    }
}
