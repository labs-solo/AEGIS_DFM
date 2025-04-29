// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Errors} from "./errors/Errors.sol";
import {TruncGeoOracleMulti} from "./TruncGeoOracleMulti.sol";
import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PrecisionConstants} from "./libraries/PrecisionConstants.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

/**
 * @title PoolPolicyManager
 * @notice Consolidated policy manager implementing the IPoolPolicy interface
 * @dev Handles all policy functionality from the original separate policy managers
 */
contract PoolPolicyManager is IPoolPolicy, Owned {
    // === Fee Policy State Variables ===

    // Fee allocation configuration
    uint24 public polSharePpm;
    uint24 public fullRangeSharePpm;
    uint24 public lpSharePpm;
    uint24 public minimumTradingFeePpm;
    uint24 public feeClaimThresholdPpm;
    uint24 public defaultDynamicFeePpm;

    // POL multiplier configuration
    uint32 public defaultPolMultiplier;
    mapping(PoolId => uint32) public poolPolMultipliers;

    // === Tick Scaling Policy State Variables ===

    // Tick scaling factor for calculating max tick movement
    int24 public tickScalingFactor;

    // Supported tick spacings
    mapping(uint24 => bool) public supportedTickSpacings;

    // === VTier Policy State Variables ===

    // Flag indicating a dynamic fee (0x800000)
    uint24 private constant DYNAMIC_FEE_FLAG = 0x800000;

    // === Policy Manager State Variables ===

    // Mapping of policy implementations by pool and type
    mapping(PoolId => mapping(PolicyType => address)) private _policies;

    // Add a new mapping for pool-specific POL share percentages
    mapping(PoolId => uint256) public poolPolSharePpm;

    // Add a flag to enable/disable pool-specific POL percentages
    bool public allowPoolSpecificPolShare;

    // === Phase 4 State Variables ===
    uint256 public protocolInterestFeePercentage; // Scaled by PRECISION (1e18)
    address public feeCollector; // Optional: May not be used if all fees become POL
    mapping(address => bool) public authorizedReinvestors;

    // === Dynamic Base‐Fee Feedback Parameters ===
    /// Default: target CAP events per day (equilibrium)
    uint32 public defaultTargetCapsPerDay; // fits - <4 G caps/day
    /// Default: seconds over which freqScaled decays linearly to zero (≈6 mo)
    uint32 public defaultCapBudgetDecayWindow; // fits - <136 yr
    /// Default: scaling factor for frequency (to avoid fractions; use 1e18)
    uint256 public defaultFreqScaling;
    /// Default minimum base‐fee (PPM) = 0.01%
    uint24 public defaultMinBaseFeePpm;
    /// Default maximum base‐fee (PPM) = 3%
    uint24 public defaultMaxBaseFeePpm;
    // Per‐pool overrides:
    mapping(PoolId => uint32) public poolTargetCapsPerDay;
    mapping(PoolId => uint32) public poolCapBudgetDecayWindow;
    mapping(PoolId => uint256) public poolFreqScaling;
    mapping(PoolId => uint24) public poolMinBaseFeePpm;
    mapping(PoolId => uint24) public poolMaxBaseFeePpm;

    // --- Add new state for surge fee policy ---
    /// Default: Surge fee decay period (seconds) e.g., 1 hour
    uint32 public defaultSurgeDecayPeriodSeconds;
    /// Default: Surge fee multiplier (PPM) e.g., 1_000_000 = 100%
    uint24 public _defaultSurgeFeeMultiplierPpm;
    // Per-pool overrides:
    mapping(PoolId => uint32) public poolSurgeDecayPeriodSeconds;
    mapping(PoolId => uint24) public _surgeFeeMultiplierPpm;

    // Events
    event FeeConfigChanged(
        uint256 polSharePpm,
        uint256 fullRangeSharePpm,
        uint256 lpSharePpm,
        uint256 minimumTradingFeePpm,
        uint256 feeClaimThresholdPpm,
        uint256 defaultPolMultiplier
    );
    event PoolPOLMultiplierChanged(PoolId indexed poolId, uint32 multiplier);
    event DefaultPOLMultiplierChanged(uint32 multiplier);
    event TickSpacingSupportChanged(uint24 tickSpacing, bool isSupported);
    event PolicySet(PoolId indexed poolId, PolicyType indexed policyType, address implementation);
    event PoolInitialized(PoolId indexed poolId, address hook, int24 initialTick);
    event PoolPOLShareChanged(PoolId indexed poolId, uint256 polSharePpm);
    event PoolSpecificPOLSharingEnabled(bool enabled);
    // --- Phase 4 Events ---
    event ProtocolInterestFeePercentageChanged(uint256 newPercentage);
    event FeeCollectorChanged(address newCollector);
    event AuthorizedReinvestorChanged(address indexed reinvestor, bool isAuthorized);
    event POLShareSet(uint256 oldShare, uint256 newShare);
    event FullRangeShareSet(uint256 oldShare, uint256 newShare);
    event DefaultDynamicFeeSet(uint256 oldFee, uint256 newFee);
    event POLFeeCollectorSet(address indexed oldCollector, address indexed newCollector);
    event ProtocolInterestFeePercentageSet(uint256 oldPercentage, uint256 newPercentage);
    event AuthorizedReinvestorSet(address indexed reinvestor, bool isAuthorized);

    // New state for surge fee policy
    mapping(bytes32 => uint32) private _maxStepPpm;
    uint32 private _globalMaxStepPpm;

    /// @notice **Target** number of cap‑events per day the protocol is willing
    ///         to subsidise before the base‑fee is nudged upwards (ppm/event).
    ///         Naming it *target* instead of *max* clarifies that falling below
    ///         the level decreases the fee.
    uint32 public capBudgetDailyPpm; // default = 1e6 = 1 cap/day

    /// @notice Linear‑decay half‑life for the budget counter, expressed in
    ///         seconds.  Default is 180 days (≈ 6 months) in production; tests
    ///         override this with much smaller values for speed.
    uint32 public capBudgetDecayWindow; // seconds

    /*──────────────────── adaptive-cap default ────────────────*/
    /// Default starting value for `maxTicksPerBlock`
    uint24 public defaultMaxTicksPerBlock = 50; // 50 ticks

    /**
     * @notice Constructor initializes the policy manager with default values
     * @param _owner The owner of the contract
     * @param _defaultFee Initial fee configuration
     * @param _supportedTickSpacings Array of initially supported tick spacings
     * @param _initialProtocolInterestFeePercentage Initial protocol interest fee percentage (scaled by PRECISION)
     * @param _initialFeeCollector Initial fee collector address (can be address(0))
     */
    constructor(
        address _owner,
        uint256 _defaultFee,
        uint24[] memory _supportedTickSpacings,
        uint256 _initialProtocolInterestFeePercentage, // Added Phase 4 param
        address _initialFeeCollector // Added Phase 4 param
    ) Owned(_owner) {
        // Initialize fee policy values
        polSharePpm = 100000; // 10% by default
        fullRangeSharePpm = 0; // 0% by default
        lpSharePpm = 900000; // 90% by default
        minimumTradingFeePpm = 100; // 0.01% minimum fee
        feeClaimThresholdPpm = 10000; // 1% threshold
        defaultPolMultiplier = 10; // 10x multiplier
        require(_defaultFee <= type(uint24).max, "defaultFee>24b");
        defaultDynamicFeePpm = uint24(_defaultFee);

        // Initialize dynamic‐base‐fee defaults
        defaultTargetCapsPerDay = 4;
        defaultCapBudgetDecayWindow = uint32(180 days);
        defaultFreqScaling = 1e18;
        defaultMinBaseFeePpm = 100; // 0.01%
        defaultMaxBaseFeePpm = 30000; //   3%
        // Initialize new surge defaults
        defaultSurgeDecayPeriodSeconds = 3600; // 1 hour
        _defaultSurgeFeeMultiplierPpm = 3_000_000; // 300% of base fee

        // Set _globalMaxStepPpm to 100,000 (10% per interval)
        _globalMaxStepPpm = 30_000; // 3% per interval

        // Initialize tick scaling policy values
        tickScalingFactor = 1; // Default tick scaling factor

        // Initialize supported tick spacings
        for (uint256 i = 0; i < _supportedTickSpacings.length; i++) {
            supportedTickSpacings[_supportedTickSpacings[i]] = true;
            emit TickSpacingSupportChanged(_supportedTickSpacings[i], true);
        }

        // Initialize Phase 4 parameters
        _setProtocolFeePercentage(_initialProtocolInterestFeePercentage);
        _setFeeCollector(_initialFeeCollector);

        // Initialize cap budget parameters with default values
        capBudgetDailyPpm = 1e6; // 1 cap per day
        capBudgetDecayWindow = 180 days; // 6 months decay window
    }

    // === Policy Management Functions ===

    /**
     * @inheritdoc IPoolPolicy
     */
    function getPolicy(PoolId poolId, PolicyType policyType) external view returns (address) {
        return _policies[poolId][policyType];
    }

    /**
     * @notice Sets a policy implementation for a specific pool and policy type
     * @param poolId The pool ID
     * @param policyType The policy type
     * @param implementation The implementation address
     */
    function setPolicy(PoolId poolId, PolicyType policyType, address implementation) external onlyOwner {
        if (implementation == address(0)) revert Errors.ZeroAddress();

        _policies[poolId][policyType] = implementation;
        emit PolicySet(poolId, policyType, implementation);
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function getSoloGovernance() external view returns (address) {
        return owner;
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function initializePolicies(PoolId poolId, address governance, address[] calldata implementations) external {
        // Ensure caller has proper permissions
        if (msg.sender != owner && msg.sender != governance) revert Errors.Unauthorized();

        // Validate implementations array length
        if (implementations.length != 4) revert Errors.InvalidPolicyImplementationsLength(implementations.length);

        // Set each policy type with its implementation
        for (uint8 i = 0; i < 4; i++) {
            address implementation = implementations[i];
            if (implementation == address(0)) revert Errors.ZeroAddress();

            PolicyType policyType = PolicyType(i);
            _policies[poolId][policyType] = implementation;
            emit PolicySet(poolId, policyType, implementation);
        }
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function handlePoolInitialization(
        PoolId poolId,
        PoolKey calldata, /*key*/
        uint160, /*sqrtPriceX96*/
        int24 tick,
        address hook
    ) external {
        // Ensure caller has proper permissions (Owner or the Hook itself)
        if (msg.sender != owner && msg.sender != hook) revert Errors.Unauthorized();

        // --- ORACLE LOGIC REMOVED ---

        // Emit the original event for observability
        emit PoolInitialized(poolId, hook, tick);
    }

    // === Fee Policy Functions ===

    /**
     * @inheritdoc IPoolPolicy
     */
    function getFeeAllocations(PoolId poolId) external view returns (uint256, uint256, uint256) {
        // Check if pool has a specific POL share
        uint256 poolSpecificPolShare = poolPolSharePpm[poolId];

        // If pool-specific POL share is enabled and set for this pool, use it
        if (allowPoolSpecificPolShare && poolSpecificPolShare > 0) {
            return (poolSpecificPolShare, 0, 1000000 - poolSpecificPolShare);
        }

        // Otherwise use the global settings
        return (polSharePpm, fullRangeSharePpm, lpSharePpm);
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function getMinimumPOLTarget(PoolId poolId, uint256 totalLiquidity, uint256 dynamicFeePpm)
        external
        view
        returns (uint256)
    {
        uint256 multiplier = poolPolMultipliers[poolId];
        if (multiplier == 0) {
            multiplier = defaultPolMultiplier;
        }

        // Calculate: (totalLiquidity * dynamicFeePpm * multiplier) / (1e6 * 1e6)
        return (totalLiquidity * dynamicFeePpm * multiplier) / 1e12;
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function getMinimumTradingFee() external view returns (uint256) {
        return minimumTradingFeePpm;
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function getFeeClaimThreshold() external view returns (uint256) {
        return feeClaimThresholdPpm;
    }

    /**
     * @notice Gets the POL multiplier for a specific pool
     * @param poolId The ID of the pool
     * @return The pool-specific POL multiplier, or the default if not set
     */
    function getPoolPOLMultiplier(PoolId poolId) external view returns (uint256) {
        uint256 multiplier = poolPolMultipliers[poolId];
        return multiplier == 0 ? defaultPolMultiplier : multiplier;
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function getDefaultDynamicFee() external view returns (uint256) {
        return defaultDynamicFeePpm;
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function setFeeConfig(
        uint256 _polSharePpm,
        uint256 _fullRangeSharePpm,
        uint256 _lpSharePpm,
        uint256 _minimumTradingFeePpm,
        uint256 _feeClaimThresholdPpm,
        uint256 _defaultPolMultiplier
    ) external onlyOwner {
        _setFeeConfig(
            _polSharePpm,
            _fullRangeSharePpm,
            _lpSharePpm,
            _minimumTradingFeePpm,
            _feeClaimThresholdPpm,
            _defaultPolMultiplier
        );
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function setPoolPOLMultiplier(PoolId poolId, uint32 multiplier) external onlyOwner {
        poolPolMultipliers[poolId] = multiplier;
        emit PoolPOLMultiplierChanged(poolId, multiplier);
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function setDefaultPOLMultiplier(uint32 multiplier) external onlyOwner {
        defaultPolMultiplier = multiplier;
        emit DefaultPOLMultiplierChanged(multiplier);
    }

    /**
     * @notice Sets the default dynamic fee in PPM
     * @param feePpm New default dynamic fee in PPM
     */
    function setDefaultDynamicFee(uint256 feePpm) external onlyOwner {
        if (feePpm < 1 || feePpm > 1000000) revert Errors.ParameterOutOfRange(feePpm, 1, 1000000);
        defaultDynamicFeePpm = uint24(feePpm);
        emit DefaultDynamicFeeSet(uint24(defaultDynamicFeePpm), uint24(feePpm));
    }

    /**
     * @notice Sets the POL share percentage for a specific pool
     * @param poolId The pool ID
     * @param newPolSharePpm The POL share in PPM (parts per million)
     */
    function setPoolPOLShare(PoolId poolId, uint256 newPolSharePpm) external onlyOwner {
        // Validate POL share is within valid range (0-100%)
        if (newPolSharePpm > 1000000) revert Errors.ParameterOutOfRange(newPolSharePpm, 0, 1000000);

        uint256 oldShare = poolPolSharePpm[poolId];
        poolPolSharePpm[poolId] = newPolSharePpm;
        emit POLShareSet(oldShare, newPolSharePpm);
    }

    /**
     * @notice Enables or disables the use of pool-specific POL share percentages
     * @param enabled Whether to enable pool-specific POL sharing
     */
    function setPoolSpecificPOLSharingEnabled(bool enabled) external onlyOwner {
        allowPoolSpecificPolShare = enabled;
        emit PoolSpecificPOLSharingEnabled(enabled);
    }

    /**
     * @notice Gets the POL share percentage for a specific pool
     * @param poolId The pool ID to get the POL share for
     * @return The POL share in PPM (parts per million)
     */
    function getPoolPOLShare(PoolId poolId) external view returns (uint256) {
        uint256 poolSpecificPolShare = poolPolSharePpm[poolId];

        // If pool-specific POL share is enabled and set for this pool, use it
        if (allowPoolSpecificPolShare && poolSpecificPolShare > 0) {
            return poolSpecificPolShare;
        }

        // Otherwise use the global setting
        return polSharePpm;
    }

    // === Tick Scaling Policy Functions ===

    /**
     * @inheritdoc IPoolPolicy
     */
    function getTickScalingFactor() external view returns (int24) {
        return tickScalingFactor;
    }

    /**
     * @notice Sets the tick scaling factor
     * @param newFactor The new tick scaling factor
     */
    function setTickScalingFactor(int24 newFactor) external onlyOwner {
        if (newFactor <= 0) revert Errors.ParameterOutOfRange(uint256(uint24(newFactor)), 1, type(uint24).max);
        tickScalingFactor = newFactor;
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function updateSupportedTickSpacing(uint24 tickSpacing, bool isSupported) external onlyOwner {
        supportedTickSpacings[tickSpacing] = isSupported;
        emit TickSpacingSupportChanged(tickSpacing, isSupported);
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function batchUpdateAllowedTickSpacings(uint24[] calldata tickSpacings, bool[] calldata allowed)
        external
        onlyOwner
    {
        if (tickSpacings.length != allowed.length) revert Errors.ArrayLengthMismatch();

        for (uint256 i = 0; i < tickSpacings.length; i++) {
            supportedTickSpacings[tickSpacings[i]] = allowed[i];
            emit TickSpacingSupportChanged(tickSpacings[i], allowed[i]);
        }
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function isTickSpacingSupported(uint24 tickSpacing) external view returns (bool) {
        return supportedTickSpacings[tickSpacing];
    }

    // === VTier Policy Functions ===

    /**
     * @inheritdoc IPoolPolicy
     */
    function isValidVtier(uint24 fee, int24 tickSpacing) external view returns (bool) {
        // First check if the tick spacing is supported
        if (!supportedTickSpacings[uint24(tickSpacing)]) {
            return false;
        }

        // For dynamic fee pools, any supported tick spacing is valid
        if (fee & DYNAMIC_FEE_FLAG != 0) {
            return true;
        }

        // For static fee pools, validate based on your fee/tick spacing rules
        // Example implementation - customize as needed:
        if (fee == 100 && tickSpacing == 1) return true;
        if (fee == 500 && tickSpacing == 10) return true;
        if (fee == 3000 && tickSpacing == 60) return true;
        if (fee == 10000 && tickSpacing == 200) return true;

        return false;
    }

    // === Phase 4 Implementation ===

    /**
     * @inheritdoc IPoolPolicy
     * @dev Returns the globally configured protocol interest fee percentage.
     *      PoolId parameter is included for interface consistency and future flexibility.
     */
    function getProtocolFeePercentage(PoolId poolId) external view override returns (uint256 feePercentage) {
        // Add poolId param for future flexibility, but return global value for now
        poolId; // Silence unused variable warning
        return protocolInterestFeePercentage;
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function getFeeCollector() external view override returns (address) {
        return feeCollector;
    }

    /**
     * @notice Sets the global protocol interest fee percentage.
     * @param _newPercentage The new percentage scaled by PRECISION (e.g., 0.1e18 for 10%)
     */
    function setProtocolFeePercentage(uint256 _newPercentage) external onlyOwner {
        _setProtocolFeePercentage(_newPercentage);
    }

    /**
     * @notice Sets the fee collector address.
     * @param _newCollector The new fee collector address. Can be address(0) if not used.
     */
    function setFeeCollector(address _newCollector) external onlyOwner {
        _setFeeCollector(_newCollector);
    }

    // === Internal Helper Functions ===

    /**
     * @notice Internal function to set fee configuration
     * @param _polSharePpm Protocol-owned liquidity share in PPM
     * @param _fullRangeSharePpm Full range incentive share in PPM
     * @param _lpSharePpm LP share in PPM
     * @param _minimumTradingFeePpm Minimum trading fee in PPM
     * @param _feeClaimThresholdPpm Fee claim threshold in PPM
     * @param _defaultPolMultiplier Default POL target multiplier
     */
    function _setFeeConfig(
        uint256 _polSharePpm,
        uint256 _fullRangeSharePpm,
        uint256 _lpSharePpm,
        uint256 _minimumTradingFeePpm,
        uint256 _feeClaimThresholdPpm,
        uint256 _defaultPolMultiplier
    ) internal {
        // Validate fee allocations sum to 1,000,000 (100%)
        if (_polSharePpm + _fullRangeSharePpm + _lpSharePpm != 1000000) {
            revert Errors.AllocationSumError(_polSharePpm, _fullRangeSharePpm, _lpSharePpm, 1000000);
        }

        // Validate minimum trading fee
        if (_minimumTradingFeePpm > 100000) {
            // Max 10%
            revert Errors.ParameterOutOfRange(_minimumTradingFeePpm, 0, 100000);
        }

        // Validate fee claim threshold
        if (_feeClaimThresholdPpm > 100000) {
            // Max 10%
            revert Errors.ParameterOutOfRange(_feeClaimThresholdPpm, 0, 100000);
        }

        // Set fee allocation values
        polSharePpm = uint24(_polSharePpm);
        fullRangeSharePpm = uint24(_fullRangeSharePpm);
        lpSharePpm = uint24(_lpSharePpm);
        minimumTradingFeePpm = uint24(_minimumTradingFeePpm);
        feeClaimThresholdPpm = uint24(_feeClaimThresholdPpm);
        defaultPolMultiplier = uint32(_defaultPolMultiplier);

        emit FeeConfigChanged(
            _polSharePpm,
            _fullRangeSharePpm,
            _lpSharePpm,
            _minimumTradingFeePpm,
            _feeClaimThresholdPpm,
            _defaultPolMultiplier
        );
    }

    /**
     * @notice Internal logic for setting protocol interest fee percentage
     */
    function _setProtocolFeePercentage(uint256 _newPercentage) internal {
        require(_newPercentage <= PrecisionConstants.PRECISION, "PPM: Percentage <= 100%");
        uint256 oldPercentage = protocolInterestFeePercentage;
        protocolInterestFeePercentage = _newPercentage;
        emit ProtocolInterestFeePercentageChanged(_newPercentage);
        emit ProtocolInterestFeePercentageSet(oldPercentage, _newPercentage);
        emit PolicySet(PoolId.wrap(bytes32(0)), PolicyType.INTEREST_FEE, msg.sender); // Use correct enum member
    }

    /**
     * @notice Internal logic for setting the fee collector
     */
    function _setFeeCollector(address _newCollector) internal {
        if (_newCollector == address(0)) revert Errors.ZeroAddress();
        address oldCollector = feeCollector;
        feeCollector = _newCollector;
        emit FeeCollectorChanged(_newCollector);
        emit POLFeeCollectorSet(oldCollector, _newCollector);
        emit PolicySet(PoolId.wrap(bytes32(0)), PolicyType.INTEREST_FEE, msg.sender); // Use correct enum member
    }

    // --- Add implementations for missing IPoolPolicy functions ---

    /// @inheritdoc IPoolPolicy
    function getTargetCapsPerDay(bytes32 poolId) external view override returns (uint256) {
        uint32 v = poolTargetCapsPerDay[PoolId.wrap(poolId)];
        return uint256(v != 0 ? v : defaultTargetCapsPerDay);
    }

    /// @inheritdoc IPoolPolicy
    function getCapBudgetDecayWindow(bytes32 poolId) external view override returns (uint32) {
        uint32 v = poolCapBudgetDecayWindow[PoolId.wrap(poolId)];
        return v != 0 ? v : defaultCapBudgetDecayWindow;
    }

    /// @inheritdoc IPoolPolicy
    function getFreqScaling(PoolId pid) external view returns (uint256) {
        uint256 v = poolFreqScaling[pid];
        return v != 0 ? v : defaultFreqScaling;
    }

    /// @inheritdoc IPoolPolicy
    function getMinBaseFee(PoolId pid) external view returns (uint256) {
        uint256 v = poolMinBaseFeePpm[pid];
        return v != 0 ? v : defaultMinBaseFeePpm;
    }

    /// @inheritdoc IPoolPolicy
    function getMaxBaseFee(PoolId pid) external view returns (uint256) {
        uint256 v = poolMaxBaseFeePpm[pid];
        return v != 0 ? v : defaultMaxBaseFeePpm;
    }

    /// @inheritdoc IPoolPolicy
    function getSurgeDecayPeriodSeconds(PoolId pid) external view returns (uint256) {
        uint256 v = poolSurgeDecayPeriodSeconds[pid];
        return v != 0 ? v : defaultSurgeDecayPeriodSeconds;
    }

    /* === Owner functions === */
    function setMaxBaseFee(PoolId pid, uint256 f) external onlyOwner {
        require(f > 0, ">0");
        poolMaxBaseFeePpm[pid] = uint24(f);
        emit PolicySet(pid, PolicyType.FEE, msg.sender);
    }

    // --- Add setters for dynamic base fee feedback policy overrides ---
    function setTargetCapsPerDay(PoolId pid, uint256 v) external onlyOwner {
        require(v > 0 && v <= type(uint32).max, "range");
        poolTargetCapsPerDay[pid] = uint32(v);
        emit PolicySet(pid, PolicyType.FEE, msg.sender);
    }

    function setCapBudgetDecayWindow(PoolId pid, uint256 w) external onlyOwner {
        require(w > 0 && w <= type(uint32).max, "range");
        poolCapBudgetDecayWindow[pid] = uint32(w);
        emit PolicySet(pid, PolicyType.FEE, msg.sender);
    }

    function setFreqScaling(PoolId pid, uint256 s) external onlyOwner {
        require(s > 0, ">0");
        poolFreqScaling[pid] = s;
        emit PolicySet(pid, PolicyType.FEE, msg.sender);
    }

    function setMinBaseFee(PoolId pid, uint256 f) external onlyOwner {
        require(f > 0, ">0");
        poolMinBaseFeePpm[pid] = uint24(f);
        emit PolicySet(pid, PolicyType.FEE, msg.sender);
    }

    // --- Add setters for new surge policy overrides ---
    function setSurgeDecayPeriodSeconds(PoolId pid, uint256 s) external onlyOwner {
        // Prevent too short or too long decay periods
        require(s >= 60, "min 60s");
        require(s <= 1 days, "max 1 day");
        poolSurgeDecayPeriodSeconds[pid] = uint32(s);
        emit PolicySet(pid, PolicyType.FEE, msg.sender);
    }

    // Add a new function to set the surge fee multiplier
    function setSurgeFeeMultiplierPpm(PoolId pid, uint24 multiplier) external onlyOwner {
        require(multiplier > 0, "must be positive");
        require(multiplier <= 3_000_000, "max 300%");
        _surgeFeeMultiplierPpm[pid] = multiplier;
        emit PolicySet(pid, PolicyType.FEE, msg.sender);
    }

    /* === Internal functions === */
    function setAuthorizedReinvestor(address reinvestor, bool isAuthorized) external onlyOwner {
        if (reinvestor == address(0)) revert Errors.ZeroAddress();
        authorizedReinvestors[reinvestor] = isAuthorized;
        emit AuthorizedReinvestorSet(reinvestor, isAuthorized);
        // Use PoolId.wrap(bytes32(0)) for zero PoolId
        emit PolicySet(PoolId.wrap(bytes32(0)), PolicyType.REINVESTOR_AUTH, msg.sender); // Use correct enum member
    }

    // --- Implement missing IPoolPolicy functions ---

    /**
     * @notice Returns the base fee update interval in seconds for the given pool.
     * @dev Currently returns a global default value.
     * @return The base fee update interval in seconds (currently 1 hour).
     */
    function getBaseFeeUpdateIntervalSeconds(PoolId /*poolId*/ ) external view override returns (uint256) {
        // TODO: Implement per-pool logic if needed
        return 1 hours; // Placeholder: Return 1 hour default
    }

    /// @inheritdoc IPoolPolicy
    function getMaxStepPpm(bytes32 poolId) external view override returns (uint32) {
        return _maxStepPpm[poolId] != 0 ? _maxStepPpm[poolId] : _globalMaxStepPpm; // now 100,000
    }

    // Implementation of new interface methods
    function getSurgeFeeMultiplierPpm(bytes32 poolId) external view override returns (uint24) {
        uint24 value = _surgeFeeMultiplierPpm[PoolId.wrap(poolId)];
        return value != 0 ? value : _defaultSurgeFeeMultiplierPpm;
    }

    function getSurgeDecaySeconds(bytes32 poolId) external view override returns (uint32) {
        uint256 value = poolSurgeDecayPeriodSeconds[PoolId.wrap(poolId)];
        return uint32(value != 0 ? value : defaultSurgeDecayPeriodSeconds);
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function isSupportedCurrency(Currency currency) external view override returns (bool) {
        // Default implementation: all currencies are supported
        return true;
    }

    function getDailyBudgetPpm(bytes32 /*poolId*/ ) external view returns (uint32) {
        return capBudgetDailyPpm;
    }

    /// -------------------------------------------------------------------
    ///  Gov ‑ Setters
    /// -------------------------------------------------------------------

    function setDailyBudgetPpm(uint32 _newBudget) external onlyOwner {
        capBudgetDailyPpm = _newBudget;
        emit DailyBudgetSet(_newBudget);
    }

    function setDecayWindow(uint32 _newWindow) external onlyOwner {
        capBudgetDecayWindow = _newWindow;
        emit DecayWindowSet(_newWindow);
    }

    event DailyBudgetSet(uint32 newBudget);
    event DecayWindowSet(uint32 newWindow);

    /**
     * @notice Helper to get both budget and window values in a single call, saving gas
     * @param id The PoolId to query
     * @return budgetPerDay Daily budget in PPM
     * @return decayWindow Decay window in seconds
     */
    function getBudgetAndWindow(PoolId id) external view returns (uint32 budgetPerDay, uint32 decayWindow) {
        budgetPerDay = capBudgetDailyPpm;
        decayWindow = capBudgetDecayWindow;
    }

    /**
     * @inheritdoc IPoolPolicy
     */
    function getDefaultMaxTicksPerBlock(bytes32) external view override returns (uint24) {
        return defaultMaxTicksPerBlock;
    }
}
