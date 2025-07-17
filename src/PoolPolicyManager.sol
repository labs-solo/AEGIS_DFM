// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

// - - - Solmate Deps - - -

import {Owned} from "solmate/src/auth/Owned.sol";

// - - - V4 Deps - - -

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

// - - - Project Deps - - -

import {PrecisionConstants} from "./libraries/PrecisionConstants.sol";
import {Errors} from "./errors/Errors.sol";
import {PolicyManagerErrors} from "./errors/PolicyManagerErrors.sol";
import {IPoolPolicyManager} from "./interfaces/IPoolPolicyManager.sol";

/// @title PoolPolicyManager
/// @notice Consolidated policy manager implementing the IPoolPolicyManager interface
/// @dev Handles all policy functionality for pool configuration and fee management
contract PoolPolicyManager is IPoolPolicyManager, Owned {
    // === Constants ===

    uint24 private constant MIN_TRADING_FEE = 100; // 0.01%
    uint24 private constant MAX_TRADING_FEE = 50_000; // 5%

    uint32 private constant DEFAULT_CAP_BUDGET_DECAY_WINDOW = 15_552_000;
    uint32 private constant DEFAULT_SURGE_DECAY_PERIOD_SECONDS = 3600;
    uint24 private constant DEFAULT_SURGE_FEE_MULTIPLIER_PPM = 3_000_000;

    uint24 private constant DEFAULT_MAX_TICKS_PER_BLOCK = 50;

    /// @notice Maximum step for base fee updates (10% per step)
    uint32 private constant MAX_STEP_PPM = 100_000;

    /// @notice Default base fee step size (2% per step)
    uint32 private constant DEFAULT_BASE_FEE_STEP_PPM = 20_000;

    /// @notice Default base fee update interval (1 day)
    uint32 private constant DEFAULT_BASE_FEE_UPDATE_INTERVAL_SECS = 1 days;

    /// @notice Default base fee factor (1 tick = 100 PPM)
    uint32 private constant DEFAULT_BASE_FEE_FACTOR_PPM = 100;

    /// @notice Maximum base fee factor to prevent overflow (1 tick = 1000 PPM max)
    uint32 private constant MAX_BASE_FEE_FACTOR_PPM = 1000;

    // === Dynamic Fee Configuration Struct ===

    struct DynamicFeeConfig {
        uint32 capBudgetDecayWindow;
        uint24 minBaseFeePpm;
        uint24 maxBaseFeePpm;
        uint32 surgeDecayPeriodSeconds;
        uint24 surgeFeeMultiplierPpm;
    }

    struct BaseFeeParams {
        uint32 stepPpm;
        uint32 updateIntervalSecs;
    }

    // === State Variables ===

    /// @notice Manual fee override per pool (if non-zero)
    mapping(PoolId => uint24) private _poolManualFee;

    /// @notice Flag to indicate if a manual fee is set for a pool
    mapping(PoolId => bool) private _hasPoolManualFee;

    /// @notice Pool-specific POL share percentages
    mapping(PoolId => uint256) private _poolPolSharePpm;

    /// @notice Pool-specific dynamic fee configurations
    mapping(PoolId => DynamicFeeConfig) private _poolDynamicFeeConfig;

    /// @notice Base fee parameters per pool
    mapping(PoolId => BaseFeeParams) private _poolBaseFeeParams;

    /// @notice Default daily budget for CAP events (ppm/day) 1e6 is 1 per day, 1e7 is 10 per day
    uint32 private _defaultCapBudgetDailyPpm;

    /// @notice Pool-specific daily budget for CAP events (0 means use default)
    mapping(PoolId => uint32) private _poolCapBudgetDailyPpm;

    /// @notice Linear decay half-life for the budget counter (seconds)
    uint32 private _capBudgetDecayWindow;

    /// @notice Pool-specific base fee factor for converting oracle ticks to PPM
    mapping(PoolId => uint32) private _poolBaseFeeFactor;

    /// @notice Constructor initializes the policy manager with default values
    /// @param _governance The owner of the contract
    /// @param _dailyBudget Initial daily budget
    constructor(address _governance, uint256 _dailyBudget) Owned(_governance) {
        if (_governance == address(0)) revert Errors.ZeroAddress();
        // Initialize global parameters
        _defaultCapBudgetDailyPpm = _dailyBudget == 0 ? 1_000_000 : uint32(_dailyBudget);
        _capBudgetDecayWindow = 15_552_000; // 180 days
    }

    // === Fee Allocation Functions ===

    /// @inheritdoc IPoolPolicyManager
    function setPoolPOLShare(PoolId poolId, uint256 newPolSharePpm) external override onlyOwner {
        // Validate POL share is within valid range (0-100%)
        if (newPolSharePpm > PrecisionConstants.PPM_SCALE) {
            revert Errors.ParameterOutOfRange(newPolSharePpm, 0, PrecisionConstants.PPM_SCALE);
        }

        uint256 oldShare = _poolPolSharePpm[poolId];
        if (oldShare != newPolSharePpm) {
            _poolPolSharePpm[poolId] = newPolSharePpm;
            emit PoolPOLShareChanged(poolId, newPolSharePpm);
        }
    }

    /// @inheritdoc IPoolPolicyManager
    function getPoolPOLShare(PoolId poolId) external view override returns (uint256 poolSpecificPolShare) {
        poolSpecificPolShare = _poolPolSharePpm[poolId];
    }

    // === Manual Fee Override Functions ===

    /// @inheritdoc IPoolPolicyManager
    function getManualFee(PoolId poolId) external view override returns (uint24 manualFee, bool isSet) {
        return (_poolManualFee[poolId], _hasPoolManualFee[poolId]);
    }

    /// @inheritdoc IPoolPolicyManager
    function setManualFee(PoolId poolId, uint24 manualFee) external override onlyOwner {
        if (manualFee < MIN_TRADING_FEE || manualFee > MAX_TRADING_FEE) {
            revert Errors.ParameterOutOfRange(manualFee, MIN_TRADING_FEE, MAX_TRADING_FEE);
        }

        _poolManualFee[poolId] = manualFee;
        _hasPoolManualFee[poolId] = true;

        emit ManualFeeSet(poolId, manualFee);
    }

    /// @inheritdoc IPoolPolicyManager
    function clearManualFee(PoolId poolId) external override onlyOwner {
        if (_hasPoolManualFee[poolId]) {
            _poolManualFee[poolId] = 0;
            _hasPoolManualFee[poolId] = false;

            emit ManualFeeSet(poolId, 0);
        }
    }

    // === Dynamic Fee Configuration Getters ===

    /// @inheritdoc IPoolPolicyManager
    function getMinBaseFee(PoolId poolId) external view override returns (uint24) {
        if (_poolDynamicFeeConfig[poolId].minBaseFeePpm != 0) {
            return _poolDynamicFeeConfig[poolId].minBaseFeePpm;
        }
        return MIN_TRADING_FEE;
    }

    /// @inheritdoc IPoolPolicyManager
    function getMaxBaseFee(PoolId poolId) external view override returns (uint24) {
        if (_poolDynamicFeeConfig[poolId].maxBaseFeePpm != 0) {
            return _poolDynamicFeeConfig[poolId].maxBaseFeePpm;
        }
        return MAX_TRADING_FEE;
    }

    /// @inheritdoc IPoolPolicyManager
    function getSurgeDecayPeriodSeconds(PoolId poolId) external view override returns (uint32) {
        if (_poolDynamicFeeConfig[poolId].surgeDecayPeriodSeconds != 0) {
            return _poolDynamicFeeConfig[poolId].surgeDecayPeriodSeconds;
        }
        return DEFAULT_SURGE_DECAY_PERIOD_SECONDS;
    }

    /// @inheritdoc IPoolPolicyManager
    function getSurgeFeeMultiplierPpm(PoolId poolId) external view override returns (uint24) {
        if (_poolDynamicFeeConfig[poolId].surgeFeeMultiplierPpm != 0) {
            return _poolDynamicFeeConfig[poolId].surgeFeeMultiplierPpm;
        }
        return DEFAULT_SURGE_FEE_MULTIPLIER_PPM;
    }

    /// @inheritdoc IPoolPolicyManager
    function getDefaultDailyBudgetPpm() external view override returns (uint32) {
        return _defaultCapBudgetDailyPpm;
    }

    /// @inheritdoc IPoolPolicyManager
    function getDailyBudgetPpm(PoolId poolId) external view override returns (uint32) {
        uint32 poolBudget = _poolCapBudgetDailyPpm[poolId];
        return poolBudget == 0 ? _defaultCapBudgetDailyPpm : poolBudget;
    }

    /// @inheritdoc IPoolPolicyManager
    function getCapBudgetDecayWindow(PoolId poolId) external view override returns (uint32) {
        if (_poolDynamicFeeConfig[poolId].capBudgetDecayWindow != 0) {
            return _poolDynamicFeeConfig[poolId].capBudgetDecayWindow;
        }
        return _capBudgetDecayWindow;
    }

    /// @inheritdoc IPoolPolicyManager
    function getDefaultMaxTicksPerBlock(PoolId) external pure override returns (uint24) {
        return DEFAULT_MAX_TICKS_PER_BLOCK;
    }

    /// @inheritdoc IPoolPolicyManager
    function getBaseFeeStepPpm(PoolId poolId) public view override returns (uint32) {
        uint32 val = _poolBaseFeeParams[poolId].stepPpm;
        return val == 0 ? DEFAULT_BASE_FEE_STEP_PPM : val;
    }

    /// @inheritdoc IPoolPolicyManager
    function getBaseFeeUpdateIntervalSeconds(PoolId poolId) public view override returns (uint32) {
        uint32 val = _poolBaseFeeParams[poolId].updateIntervalSecs;
        return val == 0 ? DEFAULT_BASE_FEE_UPDATE_INTERVAL_SECS : val;
    }

    /// @inheritdoc IPoolPolicyManager
    function getBaseFeeFactor(PoolId poolId) external view override returns (uint32) {
        uint32 factor = _poolBaseFeeFactor[poolId];
        return factor == 0 ? DEFAULT_BASE_FEE_FACTOR_PPM : factor;
    }

    // === Dynamic Fee Configuration Setters ===

    /// @inheritdoc IPoolPolicyManager
    function setMinBaseFee(PoolId poolId, uint24 newMinFee) external override onlyOwner {
        uint24 maxFee = this.getMaxBaseFee(poolId);
        if (newMinFee < MIN_TRADING_FEE || newMinFee > maxFee) {
            revert PolicyManagerErrors.InvalidFeeRange(newMinFee, MIN_TRADING_FEE, maxFee);
        }
        _poolDynamicFeeConfig[poolId].minBaseFeePpm = newMinFee;
        emit MinBaseFeeSet(poolId, newMinFee);
    }

    /// @inheritdoc IPoolPolicyManager
    function setMaxBaseFee(PoolId poolId, uint24 newMaxFee) external override onlyOwner {
        uint24 minFee = this.getMinBaseFee(poolId);
        if (newMaxFee < minFee || newMaxFee > MAX_TRADING_FEE) {
            revert PolicyManagerErrors.InvalidFeeRange(newMaxFee, minFee, MAX_TRADING_FEE);
        }
        _poolDynamicFeeConfig[poolId].maxBaseFeePpm = newMaxFee;
        emit MaxBaseFeeSet(poolId, newMaxFee);
    }

    /// @inheritdoc IPoolPolicyManager
    function setCapBudgetDecayWindow(PoolId poolId, uint32 newCapBudgetDecayWindow) external override onlyOwner {
        if (newCapBudgetDecayWindow == 0 || newCapBudgetDecayWindow > type(uint32).max) {
            revert Errors.ParameterOutOfRange(newCapBudgetDecayWindow, 1, type(uint32).max);
        }

        _poolDynamicFeeConfig[poolId].capBudgetDecayWindow = newCapBudgetDecayWindow;
        emit CapBudgetDecayWindowSet(poolId, newCapBudgetDecayWindow);
    }

    /// @inheritdoc IPoolPolicyManager
    function setSurgeDecayPeriodSeconds(PoolId poolId, uint32 newSurgeDecayPeriodSeconds) external override onlyOwner {
        if (newSurgeDecayPeriodSeconds < 60 || newSurgeDecayPeriodSeconds > 1 days) {
            revert Errors.ParameterOutOfRange(newSurgeDecayPeriodSeconds, 60, 1 days);
        }

        _poolDynamicFeeConfig[poolId].surgeDecayPeriodSeconds = newSurgeDecayPeriodSeconds;
        emit SurgeDecayPeriodSet(poolId, newSurgeDecayPeriodSeconds);
    }

    /// @inheritdoc IPoolPolicyManager
    function setSurgeFeeMultiplierPpm(PoolId poolId, uint24 multiplier) external override onlyOwner {
        if (multiplier == 0 || multiplier > 3_000_000) revert Errors.ParameterOutOfRange(multiplier, 1, 3_000_000);

        _poolDynamicFeeConfig[poolId].surgeFeeMultiplierPpm = multiplier;
        emit SurgeFeeMultiplierSet(poolId, multiplier);
    }

    /// @inheritdoc IPoolPolicyManager
    function setBaseFeeParams(PoolId poolId, uint32 stepPpm, uint32 updateIntervalSecs) external override onlyOwner {
        if (stepPpm > MAX_STEP_PPM) revert Errors.ParameterOutOfRange(stepPpm, 0, MAX_STEP_PPM);
        if (updateIntervalSecs == 0) {
            revert Errors.ParameterOutOfRange(updateIntervalSecs, 1, type(uint32).max);
        }

        _poolBaseFeeParams[poolId] = BaseFeeParams({stepPpm: stepPpm, updateIntervalSecs: updateIntervalSecs});

        emit BaseFeeParamsSet(poolId, stepPpm, updateIntervalSecs);
    }

    /// @inheritdoc IPoolPolicyManager
    function setDailyBudgetPpm(uint32 newCapBudgetDailyPpm) external override onlyOwner {
        if (newCapBudgetDailyPpm == 0 || newCapBudgetDailyPpm > 10 * PrecisionConstants.PPM_SCALE) {
            revert Errors.ParameterOutOfRange(newCapBudgetDailyPpm, 1, 10 * PrecisionConstants.PPM_SCALE);
        }
        _defaultCapBudgetDailyPpm = newCapBudgetDailyPpm;
        emit DailyBudgetSet(newCapBudgetDailyPpm);
    }

    /// @inheritdoc IPoolPolicyManager
    function setPoolDailyBudgetPpm(PoolId poolId, uint32 newBudget) external override onlyOwner {
        // Validate: 0 means "use default", or 1 to 10*PPM_SCALE
        if (newBudget != 0 && (newBudget < 1 || newBudget > 10 * PrecisionConstants.PPM_SCALE)) {
            revert Errors.ParameterOutOfRange(newBudget, 1, 10 * PrecisionConstants.PPM_SCALE);
        }

        _poolCapBudgetDailyPpm[poolId] = newBudget;
        emit PoolDailyBudgetSet(poolId, newBudget);
    }

    /// @inheritdoc IPoolPolicyManager
    function setDecayWindow(uint32 newCapBudgetDecayWindow) external override onlyOwner {
        if (newCapBudgetDecayWindow == 0) revert PolicyManagerErrors.ZeroValue();
        _capBudgetDecayWindow = newCapBudgetDecayWindow;
        emit GlobalDecayWindowSet(newCapBudgetDecayWindow);
    }

    /// @inheritdoc IPoolPolicyManager
    function setBaseFeeFactor(PoolId poolId, uint32 factor) external override onlyOwner {
        // Validate factor is reasonable (0 means use default)
        if (factor != 0 && (factor < 1 || factor > MAX_BASE_FEE_FACTOR_PPM)) {
            revert Errors.ParameterOutOfRange(factor, 1, MAX_BASE_FEE_FACTOR_PPM);
        }

        _poolBaseFeeFactor[poolId] = factor;
        emit BaseFeeFactorSet(poolId, factor);
    }
}
