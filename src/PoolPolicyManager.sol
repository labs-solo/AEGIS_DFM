// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Errors} from "./errors/Errors.sol";
import {TruncGeoOracleMulti} from "./TruncGeoOracleMulti.sol";
import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/**
 * @title PoolPolicyManager
 * @notice Consolidated policy manager implementing the IPoolPolicy interface
 * @dev Handles all policy functionality from the original separate policy managers
 */
contract PoolPolicyManager is IPoolPolicy, Owned {
    // === Fee Policy State Variables ===
    
    // Fee allocation configuration
    uint256 public polSharePpm;
    uint256 public fullRangeSharePpm;
    uint256 public lpSharePpm;
    uint256 public minimumTradingFeePpm;
    uint256 public feeClaimThresholdPpm;
    uint256 public defaultDynamicFeePpm;
    
    // POL multiplier configuration
    uint256 public defaultPolMultiplier;
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
    uint256 public constant PRECISION = 1e18; // Added for fee percentage scaling
    uint256 public protocolInterestFeePercentage; // Scaled by PRECISION
    address public feeCollector; // Optional: May not be used if all fees become POL
    mapping(address => bool) public authorizedReinvestors;
    
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
    
    /**
     * @notice Constructor initializes the policy manager with default values
     * @param _owner The owner of the contract
     * @param _polSharePpm Initial protocol-owned liquidity share in PPM
     * @param _fullRangeSharePpm Initial full range incentive share in PPM
     * @param _lpSharePpm Initial LP share in PPM
     * @param _minimumTradingFeePpm Initial minimum trading fee in PPM
     * @param _feeClaimThresholdPpm Initial fee claim threshold in PPM
     * @param _defaultPolMultiplier Initial default POL target multiplier
     * @param _defaultDynamicFeePpm Initial default dynamic fee in PPM
     * @param _tickScalingFactor Initial tick scaling factor
     * @param _supportedTickSpacings Array of initially supported tick spacings
     * @param _initialProtocolInterestFeePercentage Initial protocol interest fee percentage (scaled by PRECISION)
     * @param _initialFeeCollector Initial fee collector address (can be address(0))
     */
    constructor(
        address _owner,
        uint256 _polSharePpm,
        uint256 _fullRangeSharePpm,
        uint256 _lpSharePpm,
        uint256 _minimumTradingFeePpm,
        uint256 _feeClaimThresholdPpm,
        uint256 _defaultPolMultiplier,
        uint256 _defaultDynamicFeePpm,
        int24 _tickScalingFactor,
        uint24[] memory _supportedTickSpacings,
        uint256 _initialProtocolInterestFeePercentage, // Added Phase 4 param
        address _initialFeeCollector // Added Phase 4 param
    ) Owned(_owner) {
        // Initialize fee policy values
        _setFeeConfig(
            _polSharePpm,
            _fullRangeSharePpm,
            _lpSharePpm,
            _minimumTradingFeePpm,
            _feeClaimThresholdPpm,
            _defaultPolMultiplier
        );
        defaultDynamicFeePpm = _defaultDynamicFeePpm;
        
        // Initialize tick scaling policy values
        tickScalingFactor = _tickScalingFactor;
        
        // Initialize supported tick spacings
        for (uint256 i = 0; i < _supportedTickSpacings.length; i++) {
            supportedTickSpacings[_supportedTickSpacings[i]] = true;
            emit TickSpacingSupportChanged(_supportedTickSpacings[i], true);
        }

        // Initialize Phase 4 parameters
        _setProtocolFeePercentage(_initialProtocolInterestFeePercentage);
        _setFeeCollector(_initialFeeCollector);
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
    function handlePoolInitialization(PoolId poolId, PoolKey calldata /*key*/, uint160 /*sqrtPriceX96*/, int24 tick, address hook) external {
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
    function getMinimumPOLTarget(PoolId poolId, uint256 totalLiquidity, uint256 dynamicFeePpm) external view returns (uint256) {
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
        defaultDynamicFeePpm = feePpm;
    }
    
    /**
     * @notice Sets the POL share percentage for a specific pool
     * @param poolId The pool ID
     * @param newPolSharePpm The POL share in PPM (parts per million)
     */
    function setPoolPOLShare(PoolId poolId, uint256 newPolSharePpm) external onlyOwner {
        // Validate POL share is within valid range (0-100%)
        if (newPolSharePpm > 1000000) revert Errors.ParameterOutOfRange(newPolSharePpm, 0, 1000000);
        
        poolPolSharePpm[poolId] = newPolSharePpm;
        emit PoolPOLShareChanged(poolId, newPolSharePpm);
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
    function batchUpdateAllowedTickSpacings(uint24[] calldata tickSpacings, bool[] calldata allowed) external onlyOwner {
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
     * @inheritdoc IPoolPolicy
     */
    function isAuthorizedReinvestor(address reinvestor) external view override returns (bool isAuthorized) {
        // Also allow the owner (governance) to always be authorized implicitly
        return authorizedReinvestors[reinvestor] || reinvestor == owner;
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

    /**
     * @notice Authorizes or deauthorizes an address to trigger fee reinvestment.
     * @param _reinvestor The address to authorize/deauthorize.
     * @param _isAuthorized True to authorize, false to deauthorize.
     */
    function setAuthorizedReinvestor(address _reinvestor, bool _isAuthorized) external onlyOwner {
        require(_reinvestor != address(0), "PPM: Zero address");
        require(_reinvestor != owner, "PPM: Owner is implicitly authorized"); // Prevent explicit setting for owner
        authorizedReinvestors[_reinvestor] = _isAuthorized;
        emit AuthorizedReinvestorChanged(_reinvestor, _isAuthorized);
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
        if (_minimumTradingFeePpm > 100000) { // Max 10%
            revert Errors.ParameterOutOfRange(_minimumTradingFeePpm, 0, 100000);
        }
        
        // Validate fee claim threshold
        if (_feeClaimThresholdPpm > 100000) { // Max 10%
            revert Errors.ParameterOutOfRange(_feeClaimThresholdPpm, 0, 100000);
        }
        
        // Set fee allocation values
        polSharePpm = _polSharePpm;
        fullRangeSharePpm = _fullRangeSharePpm;
        lpSharePpm = _lpSharePpm;
        minimumTradingFeePpm = _minimumTradingFeePpm;
        feeClaimThresholdPpm = _feeClaimThresholdPpm;
        defaultPolMultiplier = _defaultPolMultiplier;
        
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
        require(_newPercentage <= PRECISION, "PPM: Percentage <= 100%");
        protocolInterestFeePercentage = _newPercentage;
        emit ProtocolInterestFeePercentageChanged(_newPercentage);
    }

    /**
     * @notice Internal logic for setting the fee collector
     */
    function _setFeeCollector(address _newCollector) internal {
        // Allow address(0) if collector role is unused
        feeCollector = _newCollector;
        emit FeeCollectorChanged(_newCollector);
    }
} 