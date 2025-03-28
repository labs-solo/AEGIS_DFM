// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SortTokens} from "v4-core/test/utils/SortTokens.sol";

// Project imports
import {IFullRangeDynamicFeeManager} from "./interfaces/IFullRangeDynamicFeeManager.sol";
import {IFullRange} from "./interfaces/IFullRange.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {MathUtils} from "./libraries/MathUtils.sol";
import {Errors} from "./errors/Errors.sol";
import {ICAPEventDetector} from "./interfaces/ICAPEventDetector.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {MathUtils} from "./libraries/MathUtils.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { Currency } from "v4-core/src/types/Currency.sol";

/**
 * @title FullRangeDynamicFeeManager
 * @notice Manages dynamic fees for pools including CAP event detection and oracle functionality
 * @dev This contract combines functionalities of the original FeeManager and OracleManager
 */
contract FullRangeDynamicFeeManager is Owned {
    // Using PPM (parts per million) for fee and multiplier values (1e6 = 100%).
    
    struct PoolState {
        // Slot 1: Fee parameters (256 bits)
        uint128 baseFeePpm;         // Reduced from uint256 (max fee won't exceed 2^128)
        uint128 currentFeePpm;      // Reduced from uint256
        
        // Slot 2: Timestamps and flags (256 bits)
        uint48 lastUpdateTimestamp; // Reduced from uint256 (good until year 10,000+)
        uint48 surgeStartTimestamp; // Reduced from uint256
        uint48 lastFeeUpdate;       // Incorporates the previously separate lastFeeUpdate mapping
        bool inSurgeMode;           // 1 byte
        bool isInCapEvent;          // 1 byte
        uint8 reserved;             // 1 byte reserved for future flags
        
        // Slot 3: Oracle data (256 bits)
        uint32 lastOracleUpdateBlock; // Reduced from uint256 (blocks fit in uint32)
        int24 lastOracleTick;        // Already optimized
        // 200 bits remaining in this slot for future use
    }
    
    // Current fee state storage
    mapping(PoolId => PoolState) public poolStates;
    
    // Reference to policy manager
    IPoolPolicy public policy;
    
    // Reference to the pool manager
    IPoolManager public immutable poolManager;
    
    // Reference to the CAP event detector
    ICAPEventDetector public immutable capEventDetector;
    
    // Default surge price multiplier (in PPM)
    uint256 public surgePriceMultiplier = 2000000; // 200% = 2x
    
    // Default surge duration (in seconds) - time after which the surge fee decays
    uint256 public surgeDuration = 86400; // 24h
    
    // Full-surge level (in PPM)
    uint256 public surgeTriggerLevel = 200000; // 20%
    
    // The address of the FullRange contract - used for access control
    address public immutable fullRangeAddress;
    
    // Oracle threshold config
    struct ThresholdConfig {
        uint32 blockUpdateThreshold;   // Minimum blocks before an update.
        int24 tickDiffThreshold;       // Minimum tick difference to trigger an update.
    }
    
    ThresholdConfig public thresholds;
    
    // Minimum time between triggered fee updates
    uint256 public constant MIN_UPDATE_INTERVAL = 1 hours;
    
    // Events
    event DynamicFeeUpdated(PoolId indexed poolId, uint256 oldFeePpm, uint256 newFeePpm, bool capEventOccurred);
    event SurgePriceMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);
    event SurgeTriggerLevelUpdated(uint256 oldLevel, uint256 newLevel);
    event SurgeDecayTimeUpdated(uint256 oldTime, uint256 newTime);
    event SurgeModeChanged(PoolId indexed poolId, bool surgeEnabled);
    event SurgeFeeUpdated(PoolId indexed poolId, uint256 surgeFee, bool capEventOccurred);
    event SurgeDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event FeeAdjustmentApplied(PoolId indexed poolId, uint256 oldFee, uint256 newFee, uint8 adjustmentType);
    
    // Oracle events
    event OracleUpdated(PoolId indexed poolId, int24 oldTick, int24 newTick, bool tickCapped);
    event TickChangeCapped(PoolId indexed poolId, int24 actualChange, int24 cappedChange);
    event CapEventStateChanged(PoolId indexed poolId, bool isInCapEvent);
    event ThresholdsUpdated(uint32 blockUpdateThreshold, int24 tickDiffThreshold);
    
    /**
     * @notice Access control modifier for FullRange contract
     * @dev This is a legacy modifier that will be phased out with the reverse authorization model
     */
    modifier onlyFullRange() {
        // Fast path: direct call from the FullRange contract
        if (msg.sender == fullRangeAddress) {
            _;
            return;
        }
        
        // Since we now use the reverse authorization model,
        // we don't need to validate hook instances anymore
        // Just reject any calls that aren't from the main FullRange contract
        revert Errors.AccessNotAuthorized(msg.sender);
    }
    
    /**
     * @notice Access control modifier for owner or FullRange contract
     * @dev This is a legacy modifier that will be phased out with the reverse authorization model
     */
    modifier onlyOwnerOrFullRange() {
        // Fast path: direct call from owner or FullRange contract
        if (msg.sender == owner || msg.sender == fullRangeAddress) {
            _;
            return;
        }
        
        // Since we now use the reverse authorization model,
        // we don't need to validate hook instances anymore
        // Just reject any calls that aren't from the owner or main FullRange contract
        revert Errors.AccessNotAuthorized(msg.sender);
    }
    
    /**
     * @notice Constructor
     * @param _owner The owner of this contract
     * @param _policy The consolidated policy contract
     * @param _poolManager The pool manager contract
     * @param _fullRange The address of the FullRange contract
     * @param _capEventDetector The CAP event detector interface
     */
    constructor(
        address _owner,
        IPoolPolicy _policy,
        IPoolManager _poolManager,
        address _fullRange,
        ICAPEventDetector _capEventDetector
    ) Owned(_owner) {
        if (address(_policy) == address(0)) revert Errors.ZeroAddress();
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();
        if (_fullRange == address(0)) revert Errors.ZeroAddress();
        if (address(_capEventDetector) == address(0)) revert Errors.ZeroAddress();
        
        policy = _policy;
        poolManager = _poolManager;
        fullRangeAddress = _fullRange;
        capEventDetector = _capEventDetector;
        
        // Initialize threshold config with default values
        thresholds = ThresholdConfig({
            blockUpdateThreshold: 1,
            tickDiffThreshold: 1
        });
    }
    
    /**
     * @notice Get oracle data for a pool from the FullRange contract
     * @dev Implements Reverse Authorization Model for gas efficiency:
     *      - Pulls data from FullRange instead of receiving updates
     *      - Eliminates need for expensive access control validation
     *      - Reduces cross-contract call overhead
     *      - Improves security by restricting write access to contract state
     * @param poolId The pool ID to get data for
     * @return tick The current tick value
     * @return lastUpdateBlock The block number of the last update
     */
    function getOracleData(PoolId poolId) internal view returns (int24 tick, uint32 lastUpdateBlock) {
        // Call FullRange contract to get the latest oracle data
        return IFullRange(fullRangeAddress).getOracleData(poolId);
    }
    
    /**
     * @notice Process oracle data for a pool
     * @dev Only processes data when needed to save gas
     * @param poolId The pool ID to process
     * @return tickCapped Whether the tick was capped
     */
    function processOracleData(PoolId poolId) internal returns (bool tickCapped) {
        // Retrieve data from FullRange
        (int24 tick, uint32 lastBlockUpdate) = getOracleData(poolId);
        PoolState storage pool = poolStates[poolId];
        
        int24 lastTick = pool.lastOracleTick;
        
        // Validate tick is within global bounds
        if (tick < TickMath.MIN_TICK) {
            tick = TickMath.MIN_TICK;
        } else if (tick > TickMath.MAX_TICK) {
            tick = TickMath.MAX_TICK;
        }
        
        // Default to not capped
        tickCapped = false;
        
        // Check if update is needed based on block threshold or tick difference
        if (pool.lastOracleUpdateBlock == 0 || 
            lastBlockUpdate >= pool.lastOracleUpdateBlock + thresholds.blockUpdateThreshold ||
            MathUtils.absDiff(tick, lastTick) >= uint24(thresholds.tickDiffThreshold)) {
            
            // Calculate max allowed tick change based on dynamic fee and scaling factor
            int24 tickScalingFactor = policy.getTickScalingFactor();
            int24 maxTickChange = _calculateMaxTickChange(pool.currentFeePpm, tickScalingFactor);
            
            // Check if tick change exceeds the maximum allowed
            int24 tickChange = tick - lastTick;
            
            if (pool.lastOracleUpdateBlock > 0 && MathUtils.absDiff(tick, lastTick) > uint24(maxTickChange)) {
                // Cap the tick change to the maximum allowed
                tickCapped = true;
                int24 cappedTick = lastTick + (tickChange > 0 ? maxTickChange : -maxTickChange);
                
                emit TickChangeCapped(poolId, tickChange, tickChange > 0 ? maxTickChange : -maxTickChange);
                
                // Use capped tick for the oracle update
                tick = cappedTick;
            }
            
            // Update CAP event status if needed
            _updateCapEventStatus(poolId, tickCapped);
            
            // Update oracle state
            pool.lastOracleUpdateBlock = lastBlockUpdate;
            pool.lastOracleTick = tick;
            
            emit OracleUpdated(poolId, lastTick, tick, tickCapped);
        }
        
        return tickCapped;
    }
    
    /**
     * @notice Update oracle data for a pool
     * @dev Legacy interface preserved for backward compatibility
     *      Now redirects to the more gas-efficient pull-based approach
     * @param poolId The pool ID to update
     * @param tick The current tick value
     */
    function updateOracle(PoolId poolId, int24 tick) external {
        // Fast path: direct call from the FullRange contract
        if (msg.sender == fullRangeAddress) {
            // Process directly when called by FullRange - old code path
            PoolState storage pool = poolStates[poolId];
            pool.lastOracleTick = tick;
            pool.lastOracleUpdateBlock = uint32(block.number);
            return;
        }
        
        // For other callers, we don't update anything - the data should be
        // pulled from FullRange using the reverse authorization model
        revert Errors.AccessNotAuthorized(msg.sender);
    }
    
    /**
     * @notice External function to trigger fee updates with rate limiting
     * @param poolId The pool ID to update fees for
     * @param key The pool key for the pool
     */
    function triggerFeeUpdate(PoolId poolId, PoolKey calldata key) external {
        PoolState storage pool = poolStates[poolId];
        
        // Rate limiting to prevent spam
        if (uint48(block.timestamp) < pool.lastFeeUpdate + MIN_UPDATE_INTERVAL)
            revert Errors.RateLimited();
        
        // Get the ID from the key
        PoolId keyId = key.toId();
        
        // Compare them by casting to bytes32 in memory (not direct conversion)
        bytes32 poolIdBytes;
        bytes32 keyIdBytes;
        
        assembly {
            poolIdBytes := poolId
            keyIdBytes := keyId
        }
        
        // Verify this is a valid pool ID/key combination
        if (keyIdBytes != poolIdBytes) revert Errors.InvalidPoolKey();
        
        // Update fees
        this.updateDynamicFeeIfNeeded(poolId, key);
        
        // Record the update time
        pool.lastFeeUpdate = uint48(block.timestamp);
    }
    
    /**
     * @notice Get the current dynamic fee for a pool
     * @dev Uses the reverse authorization model to pull oracle data
     * @param poolId The pool ID to get the fee for
     * @return The current dynamic fee in PPM
     */
    function getCurrentDynamicFee(PoolId poolId) external view returns (uint256) {
        PoolState storage pool = poolStates[poolId];
        
        // If pool isn't initialized, return the default fee
        if (pool.lastUpdateTimestamp == 0) {
            return policy.getDefaultDynamicFee();
        }
        
        return pool.currentFeePpm;
    }
    
    /**
     * @notice Updates the dynamic fee if needed based on time interval and CAP events
     * @param poolId The pool ID to update fee for
     * @param key The pool key for the pool
     * @return baseFee The current base fee in PPM
     * @return surgeFeeValue The current surge fee in PPM
     * @return wasUpdated Whether fee was updated in this call
     */
    function updateDynamicFeeIfNeeded(
        PoolId poolId,
        PoolKey calldata key
    ) external returns (
        uint256 baseFee,
        uint256 surgeFeeValue,
        bool wasUpdated
    ) {
        // First process the latest oracle data using the reverse authorization model
        processOracleData(poolId);
        
        PoolState storage pool = poolStates[poolId];
        
        // Get the ID from the key
        PoolId keyId = key.toId();
        
        // Compare them by casting to bytes32 in memory (not direct conversion)
        bytes32 poolIdBytes;
        bytes32 keyIdBytes;
        
        assembly {
            poolIdBytes := poolId
            keyIdBytes := keyId
        }
        
        // Verify this is a valid pool ID/key combination
        if (keyIdBytes != poolIdBytes) revert Errors.InvalidPoolKey();
        
        // Initialize if needed
        if (pool.lastUpdateTimestamp == 0) {
            uint256 defaultFee = policy.getDefaultDynamicFee();
            pool.baseFeePpm = uint128(defaultFee);
            pool.currentFeePpm = uint128(defaultFee);
            pool.lastUpdateTimestamp = uint48(block.timestamp);
            
            // Initialize oracle data
            (,int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
            pool.lastOracleUpdateBlock = uint32(block.number);
            pool.lastOracleTick = currentTick;
            pool.isInCapEvent = false;
            
            return (pool.baseFeePpm, pool.currentFeePpm, true);
        }
        
        // Check if we need to update the fee based on time or events
        uint256 timeSinceLastUpdate = block.timestamp - pool.lastUpdateTimestamp;
        
        // Check if we need to update the oracle data first
        _updateOracleIfNeeded(poolId, key);
        
        // Check if update is needed based on time
        bool shouldUpdate = block.timestamp >= pool.lastUpdateTimestamp + 3600; // 1 hour
        
        if (shouldUpdate) {
            // Detect CAP event
            bool capEventOccurred = pool.isInCapEvent;
            
            // Get parameters for fee calculation
            uint256 minTradingFee = policy.getMinimumTradingFee();
            uint256 maxFeePpm = 100000; // 10% max fee
            
            uint256 oldBaseFee = pool.baseFeePpm;
            uint8 adjustmentType = 0;
            
            // Calculate new fee
            uint256 newFeePpm;
            bool surgeEnabled;
            
            if (capEventOccurred) {
                // In CAP event - increase fee
                adjustmentType = 1; // Increase
                newFeePpm = (oldBaseFee * surgePriceMultiplier) / 1000000;
                surgeEnabled = true;
            } else if (pool.inSurgeMode) {
                // Check if surge period has ended
                if (block.timestamp >= pool.surgeStartTimestamp + surgeDuration) {
                    // Return to base fee
                    newFeePpm = oldBaseFee;
                    surgeEnabled = false;
                    adjustmentType = 2; // Decrease
                } else {
                    // Still in surge period - maintain current fee
                    newFeePpm = pool.currentFeePpm;
                    surgeEnabled = true;
                }
            } else {
                // Normal operation - apply small adjustment
                adjustmentType = capEventOccurred ? 1 : 2; // 1=increase, 2=decrease
                
                // Gradual adjustment (±5% per update)
                uint256 adjustmentPct = capEventOccurred ? 1050000 : 950000; // 105% or 95%
                newFeePpm = (oldBaseFee * adjustmentPct) / 1000000;
                surgeEnabled = false;
            }
            
            // Enforce fee bounds
            if (newFeePpm < minTradingFee) {
                newFeePpm = minTradingFee;
            } else if (newFeePpm > maxFeePpm) {
                newFeePpm = maxFeePpm;
            }
            
            // Update state
            if (newFeePpm != pool.currentFeePpm) {
                // Update base fee only in normal mode
                if (!pool.inSurgeMode && !surgeEnabled) {
                    pool.baseFeePpm = uint128(newFeePpm);
                }
                
                pool.currentFeePpm = uint128(newFeePpm);
                pool.inSurgeMode = surgeEnabled;
                
                if (surgeEnabled && !pool.inSurgeMode) {
                    // Just entered surge mode
                    pool.surgeStartTimestamp = uint48(block.timestamp);
                    emit SurgeModeChanged(poolId, true);
                } else if (!surgeEnabled && pool.inSurgeMode) {
                    // Just exited surge mode
                    emit SurgeModeChanged(poolId, false);
                }
                
                emit FeeAdjustmentApplied(poolId, oldBaseFee, newFeePpm, adjustmentType);
                emit DynamicFeeUpdated(poolId, oldBaseFee, newFeePpm, capEventOccurred);
            }
            
            pool.lastUpdateTimestamp = uint48(block.timestamp);
            wasUpdated = true;
        }
        
        return (pool.baseFeePpm, pool.currentFeePpm, wasUpdated);
    }
    
    /**
     * @notice Update oracle data if needed based on thresholds
     * @param poolId The ID of the pool
     * @param key The pool key for the pool
     * @return tickCapped Whether the tick was capped during this update
     */
    function _updateOracleIfNeeded(PoolId poolId, PoolKey calldata key) internal returns (bool tickCapped) {
        PoolState storage pool = poolStates[poolId];
        
        uint32 lastBlockUpdate = pool.lastOracleUpdateBlock;
        int24 lastTick = pool.lastOracleTick;
        
        // Get current tick from pool manager
        (uint160 sqrtPriceX96, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
        
        // Validate currentTick is within global bounds
        if (currentTick < TickMath.MIN_TICK) {
            currentTick = TickMath.MIN_TICK;
        } else if (currentTick > TickMath.MAX_TICK) {
            currentTick = TickMath.MAX_TICK;
        }
        
        // Default to not capped
        tickCapped = false;
        
        // Check if update is needed based on block threshold or tick difference
        if (lastBlockUpdate == 0 || 
            block.number >= lastBlockUpdate + thresholds.blockUpdateThreshold ||
            MathUtils.absDiff(currentTick, lastTick) >= uint24(thresholds.tickDiffThreshold)) {
            
            // Calculate max allowed tick change based on dynamic fee and scaling factor
            int24 tickScalingFactor = policy.getTickScalingFactor();
            int24 maxTickChange = _calculateMaxTickChange(pool.currentFeePpm, tickScalingFactor);
            
            // Check if tick change exceeds the maximum allowed
            int24 tickChange = currentTick - lastTick;
            
            if (lastBlockUpdate > 0 && MathUtils.absDiff(currentTick, lastTick) > uint24(maxTickChange)) {
                // Cap the tick change to the maximum allowed
                tickCapped = true;
                int24 cappedTick = lastTick + (tickChange > 0 ? maxTickChange : -maxTickChange);
                
                emit TickChangeCapped(poolId, tickChange, tickChange > 0 ? maxTickChange : -maxTickChange);
                
                // Use capped tick for the oracle update
                currentTick = cappedTick;
            }
            
            // Update CAP event status if needed
            _updateCapEventStatus(poolId, tickCapped);
            
            // Update oracle state
            pool.lastOracleUpdateBlock = uint32(block.number);
            pool.lastOracleTick = currentTick;
            
            emit OracleUpdated(poolId, lastTick, currentTick, tickCapped);
        }
        
        return tickCapped;
    }
    
    /**
     * @notice Updates the CAP event status for a pool
     * @param poolId The ID of the pool
     * @param tickCapped Whether the tick was capped in the current update
     */
    function _updateCapEventStatus(PoolId poolId, bool tickCapped) internal {
        PoolState storage pool = poolStates[poolId];
        
        // First check with the external CAP event detector
        bool isCapEvent = capEventDetector.detectCAPEvent(poolId);
        
        // If tick was capped, that also counts as a CAP event
        isCapEvent = isCapEvent || tickCapped;
        
        // Update state if changed
        if (pool.isInCapEvent != isCapEvent) {
            pool.isInCapEvent = isCapEvent;
            emit CapEventStateChanged(poolId, isCapEvent);
        }
    }
    
    /**
     * @notice Calculate the maximum tick change allowed based on fee and scaling factor
     * @param dynamicFeePpm The dynamic fee in PPM
     * @param tickScalingFactor The tick scaling factor
     * @return The maximum tick change allowed
     */
    function _calculateMaxTickChange(uint256 dynamicFeePpm, int24 tickScalingFactor) internal pure returns (int24) {
        if (tickScalingFactor <= 0) {
            revert Errors.ParameterOutOfRange(uint256(uint24(tickScalingFactor)), 1, type(uint24).max);
        }
        int24 maxTickChange = int24(uint24(dynamicFeePpm / uint256(uint24(tickScalingFactor))));
        if (maxTickChange == 0) {
            return int24(1);
        }
        return maxTickChange; // Ensure a minimum of 1 tick
    }
    
    /**
     * @notice Initialize fee data for a newly created pool
     * @param poolId The ID of the pool
     */
    function initializeFeeData(PoolId poolId) external onlyFullRange {
        PoolState storage pool = poolStates[poolId];
        
        // Skip if already initialized
        if (pool.lastUpdateTimestamp != 0) return;
        
        // Initialize with default dynamic fee
        uint256 defaultFee = policy.getDefaultDynamicFee();
        
        pool.baseFeePpm = uint128(defaultFee);
        pool.currentFeePpm = uint128(defaultFee);
        pool.lastUpdateTimestamp = uint48(block.timestamp);
        pool.inSurgeMode = false;
        
        emit DynamicFeeUpdated(
            poolId, 
            0, // old fee (zero for initialization)
            defaultFee, 
            false // no CAP event during initialization
        );
    }
    
    /**
     * @notice Initialize oracle data for a newly created pool
     * @param poolId The ID of the pool
     * @param initialTick The initial tick of the pool
     */
    function initializeOracleData(PoolId poolId, int24 initialTick) external onlyFullRange {
        PoolState storage pool = poolStates[poolId];
        
        // Only initialize if not already initialized
        if (pool.lastOracleUpdateBlock == 0) {
            pool.lastOracleUpdateBlock = uint32(block.number);
            pool.lastOracleTick = initialTick;
            pool.isInCapEvent = false;
            
            emit OracleUpdated(poolId, 0, initialTick, false);
        }
    }
    
    /**
     * @notice Sets threshold values for oracle updates
     * @param blockThreshold Minimum blocks between updates
     * @param tickThreshold Minimum tick difference to trigger an update
     */
    function setThresholds(uint32 blockThreshold, int24 tickThreshold) external onlyOwner {
        if (blockThreshold == 0) revert Errors.ParameterOutOfRange(blockThreshold, 1, type(uint32).max);
        if (tickThreshold <= 0) revert Errors.ParameterOutOfRange(uint256(uint24(tickThreshold)), 1, type(uint24).max);
        
        thresholds.blockUpdateThreshold = blockThreshold;
        thresholds.tickDiffThreshold = tickThreshold;
        
        emit ThresholdsUpdated(blockThreshold, tickThreshold);
    }
    
    /**
     * @notice Sets the surge price multiplier
     * @param newMultiplier The new multiplier in PPM (1000000 = 100%)
     */
    function setSurgePriceMultiplier(uint256 newMultiplier) external onlyOwner {
        if (newMultiplier < 1000000 || newMultiplier > 5000000) {
            revert Errors.ParameterOutOfRange(newMultiplier, 1000000, 5000000);
        }
        
        uint256 oldMultiplier = surgePriceMultiplier;
        surgePriceMultiplier = newMultiplier;
        
        emit SurgePriceMultiplierUpdated(oldMultiplier, newMultiplier);
    }
    
    /**
     * @notice Sets the surge duration in seconds
     * @param newDuration The new duration in seconds
     */
    function setSurgeDuration(uint256 newDuration) external onlyOwner {
        if (newDuration < 300 || newDuration > 604800) { // 5 min to 7 days
            revert Errors.ParameterOutOfRange(newDuration, 300, 604800);
        }
        
        uint256 oldDuration = surgeDuration;
        surgeDuration = newDuration;
        
        emit SurgeDurationUpdated(oldDuration, newDuration);
    }
    
    /**
     * @notice Checks if a pool is in a CAP event
     * @param poolId The ID of the pool to check
     * @return Whether the pool is in a CAP event
     */
    function isPoolInCapEvent(PoolId poolId) external view returns (bool) {
        return poolStates[poolId].isInCapEvent;
    }
}