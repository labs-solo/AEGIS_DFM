// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

// - - - external deps - - -

import {Owned} from "solmate/src/auth/Owned.sol";

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

// - - - local deps - - -

import {IDynamicFeeManager} from "./interfaces/IDynamicFeeManager.sol";
import {IPoolPolicyManager} from "./interfaces/IPoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "./TruncGeoOracleMulti.sol";
import {DynamicFeeState, DynamicFeeStateLibrary} from "./libraries/DynamicFeeState.sol";
import {Errors} from "./errors/Errors.sol";

/// @title DynamicFeeManager
/// @notice Manages dynamic fees for Uniswap v4 pools with base fees from oracle data and surge fees during capped periods
/// @dev Implements a two-phase fee system:
///      1. Base fees calculated from oracle tick volatility data
///      2. Surge fees applied during capped trading periods with linear decay
contract DynamicFeeManager is IDynamicFeeManager, Owned {
    using PoolIdLibrary for PoolId;
    using DynamicFeeStateLibrary for DynamicFeeState;

    // - - - CONSTANTS - - -

    /// @dev Fallback base fee when oracle has no data (0.5% in PPM)
    uint32 private constant DEFAULT_BASE_FEE_PPM = 5_000;

    /// @dev Parts per million denominator for percentage calculations
    uint256 private constant PPM_DENOMINATOR = 1e6;

    // - - - IMMUTABLE STATE - - -

    /// @inheritdoc IDynamicFeeManager
    IPoolPolicyManager public immutable override policyManager;

    /// @inheritdoc IDynamicFeeManager
    TruncGeoOracleMulti public immutable override oracle;

    /// @inheritdoc IDynamicFeeManager
    address public immutable override authorizedHook;

    // - - - STORAGE - - -

    /// @dev Per-pool dynamic fee state packed into a single storage slot
    mapping(PoolId => DynamicFeeState) private _poolFeeState;

    // - - - MODIFIERS - - -

    /// @notice Restricts access to contract owner or authorized hook
    modifier onlyOwnerOrHook() {
        if (msg.sender != owner && msg.sender != authorizedHook) {
            revert Errors.UnauthorizedCaller(msg.sender);
        }
        _;
    }

    /// @notice Restricts access to contract owner, authorized hook, or oracle contract
    modifier onlyOwnerOrHookOrOracle() {
        if (msg.sender != authorizedHook && msg.sender != address(oracle) && msg.sender != owner) {
            revert Errors.UnauthorizedCaller(msg.sender);
        }
        _;
    }

    // - - - CONSTRUCTOR - - -

    /// @notice Initializes the dynamic fee manager with required dependencies
    /// @param contractOwner The address that will own this contract
    /// @param _policyManager The policy manager contract for surge fee parameters
    /// @param oracleAddress The oracle contract for tick volatility data
    /// @param hookAddress The hook contract authorized to call state-changing functions
    constructor(address contractOwner, IPoolPolicyManager _policyManager, address oracleAddress, address hookAddress)
        Owned(contractOwner)
    {
        if (address(_policyManager) == address(0)) revert Errors.ZeroAddress();
        if (oracleAddress == address(0)) revert Errors.ZeroAddress();
        if (hookAddress == address(0)) revert Errors.ZeroAddress();

        policyManager = _policyManager;
        oracle = TruncGeoOracleMulti(oracleAddress);
        authorizedHook = hookAddress;
    }

    // - - - EXTERNAL FUNCTIONS - - -

    /// @inheritdoc IDynamicFeeManager
    function initialize(PoolId poolId, int24) external override onlyOwnerOrHook {
        // Idempotency check: return early if pool already initialized
        if (!_poolFeeState[poolId].isEmpty()) {
            emit AlreadyInitialized(poolId);
            return;
        }

        // Get initial base fee from oracle
        uint24 maxTicksPerBlock = oracle.maxTicksPerBlock(poolId);
        uint32 calculatedBaseFee = _calculateBaseFee(poolId, maxTicksPerBlock);

        // Initialize pool state
        DynamicFeeState initialState = DynamicFeeStateLibrary.empty().setBaseFee(calculatedBaseFee);
        _poolFeeState[poolId] = initialState;

        emit PoolInitialized(poolId);
    }

    /// @inheritdoc IDynamicFeeManager
    function notifyOracleUpdate(PoolId poolId, bool tickWasCapped) external override onlyOwnerOrHookOrOracle {
        DynamicFeeState currentState = _poolFeeState[poolId];
        if (currentState.isEmpty()) revert Errors.NotInitialized();

        uint40 currentTimestamp = uint40(block.timestamp);

        if (tickWasCapped) {
            _handleCapEntry(poolId, currentState, currentTimestamp);
        } else if (currentState.inCap()) {
            _handlePotentialCapExit(poolId, currentState, currentTimestamp);
        }
    }

    // - - - VIEW FUNCTIONS - - -

    /// @inheritdoc IDynamicFeeManager
    function getFeeState(PoolId poolId) external view override returns (uint256 baseFee, uint256 surgeFee) {
        DynamicFeeState currentState = _poolFeeState[poolId];
        if (currentState.isEmpty()) revert Errors.NotInitialized();

        uint24 maxTicksPerBlock = oracle.maxTicksPerBlock(poolId);
        baseFee = _calculateBaseFee(poolId, maxTicksPerBlock);
        surgeFee = _calculateSurge(poolId, currentState, maxTicksPerBlock);
    }

    /// @inheritdoc IDynamicFeeManager
    function isCAPEventActive(PoolId poolId) external view override returns (bool) {
        DynamicFeeState currentState = _poolFeeState[poolId];
        if (currentState.isEmpty()) revert Errors.NotInitialized();
        return currentState.inCap();
    }

    /// @notice Returns the base fee calculated from current oracle data
    /// @dev Convenience function primarily used for testing
    /// @param poolId The pool identifier
    /// @return The current base fee in PPM
    function baseFeeFromCap(PoolId poolId) external view returns (uint32) {
        uint24 maxTicksPerBlock = oracle.maxTicksPerBlock(poolId);
        return _calculateBaseFee(poolId, maxTicksPerBlock);
    }

    // - - - INTERNAL FUNCTIONS - Cap Event Handling - - -

    /// @notice Handles entering a capped trading state
    /// @param poolId The pool identifier
    /// @param currentState The current fee state
    /// @param currentTimestamp The current block timestamp
    function _handleCapEntry(PoolId poolId, DynamicFeeState currentState, uint40 currentTimestamp) private {
        DynamicFeeState updatedState = currentState.updateCapState(true, currentTimestamp);
        _poolFeeState[poolId] = updatedState;

        emit CapToggled(poolId, true);
        _emitFeeStateChanged(poolId, updatedState, currentTimestamp);
    }

    /// @notice Handles potential exit from capped trading state
    /// @param poolId The pool identifier
    /// @param currentState The current fee state
    /// @param currentTimestamp The current block timestamp
    function _handlePotentialCapExit(PoolId poolId, DynamicFeeState currentState, uint40 currentTimestamp) private {
        // Check if surge has decayed to zero
        uint24 maxTicksPerBlock = oracle.maxTicksPerBlock(poolId);
        uint256 currentSurgeFee = _calculateSurge(poolId, currentState, maxTicksPerBlock);

        if (currentSurgeFee == 0) {
            DynamicFeeState updatedState = currentState.setInCap(false);
            _poolFeeState[poolId] = updatedState;

            emit CapToggled(poolId, false);
            _emitFeeStateChanged(poolId, updatedState, currentTimestamp);
        }
    }

    /// @notice Emits fee state change event with current fee calculations
    /// @param poolId The pool identifier
    /// @param feeState The current fee state
    /// @param eventTimestamp The timestamp for the event
    function _emitFeeStateChanged(PoolId poolId, DynamicFeeState feeState, uint40 eventTimestamp) private {
        uint24 maxTicksPerBlock = oracle.maxTicksPerBlock(poolId);
        uint256 updatedBaseFee = _calculateBaseFee(poolId, maxTicksPerBlock);
        uint256 updatedSurgeFee = _calculateSurge(poolId, feeState, maxTicksPerBlock);

        emit FeeStateChanged(poolId, updatedBaseFee, updatedSurgeFee, feeState.inCap(), eventTimestamp);
    }

    // - - - INTERNAL FUNCTIONS - Fee Calculations - - -

    /// @notice Calculates base fee from oracle tick data
    /// @param maxTicksPerBlock The maximum ticks per block from oracle
    /// @return The calculated base fee in PPM
    function _calculateBaseFee(PoolId poolId, uint24 maxTicksPerBlock) private view returns (uint32) {
        uint24 minBaseFee = policyManager.getMinBaseFee(poolId);
        uint24 maxBaseFee = policyManager.getMaxBaseFee(poolId);

        // Use DEFAULT_BASE_FEE_PPM when oracle has no data
        if (maxTicksPerBlock == 0) {
            // Return default or minBaseFee, whichever is higher
            return DEFAULT_BASE_FEE_PPM > minBaseFee ? DEFAULT_BASE_FEE_PPM : minBaseFee;
        }

        // Get the pool-specific base fee factor
        uint32 baseFeeFactor = policyManager.getBaseFeeFactor(poolId);

        uint256 calculatedFee;
        unchecked {
            calculatedFee = uint256(maxTicksPerBlock) * baseFeeFactor;
        }

        // Clamp between min and max
        if (calculatedFee < minBaseFee) return minBaseFee;
        if (calculatedFee > maxBaseFee) return maxBaseFee;
        return uint32(calculatedFee);
    }

    /// @notice Calculates surge fee with linear decay
    /// @param poolId The pool identifier
    /// @param feeState The current fee state
    /// @param oracleMaxTicks The maximum ticks per block from oracle (to avoid redundant calls)
    /// @return The calculated surge fee in PPM
    function _calculateSurge(PoolId poolId, DynamicFeeState feeState, uint24 oracleMaxTicks)
        private
        view
        returns (uint256)
    {
        uint40 capStartTime = feeState.capStart();
        if (capStartTime == 0) return 0;

        uint40 currentTimestamp = uint40(block.timestamp);
        uint32 surgeDuration = uint32(policyManager.getSurgeDecayPeriodSeconds(poolId));

        if (surgeDuration == 0) return 0;

        // Calculate elapsed time since cap started
        uint40 elapsedTime = currentTimestamp > capStartTime ? currentTimestamp - capStartTime : 0;
        if (elapsedTime >= surgeDuration) return 0;

        // Get base fee for surge calculation
        uint256 oracleBaseFee = _calculateBaseFee(poolId, oracleMaxTicks);

        // Calculate maximum surge fee
        uint256 surgeMultiplierPpm = policyManager.getSurgeFeeMultiplierPpm(poolId);
        uint256 maxSurgeFee = oracleBaseFee * surgeMultiplierPpm / PPM_DENOMINATOR;

        // Apply linear decay: surgeFee = maxSurge * (remaining_time / total_time)
        uint256 remainingTime = uint256(surgeDuration) - elapsedTime;
        return maxSurgeFee * remainingTime / surgeDuration;
    }
}
