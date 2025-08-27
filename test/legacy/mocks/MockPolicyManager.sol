// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {IPoolPolicyManager} from "src/interfaces/IPoolPolicyManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import "forge-std/Test.sol";
import {PolicyValidator} from "src/libraries/PolicyValidator.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/*  VERY-LIGHT policy stub – **does not** inherit the full interface       */
/*  (only selectors the oracle touches are implemented).                   */
/* ----------------------------------------------------------------------- */
contract MockPolicyManager is IPoolPolicyManager {
    // ───────────────────────── Tunable constants ─────────────────────────
    uint24 internal constant _DEFAULT_MAX_TICKS = 50; // ← initial cap in ticks
    uint32 internal constant _DAILY_BUDGET_PPM = 100_000; // 10 % of the day may be capped
    uint32 internal constant _DECAY_WINDOW_SEC = 43_200; // 12-hour half-life
    uint32 internal constant _UPDATE_INTERVAL_SEC = 86_400; // 24 h
    uint32 internal constant _STEP_PPM = 20_000; // 2 % change per step

    // fee values are expressed in *hundredths of a tick* inside TruncGeoOracleMulti
    // so dividing by 100 should yield the target cap in ticks.
    uint256 internal constant _MIN_BASE_FEE = 1_000; // → 10 ticks
    uint256 internal constant _MAX_BASE_FEE = 10_000; // → 100 ticks

    uint32 public dailyPpm;
    uint32 public decayWindow;
    uint32 public dailyBudget;
    uint32 public dailyBudgetPpm;
    mapping(PoolId => uint32) public freqScalingPpm;

    /* ------------------------------------------------------------------ */
    /*                     simple allow-lists for tests                    */
    /* ------------------------------------------------------------------ */
    mapping(uint24 => bool) private _tickSupported;
    mapping(address => bool) private _currencySupported;

    /* configurable per-pool parameters - all have sensible non-zero defaults */
    struct Params {
        uint256 minBaseFee; // wei
        uint256 maxBaseFee; // wei
        uint256 freqScaling; // 1e18 = no-scale
        uint32 stepPpm;
        uint32 budgetPpm;
        uint32 decayWindow;
        uint32 updateInterval;
        uint24 defaultMaxTicks;
        uint24 minCap; // New
        uint24 maxCap; // New
    }

    mapping(PoolId => Params) internal _p;

    constructor() {
        // tick-spacing used in the test poolKey
        _tickSupported[60] = true;
        // currencies used in the test poolKey
        _currencySupported[address(0xA11CE)] = true;
        _currencySupported[address(0xB0B)] = true;
    }

    // NOTE: no longer part of the IPoolPolicyManager interface – keep for test convenience (no override)
    function isTickSpacingSupported(uint24 tickSpacing) external view returns (bool) {
        return _tickSupported[tickSpacing];
    }

    // NOTE: helper retained only for tests – not part of prod interface
    function isSupportedCurrency(Currency currency) external view returns (bool) {
        return _currencySupported[Currency.unwrap(currency)];
    }

    function isValidVtier(uint24, /* _fee */ int24 /* _spacing */ ) external pure returns (bool) {
        return true; // Assume valid for tests
    }

    // --- Stubs for missing IPoolPolicyManager functions ---
    // Minimal governance stub – not in prod interface
    function getSoloGovernance() external pure returns (address) {
        return address(0);
    }

    // Deprecated interface methods retained for legacy tests (no override)
    function initializePolicies(PoolId, address, address[] calldata) external {}
    function handlePoolInitialization(PoolId, PoolKey calldata, uint160, int24, address) external {}

    function getFeeAllocations(PoolId)
        external
        pure
        returns (uint256 polShare, uint256 fullRangeShare, uint256 lpShare)
    {
        return (0, 0, 0);
    }

    function getMinimumPOLTarget(PoolId, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    // Not in current interface
    function getFeeClaimThreshold() external pure returns (uint256) {
        return 0;
    }

    // Removed from interface – keep as no-ops without override
    function setPoolPOLMultiplier(PoolId, uint32) external {}
    function setDefaultPOLMultiplier(uint32) external {}


    function setPoolSpecificPOLSharingEnabled(bool) external {}

    function getPoolPOLShare(PoolId) external pure returns (uint256) {
        return 0;
    }

    function updateSupportedTickSpacing(uint24, bool) external {}
    function batchUpdateAllowedTickSpacings(uint24[] calldata, bool[] calldata) external {}

    function getProtocolFeePercentage(PoolId) external pure returns (uint256 feePercentage) {
        return 0;
    }

    function getFeeCollector() external pure returns (address) {
        return address(0);
    }

    function getSurgeDecayPeriodSeconds(PoolId) external pure override returns (uint32) {
        return 0;
    }

    function getSurgeFeeMultiplierPpm(PoolId) external pure override returns (uint24) {
        return 0;
    }

    function getDefaultDailyBudgetPpm() external view override returns (uint32) {
        return 0;
    }

    function getBaseFeeFactor(PoolId poolId) external view returns (uint32) {
        return 100; // Default base fee factor
    }

    // --- New functions ---

    // Stubbed functions required by interface
    function setCapBudgetDecayWindow(PoolId, uint32) external override {}
    function setDailyBudgetPpm(uint32) external override {}
    function setDecayWindow(uint32) external override {}
    function setPoolDailyBudgetPpm(PoolId poolId, uint32 newBudget) external override {}

    function setBaseFeeParams(PoolId, uint32, uint32) external override {}

    function setManualFee(PoolId, uint24) external override {}
    function clearManualFee(PoolId) external override {}

    function getManualFee(PoolId) external pure override returns (uint24 manualFee, bool isSet) {
        return (0, false);
    }

    // Not part of the interface anymore – keep for tests without override
    function getDefaultDynamicFee() external pure returns (uint256) {
        return _MAX_BASE_FEE;
    }

    /* ----------- setters for tests ----------- */
    function setParams(PoolId pid, Params memory p) external {
        // shared invariant checks (Rule 3: never skip validation in mocks)
        PolicyValidator.validate(
            SafeCast.toUint24(p.minBaseFee / 100),
            SafeCast.toUint24(p.maxBaseFee / 100),
            p.stepPpm,
            p.budgetPpm,
            p.decayWindow,
            p.updateInterval
        );
        _p[pid] = p;
    }

    function setMinBaseFee(PoolId id, uint24 fee) external {
        _p[id].minBaseFee = fee;
    }

    function setMaxBaseFee(PoolId id, uint24 fee) external {
        _p[id].maxBaseFee = fee;
    }

    function setBaseFeeFactor(PoolId poolId, uint32 factor) external {}

    /* ----------- getters used by the oracle ----------- */
    function getMinBaseFee(PoolId id) external view override returns (uint24) {
        return uint24(_p[id].minBaseFee != 0 ? _p[id].minBaseFee : 100);
    }

    function getMaxBaseFee(PoolId id) external view override returns (uint24) {
        return uint24(_p[id].maxBaseFee != 0 ? _p[id].maxBaseFee : 10_000);
    }

    function getBaseFeeStepPpm(PoolId id) external view override returns (uint32) {
        return _p[id].stepPpm != 0 ? _p[id].stepPpm : 50_000;
    }

    function getDailyBudgetPpm(PoolId id) external view override returns (uint32) {
        return _p[id].budgetPpm != 0 ? _p[id].budgetPpm : 100_000;
    }

    function getCapBudgetDecayWindow(PoolId id) external view override returns (uint32) {
        return _p[id].decayWindow != 0 ? _p[id].decayWindow : 86_400;
    }

    function getBaseFeeUpdateIntervalSeconds(PoolId id) external view override returns (uint32) {
        return _p[id].updateInterval != 0 ? _p[id].updateInterval : 600;
    }

    function getDefaultMaxTicksPerBlock(PoolId id) external view override returns (uint24) {
        return _p[id].defaultMaxTicks != 0 ? _p[id].defaultMaxTicks : 50;
    }

    /* ----------- new selector needed by interface ----------- */

    // Add missing interface implementations
    function setSurgeDecayPeriodSeconds(PoolId, uint32) external override {}
    function setSurgeFeeMultiplierPpm(PoolId, uint24) external override {}

    // Add missing getMinCap and getMaxCap functions
    function getMinCap(PoolId poolId) external view override returns (uint24) {
        uint24 minCap = _p[poolId].minCap;
        return minCap == 0 ? 5 : minCap; // Default to 5 ticks if not set
    }

    function getMaxCap(PoolId poolId) external view override returns (uint24) {
        uint24 maxCap = _p[poolId].maxCap;
        return maxCap == 0 ? 200 : maxCap; // Default to 200 ticks if not set
    }

    // Add setter functions for testing
    function setMinCap(PoolId poolId, uint24 minCap) external {
        _p[poolId].minCap = minCap;
    }

    function setMaxCap(PoolId poolId, uint24 maxCap) external {
        _p[poolId].maxCap = maxCap;
    }

    // Add missing setPoolPOLShare function
    function setPoolPOLShare(PoolId, uint256) external override {}

    // Add missing perSwap mode functions
    function getPerSwapMode(PoolId) external pure override returns (bool) {
        return true; // Default to perSwap mode
    }
    
    function setPerSwapMode(PoolId, bool) external override {
        // No-op for mock
    }

    // Add global default perSwap mode functions
    function getDefaultPerSwapMode() external pure returns (bool) {
        return true; // Default to perSwap mode
    }
    
    function setDefaultPerSwapMode(bool) external {
        // No-op for mock
    }
}
