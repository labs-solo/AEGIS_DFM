// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

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

    /// @notice Daily budget for CAP events (ppm/day)
    uint32 private _capBudgetDailyPpm;

    /// @notice Linear decay half-life for the budget counter (seconds)
    uint32 private _capBudgetDecayWindow;

    /// @notice Constructor initializes the policy manager with default values
    /// @param _governance The owner of the contract
    /// @param _dailyBudget Initial daily budget
    constructor(address _governance, uint256 _dailyBudget) Owned(_governance) {
        if (_governance == address(0)) revert Errors.ZeroAddress();
        // Initialize global parameters
        _capBudgetDailyPpm = _dailyBudget == 0 ? 1_000_000 : uint32(_dailyBudget);
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
    function getDailyBudgetPpm(PoolId) external view override returns (uint32) {
        // TODO: consider making this per pool
        return _capBudgetDailyPpm;
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

    // === Dynamic Fee Configuration Setters ===

    /// @inheritdoc IPoolPolicyManager
    function setMinBaseFee(PoolId poolId, uint24 newMinFee) external override onlyOwner {
        uint24 maxFee = this.getMaxBaseFee(poolId);
        if (newMinFee < MIN_TRADING_FEE || newMinFee >= maxFee) {
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

        _poolBaseFeeParams[poolId] = BaseFeeParams({stepPpm: stepPpm, updateIntervalSecs: updateIntervalSecs});

        emit BaseFeeParamsSet(poolId, stepPpm, updateIntervalSecs);
    }

    /// @inheritdoc IPoolPolicyManager
    function setDailyBudgetPpm(uint32 ppm) external override onlyOwner {
        _capBudgetDailyPpm = ppm;
        emit DailyBudgetSet(ppm);
    }

    /// @inheritdoc IPoolPolicyManager
    function setDecayWindow(uint32 secs) external override onlyOwner {
        _capBudgetDecayWindow = secs;
        emit GlobalDecayWindowSet(secs);
    }
}
