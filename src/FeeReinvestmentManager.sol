// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFeeReinvestmentManager} from "./interfaces/IFeeReinvestmentManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullRangeLiquidityManager} from "./FullRangeLiquidityManager.sol";
import {IFullRangeLiquidityManager} from "./interfaces/IFullRangeLiquidityManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {MathUtils} from "./libraries/MathUtils.sol";
import {Errors} from "./errors/Errors.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IFullRange} from "./interfaces/IFullRange.sol";

/**
 * @title FeeReinvestmentManager
 * @notice Optimized implementation for managing fee claiming, reinvestment, and protocol-owned liquidity (POL)
 * @dev Hybrid approach combining efficiency optimizations with flexibility preservation
 */
contract FeeReinvestmentManager is IFeeReinvestmentManager, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    
    // ================ IMMUTABLE STATE ================
    
    /// @notice The Uniswap V4 pool manager
    IPoolManager public immutable poolManager;
    
    /// @notice The FullRange contract address
    address public immutable fullRange;
    
    // ================ CONFIGURATION ================
    
    /// @notice Operation modes for fee reinvestment
    enum ReinvestmentMode { ALWAYS, THRESHOLD_CHECK, NEVER }
    
    /// @notice Default reinvestment mode
    ReinvestmentMode public defaultReinvestmentMode = ReinvestmentMode.ALWAYS;
    
    /// @notice Governance address for POL withdrawals
    address public governanceTreasury;
    
    /// @notice Fee reinvestment threshold (in basis points, default 10 = 0.1%)
    uint256 public feeReinvestmentThresholdBps = 10;
    
    /// @notice Minimum time between fee collections
    uint256 public minimumFeeCollectionInterval = 1 hours;
    
    /// @notice Minimum time between reinvestments
    uint256 public minimumReinvestmentInterval = 4 hours;
    
    /// @notice Global reinvestment pause switch
    bool public reinvestmentPaused;
    
    /// @notice Fee distribution settings (in PPM, must sum to 1,000,000)
    uint256 public polSharePpm = 100000;      // 10% default
    uint256 public fullRangeSharePpm = 100000; // 10% default
    uint256 public lpSharePpm = 800000;       // 80% default
    
    // ================ POOL STATE ================
    
    /// @notice Consolidated pool fee state structure
    struct PoolFeeState {
        uint256 pendingFee0;                 // Pending token0 fees
        uint256 pendingFee1;                 // Pending token1 fees
        uint256 cumulativeFeeMultiplier;     // Current fee multiplier (0 = default)
        uint256 lastFeeCollectionTimestamp;  // Last time fees were collected
        uint256 lastSuccessfulReinvestment;  // Last time reinvestment succeeded
        bool reinvestmentPaused;             // Pool-specific pause flag
    }
    
    // ================ STORAGE ================
    
    /// @notice Consolidated fee state for each pool
    mapping(PoolId => PoolFeeState) public poolFeeStates;
    
    /// @notice Pending LP fees for token0
    mapping(PoolId => uint256) public lpFeesPending0;
    
    /// @notice Pending LP fees for token1
    mapping(PoolId => uint256) public lpFeesPending1;
    
    /// @notice Reference to the liquidity manager
    IFullRangeLiquidityManager public liquidityManager;
    
    /// @notice Reference to the policy manager
    IPoolPolicy public policyManager;
    
    // ================ CONSTANTS ================
    
    /// @notice Default multiplier value
    uint256 private constant DEFAULT_MULTIPLIER = 1e18;
    
    /// @notice PPM denominator (100%)
    uint256 private constant PPM_DENOMINATOR = 1000000;
    
    // ================ EVENTS ================
    
    /// @notice Emitted when fees are accumulated from pool
    event FeesAccumulated(PoolId indexed poolId, uint256 fee0, uint256 fee1);
    
    /// @notice Emitted when a configuration value is updated
    event ConfigUpdated(string indexed configName, bytes value);
    
    /// @notice Emitted when fee distribution settings are updated
    event FeeDistributionUpdated(uint256 polShare, uint256 fullRangeShare, uint256 lpShare);
    
    /// @notice Emitted when the fee multiplier is updated
    event FeeMultiplierUpdated(PoolId indexed poolId, uint256 oldMultiplier, uint256 newMultiplier);
    
    /// @notice Emitted when reinvestment is paused or resumed
    event ReinvestmentStatusChanged(bool globalPaused);
    
    /// @notice Emitted when pool-specific reinvestment is paused or resumed
    event PoolReinvestmentStatusChanged(PoolId indexed poolId, bool paused);
    
    /// @notice Emitted when reinvestment mode is changed
    event ReinvestmentModeChanged(ReinvestmentMode mode);
    
    /// @notice Emitted when reinvestment thresholds are updated
    event ReinvestmentThresholdUpdated(uint256 thresholdBps);
    
    /// @notice Emitted when LP fees are accumulated
    event LPFeesAccumulated(PoolId indexed poolId, uint256 amount0, uint256 amount1);
    
    /// @notice Emitted when POL is accumulated
    event POLAccrued(PoolId indexed poolId, uint256 amount0, uint256 amount1);
    
    /// @notice Emitted when reinvestment fails
    event ReinvestmentFailed(PoolId indexed poolId, string reason);
    
    // ================ MODIFIERS ================
    
    /**
     * @notice Ensures only governance can call a function
     */
    modifier onlyGovernance() {
        if (msg.sender != governanceTreasury) revert Errors.AccessOnlyGovernance(msg.sender);
        _;
    }
    
    /**
     * @notice Ensures only the FullRange contract can call a function
     */
    modifier onlyFullRange() {
        if (msg.sender != fullRange) revert Errors.AccessNotAuthorized(msg.sender);
        _;
    }
    
    // ================ CONSTRUCTOR ================
    
    /**
     * @notice Constructor initializes the contract with required dependencies
     * @param _poolManager The Uniswap V4 pool manager
     * @param _fullRange The FullRange contract address
     * @param _governance The governance address
     * @param _policyManager The policy manager contract
     */
    constructor(
        IPoolManager _poolManager,
        address _fullRange,
        address _governance,
        IPoolPolicy _policyManager
    ) {
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();
        if (_fullRange == address(0)) revert Errors.ZeroAddress();
        if (_governance == address(0)) revert Errors.ZeroAddress();
        if (address(_policyManager) == address(0)) revert Errors.ZeroAddress();
        
        poolManager = _poolManager;
        fullRange = _fullRange;
        governanceTreasury = _governance;
        policyManager = _policyManager;
    }
    
    // ================ CONFIGURATION FUNCTIONS ================
    
    /**
     * @notice Sets the liquidity manager address
     * @param _liquidityManager The address of the FullRangeLiquidityManager
     */
    function setLiquidityManager(address _liquidityManager) external onlyGovernance {
        if (_liquidityManager == address(0)) revert Errors.ZeroAddress();
        liquidityManager = IFullRangeLiquidityManager(_liquidityManager);
        emit ConfigUpdated("liquidityManager", abi.encode(_liquidityManager));
    }
    
    /**
     * @notice Sets the governance treasury address
     * @param _treasury New treasury address
     */
    function setGovernanceTreasury(address _treasury) external onlyGovernance {
        if (_treasury == address(0)) revert Errors.ZeroAddress();
        governanceTreasury = _treasury;
        emit ConfigUpdated("governanceTreasury", abi.encode(_treasury));
    }
    
    /**
     * @notice Pause global fee reinvestment functionality
     * @param paused True to pause, false to resume
     */
    function setReinvestmentPaused(bool paused) external onlyGovernance {
        reinvestmentPaused = paused;
        emit ReinvestmentStatusChanged(paused);
    }
    
    /**
     * @notice Pause fee reinvestment for a specific pool
     * @param poolId The pool to pause reinvestment for
     * @param paused True to pause, false to resume
     */
    function setPoolReinvestmentPaused(PoolId poolId, bool paused) external onlyGovernance {
        poolFeeStates[poolId].reinvestmentPaused = paused;
        emit PoolReinvestmentStatusChanged(poolId, paused);
    }
    
    /**
     * @notice Sets the fee reinvestment threshold
     * @param newThresholdBps New threshold value (10 = 0.1%)
     */
    function setFeeReinvestmentThreshold(uint256 newThresholdBps) external onlyGovernance {
        if (newThresholdBps > 1000) revert Errors.ParameterOutOfRange(newThresholdBps, 0, 1000);
        feeReinvestmentThresholdBps = newThresholdBps;
        emit ReinvestmentThresholdUpdated(newThresholdBps);
    }
    
    /**
     * @notice Sets the default reinvestment mode
     * @param mode The new reinvestment mode
     */
    function setDefaultReinvestmentMode(ReinvestmentMode mode) external onlyGovernance {
        defaultReinvestmentMode = mode;
        emit ReinvestmentModeChanged(mode);
    }
    
    /**
     * @notice Sets fee distribution percentages
     * @param _polSharePpm Protocol-owned liquidity share in PPM
     * @param _fullRangeSharePpm Full range share in PPM
     * @param _lpSharePpm LP share in PPM
     */
    function setFeeDistribution(
        uint256 _polSharePpm,
        uint256 _fullRangeSharePpm,
        uint256 _lpSharePpm
    ) external onlyGovernance {
        if (_polSharePpm + _fullRangeSharePpm + _lpSharePpm != PPM_DENOMINATOR) {
            revert Errors.AllocationSumError(_polSharePpm, _fullRangeSharePpm, _lpSharePpm, PPM_DENOMINATOR);
        }
        
        polSharePpm = _polSharePpm;
        fullRangeSharePpm = _fullRangeSharePpm;
        lpSharePpm = _lpSharePpm;
        
        emit FeeDistributionUpdated(_polSharePpm, _fullRangeSharePpm, _lpSharePpm);
    }
    
    /**
     * @notice Sets minimum time between fee collections
     * @param newInterval New interval in seconds
     */
    function setMinimumFeeCollectionInterval(uint256 newInterval) external onlyGovernance {
        if (newInterval < 300 || newInterval > 1 days) {
            revert Errors.ParameterOutOfRange(newInterval, 300, 1 days);
        }
        minimumFeeCollectionInterval = newInterval;
        emit ConfigUpdated("minimumFeeCollectionInterval", abi.encode(newInterval));
    }
    
    /**
     * @notice Sets minimum time between reinvestments
     * @param newInterval New interval in seconds
     */
    function setMinimumReinvestmentInterval(uint256 newInterval) external onlyGovernance {
        if (newInterval < 600 || newInterval > 1 days) {
            revert Errors.ParameterOutOfRange(newInterval, 600, 1 days);
        }
        minimumReinvestmentInterval = newInterval;
        emit ConfigUpdated("minimumReinvestmentInterval", abi.encode(newInterval));
    }
    
    // ================ CORE FUNCTIONS ================
    
    /**
     * @notice Processes reinvestment if needed based on current reinvestment mode
     * @param poolId The pool ID
     * @param value Value to use for threshold calculation (e.g., swap amount)
     * @return reinvested Whether fees were successfully reinvested
     * @return autoCompounded Whether auto-compounding was performed
     */
    function processReinvestmentIfNeeded(
        PoolId poolId,
        uint256 value
    ) external override returns (bool reinvested, bool autoCompounded) {
        return _processReinvestment(poolId, OperationType.SWAP, value);
    }
    
    /**
     * @notice Processes reinvestment if needed based on operation type
     * @param poolId The pool ID
     * @param opType The operation type
     * @return reinvested Whether fees were successfully reinvested
     * @return autoCompounded Whether auto-compounding was performed
     */
    function processReinvestmentIfNeeded(
        PoolId poolId,
        OperationType opType
    ) external override returns (bool reinvested, bool autoCompounded) {
        // Use a default value based on operation type
        uint256 defaultValue = opType == OperationType.DEPOSIT ? 1000000 : 500000;
        return _processReinvestment(poolId, opType, defaultValue);
    }
    
    /**
     * @notice Internal implementation of processReinvestmentIfNeeded
     * @param poolId The pool ID
     * @param opType The operation type
     * @param value Value for threshold calculation
     * @return reinvested Whether fees were successfully reinvested
     * @return autoCompounded Whether auto-compounding was performed
     */
    function _processReinvestment(
        PoolId poolId,
        OperationType opType,
        uint256 value
    ) internal nonReentrant returns (bool reinvested, bool autoCompounded) {
        // Circuit breaker check
        PoolFeeState storage feeState = poolFeeStates[poolId];
        if (reinvestmentPaused || feeState.reinvestmentPaused) {
            return (false, false);
        }
        
        // Check if reinvestment should be performed
        if (!_shouldReinvest(poolId, opType, value)) {
            return (false, false);
        }
        
        // For deposits, apply auto-compounding
        if (opType == OperationType.DEPOSIT) {
            autoCompounded = _autoCompoundFees(poolId);
        }
        
        // Execute reinvestment for POL portion
        reinvested = _executeReinvestment(poolId);
        
        return (reinvested, autoCompounded);
    }
    
    /**
     * @notice Reinvests accumulated fees for a specific pool
     * @param poolId The pool ID to reinvest fees for
     * @return amount0 The amount of token0 fees reinvested
     * @return amount1 The amount of token1 fees reinvested
     */
    function reinvestFees(PoolId poolId) external override returns (uint256 amount0, uint256 amount1) {
        // Skip if reinvestment is paused
        PoolFeeState storage feeState = poolFeeStates[poolId];
        if (reinvestmentPaused || feeState.reinvestmentPaused) {
            return (0, 0);
        }
        
        // Collect any pending fees
        collectFees(poolId);
        
        // Get pending fees
        amount0 = feeState.pendingFee0;
        amount1 = feeState.pendingFee1;
        
        if (amount0 == 0 && amount1 == 0) {
            return (0, 0);
        }
        
        // Apply auto-compounding first
        _autoCompoundFees(poolId);
        
        // Then execute POL reinvestment
        bool success = _executeReinvestment(poolId);
        
        // Return the fee amounts
        return success ? (amount0, amount1) : (0, 0);
    }
    
    /**
     * @notice Collects accrued fees from the pool
     * @param poolId The pool ID to collect fees for
     * @return fee0 Amount of token0 fees collected
     * @return fee1 Amount of token1 fees collected
     */
    function collectFees(PoolId poolId) public returns (uint256 fee0, uint256 fee1) {
        PoolFeeState storage feeState = poolFeeStates[poolId];
        
        // Check if enough time has passed since last collection
        if (block.timestamp < feeState.lastFeeCollectionTimestamp + minimumFeeCollectionInterval) {
            return (0, 0);
        }
        
        // Get pool key
        PoolKey memory key = _getPoolKey(poolId);
        if (key.tickSpacing == 0) {
            // Pool key not found, pool may not exist
            return (0, 0);
        }
        
        // Track token balances before take to determine collected fees
        uint256 token0BalanceBefore = 0;
        uint256 token1BalanceBefore = 0;
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        
        if (token0 != address(0)) {
            token0BalanceBefore = ERC20(token0).balanceOf(address(this));
        }
        if (token1 != address(0)) {
            token1BalanceBefore = ERC20(token1).balanceOf(address(this));
        }
        
        // Execute take for token0 fees
        bool takeSuccess = false;
        try poolManager.take(key.currency0, address(this), 0) {
            takeSuccess = true;
        } catch {
            // Take failed, fallback to try token1 only
        }
        
        // Execute take for token1 fees if token0 succeeded
        if (takeSuccess) {
            try poolManager.take(key.currency1, address(this), 0) {
                // Both takes succeeded
            } catch {
                // Token1 take failed, but we continue
            }
        }
        
        // Calculate the delta in balances to determine collected fees
        uint256 token0BalanceAfter = token0 != address(0) ? ERC20(token0).balanceOf(address(this)) : 0;
        uint256 token1BalanceAfter = token1 != address(0) ? ERC20(token1).balanceOf(address(this)) : 0;
        
        fee0 = token0BalanceAfter > token0BalanceBefore ? token0BalanceAfter - token0BalanceBefore : 0;
        fee1 = token1BalanceAfter > token1BalanceBefore ? token1BalanceAfter - token1BalanceBefore : 0;
        
        if (fee0 > 0 || fee1 > 0) {
            // Update pending fees
            feeState.pendingFee0 += fee0;
            feeState.pendingFee1 += fee1;
            feeState.lastFeeCollectionTimestamp = block.timestamp;
            
            emit FeesAccumulated(poolId, fee0, fee1);
        }
        
        return (fee0, fee1);
    }
    
    /**
     * @notice Determines if reinvestment should be performed
     * @param poolId The pool ID
     * @param opType The operation type
     * @param value Value for threshold calculation
     * @return shouldPerform Whether reinvestment should be performed
     */
    function _shouldReinvest(
        PoolId poolId,
        OperationType opType,
        uint256 value
    ) internal view returns (bool shouldPerform) {
        PoolFeeState storage feeState = poolFeeStates[poolId];
        
        // Quick return paths based on reinvestment mode
        if (defaultReinvestmentMode == ReinvestmentMode.NEVER) {
            return false;
        }
        
        // For deposits, always consider reinvestment
        if (opType == OperationType.DEPOSIT) {
            return block.timestamp >= feeState.lastSuccessfulReinvestment + minimumReinvestmentInterval;
        }
        
        if (defaultReinvestmentMode == ReinvestmentMode.ALWAYS) {
            return block.timestamp >= feeState.lastSuccessfulReinvestment + minimumReinvestmentInterval;
        }
        
        // THRESHOLD_CHECK mode - implement proportional threshold check
        uint256 pendingTotal = feeState.pendingFee0 + feeState.pendingFee1;
        if (pendingTotal == 0) return false;
        
        // Get reserves for proportional threshold
        (uint256 reserve0, uint256 reserve1) = _getReserves(poolId);
        uint256 reserveTotal = reserve0 + reserve1;
        
        // If no reserves, use absolute threshold
        if (reserveTotal == 0) {
            return pendingTotal >= 1000;
        }
        
        // Calculate threshold as percentage of reserves
        uint256 thresholdValue = (reserveTotal * feeReinvestmentThresholdBps) / 10000;
        
        // Use minimum threshold for small pools
        if (thresholdValue < 1000) thresholdValue = 1000;
        
        return pendingTotal >= thresholdValue;
    }
    
    /**
     * @notice Auto-compounds fees by increasing the fee multiplier
     * @param poolId The pool ID
     * @return compounded Whether auto-compounding was performed
     */
    function _autoCompoundFees(PoolId poolId) internal returns (bool compounded) {
        PoolFeeState storage feeState = poolFeeStates[poolId];
        
        // Get pending fees
        uint256 fee0 = feeState.pendingFee0;
        uint256 fee1 = feeState.pendingFee1;
        
        if (fee0 == 0 && fee1 == 0) {
            return false;
        }
        
        // Calculate fee distribution
        uint256 fr0 = (fee0 * fullRangeSharePpm) / PPM_DENOMINATOR;
        uint256 fr1 = (fee1 * fullRangeSharePpm) / PPM_DENOMINATOR;
        uint256 pol0 = (fee0 * polSharePpm) / PPM_DENOMINATOR;
        uint256 pol1 = (fee1 * polSharePpm) / PPM_DENOMINATOR;
        uint256 lp0 = fee0 - fr0 - pol0;
        uint256 lp1 = fee1 - fr1 - pol1;
        
        // Handle full range portion through multiplier
        bool frCompounded = false;
        if (fr0 > 0 || fr1 > 0) {
            // Get pool reserves
            (uint256 reserve0, uint256 reserve1) = _getReserves(poolId);
            
            // Skip if no reserves 
            if (reserve0 > 0 && reserve1 > 0) {
                // Calculate the multiplier increase
                uint256 oldMultiplier = _getEffectiveMultiplier(feeState.cumulativeFeeMultiplier);
                
                // Calculate geometric means for fees and reserves
                uint256 feeValue = MathUtils.calculateGeometricShares(fr0, fr1);
                uint256 reserveValue = MathUtils.calculateGeometricShares(reserve0, reserve1);
                
                if (reserveValue > 0) {
                    // Calculate increase factor proportional to reserve value
                    uint256 increaseFactor = (feeValue * DEFAULT_MULTIPLIER) / reserveValue;
                    
                    // Update the multiplier if there's an increase
                    if (increaseFactor > 0) {
                        uint256 newMultiplier = oldMultiplier + increaseFactor;
                        feeState.cumulativeFeeMultiplier = newMultiplier;
                        
                        emit FeeMultiplierUpdated(poolId, oldMultiplier, newMultiplier);
                        
                        // Mark the fees as "invested" through the multiplier
                        feeState.pendingFee0 -= fr0;
                        feeState.pendingFee1 -= fr1;
                        
                        frCompounded = true;
                    }
                }
            }
        }
        
        // Set aside POL fees for reinvestment
        if (pol0 > 0 || pol1 > 0) {
            // Keep in pending fees - they'll be used in executeReinvestment
            emit POLAccrued(poolId, pol0, pol1);
        }
        
        // Handle LP fees
        if (lp0 > 0 || lp1 > 0) {
            // Add to LP pending fees for claiming
            lpFeesPending0[poolId] += lp0;
            lpFeesPending1[poolId] += lp1;
            
            // Remove from pending fees
            feeState.pendingFee0 -= lp0;
            feeState.pendingFee1 -= lp1;
            
            emit LPFeesAccumulated(poolId, lp0, lp1);
        }
        
        return frCompounded;
    }
    
    /**
     * @notice Execute POL reinvestment
     * @param poolId The pool ID
     * @return success Whether reinvestment was successful
     */
    function _executeReinvestment(PoolId poolId) internal returns (bool success) {
        PoolFeeState storage feeState = poolFeeStates[poolId];
        
        // Calculate POL amounts (from pending fees)
        uint256 fee0 = feeState.pendingFee0;
        uint256 fee1 = feeState.pendingFee1;
        
        if (fee0 == 0 && fee1 == 0) {
            return false;
        }
        
        // Calculate POL amounts
        uint256 pol0 = (fee0 * polSharePpm) / PPM_DENOMINATOR;
        uint256 pol1 = (fee1 * polSharePpm) / PPM_DENOMINATOR;
        
        // Skip if no POL amounts
        if (pol0 == 0 && pol1 == 0) {
            return false;
        }
        
        // Get pool reserves for optimal ratios
        (uint256 reserve0, uint256 reserve1) = _getReserves(poolId);
        
        // Calculate optimal investment amounts
        (uint256 optimal0, uint256 optimal1) = MathUtils.calculateReinvestableFees(
            pol0, pol1, reserve0, reserve1
        );
        
        // Ensure optimal amounts don't exceed available fees
        if (optimal0 > pol0) optimal0 = pol0;
        if (optimal1 > pol1) optimal1 = pol1;
        
        // Skip if no reinvestable amounts
        if (optimal0 == 0 && optimal1 == 0) {
            return false;
        }
        
        // Execute reinvestment
        success = _executePolReinvestment(poolId, optimal0, optimal1);
        
        if (success) {
            // Update fee state
            feeState.pendingFee0 = 0;
            feeState.pendingFee1 = 0;
            feeState.lastSuccessfulReinvestment = block.timestamp;
            
            // Emit event
            emit FeesReinvested(poolId, fee0, fee1, optimal0, optimal1);
        } else {
            emit ReinvestmentFailed(poolId, "POL reinvestment execution failed");
        }
        
        return success;
    }
    
    /**
     * @notice Execute POL reinvestment with token approvals
     * @param poolId The pool ID
     * @param amount0 Token0 amount to reinvest
     * @param amount1 Token1 amount to reinvest
     * @return success Whether reinvestment was successful
     */
    function _executePolReinvestment(
        PoolId poolId,
        uint256 amount0,
        uint256 amount1
    ) internal returns (bool success) {
        // Get tokens from pool key
        PoolKey memory key = _getPoolKey(poolId);
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        
        // Skip if liquidity manager not set
        if (address(liquidityManager) == address(0)) {
            return false;
        }
        
        // Safe approve tokens
        _safeApprove(token0, address(liquidityManager), amount0);
        _safeApprove(token1, address(liquidityManager), amount1);
        
        try liquidityManager.reinvestFees(
            poolId,
            0, // No full-range component (handled by auto-compounding)
            0,
            amount0,
            amount1
        ) returns (uint256) {
            success = true;
        } catch {
            success = false;
            // Reset approvals
            _safeApprove(token0, address(liquidityManager), 0);
            _safeApprove(token1, address(liquidityManager), 0);
        }
        
        return success;
    }
    
    // ================ HELPER FUNCTIONS ================
    
    /**
     * @notice Get pool reserves with non-reverting call
     * @param poolId The pool ID
     * @return reserve0 Token0 reserves
     * @return reserve1 Token1 reserves
     */
    function _getReserves(PoolId poolId) internal view returns (uint256 reserve0, uint256 reserve1) {
        // Try getting from IFullRange interface if available
        try IFullRange(fullRange).getPoolInfo(poolId) returns (
            bool isInitialized,
            uint256[2] memory reserves,
            uint128,
            uint256
        ) {
            if (isInitialized) {
                reserve0 = reserves[0];
                reserve1 = reserves[1];
            }
        } catch {
            // Fallback to liquidity manager if available
            if (address(liquidityManager) != address(0)) {
                try liquidityManager.poolInfo(poolId) returns (
                    uint128, // totalShares
                    uint256 r0, // reserve0
                    uint256 r1  // reserve1
                ) {
                    reserve0 = r0;
                    reserve1 = r1;
                } catch {
                    // Silent failure, return zeros
                }
            }
        }
    }
    
    /**
     * @notice Get pool key with non-reverting call
     * @param poolId The pool ID
     * @return key The pool key
     */
    function _getPoolKey(PoolId poolId) internal view returns (PoolKey memory key) {
        // Try getting from fullRange interface
        try IFullRange(fullRange).getPoolKey(poolId) returns (PoolKey memory poolKey) {
            key = poolKey;
        } catch {
            // Fallback to liquidity manager if available
            if (address(liquidityManager) != address(0)) {
                try liquidityManager.poolKeys(poolId) returns (PoolKey memory poolKey) {
                    key = poolKey;
                } catch {
                    // Silent failure, return empty key
                }
            }
        }
    }
    
    /**
     * @notice Get effective multiplier with default handling
     * @param storedMultiplier The stored multiplier value
     * @return effectiveMultiplier The effective multiplier to use
     */
    function _getEffectiveMultiplier(uint256 storedMultiplier) internal pure returns (uint256) {
        return storedMultiplier == 0 ? DEFAULT_MULTIPLIER : storedMultiplier;
    }
    
    /**
     * @notice Safe token approval with redundant call elimination
     * @param token The token to approve
     * @param spender The address to approve
     * @param amount The amount to approve
     */
    function _safeApprove(address token, address spender, uint256 amount) internal {
        if (amount == 0) return;
        
        uint256 currentAllowance = ERC20(token).allowance(address(this), spender);
        if (currentAllowance != amount) {
            if (currentAllowance > 0) {
                SafeTransferLib.safeApprove(ERC20(token), spender, 0);
            }
            SafeTransferLib.safeApprove(ERC20(token), spender, amount);
        }
    }
    
    // ================ VIEW FUNCTIONS ================
    
    /**
     * @notice Get the amount of pending fees for token0 for a pool
     * @param poolId The pool ID
     * @return The amount of pending token0 fees
     */
    function pendingFees0(PoolId poolId) external view override returns (uint256) {
        return poolFeeStates[poolId].pendingFee0;
    }
    
    /**
     * @notice Get the amount of pending fees for token1 for a pool
     * @param poolId The pool ID
     * @return The amount of pending token1 fees
     */
    function pendingFees1(PoolId poolId) external view override returns (uint256) {
        return poolFeeStates[poolId].pendingFee1;
    }
    
    /**
     * @notice Get the cumulative fee multiplier for a pool
     * @param poolId The pool ID
     * @return The cumulative fee multiplier
     */
    function cumulativeFeeMultiplier(PoolId poolId) external view override returns (uint256) {
        return _getEffectiveMultiplier(poolFeeStates[poolId].cumulativeFeeMultiplier);
    }
    
    /**
     * @notice Returns true if fees should be reinvested based on current settings
     * @param poolId The pool ID
     * @param value Value for threshold calculation
     * @return shouldReinvest Whether fees should be reinvested
     */
    function shouldReinvest(PoolId poolId, uint256 value) external view returns (bool) {
        return _shouldReinvest(poolId, OperationType.SWAP, value);
    }
    
    /**
     * @notice Gets LP pending fees for a specific pool
     * @param poolId The pool ID
     * @return pending0 Pending token0 LP fees
     * @return pending1 Pending token1 LP fees
     */
    function getLPPendingFees(PoolId poolId) external view returns (uint256 pending0, uint256 pending1) {
        return (lpFeesPending0[poolId], lpFeesPending1[poolId]);
    }
    
    /**
     * @notice Gets all fee-related information for a pool
     * @param poolId The pool ID
     * @return state The pool fee state
     * @return lpFees0 Pending LP token0 fees
     * @return lpFees1 Pending LP token1 fees
     * @return isPaused Whether reinvestment is paused for this pool
     */
    function getPoolFeeInfo(PoolId poolId) external view returns (
        PoolFeeState memory state,
        uint256 lpFees0,
        uint256 lpFees1,
        bool isPaused
    ) {
        state = poolFeeStates[poolId];
        lpFees0 = lpFeesPending0[poolId];
        lpFees1 = lpFeesPending1[poolId];
        isPaused = reinvestmentPaused || state.reinvestmentPaused;
    }
} 