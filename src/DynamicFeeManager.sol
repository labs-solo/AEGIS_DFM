// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IDynamicFeeManager} from "./interfaces/IDynamicFeeManager.sol";
import {TruncGeoOracleMulti} from "./TruncGeoOracleMulti.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

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
contract DynamicFeeManager is IDynamicFeeManager, Owned {
    using _P for uint256;
    using PoolIdLibrary for PoolId;

    /* ─── custom errors ──────────────────────────────── */
    error UnauthorizedHook();
    error ZeroHookAddress();
    error NotInitialized();
    error InvalidMaxTicks(uint24 maxTicks);
    error InvalidBaseFee(uint256 baseFee);
    error ZeroPolicyManager();
    error ZeroOracleAddress();
    error AlreadyInitialised();

    /* ─── events ─────────────────────────────────────── */
    /// @notice fired when a CAP event starts or ends
    event CapToggled(PoolId indexed id, bool inCap);

    /// @notice emitted when a pool is successfully initialized
    event PoolInitialized(PoolId indexed id);

    /// @notice emitted when a pool is already initialized
    event AlreadyInitialized(PoolId indexed id);

    /* ─── constants ─────────────────────────────────────────── */
    /// @dev fallback base-fee when the oracle has no data yet (0.5 %)
    uint32 internal constant DEFAULT_BASE_FEE_PPM = 5_000;
    /// @dev oracle ticks → base-fee conversion factor (1 tick = 100 ppm)
    uint256 internal constant BASE_FEE_FACTOR_PPM = 100;

    /* ─── config / state ─────────────────────────────────────── */
    IPoolPolicy public immutable policyManager;
    /// @notice address allowed to call `notifyOracleUpdate` – immutable after deployment
    address public immutable authorizedHook;

    /// direct handle to the oracle (for cap → fee mapping)
    TruncGeoOracleMulti public immutable oracle;

    /// @dev per-pool state word – we only use `capStart` + `inCap`
    mapping(PoolId => uint256) private _s;

    /* ─── modifiers ─────────────────────────────────────── */
    modifier onlyOwnerOrHook() {
        if (msg.sender != owner && msg.sender != authorizedHook) revert UnauthorizedHook();
        _;
    }

    /* ─── constructor / init ─────────────────────────────────── */
    constructor(IPoolPolicy _policyManager, address _oracle, address _authorizedHook) Owned(msg.sender) {
        if (address(_policyManager) == address(0)) revert ZeroPolicyManager();
        if (_oracle == address(0)) revert ZeroOracleAddress();
        if (_authorizedHook == address(0)) revert ZeroHookAddress();
        policyManager = _policyManager; // immutable handle for surge-knobs
        oracle = TruncGeoOracleMulti(_oracle);
        authorizedHook = _authorizedHook;
    }

    function initialize(PoolId id, int24 /*initialTick*/ ) external override onlyOwnerOrHook {
        /* --------------------------------------------------------
         * Idempotency: if the pool is already initialised simply
         * emit a notice and return without mutating state.
         * ------------------------------------------------------*/
        if (_s[id] != 0) {
            emit AlreadyInitialized(id);
            return;
        }

        // Fetch the current maxTicksPerBlock from the associated oracle contract
        uint24 maxTicks = oracle.maxTicksPerBlock(PoolId.unwrap(id)); // Direct call
        uint256 baseFee;
        unchecked { baseFee = uint256(maxTicks) * BASE_FEE_FACTOR_PPM; }

        // Initialize state
        uint32 ts = uint32(block.timestamp);
        uint256 w = _s[id];
        w = w.setFreqL(uint40(ts));
        // Store base fee derived from oracle (could be 0 if oracle returns 0)
        w = w.setFreq(uint96(baseFee));
        _s[id] = w;

        emit PoolInitialized(id);
    }

    function notifyOracleUpdate(PoolId poolId, bool tickWasCapped) external override {
        _requireHookAuth(); // Ensure only authorized hook can call

        uint256 w = _s[poolId];
        if (w == 0) revert NotInitialized();

        uint32 nowTs = uint32(block.timestamp);
        uint256 w1 = w; // scratch copy (cheaper mutations)

        // ── cache fee snapshot *before* state mutation ───────────────────────
        uint256 oldBase = _baseFee(poolId); // Uses direct call internally now
        uint256 oldSurge = _surge(poolId, w1); // Uses direct call internally now

        // ---- CAP-event handling ---------------------------------------
        if (tickWasCapped) {
            w1 = w1.setInCap(true).setCapSt(uint40(nowTs));
            emit CapToggled(poolId, true);
            _s[poolId] = w1; // single SSTORE
            uint256 newBase = _baseFee(poolId);
            uint256 newSurge = _surge(poolId, w1);
            emit FeeStateChanged(poolId, newBase, newSurge, true, nowTs);
        } else if (w1.inCap()) {
            if (_surge(poolId, w1) == 0) {
                // Check if surge decayed
                w1 = w1.setInCap(false);
                emit CapToggled(poolId, false);
                _s[poolId] = w1;
                uint256 newBase = _baseFee(poolId);
                uint256 newSurge = _surge(poolId, w1);
                emit FeeStateChanged(poolId, newBase, newSurge, false, nowTs);
            }
        }
    }

    /* ── stateless base-fee helper ───────────────────────────────────── */
    function _baseFee(PoolId id) private view returns (uint256) {
        uint24 maxTicks = oracle.maxTicksPerBlock(PoolId.unwrap(id)); // Direct call
        uint256 fee;
        unchecked { fee = uint256(maxTicks) * BASE_FEE_FACTOR_PPM; }
        return fee == 0 ? DEFAULT_BASE_FEE_PPM : fee; // Use default if oracle returns 0
    }

    /* ─── public views ───────────────────────────────────────── */
    function getFeeState(PoolId id) external view override returns (uint256 baseFee, uint256 surgeFee) {
        uint256 w = _s[id];
        if (w == 0) revert NotInitialized();

        baseFee = _baseFee(id);
        surgeFee = _surge(id, w);
    }

    function isCAPEventActive(PoolId id) external view override returns (bool) {
        uint256 w = _s[id];
        if (w == 0) revert NotInitialized();
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
        uint32 decay = uint32(policyManager.getSurgeDecayPeriodSeconds(id));

        if (decay == 0) return 0;

        uint32 dt = nowTs > start ? nowTs - uint32(start) : 0;
        if (dt >= decay) return 0;

        // Get current base fee from oracle for surge calculation
        bytes32 poolBytes = PoolId.unwrap(id);
        uint24 maxTicks = oracle.maxTicksPerBlock(poolBytes); // Direct call
        uint256 currentBaseFee;
        unchecked { currentBaseFee = uint256(maxTicks) * BASE_FEE_FACTOR_PPM; }
        if (currentBaseFee == 0) {
            currentBaseFee = DEFAULT_BASE_FEE_PPM; // Use default if oracle returns 0
        }

        uint256 multiplierPpm = policyManager.getSurgeFeeMultiplierPpm(id);
        uint256 maxSurge = currentBaseFee * multiplierPpm / 1e6;
        return maxSurge * (uint256(decay) - dt) / decay;
    }

    function _requireHookAuth() internal view {
        if (msg.sender != authorizedHook) revert UnauthorizedHook();
    }

    /* ---------- Back-compat alias (optional – can be deleted later) ---- */
    /// @dev Temporary shim so older tests that call `.policy()` still compile.
    /// @inheritdoc IDynamicFeeManager
    function policy() external view override returns (IPoolPolicy) {
        return policyManager;
    }

    /// @dev Convenience proxy; no longer declared in this contract's own
    ///      interface, so `override` removed.
    function getCapBudgetDecayWindow(PoolId pid) external view returns (uint32) {
        return policyManager.getCapBudgetDecayWindow(pid);
    }
}
