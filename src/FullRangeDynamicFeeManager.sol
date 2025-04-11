// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SortTokens} from "v4-core/test/utils/SortTokens.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";

// Project imports
import {IFullRangeDynamicFeeManager} from "./interfaces/IFullRangeDynamicFeeManager.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {MathUtils} from "./libraries/MathUtils.sol";
import {Errors} from "./errors/Errors.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {MathUtils} from "./libraries/MathUtils.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";

/**
 * @title FullRangeDynamicFeeManager
 * @notice Manages dynamic fees for pools including CAP event detection (based on oracle tick capping) and oracle functionality
 * @dev This contract combines functionalities of the original FeeManager and OracleManager
 */
contract FullRangeDynamicFeeManager is Owned {
    // Using PPM (parts per million) for fee and multiplier values (1e6 = 100%).
    
    // --- Constants for Surge Fees ---
    uint256 public constant INITIAL_SURGE_FEE_PPM = 5000; // Example: 0.5% Surge Fee
    uint256 public constant SURGE_DECAY_PERIOD_SECONDS = 3600; // Example: 1 hour decay

    struct PoolState {
        // Slot 1: Fee parameters (256 bits)
        uint128 baseFeePpm;         // Renamed from currentFeePpm for clarity (still represents base)
        uint128 currentSurgeFeePpm; // Added: Stores the current value of the surge component
        
        // Slot 2: Timestamps and flags (256 bits)
        uint48 lastUpdateTimestamp; // Timestamp of the last base fee update
        uint48 capEventEndTime;     // Added: Timestamp when the last CAP event ended
        uint48 lastFeeUpdate;       // Rate limiting timestamp for triggerFeeUpdate
        bool isInCapEvent;          // Tracks if currently in CAP event (tick was capped)
        uint8 reserved;             // 1 byte reserved for future flags
        
        // Slot 3: Oracle data (256 bits)
        uint32 lastOracleUpdateBlock; 
        int24 lastOracleTick;        // Already optimized
        // 200 bits remaining in this slot for future use
    }
    
    // Current fee state storage
    mapping(PoolId => PoolState) public poolStates;
    
    // Reference to policy manager
    IPoolPolicy public policy;
    
    // Reference to the pool manager
    IPoolManager public immutable poolManager;
    
    // The address of the Spot contract - used for access control
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
    event SurgeFeeUpdated(PoolId indexed poolId, uint256 surgeFee, bool capEventOccurred);
    event FeeAdjustmentApplied(PoolId indexed poolId, uint256 oldFee, uint256 newFee, uint8 adjustmentType);
    
    // Oracle events
    event OracleUpdated(PoolId indexed poolId, int24 oldTick, int24 newTick, bool tickCapped);
    event TickChangeCapped(PoolId indexed poolId, int24 actualChange, int24 cappedChange);
    event CapEventStateChanged(PoolId indexed poolId, bool isInCapEvent);
    event ThresholdsUpdated(uint32 blockUpdateThreshold, int24 tickThreshold);
    
    /**
     * @notice Access control modifier for Spot contract
     * @dev This is a legacy modifier that will be phased out with the reverse authorization model
     */
    modifier onlyFullRange() {
        // Fast path: direct call from the Spot contract
        if (msg.sender == fullRangeAddress) {
            _;
            return;
        }
        
        // Since we now use the reverse authorization model,
        // we don't need to validate hook instances anymore
        // Just reject any calls that aren't from the main Spot contract
        revert Errors.AccessNotAuthorized(msg.sender);
    }
    
    /**
     * @notice Access control modifier for owner or Spot contract
     * @dev This is a legacy modifier that will be phased out with the reverse authorization model
     */
    modifier onlyOwnerOrFullRange() {
        // Fast path: direct call from owner or Spot contract
        if (msg.sender == owner || msg.sender == fullRangeAddress) {
            _;
            return;
        }
        
        // Since we now use the reverse authorization model,
        // we don't need to validate hook instances anymore
        // Just reject any calls that aren't from the owner or main Spot contract
        revert Errors.AccessNotAuthorized(msg.sender);
    }
    
    /**
     * @notice Constructor
     * @param _owner The owner of this contract
     * @param _policy The consolidated policy contract
     * @param _poolManager The pool manager contract
     * @param _fullRange The address of the Spot contract
     */
    constructor(
        address _owner,
        IPoolPolicy _policy,
        IPoolManager _poolManager,
        address _fullRange
    ) Owned(_owner) {
        if (address(_policy) == address(0)) revert Errors.ZeroAddress();
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();
        if (_fullRange == address(0)) revert Errors.ZeroAddress();
        
        policy = _policy;
        poolManager = _poolManager;
        fullRangeAddress = _fullRange;
        
        // Initialize threshold config with default values
        thresholds = ThresholdConfig({
            blockUpdateThreshold: 1,
            tickDiffThreshold: 1
        });
    }
    
    /**
     * @notice Get oracle data for a pool from the Spot contract
     * @dev Implements Reverse Authorization Model for gas efficiency:
     *      - Pulls data from Spot instead of receiving updates
     *      - Eliminates need for expensive access control validation
     *      - Reduces cross-contract call overhead
     *      - Improves security by restricting write access to contract state
     * @param poolId The pool ID to get data for
     * @return tick The current tick value
     * @return blockNumber The block number the oracle data was last updated
     */
    function getOracleData(PoolId poolId) external view returns (int24 tick, uint32 blockNumber) {
        // Calls the ISpot interface on the associated FullRange/Spot hook address
        return ISpot(fullRangeAddress).getOracleData(poolId); // Don't unwrap PoolId
    }
    
    /**
     * @notice Process oracle data for a pool
     * @dev Only processes data when needed to save gas
     * @param poolId The pool ID to process
     * @return tickCapped Whether the tick was capped
     */
    function processOracleData(PoolId poolId) internal returns (bool tickCapped) {
        // Retrieve data from Spot
        (int24 tick, uint32 lastBlockUpdate) = this.getOracleData(poolId);
        PoolState storage pool = poolStates[poolId];
        
        int24 lastTick = pool.lastOracleTick;
        
        // Default to not capped
        tickCapped = false;
        
        // Check if update is needed based on block threshold or tick difference
        if (pool.lastOracleUpdateBlock == 0 || 
            lastBlockUpdate >= pool.lastOracleUpdateBlock + thresholds.blockUpdateThreshold ||
            MathUtils.absDiff(tick, lastTick) >= uint24(thresholds.tickDiffThreshold)) {
            
            // Calculate max allowed tick change based on dynamic fee and scaling factor
            int24 tickScalingFactor = policy.getTickScalingFactor();
            int24 maxTickChange = _calculateMaxTickChange(pool.baseFeePpm, tickScalingFactor);
            
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
        updateDynamicFeeIfNeeded(poolId, key);
        
        // Record the update time
        pool.lastFeeUpdate = uint48(block.timestamp);
    }
    
    /**
     * @notice Get the current dynamic fee for a pool
     * @dev Uses the reverse authorization model to pull oracle data
     * @param poolId The pool ID to get the fee for
     * @return The current dynamic fee in PPM (including base + surge)
     */
    function getCurrentDynamicFee(PoolId poolId) external view returns (uint256) {
        // Ensure pool is initialized before calculating total fee
        if (poolStates[poolId].lastUpdateTimestamp == 0) {
            return policy.getDefaultDynamicFee();
        }
        return _getCurrentTotalFeePpm(poolId);
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
    ) public returns (
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
            pool.lastUpdateTimestamp = uint48(block.timestamp);
            
            // Initialize oracle data
            (,int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
            pool.lastOracleUpdateBlock = uint32(block.number);
            pool.lastOracleTick = currentTick;
            pool.isInCapEvent = false;
            pool.currentSurgeFeePpm = 0; // Initialize surge fee
            pool.capEventEndTime = 0;    // Initialize end time
            
            return (pool.baseFeePpm, 0, true); // Return base fee, zero surge fee
        }
        
        // Check if we need to update the fee based on time interval and CAP events
        uint256 timeSinceLastUpdate = block.timestamp - pool.lastUpdateTimestamp;
        
        // Check if we need to update the oracle data first
        _updateOracleIfNeeded(poolId, key); // This calls _updateCapEventStatus internally
        
        // Check if update is needed based on time
        bool shouldUpdate = block.timestamp >= pool.lastUpdateTimestamp + 3600; // 1 hour
        
        // Calculate current surge fee (needed regardless of base fee update)
        surgeFeeValue = _calculateCurrentDecayedSurgeFee(poolId);

        if (shouldUpdate) {
            // --- Base Fee Calculation --- 
            // This part should contain the logic for adjusting the BASE fee over time,
            // independently of CAP events/surge fees. 
            // For now, let's assume a simple fixed base fee or minimal adjustment.
            // TODO: Implement desired base dynamic fee logic here.
            uint256 oldBaseFee = pool.baseFeePpm;
            uint256 newBaseFeePpm = oldBaseFee; // Placeholder: Keep base fee constant for now
            
            // Example: Gradual adjustment logic (if needed, unrelated to surge)
            // uint256 adjustmentPct = 990000; // e.g., slowly decrease base fee by 1% per hour
            // newBaseFeePpm = (oldBaseFee * adjustmentPct) / 1000000;

            // Enforce base fee bounds (using min fee from policy)
            uint256 minTradingFee = policy.getMinimumTradingFee();
            uint256 maxBaseFeePpm = 50000; // Example Max Base Fee: 5%
            if (newBaseFeePpm < minTradingFee) {
                newBaseFeePpm = minTradingFee;
            } else if (newBaseFeePpm > maxBaseFeePpm) {
                newBaseFeePpm = maxBaseFeePpm;
            }

            // Update base fee state if changed
            if (newBaseFeePpm != oldBaseFee) {
                pool.baseFeePpm = uint128(newBaseFeePpm);
                // Emit event reflecting only the base fee change
                emit DynamicFeeUpdated(poolId, oldBaseFee, newBaseFeePpm, pool.isInCapEvent); 
            }
            
            pool.lastUpdateTimestamp = uint48(block.timestamp);
            wasUpdated = true; // Base fee calculation was attempted
        }
        
        baseFee = pool.baseFeePpm; // Return current base fee
        // surgeFeeValue was calculated earlier
        // wasUpdated reflects if base fee calculation ran
        return (baseFee, surgeFeeValue, wasUpdated); 
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
        
        // Default to not capped
        tickCapped = false;
        
        // Check if update is needed based on block threshold or tick difference
        if (lastBlockUpdate == 0 || 
            block.number >= lastBlockUpdate + thresholds.blockUpdateThreshold ||
            MathUtils.absDiff(currentTick, lastTick) >= uint24(thresholds.tickDiffThreshold)) {
            
            // Calculate max allowed tick change based on dynamic fee and scaling factor
            int24 tickScalingFactor = policy.getTickScalingFactor();
            int24 maxTickChange = _calculateMaxTickChange(pool.baseFeePpm, tickScalingFactor);
            
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
     * @notice Updates the CAP event status for a pool based ONLY on tick capping.
     * @param poolId The ID of the pool
     * @param tickCapped Whether the tick was capped in the current update
     */
    function _updateCapEventStatus(PoolId poolId, bool tickCapped) internal {
        PoolState storage pool = poolStates[poolId];
        
        // Determine the new CAP state SOLELY based on whether the tick was capped
        bool newCapState = tickCapped;
        
        // Check if the state needs to change
        if (pool.isInCapEvent != newCapState) {
            pool.isInCapEvent = newCapState;
            emit CapEventStateChanged(poolId, newCapState);
            
            // -- Add logic here for Phase 3 (surge start/end time tracking) --
            if (newCapState) {
                // CAP Event Started
                pool.currentSurgeFeePpm = uint128(INITIAL_SURGE_FEE_PPM);
                pool.capEventEndTime = 0; // Reset end time
                emit SurgeFeeUpdated(poolId, pool.currentSurgeFeePpm, true); // Emit surge update (CAP Active)
            } else {
                // CAP Event Ended
                pool.capEventEndTime = uint48(block.timestamp); // Record end time
                // Surge fee remains at its current value, decay starts now.
                // Emit surge update (CAP Inactive, decay begins)
                emit SurgeFeeUpdated(poolId, pool.currentSurgeFeePpm, false); 
            }
        }
    }
    
    /**
     * @notice Calculate the maximum tick change allowed based on fee and scaling factor
     * @param currentFeePpm The dynamic fee in PPM
     * @param tickScalingFactor The tick scaling factor
     * @return The maximum tick change allowed
     */
    function _calculateMaxTickChange(uint256 currentFeePpm, int24 tickScalingFactor) internal pure returns (int24) {
        // Calculate the max tick change based on the fee and scaling factor using MathUtils for consistency
        // Use MathUtils.calculateFeeWithScale for better precision and overflow protection
        uint256 maxChangeUint = MathUtils.calculateFeeWithScale(
            currentFeePpm, 
            uint256(uint24(tickScalingFactor)), // Safe conversion to uint256
            1e6 // PPM denominator
        );
        
        int256 maxChangeScaled = int256(maxChangeUint);

        // Clamp to int24 bounds
        if (maxChangeScaled > type(int24).max) return type(int24).max;
        if (maxChangeScaled < type(int24).min) return type(int24).min; // Should be positive anyway
        
        return int24(maxChangeScaled);
    }
    
    /**
     * @notice Calculates the current surge fee, applying decay if the CAP event has ended.
     * @param poolId The ID of the pool.
     * @return The current surge fee component in PPM.
     */
    function _calculateCurrentDecayedSurgeFee(PoolId poolId) internal view returns (uint256) {
        PoolState storage pool = poolStates[poolId];
        uint128 initialSurge = uint128(INITIAL_SURGE_FEE_PPM); // Use constant

        // If still in CAP event, return the full initial surge fee
        if (pool.isInCapEvent) {
            // Ensure surge fee is set (might happen if CAP starts before first updateDynamicFeeIfNeeded)
            if (pool.currentSurgeFeePpm == 0) {
                return initialSurge; 
            } 
            return pool.currentSurgeFeePpm;
        }

        // If CAP event has ended, calculate decay
        uint48 endTime = pool.capEventEndTime;
        if (endTime == 0) {
            return 0; // CAP never happened or surge fully decayed previously
        }

        uint256 timeSinceEnd = block.timestamp - endTime;

        // Check if decay period is complete
        if (timeSinceEnd >= SURGE_DECAY_PERIOD_SECONDS) {
            return 0; // Decay finished
        }

        // Calculate linear decay
        // decayedSurge = initialSurge * (remaining_decay_time / total_decay_time)
        uint256 decayedSurge = (uint256(initialSurge) * (SURGE_DECAY_PERIOD_SECONDS - timeSinceEnd)) / SURGE_DECAY_PERIOD_SECONDS;

        return decayedSurge;
    }

    /**
     * @notice Calculates the total current fee (base + decayed surge).
     * @param poolId The ID of the pool.
     * @return The total fee in PPM.
     */
    function _getCurrentTotalFeePpm(PoolId poolId) internal view returns (uint256) {
        PoolState storage pool = poolStates[poolId];
        uint256 baseFee = pool.baseFeePpm;
        uint256 surgeFee = _calculateCurrentDecayedSurgeFee(poolId);
        
        // Add safety check for potential overflow, though unlikely with uint128 + decayed uint256
        uint256 totalFee = baseFee + surgeFee;
        if (totalFee > type(uint128).max) { // Check against reasonable upper bound if needed
            totalFee = type(uint128).max; // Cap at max uint128 for safety
        }
        
        return totalFee;
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
        pool.lastUpdateTimestamp = uint48(block.timestamp);
        pool.isInCapEvent = false;
        
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
     * @notice Checks if a pool is currently in a CAP event state.
     * @param poolId The ID of the pool.
     * @return True if the pool is in a CAP event state, false otherwise.
     */
    function isPoolInCapEvent(PoolId poolId) external view returns (bool) {
        return poolStates[poolId].isInCapEvent;
    }

    /**
     * @notice Checks if a pool's tick movement is currently capped.
     * @param poolId The ID of the pool.
     * @return True if the tick movement is capped, false otherwise.
     */
    function isTickCapped(PoolId poolId) external view returns (bool) {
        PoolState storage pool = poolStates[poolId];
        
        // Get current tick from pool manager
        (,int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        
        // Calculate max allowed tick change based on dynamic fee and scaling factor
        int24 tickScalingFactor = policy.getTickScalingFactor();
        int24 maxTickChange = _calculateMaxTickChange(pool.baseFeePpm, tickScalingFactor);
        
        // Check if tick change exceeds the maximum allowed
        return MathUtils.absDiff(currentTick, pool.lastOracleTick) > uint24(maxTickChange);
    }
}