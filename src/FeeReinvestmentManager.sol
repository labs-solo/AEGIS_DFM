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
import {TokenSafetyWrapper} from "./utils/TokenSafetyWrapper.sol";

/**
 * @title FeeReinvestmentManager
 * @notice Streamlined implementation for managing fee extraction and protocol-owned liquidity (POL)
 * @dev This implementation uses a time-based, permissionless fee collection mechanism that prioritizes 
 *      gas efficiency over immediate fee reinvestment. Fees remain in the pool until explicitly collected.
 *      
 * @dev DESIGN RATIONALE: 
 *      1. Gas Efficiency: By collecting fees periodically rather than on every operation
 *      2. Operational Simplicity: Time-based triggers are easier to audit and reason about
 *      3. Permissionless Collection: Anyone can trigger fee collection after minimum interval
 *      
 * @dev TRADEOFFS:
 *      - Fees are not immediately reinvested, creating an opportunity cost (delayed compounding)
 *      - Relies on external triggers (withdrawals or manual collection) to process fees
 *      - No risk of permanently missing fees as they remain in the pool until collected
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
        uint256 pendingFee0;                 // Pending token0 fees for processing
        uint256 pendingFee1;                 // Pending token1 fees for processing
        uint256 accumulatedFee0;             // Added from FeeTracker
        uint256 accumulatedFee1;             // Added from FeeTracker
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
    
    /// @notice Consolidated event for POL reinvestment
    event POLReinvested(
        PoolId indexed poolId,
        uint256 amount0,
        uint256 amount1,
        uint256 leftover0,
        uint256 leftover1
    );
    
    /// @notice Simple event for reinvestment failures
    event POLReinvestmentFailed(
        PoolId indexed poolId,
        uint256 attempted0,
        uint256 attempted1
    );
    
    /// @notice Emitted when cache update fails
    event CacheUpdateFailed(PoolId indexed poolId);
    
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
     * @dev This interval represents a direct tradeoff:
     *      - SHORTER intervals: More frequent reinvestment but higher gas costs
     *      - LONGER intervals: Lower gas costs but delayed reinvestment (opportunity cost)
     *      
     * @dev The interval doesn't affect fee accrual - fees continue to accumulate in the pool
     *      regardless of collection frequency. It only affects when those fees can be
     *      reinvested to generate additional returns.
     *      
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
     * @notice Comprehensive fee extraction handler for FullRange.sol
     * @dev This function handles all fee extraction logic to keep FullRange.sol lean
     * 
     * @param poolId The pool ID
     * @param feesAccrued The total fees accrued during the operation
     * @return extractDelta The balance delta representing fees to extract
     */
    function handleFeeExtraction(
        PoolId poolId,
        BalanceDelta feesAccrued
    ) external override onlyFullRange returns (BalanceDelta extractDelta) {
        // Enhanced validations
        if (address(liquidityManager) == address(0)) {
            revert Errors.ZeroAddress();
        }
        
        // Skip if no fees accrued
        if (feesAccrued.amount0() == 0 && feesAccrued.amount1() == 0) {
            return BalanceDeltaLibrary.ZERO_DELTA;
        }
        
        // Check if pool exists by querying key from liquidityManager
        PoolKey memory key;
        try liquidityManager.poolKeys(poolId) returns (PoolKey memory _key) {
            key = _key;
            if (key.tickSpacing == 0) {
                // Pool doesn't exist or isn't initialized
                return BalanceDeltaLibrary.ZERO_DELTA;
            }
        } catch {
            // Pool doesn't exist or query failed
            return BalanceDeltaLibrary.ZERO_DELTA;
        }
        
        // Skip if no fees to extract or system paused
        if (reinvestmentPaused || poolFeeStates[poolId].reinvestmentPaused ||
            (feesAccrued.amount0() <= 0 && feesAccrued.amount1() <= 0)) {
            return BalanceDeltaLibrary.ZERO_DELTA;
        }
        
        // Check if sufficient time has passed since last extraction
        if (block.timestamp < poolFeeStates[poolId].lastFeeCollectionTimestamp + minimumCollectionInterval) {
            // Too soon to extract again, return zero delta
            return BalanceDeltaLibrary.ZERO_DELTA;
        }
        
        // Calculate extraction amounts based on protocol fee percentage
        uint256 polSharePpm = getPolSharePpm(poolId);
        
        int256 fee0 = int256(feesAccrued.amount0());
        int256 fee1 = int256(feesAccrued.amount1());
        
        int256 extract0 = (fee0 * int256(polSharePpm)) / int256(PPM_DENOMINATOR);
        int256 extract1 = (fee1 * int256(polSharePpm)) / int256(PPM_DENOMINATOR);
        
        // Validate calculated values for sanity check
        if (extract0 > fee0 || extract1 > fee1) {
            revert Errors.ExtractionAmountExceedsFees();
        }
        
        // Create extraction delta
        extractDelta = toBalanceDelta(int128(extract0), int128(extract1));
        
        // Only proceed if we're extracting something
        if (extract0 > 0 || extract1 > 0) {
            // Update state with the extraction details
            poolFeeStates[poolId].lastFeeCollectionTimestamp = block.timestamp;
            poolFeeStates[poolId].accumulatedFee0 += uint256(extract0);
            poolFeeStates[poolId].accumulatedFee1 += uint256(extract1);
            
            // Emit event for the extraction
            emit FeesExtracted(
                poolId, 
                uint256(extract0), 
                uint256(extract1), 
                msg.sender
            );
            
            // Queue the extracted fees for processing
            queueExtractedFeesForProcessing(
                poolId, 
                uint256(extract0), 
                uint256(extract1)
            );
            
            // After successful fee extraction, update position cache
            try liquidityManager.updatePositionCache(poolId) returns (bool success) {
                // Cache update attempt completed
                if (!success) {
                    emit CacheUpdateFailed(poolId);
                }
            } catch {
                // Cache update failed but continue with extraction
                emit CacheUpdateFailed(poolId);
            }
        }
        
        return extractDelta;
    }

    /**
     * @notice Queues extracted fees for later processing
     * @dev This avoids performing too much work in the liquidity removal transaction
     *      by queueing the fees for processing in a separate transaction
     * 
     * @param poolId The pool ID
     * @param fee0 Amount of token0 fees
     * @param fee1 Amount of token1 fees
     */
    function queueExtractedFeesForProcessing(
        PoolId poolId,
        uint256 fee0,
        uint256 fee1
    ) internal {
        if (fee0 == 0 && fee1 == 0) return;
        
        // Add to pending fees for this pool
        PoolFeeState storage feeState = poolFeeStates[poolId];
        feeState.pendingFee0 += fee0;
        feeState.pendingFee1 += fee1;
        
        // Emit event for queued fees
        emit FeesQueuedForProcessing(poolId, fee0, fee1);
    }

    /**
     * @notice Permissionless function to process queued fees
     * @dev Anyone can call this to process fees that have been extracted but not yet reinvested
     * 
     * @param poolId The pool ID
     * @return reinvested Whether fees were successfully reinvested
     */
    function processQueuedFees(PoolId poolId) external nonReentrant returns (bool reinvested) {
        // Check if there are any pending fees to process
        PoolFeeState storage feeState = poolFeeStates[poolId];
        uint256 fee0 = feeState.pendingFee0;
        uint256 fee1 = feeState.pendingFee1;
        
        if (fee0 == 0 && fee1 == 0) {
            return false; // Nothing to process
        }
        
        // Reset pending fees before processing to prevent reentrancy issues
        feeState.pendingFee0 = 0;
        feeState.pendingFee1 = 0;
        
        // Process the fees
        (uint256 pol0, uint256 pol1) = _processPOLPortion(poolId, fee0, fee1);
        
        // Return true if fees were processed
        reinvested = (pol0 > 0 || pol1 > 0);
        
        if (reinvested) {
            feeState.lastSuccessfulReinvestment = block.timestamp;
            emit FeesReinvested(poolId, fee0, fee1, pol0, pol1);
        }
        
        return reinvested;
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
        if (block.timestamp < poolFeeStates[poolId].lastFeeCollectionTimestamp + minimumCollectionInterval) {
            return false;
        }
        
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
     * @notice Checks if reinvestment should be performed based on the current mode and conditions
     * @param poolId The pool ID
     * @return shouldPerformReinvestment Whether reinvestment should be performed
     */
    function shouldReinvest(PoolId poolId) external view returns (bool shouldPerformReinvestment) {
        return _shouldReinvest(poolId);
    }

    /**
     * @notice Unified function to collect fees, reset leftovers, and return amounts
     * @dev This replaces collectAccumulatedFees, processReinvestmentIfNeeded, and reinvestFees
     * 
     * @param poolId The pool ID to collect fees for
     * @param opType The operation type (for event emission)
     * @return success Whether collection was successful
     * @return amount0 Amount of token0 collected and reset from leftovers 
     * @return amount1 Amount of token1 collected and reset from leftovers
     */
    function collectFees(
        PoolId poolId,
        OperationType opType
    ) external nonReentrant returns (
        bool success,
        uint256 amount0,
        uint256 amount1
    ) {
        // Check overall reinvestment conditions
        if (!_shouldReinvest(poolId)) {
            return (false, 0, 0);
        }
        
        // Try to collect fees
        success = _collectAccumulatedFees(poolId);
        
        // Always handle leftover tokens when successful
        if (success) {
            PoolFeeState storage feeState = poolFeeStates[poolId];
            amount0 = feeState.leftoverToken0;
            amount1 = feeState.leftoverToken1;
            
            // Reset leftover amounts
            feeState.leftoverToken0 = 0;
            feeState.leftoverToken1 = 0;
        }
        
        return (success, amount0, amount1);
    }
    
    /**
     * @notice Unlock callback for fee extraction
     * @dev Uses the "zero-take" technique to collect accrued fees from the pool. This approach
     *      extracts available fees without specifying explicit amounts by measuring token balance
     *      differences before and after the take operation.
     *      
     * @dev This method is gas-efficient and doesn't require tracking exact fee accruals, but
     *      it assumes the contract's balance changes are solely due to fee collection. The
     *      approach is safe because no fees are permanently lost - uncollected fees remain
     *      in the pool until a future collection event.
     *      
     * @param data The encoded callback data
     * @return The result of the operation (success flag, extracted token amounts)
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
        uint256 total0 = pol0 + leftover0;
        uint256 total1 = pol1 + leftover1;
        
        if (total0 == 0 && total1 == 0) {
            return (0, 0);
        }
        
        // Get pool reserves for optimal ratios
        (uint256 reserve0, uint256 reserve1) = _getReserves(poolId);
        
        // Calculate optimal investment amounts
        (uint256 optimal0, uint256 optimal1) = MathUtils.calculateReinvestableFees(
            total0, total1, reserve0, reserve1
        );
        
        // Ensure optimal amounts don't exceed available fees
        if (optimal0 > total0) optimal0 = total0;
        if (optimal1 > total1) optimal1 = total1;
        
        // Skip if no reinvestable amounts
        if (optimal0 == 0 && optimal1 == 0) {
            return (0, 0);
        }
        
        // Store original leftover values
        uint256 originalLeftover0 = feeState.leftoverToken0;
        uint256 originalLeftover1 = feeState.leftoverToken1;
        
        // Clear leftovers - will be restored on failure
        feeState.leftoverToken0 = 0;
        feeState.leftoverToken1 = 0;
        
        // Execute reinvestment with external calls BEFORE state updates
        bool success = _executePolReinvestment(poolId, optimal0, optimal1);
        
        if (success) {
            // Calculate new leftovers after successful operation
            uint256 newLeftover0 = total0 - optimal0;
            uint256 newLeftover1 = total1 - optimal1;
            
            // Only store non-zero leftover amounts
            if (newLeftover0 > 0) feeState.leftoverToken0 = newLeftover0;
            if (newLeftover1 > 0) feeState.leftoverToken1 = newLeftover1;
            
            // Update last successful timestamp
            feeState.lastSuccessfulReinvestment = block.timestamp;
            
            // Emit event for POL accrual - single event instead of multiple
            emit POLReinvested(poolId, optimal0, optimal1, newLeftover0, newLeftover1);
            
            return (optimal0, optimal1);
        } else {
            // On failure, restore the original leftovers plus current amounts
            feeState.leftoverToken0 = originalLeftover0 + pol0;
            feeState.leftoverToken1 = originalLeftover1 + pol1;
            
            // Emit single failure event
            emit POLReinvestmentFailed(poolId, optimal0, optimal1);
            
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
        
        // Simplified approval logic - approve only what's needed
        if (amount0 > 0) TokenSafetyWrapper.safeApprove(token0, address(liquidityManager), amount0);
        if (amount1 > 0) TokenSafetyWrapper.safeApprove(token1, address(liquidityManager), amount1);
        
        try liquidityManager.reinvestFees(
            poolId,
            amount0,
            amount1
        ) returns (uint256) {
            success = true;
        } catch {
            success = false;
            // Reset approvals
            if (amount0 > 0) TokenSafetyWrapper.safeRevokeApproval(token0, address(liquidityManager));
            if (amount1 > 0) TokenSafetyWrapper.safeRevokeApproval(token1, address(liquidityManager));
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
     * @notice Get information about leftover tokens from previous reinvestments
     * @param poolId The pool ID
     * @return leftover0 Leftover token0 amount
     * @return leftover1 Leftover token1 amount
     */
    function getLeftoverTokens(PoolId poolId) external view returns (uint256 leftover0, uint256 leftover1) {
        PoolFeeState storage feeState = poolFeeStates[poolId];
        return (feeState.leftoverToken0, feeState.leftoverToken1);
    }

    /**
     * @notice Minimal state consistency check
     * @dev Lightweight function for off-chain monitoring to detect issues
     * @param poolId The pool ID to check
     * @return isConsistent Whether state is consistent
     * @return leftover0 Amount of token0 leftovers
     * @return leftover1 Amount of token1 leftovers
     */
    function checkStateConsistency(PoolId poolId) external view returns (
        bool isConsistent,
        uint256 leftover0,
        uint256 leftover1
    ) {
        PoolFeeState storage feeState = poolFeeStates[poolId];
        
        // Return leftover amounts
        leftover0 = feeState.leftoverToken0;
        leftover1 = feeState.leftoverToken1;
        
        // Skip detailed checks if no leftovers
        if (leftover0 == 0 && leftover1 == 0) {
            return (true, 0, 0);
        }
        
        // Get token balances
        PoolKey memory key = _getPoolKey(poolId);
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        
        uint256 balance0 = token0 != address(0) ? TokenSafetyWrapper.safeBalanceOf(token0, address(this)) : 0;
        uint256 balance1 = token1 != address(0) ? TokenSafetyWrapper.safeBalanceOf(token1, address(this)) : 0;
        
        // Check if contract has enough balance to cover leftovers
        isConsistent = (balance0 >= leftover0) && (balance1 >= leftover1);
        
        return (isConsistent, leftover0, leftover1);
    }

    /**
     * @notice View function to get pool operational status
     * @dev Designed for off-chain monitoring services
     * @param poolId The pool ID to check
     * @return lastCollection Last collection timestamp
     * @return lastSuccess Last successful reinvestment timestamp
     * @return leftover0 Amount of token0 leftovers
     * @return leftover1 Amount of token1 leftovers
     * @return isPaused Whether reinvestment is paused for this pool
     */
    function getPoolOperationalStatus(PoolId poolId) external view returns (
        uint256 lastCollection,
        uint256 lastSuccess,
        uint256 leftover0,
        uint256 leftover1,
        bool isPaused
    ) {
        PoolFeeState storage feeState = poolFeeStates[poolId];
        
        return (
            feeState.lastFeeCollectionTimestamp,
            feeState.lastSuccessfulReinvestment,
            feeState.leftoverToken0,
            feeState.leftoverToken1,
            feeState.reinvestmentPaused || reinvestmentPaused
        );
    }

    /**
     * @notice Get the cumulative fee multiplier for a pool
     * @param poolId The pool ID
     * @return The cumulative fee multiplier
     */
    function cumulativeFeeMultiplier(PoolId poolId) external view override returns (uint256) {
        // Return accumulated fees relative to initial state
        PoolFeeState storage feeState = poolFeeStates[poolId];
        if (feeState.accumulatedFee0 == 0 && feeState.accumulatedFee1 == 0) {
            return 1e18; // No fees accumulated yet
        }
        return 1e18 + ((feeState.accumulatedFee0 + feeState.accumulatedFee1) * 1e18) / PPM_DENOMINATOR;
    }
    
    /**
     * @notice Get the amount of pending fees for token0 for a pool
     * @param poolId The pool ID
     * @return The amount of pending token0 fees
     */
    function pendingFees0(PoolId poolId) external view override returns (uint256) {
        // Return both queued and leftover fees
        PoolFeeState storage feeState = poolFeeStates[poolId];
        return feeState.pendingFee0 + feeState.leftoverToken0;
    }
    
    /**
     * @notice Get the amount of pending fees for token1 for a pool
     * @param poolId The pool ID
     * @return The amount of pending token1 fees
     */
    function pendingFees1(PoolId poolId) external view override returns (uint256) {
        // Return both queued and leftover fees
        PoolFeeState storage feeState = poolFeeStates[poolId];
        return feeState.pendingFee1 + feeState.leftoverToken1;
    }
} 