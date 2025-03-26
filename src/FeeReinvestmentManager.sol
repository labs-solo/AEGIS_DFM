// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFeeReinvestmentManager} from "./interfaces/IFeeReinvestmentManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullRangeLiquidityManager} from "./FullRangeLiquidityManager.sol";
import {IFullRangeLiquidityManager} from "./interfaces/IFullRangeLiquidityManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {MathUtils} from "./libraries/MathUtils.sol";
import {Errors} from "./errors/Errors.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IFullRange} from "./interfaces/IFullRange.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

/**
 * @title FeeReinvestmentManager
 * @notice Streamlined implementation for managing fee extraction and protocol-owned liquidity (POL)
 * @dev Optimized approach focusing on POL fee extraction and reinvestment
 */
contract FeeReinvestmentManager is IFeeReinvestmentManager, ReentrancyGuard, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    
    // ================ IMMUTABLE STATE ================
    
    /// @notice The Uniswap V4 pool manager
    IPoolManager public immutable poolManager;
    
    /// @notice The FullRange contract address
    address public immutable fullRange;
    
    // ================ CONFIGURATION ================
    
    /// @notice Governance address for POL withdrawals
    address public governanceTreasury;
    
    /// @notice Minimum time between fee collections
    uint256 public minimumCollectionInterval = 6 hours;
    
    /// @notice Maximum time between fee collections
    uint256 public maximumCollectionInterval = 7 days;
    
    /// @notice Global reinvestment pause switch
    bool public reinvestmentPaused;
    
    // ================ POOL STATE ================
    
    /// @notice Consolidated pool fee state structure
    struct PoolFeeState {
        uint256 lastFeeCollectionTimestamp;  // Last time fees were collected
        uint256 lastSuccessfulReinvestment;  // Last time reinvestment succeeded
        bool reinvestmentPaused;             // Pool-specific pause flag
        uint256 leftoverToken0;              // Leftover token0 from previous reinvestment
        uint256 leftoverToken1;              // Leftover token1 from previous reinvestment
    }
    
    /// @notice Callback data for extraction operations
    struct CallbackData {
        PoolId poolId;
        address token0;
        address token1;
    }
    
    // ================ STORAGE ================
    
    /// @notice Consolidated fee state for each pool
    mapping(PoolId => PoolFeeState) public poolFeeStates;
    
    /// @notice Reference to the liquidity manager
    IFullRangeLiquidityManager public liquidityManager;
    
    /// @notice Reference to the policy manager
    IPoolPolicy public policyManager;
    
    // ================ CONSTANTS ================
    
    /// @notice Default POL share
    uint256 private constant DEFAULT_POL_SHARE_PPM = 100000; // 10%
    
    /// @notice PPM denominator (100%)
    uint256 private constant PPM_DENOMINATOR = 1000000;
    
    // ================ EVENTS ================
    
    /// @notice Emitted when fees are accumulated from pool
    event FeesAccumulated(PoolId indexed poolId, uint256 fee0, uint256 fee1);
    
    /// @notice Emitted when a configuration value is updated
    event ConfigUpdated(string indexed configName, bytes value);
    
    /// @notice Emitted when reinvestment is paused or resumed
    event ReinvestmentStatusChanged(bool globalPaused);
    
    /// @notice Emitted when pool-specific reinvestment is paused or resumed
    event PoolReinvestmentStatusChanged(PoolId indexed poolId, bool paused);
    
    /// @notice Emitted when POL is accumulated
    event POLAccrued(PoolId indexed poolId, uint256 amount0, uint256 amount1);
    
    /// @notice Emitted when reinvestment fails
    event ReinvestmentFailed(PoolId indexed poolId, string reason);
    
    /// @notice Emitted when reinvestment succeeds
    event POLFeesProcessed(PoolId indexed poolId, uint256 pol0, uint256 pol1, bool reinvested);
    
    /// @notice Emitted when collection interval is updated
    event CollectionIntervalUpdated(uint256 newIntervalSeconds);
    
    /// @notice Emitted when leftover tokens are included in reinvestment
    event LeftoverTokensProcessed(PoolId indexed poolId, uint256 leftover0, uint256 leftover1);
    
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
    
    /**
     * @notice Ensures the pool manager can call a function
     */
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert Errors.AccessOnlyPoolManager(msg.sender);
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
     * @notice Sets the collection interval for permissionless fee collection
     * @param newIntervalSeconds The new interval in seconds
     */
    function setCollectionInterval(uint256 newIntervalSeconds) external onlyGovernance {
        if (newIntervalSeconds < 1 hours) {
            revert Errors.CollectionIntervalTooShort(newIntervalSeconds, 1 hours);
        }
        if (newIntervalSeconds > 7 days) {
            revert Errors.CollectionIntervalTooLong(newIntervalSeconds, 7 days);
        }
        
        minimumCollectionInterval = newIntervalSeconds;
        emit CollectionIntervalUpdated(newIntervalSeconds);
    }
    
    // ================ CORE FUNCTIONS ================
    
    /**
     * @notice Calculates the fee delta to extract for protocol purposes
     * @param poolId The pool ID
     * @param feesAccrued The total fees accrued
     * @return extractDelta The balance delta representing the portion to extract
     */
    function calculateExtractDelta(
        PoolId poolId,
        BalanceDelta feesAccrued
    ) external view override returns (BalanceDelta extractDelta) {
        // Skip if no fees to extract or system paused
        if (reinvestmentPaused || poolFeeStates[poolId].reinvestmentPaused ||
            (feesAccrued.amount0() <= 0 && feesAccrued.amount1() <= 0)) {
            return BalanceDeltaLibrary.ZERO_DELTA;
        }
        
        // Get POL share for this pool (either pool-specific or global)
        uint256 polSharePpm = getPolSharePpm(poolId);
        
        // Calculate portions to extract for POL
        int256 fee0 = feesAccrued.amount0() > 0 ? int256(feesAccrued.amount0()) : int256(0);
        int256 fee1 = feesAccrued.amount1() > 0 ? int256(feesAccrued.amount1()) : int256(0);
        
        // Use unchecked for gas optimization as these calculations cannot overflow
        unchecked {
            int256 extract0 = (fee0 * int256(polSharePpm)) / int256(PPM_DENOMINATOR);
            int256 extract1 = (fee1 * int256(polSharePpm)) / int256(PPM_DENOMINATOR);
            
            return toBalanceDelta(int128(extract0), int128(extract1));
        }
    }
    
    /**
     * @notice Internal function to check if reinvestment should be performed
     * @param poolId The pool ID
     * @return shouldPerformReinvestment Whether reinvestment should be performed
     */
    function _shouldReinvest(PoolId poolId) internal view returns (bool shouldPerformReinvestment) {
        // Skip if reinvestment is paused
        if (reinvestmentPaused || poolFeeStates[poolId].reinvestmentPaused) {
            return false;
        }
        
        // Check if enough time has passed since last collection
        PoolFeeState storage feeState = poolFeeStates[poolId];
        if (block.timestamp < feeState.lastFeeCollectionTimestamp + minimumCollectionInterval) {
            return false;
        }
        
        // Default to true if all checks pass
        return true;
    }

    /**
     * @notice Internal function to collect and process accumulated fees
     * @param poolId The pool ID to collect fees for
     * @return extracted Whether fees were successfully extracted and processed
     */
    function _collectAccumulatedFees(PoolId poolId) internal returns (bool extracted) {
        PoolFeeState storage feeState = poolFeeStates[poolId];
        
        // Check if system is paused
        if (reinvestmentPaused || feeState.reinvestmentPaused) {
            revert Errors.PoolReinvestmentBlocked(poolId);
        }
        
        // Get pool key
        PoolKey memory key = _getPoolKey(poolId);
        if (key.tickSpacing == 0) {
            revert Errors.PoolNotInitialized(poolId);
        }
        
        // Prepare callback data
        bytes memory data = abi.encode(
            CallbackData({
                poolId: poolId,
                token0: Currency.unwrap(key.currency0),
                token1: Currency.unwrap(key.currency1)
            })
        );

        // Call unlock to extract fees
        bytes memory result = poolManager.unlock(data);
        
        // Decode the result
        (bool success, uint256 extracted0, uint256 extracted1) = abi.decode(result, (bool, uint256, uint256));
        
        if (!success || (extracted0 == 0 && extracted1 == 0)) {
            return false;
        }

        // Update last fee collection timestamp
        feeState.lastFeeCollectionTimestamp = block.timestamp;

        // Get leftover tokens from previous attempts
        uint256 leftover0 = feeState.leftoverToken0;
        uint256 leftover1 = feeState.leftoverToken1;

        // Calculate total tokens available for reinvestment
        uint256 total0 = extracted0 + leftover0;
        uint256 total1 = extracted1 + leftover1;

        // Emit fee extraction event
        emit FeesExtracted(poolId, extracted0, extracted1, msg.sender);

        // Process POL portion (10%)
        (uint256 pol0, uint256 pol1) = _processPOLPortion(poolId, total0, total1);
        
        // Emit POL fees processed event
        emit POLFeesProcessed(poolId, pol0, pol1, true);

        return true;
    }

    /**
     * @notice Internal implementation of fee reinvestment logic
     * @param poolId The pool ID
     * @return reinvested Whether fees were successfully reinvested
     * @return autoCompounded Whether auto-compounding was performed
     */
    function _processReinvestmentIfNeeded(
        PoolId poolId
    ) internal returns (bool reinvested, bool autoCompounded) {
        // Check if enough time has passed since last collection
        PoolFeeState storage feeState = poolFeeStates[poolId];
        uint256 collectionThreshold = minimumCollectionInterval;
        if (block.timestamp < feeState.lastFeeCollectionTimestamp + collectionThreshold) {
            revert Errors.ValidationDeadlinePassed(
                uint32(feeState.lastFeeCollectionTimestamp + collectionThreshold), 
                uint32(block.timestamp)
            );
        }

        // Check if we should reinvest
        if (!_shouldReinvest(poolId)) {
            return (false, false);
        }
        
        // Try to collect fees
        bool success = _collectAccumulatedFees(poolId);
        if (!success) {
            return (false, false);
        }
        return (true, false);
    }

    /**
     * @notice Checks if reinvestment should be performed based on the current mode and conditions
     * @param poolId The pool ID
     * @param swapValue Used for threshold calculations
     * @return shouldPerformReinvestment Whether reinvestment should be performed
     */
    function shouldReinvest(PoolId poolId, uint256 swapValue) external view returns (bool shouldPerformReinvestment) {
        return _shouldReinvest(poolId);
    }

    /**
     * @notice Permissionless function to collect and process accumulated fees
     * @param poolId The pool ID to collect fees for
     * @return extracted Whether fees were successfully extracted and processed
     */
    function collectAccumulatedFees(PoolId poolId) external nonReentrant returns (bool extracted) {
        // Check if enough time has passed since last collection
        PoolFeeState storage feeState = poolFeeStates[poolId];
        uint256 collectionThreshold = minimumCollectionInterval;
        if (block.timestamp < feeState.lastFeeCollectionTimestamp + collectionThreshold) {
            revert Errors.ValidationDeadlinePassed(
                uint32(feeState.lastFeeCollectionTimestamp + collectionThreshold), 
                uint32(block.timestamp)
            );
        }

        return _collectAccumulatedFees(poolId);
    }

    /**
     * @notice Processes reinvestment if needed based on value threshold
     * @param poolId The pool ID
     * @param value Used for threshold calculations
     * @return reinvested Whether fees were successfully reinvested
     * @return autoCompounded Whether auto-compounding was performed
     */
    function processReinvestmentIfNeeded(
        PoolId poolId,
        uint256 value
    ) external nonReentrant returns (bool reinvested, bool autoCompounded) {
        return _processReinvestmentIfNeeded(poolId);
    }

    /**
     * @notice Processes reinvestment if needed based on operation type
     * @param poolId The pool ID
     * @param opType The operation type (SWAP, DEPOSIT, WITHDRAWAL)
     * @return reinvested Whether fees were successfully reinvested
     * @return autoCompounded Whether auto-compounding was performed
     */
    function processReinvestmentIfNeeded(
        PoolId poolId,
        OperationType opType
    ) external nonReentrant returns (bool reinvested, bool autoCompounded) {
        return _processReinvestmentIfNeeded(poolId);
    }

    /**
     * @notice Reinvests accumulated fees for a specific pool
     * @param poolId The pool ID to reinvest fees for
     * @return amount0 The amount of token0 fees reinvested
     * @return amount1 The amount of token1 fees reinvested
     */
    function reinvestFees(PoolId poolId) external returns (uint256 amount0, uint256 amount1) {
        // Skip if reinvestment is paused
        if (reinvestmentPaused || poolFeeStates[poolId].reinvestmentPaused) {
            return (0, 0);
        }
        
        // Get pool key
        PoolKey memory key = _getPoolKey(poolId);
        if (key.tickSpacing == 0) {
            revert Errors.PoolNotInitialized(poolId);
        }
        
        // Try to collect fees first
        bool success = _collectAccumulatedFees(poolId);
        if (!success) {
            return (0, 0);
        }
        
        // Get current leftover amounts
        PoolFeeState storage feeState = poolFeeStates[poolId];
        amount0 = feeState.leftoverToken0;
        amount1 = feeState.leftoverToken1;
        
        // Reset leftover amounts since we're reinvesting them
        feeState.leftoverToken0 = 0;
        feeState.leftoverToken1 = 0;
        
        return (amount0, amount1);
    }
    
    /**
     * @notice Unlock callback for fee extraction
     * @param data The encoded callback data
     * @return The result of the operation
     */
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        // Decode callback data
        CallbackData memory cb = abi.decode(data, (CallbackData));
        
        // Get pool ID and tokens
        PoolId poolId = cb.poolId;
        address token0 = cb.token0;
        address token1 = cb.token1;
        
        // Try to extract fees using take(0) technique
        uint256 token0Before = token0 != address(0) ? ERC20(token0).balanceOf(address(this)) : 0;
        uint256 token1Before = token1 != address(0) ? ERC20(token1).balanceOf(address(this)) : 0;
        
        // Execute zero-take to collect fees
        try poolManager.take(Currency.wrap(token0), address(this), 0) {
            // First take succeeded
        } catch {
            // Take failed, return failure
            return abi.encode(false, 0, 0);
        }
        
        try poolManager.take(Currency.wrap(token1), address(this), 0) {
            // Second take succeeded
        } catch {
            // Take failed but continue since we might have token0 fees
        }
        
        // Calculate extracted amounts
        uint256 token0After = token0 != address(0) ? ERC20(token0).balanceOf(address(this)) : 0;
        uint256 token1After = token1 != address(0) ? ERC20(token1).balanceOf(address(this)) : 0;
        
        uint256 extracted0 = token0After > token0Before ? token0After - token0Before : 0;
        uint256 extracted1 = token1After > token1Before ? token1After - token1Before : 0;
        
        // Return success and extracted amounts
        return abi.encode(true, extracted0, extracted1);
    }
    
    /**
     * @notice Process the POL portion of fees
     * @param poolId The pool ID
     * @param pol0 Amount of token0 for POL
     * @param pol1 Amount of token1 for POL
     * @return amount0 The amount of token0 reinvested
     * @return amount1 The amount of token1 reinvested
     */
    function _processPOLPortion(
        PoolId poolId,
        uint256 pol0,
        uint256 pol1
    ) internal returns (uint256 amount0, uint256 amount1) {
        PoolFeeState storage feeState = poolFeeStates[poolId];
        
        // Get previous leftover amounts
        uint256 leftover0 = feeState.leftoverToken0;
        uint256 leftover1 = feeState.leftoverToken1;
        
        // Add any leftover amounts from previous reinvestment attempts
        pol0 += leftover0;
        pol1 += leftover1;
        
        // Emit event if we're processing leftovers
        if (leftover0 > 0 || leftover1 > 0) {
            emit LeftoverTokensProcessed(poolId, leftover0, leftover1);
        }
        
        if (pol0 == 0 && pol1 == 0) {
            return (0, 0);
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
            return (0, 0);
        }
        
        // Execute reinvestment
        bool success = _executePolReinvestment(poolId, optimal0, optimal1);
        
        if (success) {
            // Calculate and store the leftover amounts
            feeState.leftoverToken0 = pol0 - optimal0;
            feeState.leftoverToken1 = pol1 - optimal1;
            
            // Emit event for POL accrual
            emit POLAccrued(poolId, optimal0, optimal1);
            emit FeesReinvested(poolId, pol0, pol1, optimal0, optimal1);
            return (optimal0, optimal1);
        } else {
            // If reinvestment failed, store all amounts as leftovers
            feeState.leftoverToken0 = pol0;
            feeState.leftoverToken1 = pol1;
            
            emit ReinvestmentFailed(poolId, "POL reinvestment execution failed");
            return (0, 0);
        }
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
     * @notice Get the POL share percentage for a specific pool
     * @param poolId The pool ID to get the POL share for
     * @return The POL share in PPM (parts per million)
     */
    function getPolSharePpm(PoolId poolId) public view override returns (uint256) {
        // First check if pool-specific POL shares are enabled
        if (address(policyManager) != address(0)) {
            // Use the new method that supports pool-specific POL shares
            return policyManager.getPoolPOLShare(poolId);
        }
        
        // Default to 10% if no policy manager or no pool-specific value
        return DEFAULT_POL_SHARE_PPM; 
    }
    
    /**
     * @notice Get the cumulative fee multiplier for a pool
     * @param poolId The pool ID
     * @return The cumulative fee multiplier
     */
    function cumulativeFeeMultiplier(PoolId poolId) external view override returns (uint256) {
        // Fixed at 1e18 in the new model
        return 1e18;
    }
    
    /**
     * @notice Get the amount of pending fees for token0 for a pool
     * @param poolId The pool ID
     * @return The amount of pending token0 fees
     */
    function pendingFees0(PoolId poolId) external view override returns (uint256) {
        // This always returns 0 in the new model since we don't track pending fees
        return 0;
    }
    
    /**
     * @notice Get the amount of pending fees for token1 for a pool
     * @param poolId The pool ID
     * @return The amount of pending token1 fees
     */
    function pendingFees1(PoolId poolId) external view override returns (uint256) {
        // This always returns 0 in the new model since we don't track pending fees
        return 0;
    }
    
    /**
     * @notice Get information about leftover tokens from previous reinvestments
     * @param poolId The pool ID
     * @return leftover0 Leftover token0 amount
     * @return leftover1 Leftover token1 amount
     */
    function getLeftoverTokens(PoolId poolId) external view returns (uint256 leftover0, uint256 leftover1) {
        PoolFeeState storage feeState = poolFeeStates[poolId];
        return (feeState.leftoverToken0, feeState.leftoverToken1);
    }
} 