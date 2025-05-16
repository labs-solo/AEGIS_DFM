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

    /// @notice Maximum step for base fee updates (10% per step)
    uint32 private constant MAX_STEP_PPM = 100_000;

    /// @notice Default base fee step size (2% per step)
    uint32 private constant DEFAULT_BASE_FEE_STEP_PPM = 20_000;

    /// @notice Default base fee update interval (1 day)
    uint32 private constant DEFAULT_BASE_FEE_UPDATE_INTERVAL_SECS = 1 days;

    /// @notice Flag indicating a dynamic fee (0x800000)
    uint24 private constant DYNAMIC_FEE_FLAG = 0x800000;

    // === Fee Configuration Struct ===

    struct FeeConfig {
        uint24 polSharePpm;
        uint24 fullRangeSharePpm;
        uint24 lpSharePpm;
        uint24 minimumTradingFeePpm;
    }

    // === Dynamic Fee Configuration Struct ===

    struct DynamicFeeConfig {
        uint32 targetCapsPerDay;
        uint32 capBudgetDecayWindow;
        uint256 freqScaling;
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

    /// @notice Global fee configuration
    FeeConfig private _defaultFeeConfig;

    /// @notice Global dynamic fee configuration
    DynamicFeeConfig private _defaultDynamicFeeConfig;

    /// @notice Manual fee override per pool (if non-zero)
    mapping(PoolId => uint24) private _poolManualFee;

    /// @notice Flag to indicate if a manual fee is set for a pool
    mapping(PoolId => bool) private _hasPoolManualFee;

    /// @notice Pool-specific POL share percentages
    mapping(PoolId => uint256) private _poolPolSharePpm;

    /// @notice Flag to enable/disable pool-specific POL percentages
    bool private _allowPoolSpecificPolShare;

    /// @notice Pool-specific dynamic fee configurations
    mapping(PoolId => DynamicFeeConfig) private _poolDynamicFeeConfig;

    /// @notice Base fee parameters per pool
    mapping(PoolId => BaseFeeParams) private _poolBaseFeeParams;

    /// @notice Default maximum ticks per block
    uint24 private _defaultMaxTicksPerBlock;

    /// @notice Daily budget for CAP events (ppm/day)
    uint32 private _capBudgetDailyPpm;

    /// @notice Linear decay half-life for the budget counter (seconds)
    uint32 private _capBudgetDecayWindow;

    /// @notice Immutable min base fee
    uint24 public immutable minBaseFeePpm;

    /// @notice Immutable max base fee
    uint24 public immutable maxBaseFeePpm;

    /// @notice Constructor initializes the policy manager with default values
    /// @param _governance The owner of the contract
    /// @param _dailyBudget Initial daily budget
    /// @param _minTradingFee Minimum trading fee
    /// @param _maxTradingFee Maximum trading fee
    constructor(address _governance, uint256 _dailyBudget, uint24 _minTradingFee, uint24 _maxTradingFee)
        Owned(_governance)
    {
        if (_governance == address(0)) revert Errors.ZeroAddress();

        // Initialize immutables
        minBaseFeePpm = _minTradingFee;
        maxBaseFeePpm = _maxTradingFee;

        // Initialize default fee configuration
        _setFeeConfig({
            _polSharePpm: 100_000,
            _fullRangeSharePpm: 0,
            _lpSharePpm: 900_000,
            _minimumTradingFeePpm: _minTradingFee,
            _feeClaimThresholdPpm: 10_000 // 1% claim threshold
        });

        // Initialize default dynamic fee configuration
        _defaultDynamicFeeConfig = DynamicFeeConfig({
            targetCapsPerDay: 1,
            capBudgetDecayWindow: 15_552_000, // 180 days
            freqScaling: 1e18, // 1x
            minBaseFeePpm: _minTradingFee,
            maxBaseFeePpm: _maxTradingFee,
            surgeDecayPeriodSeconds: 3600, // 1 hour
            surgeFeeMultiplierPpm: 3_000_000 // 300%
        });

        // Initialize global parameters
        _defaultMaxTicksPerBlock = 50;
        _capBudgetDailyPpm = _dailyBudget == 0 ? 1_000_000 : uint32(_dailyBudget);
        _capBudgetDecayWindow = 15_552_000; // 180 days
    }

    // === Fee Allocation Functions ===

    /// @inheritdoc IPoolPolicyManager
    function getFeeAllocations(PoolId poolId) external view override returns (uint256, uint256, uint256) {
        // Check if pool has a specific POL share
        uint256 poolSpecificPolShare = _poolPolSharePpm[poolId];

        // If pool-specific POL share is enabled and set for this pool, use it
        if (_allowPoolSpecificPolShare && poolSpecificPolShare > 0) {
            return (poolSpecificPolShare, 0, 1000000 - poolSpecificPolShare);
        }

        // Otherwise use the global settings
        return (_defaultFeeConfig.polSharePpm, _defaultFeeConfig.fullRangeSharePpm, _defaultFeeConfig.lpSharePpm);
    }

    /// @inheritdoc IPoolPolicyManager
    function getMinimumTradingFee() external view override returns (uint256) {
        return _defaultFeeConfig.minimumTradingFeePpm;
    }

    /// @inheritdoc IPoolPolicyManager
    function setFeeConfig(
        uint256 _polSharePpm,
        uint256 _fullRangeSharePpm,
        uint256 _lpSharePpm,
        uint256 _minimumTradingFeePpm,
        uint256 _feeClaimThresholdPpm
    ) external override onlyOwner {
        _setFeeConfig(_polSharePpm, _fullRangeSharePpm, _lpSharePpm, _minimumTradingFeePpm, _feeClaimThresholdPpm);
    }

    /// @inheritdoc IPoolPolicyManager
    function setPoolPOLShare(PoolId poolId, uint256 newPolSharePpm) external override onlyOwner {
        // Validate POL share is within valid range (0-100%)
        if (newPolSharePpm > 1000000) revert Errors.ParameterOutOfRange(newPolSharePpm, 0, 1000000);

        uint256 oldShare = _poolPolSharePpm[poolId];
        _poolPolSharePpm[poolId] = newPolSharePpm;

        emit POLShareSet(oldShare, newPolSharePpm);
        emit PoolPOLShareChanged(poolId, newPolSharePpm);
        emit PolicySet(poolId, PolicyType.FEE, address(uint160(newPolSharePpm)), msg.sender);
    }

    /// @inheritdoc IPoolPolicyManager
    function setPoolSpecificPOLSharingEnabled(bool enabled) external override onlyOwner {
        _allowPoolSpecificPolShare = enabled;

        emit PoolSpecificPOLSharingEnabled(enabled);
        emit PolicySet(PoolId.wrap(bytes32(0)), PolicyType.FEE, address(uint160(enabled ? 1 : 0)), msg.sender);
    }

    /// @inheritdoc IPoolPolicyManager
    function getPoolPOLShare(PoolId poolId) external view override returns (uint256) {
        uint256 poolSpecificPolShare = _poolPolSharePpm[poolId];

        // If pool-specific POL share is enabled and set for this pool, use it
        if (_allowPoolSpecificPolShare && poolSpecificPolShare > 0) {
            return poolSpecificPolShare;
        }

        // Otherwise use the global setting
        return _defaultFeeConfig.polSharePpm;
    }

    // === Manual Fee Override Functions ===

    /// @inheritdoc IPoolPolicyManager
    function getManualFee(PoolId poolId) external view override returns (uint24 manualFee, bool isSet) {
        return (_poolManualFee[poolId], _hasPoolManualFee[poolId]);
    }

    /// @inheritdoc IPoolPolicyManager
    function setManualFee(PoolId poolId, uint24 manualFee) external override onlyOwner {
        // Validate fee is within range
        if (manualFee < minBaseFeePpm || manualFee > maxBaseFeePpm) {
            revert Errors.ParameterOutOfRange(manualFee, minBaseFeePpm, maxBaseFeePpm);
        }

        _poolManualFee[poolId] = manualFee;
        _hasPoolManualFee[poolId] = true;

        emit ManualFeeSet(poolId, manualFee);
        emit PolicySet(poolId, PolicyType.FEE, address(uint160(manualFee)), msg.sender);
    }

    /// @inheritdoc IPoolPolicyManager
    function clearManualFee(PoolId poolId) external override onlyOwner {
        if (_hasPoolManualFee[poolId]) {
            _poolManualFee[poolId] = 0;
            _hasPoolManualFee[poolId] = false;

            emit ManualFeeSet(poolId, 0);
            emit PolicySet(poolId, PolicyType.FEE, address(0), msg.sender);
        }
    }

    // === Dynamic Fee Configuration Getters ===

    /// @inheritdoc IPoolPolicyManager
    function getFreqScaling(PoolId poolId) external view override returns (uint256) {
        if (_poolDynamicFeeConfig[poolId].freqScaling != 0) {
            return _poolDynamicFeeConfig[poolId].freqScaling;
        }
        return _defaultDynamicFeeConfig.freqScaling;
    }

    /// @inheritdoc IPoolPolicyManager
    function getMinBaseFee(PoolId poolId) external view override returns (uint256) {
        if (_poolDynamicFeeConfig[poolId].minBaseFeePpm != 0) {
            return _poolDynamicFeeConfig[poolId].minBaseFeePpm;
        }
        return minBaseFeePpm;
    }

    /// @inheritdoc IPoolPolicyManager
    function getMaxBaseFee(PoolId poolId) external view override returns (uint256) {
        if (_poolDynamicFeeConfig[poolId].maxBaseFeePpm != 0) {
            return _poolDynamicFeeConfig[poolId].maxBaseFeePpm;
        }
        return maxBaseFeePpm;
    }

    /// @inheritdoc IPoolPolicyManager
    function getSurgeDecayPeriodSeconds(PoolId poolId) external view override returns (uint256) {
        if (_poolDynamicFeeConfig[poolId].surgeDecayPeriodSeconds != 0) {
            return _poolDynamicFeeConfig[poolId].surgeDecayPeriodSeconds;
        }
        return _defaultDynamicFeeConfig.surgeDecayPeriodSeconds;
    }

    /// @inheritdoc IPoolPolicyManager
    function getSurgeFeeMultiplierPpm(PoolId poolId) external view override returns (uint24) {
        if (_poolDynamicFeeConfig[poolId].surgeFeeMultiplierPpm != 0) {
            return _poolDynamicFeeConfig[poolId].surgeFeeMultiplierPpm;
        }
        return _defaultDynamicFeeConfig.surgeFeeMultiplierPpm;
    }

    /// @inheritdoc IPoolPolicyManager
    function getSurgeDecaySeconds(PoolId poolId) external view override returns (uint32) {
        if (_poolDynamicFeeConfig[poolId].surgeDecayPeriodSeconds != 0) {
            return _poolDynamicFeeConfig[poolId].surgeDecayPeriodSeconds;
        }
        return _defaultDynamicFeeConfig.surgeDecayPeriodSeconds;
    }

    /// @inheritdoc IPoolPolicyManager
    function getDailyBudgetPpm(PoolId poolId) external view override returns (uint32) {
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
    function getDefaultMaxTicksPerBlock(PoolId) external view override returns (uint24) {
        return _defaultMaxTicksPerBlock;
    }

    /// @inheritdoc IPoolPolicyManager
    function getBudgetAndWindow(PoolId poolId)
        external
        view
        override
        returns (uint32 budgetPerDay, uint32 decayWindow)
    {
        budgetPerDay = _capBudgetDailyPpm;
        decayWindow = _poolDynamicFeeConfig[poolId].capBudgetDecayWindow != 0
            ? _poolDynamicFeeConfig[poolId].capBudgetDecayWindow
            : _capBudgetDecayWindow;
        return (budgetPerDay, decayWindow);
    }

    /// @inheritdoc IPoolPolicyManager
    function getBaseFeeStepPpm(PoolId poolId) public view override returns (uint32) {
        uint32 val = _poolBaseFeeParams[poolId].stepPpm;
        return val == 0 ? DEFAULT_BASE_FEE_STEP_PPM : val;
    }

    /// @inheritdoc IPoolPolicyManager
    function getMaxStepPpm(PoolId poolId) external view override returns (uint32) {
        return getBaseFeeStepPpm(poolId);
    }

    /// @inheritdoc IPoolPolicyManager
    function getBaseFeeUpdateIntervalSeconds(PoolId poolId) public view override returns (uint32) {
        uint32 val = _poolBaseFeeParams[poolId].updateIntervalSecs;
        return val == 0 ? DEFAULT_BASE_FEE_UPDATE_INTERVAL_SECS : val;
    }

    // === Dynamic Fee Configuration Setters ===

    /// @inheritdoc IPoolPolicyManager
    function setMaxBaseFee(PoolId poolId, uint256 f) external override onlyOwner {
        if (f == 0) revert Errors.ParameterOutOfRange(f, 1, type(uint24).max);

        uint256 minFee = this.getMinBaseFee(poolId);
        if (f < minFee) revert PolicyManagerErrors.InvalidFeeRange(uint24(f), uint24(minFee), maxBaseFeePpm);

        _poolDynamicFeeConfig[poolId].maxBaseFeePpm = uint24(f);
        emit PolicySet(poolId, PolicyType.FEE, address(0), msg.sender);
    }

    /// @inheritdoc IPoolPolicyManager
    function setTargetCapsPerDay(PoolId poolId, uint256 v) external override onlyOwner {
        if (v == 0 || v > type(uint32).max) revert Errors.ParameterOutOfRange(v, 1, type(uint32).max);

        _poolDynamicFeeConfig[poolId].targetCapsPerDay = uint32(v);
        emit PolicySet(poolId, PolicyType.FEE, address(0), msg.sender);
    }

    /// @inheritdoc IPoolPolicyManager
    function setCapBudgetDecayWindow(PoolId poolId, uint256 w) external override onlyOwner {
        if (w == 0 || w > type(uint32).max) revert Errors.ParameterOutOfRange(w, 1, type(uint32).max);

        _poolDynamicFeeConfig[poolId].capBudgetDecayWindow = uint32(w);
        emit PolicySet(poolId, PolicyType.FEE, address(0), msg.sender);
    }

    /// @inheritdoc IPoolPolicyManager
    function setFreqScaling(PoolId poolId, uint256 s) external override onlyOwner {
        if (s == 0) revert Errors.ParameterOutOfRange(s, 1, type(uint256).max);

        _poolDynamicFeeConfig[poolId].freqScaling = s;
        emit PolicySet(poolId, PolicyType.FEE, address(0), msg.sender);
    }

    /// @inheritdoc IPoolPolicyManager
    function setMinBaseFee(PoolId poolId, uint256 f) external override onlyOwner {
        if (f == 0) revert Errors.ParameterOutOfRange(f, 1, type(uint24).max);

        uint256 maxFee = this.getMaxBaseFee(poolId);
        if (f > maxFee) revert PolicyManagerErrors.InvalidFeeRange(uint24(f), minBaseFeePpm, uint24(maxFee));

        _poolDynamicFeeConfig[poolId].minBaseFeePpm = uint24(f);
        emit PolicySet(poolId, PolicyType.FEE, address(0), msg.sender);
    }

    /// @inheritdoc IPoolPolicyManager
    function setSurgeDecayPeriodSeconds(PoolId poolId, uint256 s) external override onlyOwner {
        if (s < 60) revert Errors.ParameterOutOfRange(s, 60, 1 days);
        if (s > 1 days) revert Errors.ParameterOutOfRange(s, 60, 1 days);

        _poolDynamicFeeConfig[poolId].surgeDecayPeriodSeconds = uint32(s);
        emit PolicySet(poolId, PolicyType.FEE, address(uint160(s)), msg.sender);
    }

    /// @inheritdoc IPoolPolicyManager
    function setSurgeFeeMultiplierPpm(PoolId poolId, uint24 multiplier) external override onlyOwner {
        if (multiplier == 0) revert Errors.ParameterOutOfRange(multiplier, 1, 3_000_000);
        if (multiplier > 3_000_000) revert Errors.ParameterOutOfRange(multiplier, 1, 3_000_000);

        _poolDynamicFeeConfig[poolId].surgeFeeMultiplierPpm = multiplier;
        emit PolicySet(poolId, PolicyType.FEE, address(uint160(multiplier)), msg.sender);
    }

    /// @inheritdoc IPoolPolicyManager
    function setBaseFeeParams(PoolId poolId, uint32 stepPpm, uint32 updateIntervalSecs) external override onlyOwner {
        if (stepPpm > MAX_STEP_PPM) revert Errors.ParameterOutOfRange(stepPpm, 0, MAX_STEP_PPM);

        _poolBaseFeeParams[poolId] = BaseFeeParams({stepPpm: stepPpm, updateIntervalSecs: updateIntervalSecs});

        emit BaseFeeParamsSet(poolId, stepPpm, updateIntervalSecs);
        emit PolicySet(poolId, PolicyType.FEE, address(0), msg.sender);
    }

    /// @inheritdoc IPoolPolicyManager
    function setDailyBudgetPpm(uint32 ppm) external override onlyOwner {
        _capBudgetDailyPpm = ppm;
        emit DailyBudgetSet(ppm);
    }

    /// @inheritdoc IPoolPolicyManager
    function setDecayWindow(uint32 secs) external override onlyOwner {
        _capBudgetDecayWindow = secs;
    }

    // === Internal Helper Functions ===

    /// @dev Internal function to set fee configuration
    /// @param _polSharePpm Protocol-owned liquidity share in PPM
    /// @param _fullRangeSharePpm Full range incentive share in PPM
    /// @param _lpSharePpm LP share in PPM
    /// @param _minimumTradingFeePpm Minimum trading fee in PPM
    /// @param _feeClaimThresholdPpm Fee claim threshold in PPM
    function _setFeeConfig(
        uint256 _polSharePpm,
        uint256 _fullRangeSharePpm,
        uint256 _lpSharePpm,
        uint256 _minimumTradingFeePpm,
        uint256 _feeClaimThresholdPpm
    ) internal {
        // Validate inputs
        if (_polSharePpm + _fullRangeSharePpm + _lpSharePpm != 1_000_000) {
            revert Errors.AllocationSumError(_polSharePpm, _fullRangeSharePpm, _lpSharePpm, 1_000_000);
        }

        if (_minimumTradingFeePpm > 100_000) {
            revert Errors.ParameterOutOfRange(_minimumTradingFeePpm, 0, 100_000);
        }

        if (_feeClaimThresholdPpm > 100_000) {
            revert Errors.ParameterOutOfRange(_feeClaimThresholdPpm, 0, 100_000);
        }

        // Update state variables
        _defaultFeeConfig = FeeConfig({
            polSharePpm: uint24(_polSharePpm),
            fullRangeSharePpm: uint24(_fullRangeSharePpm),
            lpSharePpm: uint24(_lpSharePpm),
            minimumTradingFeePpm: uint24(_minimumTradingFeePpm)
        });

        // Emit event
        emit FeeConfigChanged(_polSharePpm, _fullRangeSharePpm, _lpSharePpm, _minimumTradingFeePpm);
        emit PolicySet(PoolId.wrap(bytes32(0)), PolicyType.FEE, address(0), msg.sender);
    }
}
