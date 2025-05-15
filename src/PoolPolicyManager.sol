// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IPoolPolicyManager} from "./interfaces/IPoolPolicyManager.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Errors} from "./errors/Errors.sol";
import {TruncGeoOracleMulti} from "./TruncGeoOracleMulti.sol";
import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PrecisionConstants} from "./libraries/PrecisionConstants.sol";

// TODO: make state variables all private and expose wrapper functions that accept a PoolId and if a configuration exists for a PoolId then return that
// else return the default/global configuration??
// TODO: remove all dead/unused configuration variables.
// TODO: advancedFee per pool and if != 0 use it instead of dynamicFee
// TODO: make everything per pool with GLOBAL CONSTANTS

/**
 * @title PoolPolicyManager
 * @notice Consolidated policy manager implementing the IPoolPolicyManager interface
 * @dev Handles all policy functionality from the original separate policy managers
 */
contract PoolPolicyManager is IPoolPolicyManager, Owned {
    // === Fee Policy State Variables ===

    // Maximum step for base fee updates (10% per step)
    uint32 internal constant MAX_STEP_PPM = 100_000; // TODO: make global variable updateable

    // Fee allocation configuration
    uint24 private constant _DEFAULT_BASE_FEE = 5_000; // 0.5 % // TODO: remove
    uint32 private constant _SURGE_DECAY_SECS = 3_600; // surge fade // TODO: rename DEFAULT_{}
    uint32 private constant _DAILY_BUDGET_PPM = 5_000; // example // TODO: remove!!!
    uint32 private constant _CAP_BUDGET_DECAY_WINDOW = 15_552_000; // 180 d

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
    uint256 public protocolInterestFeePercentagePpm;
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
    event PolicySet(
        PoolId indexed poolId, PolicyType indexed policyType, address implementation, address indexed setter
    );
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
    event DynamicFeeChanged(uint32 newFee);

    /// @notice **Target** number of cap‑events per day the protocol is willing
    ///         to subsidise before the base‑fee is nudged upwards (ppm/event).
    ///         Naming it *target* instead of *max* clarifies that falling below
    ///         the level decreases the fee.
    uint32 public capBudgetDailyPpm; // default budget (ppm-seconds per day) - TODO: make global per pool?
    uint32 public decayWindowSeconds; // default decay window
    mapping(PoolId => uint32) public freqScalingPpm; // test helper

    /// @notice Linear‑decay half‑life for the budget counter, expressed in
    ///         seconds.  Default is 180 days (≈ 6 months) in production; tests
    ///         override this with much smaller values for speed.
    uint32 public capBudgetDecayWindow; // seconds

    /*──────────────────── adaptive-cap default ────────────────*/
    /// Default starting value for `maxTicksPerBlock`
    uint24 public defaultMaxTicksPerBlock = 50; // 50 ticks

    uint24 private constant _SURGE_MULTIPLIER_PPM = 10_000; // 1× (no surge)
    uint32 private constant _TARGET_CAPS_PER_DAY = 4;

    /*──────────────  Base-fee step-engine parameters  ──────────────*/

    uint32 internal constant _DEF_BASE_FEE_STEP_PPM = 20_000; // 2 %
    uint32 internal constant _DEF_BASE_FEE_UPDATE_INTERVAL_SECS = 1 days; // 86 400 s

    mapping(PoolId => uint32) private _baseFeeStepPpm; // 0 ⇒ default
    mapping(PoolId => uint32) private _baseFeeUpdateIntervalSecs; // 0 ⇒ default

    event BaseFeeParamsSet(PoolId indexed poolId, uint32 stepPpm, uint32 updateIntervalSecs);

    /* ─── immutable config ----------------------------------- */
    uint24 public immutable minBaseFeePpm; // e.g.   100 → 0.01 %
    uint24 public immutable maxBaseFeePpm; // e.g. 50 000 → 5 %

    /**
     * @notice Constructor initializes the policy manager with default values
     * @param _governance The owner of the contract
     * @param _defaultDynamicFee Initial fee configuration
     * @param _supportedTickSpacings Array of initially supported tick spacings
     * @param _dailyBudget Initial daily budget
     * @param _feeCollector Initial fee collector address (can be address(0))
     * @param _minTradingFee Minimum trading fee
     * @param _maxTradingFee Maximum trading fee
     */
    constructor(
        address _governance,
        uint24 _defaultDynamicFee,
        uint24[] memory _supportedTickSpacings,
        uint256 _dailyBudget,
        address _feeCollector,
        uint24 _minTradingFee,
        uint24 _maxTradingFee
    ) Owned(_governance) {
        require(_governance != address(0), "ZeroAddress");

        // Sanity check: ensure the deployment is immediately usable by requiring
        // at least one supported tick spacing. Without this, no pools could be
        // initialised until governance (owner) adds a tick spacing via
        // `updateSupportedTickSpacing`, leaving the contract in a non-operational
        // state right after deployment.
        require(_supportedTickSpacings.length > 0, "TickSpacings: none");

        /* ── copy constructor params into the *current* field names ── */
        defaultDynamicFeePpm = _defaultDynamicFee;
        minimumTradingFeePpm = _minTradingFee;
        capBudgetDailyPpm = uint32(_dailyBudget);

        require(_feeCollector != address(0), "ZeroAddress");
        feeCollector = _feeCollector;

        /* initialise tick-spacing list */
        for (uint256 i; i < _supportedTickSpacings.length;) {
            _updateSupportedTickSpacing(_supportedTickSpacings[i], true);
            unchecked {
                ++i;
            }
        }

        // initialise immutables
        minBaseFeePpm = _minTradingFee;
        maxBaseFeePpm = _maxTradingFee;

        /* ────────────────────────────────
         *  Set **sane defaults** so that newly deployed
         *  instances behave consistently with the unit-test
         *  harness expectations (see PoolPolicyManager_* tests).
         * ──────────────────────────────── */

        // 1️⃣  Fee-split defaults: 10 % POL / 0 % FR / 90 % LP
        _setFeeConfig({
            _polSharePpm: 100_000,
            _fullRangeSharePpm: 0,
            _lpSharePpm: 900_000,
            _minimumTradingFeePpm: _minTradingFee,
            _feeClaimThresholdPpm: 10_000, // 1 % claim threshold
            _defaultPolMultiplier: 10 // 10× POL target
        });

        // 3️⃣  Oracle / base-fee feedback defaults
        defaultFreqScaling = 1e18; // 1 ×
        defaultSurgeDecayPeriodSeconds = 3_600; // 1 h
        _defaultSurgeFeeMultiplierPpm = 3_000_000; // 300 %

        // 4️⃣  Adaptive-cap budget defaults (1 cap-event/day, 180 d decay)
        capBudgetDailyPpm = _dailyBudget == 0 ? 1_000_000 : uint32(_dailyBudget);
        capBudgetDecayWindow = _CAP_BUDGET_DECAY_WINDOW; // 180 d

        // 5️⃣  Protocol-interest fee default (5 %)
        protocolInterestFeePercentagePpm = 50_000;
    }

    // === Policy Management Functions ===

    /**
     * @inheritdoc IPoolPolicyManager
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
        emit PolicySet(poolId, policyType, implementation, msg.sender);
    }

    // TODO: remove
    /**
     * @inheritdoc IPoolPolicyManager
     */
    function getSoloGovernance() external view returns (address) {
        return owner;
    }

    /**
     * @inheritdoc IPoolPolicyManager
     */
    function initializePolicies(PoolId poolId,
                                address /* governance */,
                                address[] calldata implementations) external onlyOwner {
        // Validate implementations array length
        if (implementations.length != 4) revert Errors.InvalidPolicyImplementationsLength(implementations.length);

        // Set each policy type with its implementation
        for (uint8 i = 0; i < 4;) {
            address implementation = implementations[i];
            if (implementation == address(0)) revert Errors.ZeroAddress();

            PolicyType policyType = PolicyType(i);
            _policies[poolId][policyType] = implementation;
            emit PolicySet(poolId, policyType, implementation, msg.sender);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @inheritdoc IPoolPolicyManager
     */
    function handlePoolInitialization(
        PoolId poolId,
        PoolKey calldata key,
        uint160, /*sqrtPriceX96*/
        int24 tick,
        address /* hook */
    ) external {
        /* --------------------------------------------------------------------
         *  Access control
         *  1.  Ensure the supplied `key` actually corresponds to `poolId` so a
         *      caller cannot forge a random key/hook combination for an
         *      existing pool.
         *  2.  Allow the call only from:
         *        – the contract owner (governance), or
         *        – the hook address embedded in the `PoolKey` (the legitimate
         *          pool-specific hook that Uniswap V4 stores inside the pool
         *          ID hash).
         *      An arbitrary caller can no longer gain access by simply
         *      supplying their own address as the `hook` parameter.
         * ------------------------------------------------------------------*/

        if (poolId != PoolIdLibrary.toId(key)) revert Errors.InvalidPoolKey();

        address expectedHook = address(key.hooks);
        if (msg.sender != owner && msg.sender != expectedHook) revert Errors.Unauthorized();

        // --- ORACLE LOGIC REMOVED ---

        emit PoolInitialized(poolId, expectedHook, tick);
    }

    // === Fee Policy Functions ===

    /**
     * @inheritdoc IPoolPolicyManager
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
     * @inheritdoc IPoolPolicyManager
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
     * @inheritdoc IPoolPolicyManager
     */
    function getMinimumTradingFee() external view returns (uint256) {
        return minimumTradingFeePpm;
    }

    /**
     * @inheritdoc IPoolPolicyManager
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
     * @inheritdoc IPoolPolicyManager
     */
    function getDefaultDynamicFee() external view override returns (uint256) {
        return defaultDynamicFeePpm;
    }

    /**
     * @inheritdoc IPoolPolicyManager
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
     * @inheritdoc IPoolPolicyManager
     */
    function setPoolPOLMultiplier(PoolId poolId, uint32 multiplier) external onlyOwner {
        poolPolMultipliers[poolId] = multiplier;
        emit PoolPOLMultiplierChanged(poolId, multiplier);
        emit PolicySet(poolId, PolicyType.FEE, address(uint160(multiplier)), msg.sender);
    }

    /**
     * @inheritdoc IPoolPolicyManager
     */
    function setDefaultPOLMultiplier(uint32 multiplier) external onlyOwner {
        defaultPolMultiplier = multiplier;
        emit DefaultPOLMultiplierChanged(multiplier);
        emit PolicySet(PoolId.wrap(bytes32(0)), PolicyType.FEE, address(uint160(multiplier)), msg.sender);
    }

    /**
     * @notice Sets the default dynamic fee in PPM
     * @param feePpm New default dynamic fee in PPM
     */
    function setDefaultDynamicFee(uint256 feePpm) external onlyOwner {
        if (feePpm < 1 || feePpm > 50_000) revert Errors.FeeTooHigh();
        defaultDynamicFeePpm = uint24(feePpm);
        emit DefaultDynamicFeeSet(uint24(defaultDynamicFeePpm), uint24(feePpm));
        emit DynamicFeeChanged(uint32(feePpm));
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
        emit PoolPOLShareChanged(poolId, newPolSharePpm);
        emit PolicySet(poolId, PolicyType.FEE, address(uint160(newPolSharePpm)), msg.sender);
    }

    /**
     * @notice Enables or disables the use of pool-specific POL share percentages
     * @param enabled Whether to enable pool-specific POL sharing
     */
    function setPoolSpecificPOLSharingEnabled(bool enabled) external onlyOwner {
        allowPoolSpecificPolShare = enabled;
        emit PoolSpecificPOLSharingEnabled(enabled);
        emit PolicySet(PoolId.wrap(bytes32(0)), PolicyType.FEE, address(uint160(enabled ? 1 : 0)), msg.sender);
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
     * @inheritdoc IPoolPolicyManager
     */
    function updateSupportedTickSpacing(uint24 tickSpacing, bool isSupported) external onlyOwner {
        supportedTickSpacings[tickSpacing] = isSupported;
        emit TickSpacingSupportChanged(tickSpacing, isSupported);
        emit PolicySet(
            PoolId.wrap(bytes32(0)), PolicyType.VTIER, address(uint160(uint256(isSupported ? 1 : 0))), msg.sender
        );
    }

    /**
     * @inheritdoc IPoolPolicyManager
     */
    function batchUpdateAllowedTickSpacings(uint24[] calldata tickSpacings, bool[] calldata allowed)
        external
        onlyOwner
    {
        if (tickSpacings.length != allowed.length) revert Errors.ArrayLengthMismatch();

        for (uint256 i; i < tickSpacings.length;) {
            supportedTickSpacings[tickSpacings[i]] = allowed[i];
            emit TickSpacingSupportChanged(tickSpacings[i], allowed[i]);
            emit PolicySet(
                PoolId.wrap(bytes32(0)), PolicyType.VTIER, address(uint160(uint256(allowed[i] ? 1 : 0))), msg.sender
            );
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @inheritdoc IPoolPolicyManager
     */
    function isTickSpacingSupported(uint24 tickSpacing) external view returns (bool) {
        return supportedTickSpacings[tickSpacing];
    }

    // === VTier Policy Functions ===

    /**
     * @inheritdoc IPoolPolicyManager
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
     * @inheritdoc IPoolPolicyManager
     * @dev Returns the globally configured protocol interest fee percentage.
     *      PoolId parameter is included for interface consistency and future flexibility.
     */
    function getProtocolFeePercentage(PoolId poolId) external view override returns (uint256 feePercentage) {
        // Add poolId param for future flexibility, but return global value for now
        poolId; // Silence unused variable warning
        return uint256(protocolInterestFeePercentagePpm);
    }

    /**
     * @inheritdoc IPoolPolicyManager
     */
    function getFeeCollector() external view override returns (address) {
        return feeCollector;
    }

    /**
     * @notice Sets the global protocol interest fee percentage.
     * @param _newPercentage The new percentage scaled by PPM_SCALE (e.g., 100_000 for 10%)
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
        // Validate inputs
        if (_polSharePpm + _fullRangeSharePpm + _lpSharePpm != 1_000_000) {
            revert Errors.AllocationSumError(_polSharePpm, _fullRangeSharePpm, _lpSharePpm, 1_000_000);
        }
        // minTradingFee must be <= MAX_DEFAULT_FEE
        if (_minimumTradingFeePpm > 100_000) {
            revert Errors.ParameterOutOfRange(_minimumTradingFeePpm, 0, 100_000);
        }
        if (_feeClaimThresholdPpm > 100_000) {
            revert Errors.ParameterOutOfRange(_feeClaimThresholdPpm, 0, 100_000);
        }

        // Update state variables
        polSharePpm = uint24(_polSharePpm);
        fullRangeSharePpm = uint24(_fullRangeSharePpm);
        lpSharePpm = uint24(_lpSharePpm);
        minimumTradingFeePpm = uint24(_minimumTradingFeePpm);
        feeClaimThresholdPpm = uint24(_feeClaimThresholdPpm);
        defaultPolMultiplier = uint32(_defaultPolMultiplier);

        // Emit event
        emit FeeConfigChanged(
            _polSharePpm,
            _fullRangeSharePpm,
            _lpSharePpm,
            _minimumTradingFeePpm,
            _feeClaimThresholdPpm,
            _defaultPolMultiplier
        );
        emit PolicySet(PoolId.wrap(bytes32(0)), PolicyType.FEE, address(0), msg.sender);
    }

    /**
     * @notice Internal logic for setting protocol interest fee percentage
     */
    function _setProtocolFeePercentage(uint256 _newPercentage) internal {
        require(_newPercentage <= PrecisionConstants.ONE_HUNDRED_PERCENT_PPM, "PPM: <= 1e6");
        uint256 oldPercentage = protocolInterestFeePercentagePpm;
        protocolInterestFeePercentagePpm = _newPercentage;
        emit ProtocolInterestFeePercentageChanged(_newPercentage);
        emit ProtocolInterestFeePercentageSet(oldPercentage, _newPercentage);
        emit PolicySet(
            PoolId.wrap(bytes32(0)),
            PolicyType.INTEREST_FEE,
            address(0), // Implementation is not relevant here, use zero
            msg.sender
        );
    }

    /**
     * @notice Internal logic for setting the fee collector
     */
    function _setFeeCollector(address _newCollector) internal {
        if (_newCollector == address(0)) revert Errors.ZeroAddress();
        if (feeCollector == _newCollector) return; // no-op
        address oldCollector = feeCollector;
        feeCollector = _newCollector;
        emit FeeCollectorChanged(_newCollector);
        emit POLFeeCollectorSet(oldCollector, _newCollector);
        emit PolicySet(
            PoolId.wrap(bytes32(0)),
            PolicyType.INTEREST_FEE, // PolicyType should reflect fee collector change? Using INTEREST_FEE for now.
            _newCollector, // Use the new collector address as the 'implementation' for the event
            msg.sender
        );
    }

    // --- Add implementations for missing IPoolPolicyManager functions ---

    /// @inheritdoc IPoolPolicyManager
    function getFreqScaling(PoolId pid) external view returns (uint256) {
        uint256 v = poolFreqScaling[pid];
        return v != 0 ? v : defaultFreqScaling;
    }

    /// @inheritdoc IPoolPolicyManager
    function getMinBaseFee(PoolId pid) external view override returns (uint256) {
        uint256 v = poolMinBaseFeePpm[pid];
        return v != 0 ? v : minBaseFeePpm;
    }

    /// @inheritdoc IPoolPolicyManager
    function getMaxBaseFee(PoolId pid) external view override returns (uint256) {
        uint256 v = poolMaxBaseFeePpm[pid];
        return v != 0 ? v : maxBaseFeePpm;
    }

    /// @inheritdoc IPoolPolicyManager
    function getSurgeDecayPeriodSeconds(PoolId pid) external view returns (uint256) {
        uint256 v = poolSurgeDecayPeriodSeconds[pid];
        return v != 0 ? v : defaultSurgeDecayPeriodSeconds;
    }

    /* === Owner functions === */
    function setMaxBaseFee(PoolId pid, uint256 f) external onlyOwner {
        require(f > 0, ">0");
        uint256 minFee = getMinBaseFee(pid);
        require(f >= minFee, "max fee < min fee");
        poolMaxBaseFeePpm[pid] = uint24(f);
        emit PolicySet(pid, PolicyType.FEE, address(0), msg.sender);
    }

    // --- Add setters for dynamic base fee feedback policy overrides ---
    function setTargetCapsPerDay(PoolId pid, uint256 v) external onlyOwner {
        require(v > 0 && v <= type(uint32).max, "range");
        poolTargetCapsPerDay[pid] = uint32(v);
        emit PolicySet(pid, PolicyType.FEE, address(0), msg.sender);
    }

    function setCapBudgetDecayWindow(PoolId pid, uint256 w) external onlyOwner {
        require(w > 0 && w <= type(uint32).max, "range");
        poolCapBudgetDecayWindow[pid] = uint32(w);
        emit PolicySet(pid, PolicyType.FEE, address(0), msg.sender);
    }

    function setFreqScaling(PoolId pid, uint256 s) external virtual onlyOwner {
        require(s > 0, ">0");
        poolFreqScaling[pid] = s;
        emit PolicySet(pid, PolicyType.FEE, address(0), msg.sender);
    }

    function setMinBaseFee(PoolId pid, uint256 f) external onlyOwner {
        require(f > 0, ">0");
        uint256 maxFee = getMaxBaseFee(pid);
        require(f <= maxFee, "min fee > max fee");
        poolMinBaseFeePpm[pid] = uint24(f);
        emit PolicySet(pid, PolicyType.FEE, address(0), msg.sender);
    }

    // --- Add setters for new surge policy overrides ---
    function setSurgeDecayPeriodSeconds(PoolId pid, uint256 s) external onlyOwner {
        // Prevent too short or too long decay periods
        require(s >= 60, "min 60s");
        require(s <= 1 days, "max 1 day");
        poolSurgeDecayPeriodSeconds[pid] = uint32(s);
        emit PolicySet(pid, PolicyType.FEE, address(uint160(s)), msg.sender);
    }

    // Add a new function to set the surge fee multiplier
    function setSurgeFeeMultiplierPpm(PoolId pid, uint24 multiplier) external onlyOwner {
        require(multiplier > 0, "must be positive");
        require(multiplier <= 3_000_000, "max 300%");
        _surgeFeeMultiplierPpm[pid] = multiplier;
        emit PolicySet(pid, PolicyType.FEE, address(uint160(multiplier)), msg.sender);
    }

    /* === Internal functions === */
    function setAuthorizedReinvestor(address reinvestor, bool isAuthorized) external onlyOwner {
        if (reinvestor == address(0)) revert Errors.ZeroAddress();
        authorizedReinvestors[reinvestor] = isAuthorized;
        emit AuthorizedReinvestorSet(reinvestor, isAuthorized);
        // Use PoolId.wrap(bytes32(0)) for zero PoolId
        emit PolicySet(PoolId.wrap(bytes32(0)), PolicyType.REINVESTOR_AUTH, reinvestor, msg.sender);
    }

    /*─── IPoolPolicyManager - step-engine getters ───*/
    function getBaseFeeStepPpm(PoolId pid) public view override returns (uint32) {
        uint32 val = _baseFeeStepPpm[pid];
        return val == 0 ? _DEF_BASE_FEE_STEP_PPM : val;
    }

    // kept for backwards compatibility – alias to the function above
    function getMaxStepPpm(PoolId pid) external view override returns (uint32) {
        return getBaseFeeStepPpm(pid);
    }

    function getBaseFeeUpdateIntervalSeconds(PoolId pid) public view override returns (uint32) {
        uint32 val = _baseFeeUpdateIntervalSecs[pid];
        return val == 0 ? _DEF_BASE_FEE_UPDATE_INTERVAL_SECS : val;
    }

    /*─── Governance setter ───*/
    function setBaseFeeParams(PoolId pid, uint32 stepPpm, uint32 updateIntervalSecs) external onlyOwner {
        require(stepPpm <= MAX_STEP_PPM, "stepPpm too large");
        _baseFeeStepPpm[pid] = stepPpm;
        _baseFeeUpdateIntervalSecs[pid] = updateIntervalSecs;
        emit BaseFeeParamsSet(pid, stepPpm, updateIntervalSecs);
        emit PolicySet(pid, PolicyType.FEE, address(0), msg.sender);
    }

    /*──────────────  Surge-fee default getters  ─────────────────*/
    function getSurgeFeeMultiplierPpm(PoolId pid) external view override returns (uint24) {
        uint24 v = _surgeFeeMultiplierPpm[pid];
        // fall back to the configured default, not the old static constant
        return v != 0 ? v : _defaultSurgeFeeMultiplierPpm;
    }

    function getSurgeDecaySeconds(PoolId pid) external view override returns (uint32) {
        uint32 v = poolSurgeDecayPeriodSeconds[pid];
        return v != 0 ? v : _SURGE_DECAY_SECS;
    }

    /*──────────────  Oracle / cap defaults  ─────────────────────*/
    function getTargetCapsPerDay(PoolId pid) external view override returns (uint32) {
        uint32 v = poolTargetCapsPerDay[pid];
        return v != 0 ? v : _TARGET_CAPS_PER_DAY;
    }

    function getDailyBudgetPpm(PoolId /* pid */ ) external view virtual override returns (uint32) {
        return capBudgetDailyPpm; // TODO: use it here?
    }

    function getCapBudgetDecayWindow(PoolId /* pid */ ) external view virtual override returns (uint32) {
        return capBudgetDecayWindow;
    }

    /**
     * @inheritdoc IPoolPolicyManager
     * @dev All currencies are considered supported by default in this implementation.
     */
    function isSupportedCurrency(Currency /* currency */ ) external pure override returns (bool) {
        return true;
    }

    /**
     * @notice Helper to get both budget and window values in a single call, saving gas
     * @return budgetPerDay Daily budget in PPM
     * @return decayWindow Decay window in seconds
     */
    function getBudgetAndWindow(PoolId /* poolId */ ) external view returns (uint32 budgetPerDay, uint32 decayWindow) {
        budgetPerDay = capBudgetDailyPpm;
        decayWindow = capBudgetDecayWindow;
    }

    /// -------------------------------------------------------------------
    ///  Gov ‑ Setters
    /// -------------------------------------------------------------------

    event DailyBudgetSet(uint32 newBudget);

    /**
     * @inheritdoc IPoolPolicyManager
     */
    function getDefaultMaxTicksPerBlock(PoolId) external view override returns (uint24) {
        return defaultMaxTicksPerBlock;
    }

    /* --------------------------------------------------------- */
    /*  Governance test helpers (no-op on prod chains)           */
    /* --------------------------------------------------------- */

    /* ───────────────── governance helpers (test-only) ───────────────── */
    function setDailyBudgetPpm(uint32 ppm) external virtual onlyOwner {
        capBudgetDailyPpm = ppm;
    }

    function setDecayWindow(uint32 secs) external virtual onlyOwner {
        capBudgetDecayWindow = secs;
    }

    /// @notice Adds or removes a tick spacing from the supported list.
    function _updateSupportedTickSpacing(uint24 tickSpacing, bool isSupported) internal {
        if (supportedTickSpacings[tickSpacing] == isSupported) return;
        supportedTickSpacings[tickSpacing] = isSupported;
        emit TickSpacingSupportChanged(tickSpacing, isSupported);
        emit PolicySet(
            PoolId.wrap(bytes32(0)), PolicyType.VTIER, address(uint160(uint256(isSupported ? 1 : 0))), msg.sender
        );
    }


}
