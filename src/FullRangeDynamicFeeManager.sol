// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SortTokens} from "v4-core/test/utils/SortTokens.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

// Project imports
import {IFullRangeDynamicFeeManager} from "./interfaces/IFullRangeDynamicFeeManager.sol";
import {ISpot} from "./interfaces/ISpot.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {MathUtils} from "./libraries/MathUtils.sol";
import {Errors} from "./errors/Errors.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TruncatedOracle} from "./libraries/TruncatedOracle.sol";
import {console} from "forge-std/console.sol";

/**
 * @title FullRangeDynamicFeeManager
 * @notice Manages dynamic fees for pools including CAP event detection (based on oracle tick capping) and oracle functionality
 * @dev This contract combines functionalities of the original FeeManager and OracleManager
 */
contract FullRangeDynamicFeeManager is Owned, IFullRangeDynamicFeeManager {
    // Using PPM (parts per million) for fee and multiplier values (1e6 = 100%).

    // --- Removed in-line cap-frequency and base-fee constants; configurable via policy ---

    /// @dev We pack several things into a single struct per pool to save SSTOREs:
    ///      - the base fee PPM
    ///      - the surge fee PPM (calculated dynamically)
    ///      - the timestamp when the surge was last triggered
    ///      - the timestamp of last base-fee update
    ///      - the timestamp used for rate-limiting fee updates
    ///      - whether we are currently in a cap event
    ///      - last oracle tick and update block
    struct PoolState {
        // Fee state
        uint128 baseFeePpm;
        uint48  lastCapTimestamp; // Replaces currentSurgeFeePpm and capEventEndTime

        // Timestamps for base-fee logic
        uint48  lastUpdateTimestamp;
        uint48  lastFeeUpdate;

        // Frequency state
        uint128 freqScaled;
        uint48  freqLastUpdate;

        // Oracle state (Added back)
        int24   lastOracleTick;
        uint32  lastOracleUpdateBlock;

        // Flags
        bool    isInCapEvent;
    }

    // Current fee state storage (now private; expose via helper below)
    mapping(PoolId => PoolState) private poolStates;

    // Reference to policy manager
    IPoolPolicy public policy;

    // Reference to the pool manager
    IPoolManager public immutable poolManager;

    // The address of the Spot contract - used for access control
    address public immutable fullRangeAddress;

    // Oracle threshold config
    struct ThresholdConfig {
        uint32 blockUpdateThreshold; // Minimum blocks before an update.
        int24 tickDiffThreshold; // Minimum tick difference to trigger an update.
    }

    ThresholdConfig public thresholds;

    // Define the enum for adjustment types
    enum AdjustmentType { Increase, Decrease }

    // Events
    event FeeAdjustmentApplied(PoolId indexed poolId, uint256 oldFee, uint256 newFee, uint8 adjustmentType);

    // Oracle events
    event TickChangeCapped(PoolId indexed poolId, int24 actualChange, int24 cappedChange);
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
    constructor(address _owner, IPoolPolicy _policy, IPoolManager _poolManager, address _fullRange) Owned(_owner) {
        if (address(_policy) == address(0)) revert Errors.ZeroAddress();
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();
        if (_fullRange == address(0)) revert Errors.ZeroAddress();

        policy = _policy;
        poolManager = _poolManager;
        fullRangeAddress = _fullRange;

        // Initialize threshold config with default values
        thresholds = ThresholdConfig({blockUpdateThreshold: 1, tickDiffThreshold: 1});
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
     * @dev Read the *live* pool tick from slot0, apply your block/tick thresholds,
     *      cap any excessive jump, update CAP-event state, and emit one unified OracleUpdated.
     */
    function _syncOracleData(PoolId poolId, PoolKey calldata key) internal returns (bool tickCapped) {
        // 1) Fetch the current tick directly from the PoolManager
        (, int24 reportedTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
        uint32 reportedBlock = uint32(block.number);

        PoolState storage ps = poolStates[poolId];
        int24 lastRecordedTick = ps.lastOracleTick; // Use a distinct name
        uint32 lastBlock = ps.lastOracleUpdateBlock;
        int24 nextTickToRecord = reportedTick; // Start with the reported tick
        tickCapped = false;

        // 2) Only update when block or tick thresholds are exceeded.
        //    Check if the time/tick diff is NOT below thresholds (i.e., if an update IS needed).
        if (
            lastBlock == 0 || // Always update if it's the first time
            !( // Use NOT to check if thresholds ARE met
                reportedBlock < lastBlock + thresholds.blockUpdateThreshold && // CHANGED from >= to <
                MathUtils.absDiff(reportedTick, lastRecordedTick) < uint24(thresholds.tickDiffThreshold) // Also check tick diff < threshold
            )
        ) {
            // Log values inside threshold check
            // console.log("[_syncOracleData] Thresholds met for pool (bytes32 ID):"); // Log string first
            // console.logBytes32(PoolId.unwrap(poolId)); // Log bytes32 separately
            // console.log("  Reported Tick:", reportedTick);
            // console.log("  Last Recorded Tick:", lastRecordedTick);
            // console.log("  Current Base Fee (PPM):", ps.baseFeePpm);

            // 3) Determine max allowed tick move based on current base fee
            int24 maxChange = _calculateMaxTickChange(ps.baseFeePpm, policy.getTickScalingFactor());
            // console.log("  Calculated Max Tick Change:", maxChange);
            int24 actualDelta = reportedTick - lastRecordedTick; // Calculate actual change vs last recorded
            uint256 absActualDelta = MathUtils.absDiff(reportedTick, lastRecordedTick);
            // console.log("  Absolute Actual Tick Delta:", absActualDelta);

            // 4) Check if actual jump vs. last recorded tick is too big
            if (lastBlock > 0 && absActualDelta > uint24(maxChange)) { // Compare abs diff
                tickCapped = true;
                // console.log("  *** Tick Capped! ***");
                int24 cap = actualDelta > 0 ? maxChange : -maxChange;
                // If maxChange==0, force a full tick update so we can exit the cap event
                if (cap == 0) cap = actualDelta;
                nextTickToRecord = lastRecordedTick + cap; // Update to the CAPPED tick
                emit TickChangeCapped(poolId, actualDelta, cap);
            }
            // If not capped, nextTickToRecord remains the reportedTick

            // 5) Update CAP event status based on the tickCapped flag determined above
            _updateCapEventStatus(poolId, tickCapped);

            // 6) Record the new oracle state (block and the potentially capped tick)
            ps.lastOracleUpdateBlock = reportedBlock;
            ps.lastOracleTick = nextTickToRecord; // Record the calculated next tick
            emit OracleUpdated(poolId, lastRecordedTick, nextTickToRecord, tickCapped);
            // split the log into two 2‑arg calls to match forge-std overloads
            // console.log("  Oracle Updated. New Recorded Tick:", nextTickToRecord);
            // console.log("  Tick Capped Flag:", tickCapped);
        }
        // If thresholds not met, tickCapped remains false, no state updated

        return tickCapped; // Return the status determined within the threshold check
    }

    /**
     * @notice External function to trigger fee updates with rate limiting
     * @param poolId The pool ID to update fees for
     * @param key The pool key for the pool
     */
    function triggerFeeUpdate(PoolId poolId, PoolKey calldata key) external {
        // Removed redundant rate limiting check; it's handled in _updateBaseFeeAndFrequency
        /*
        PoolState storage pool = poolStates[poolId];
        if (uint48(block.timestamp) < pool.lastFeeUpdate + MIN_UPDATE_INTERVAL) {
            revert Errors.RateLimited();
        }
        */

        // Get the ID from the key
        PoolId keyId = key.toId();

        // Verify this is a valid pool ID/key combination
        if (PoolId.unwrap(poolId) != PoolId.unwrap(keyId)) revert Errors.InvalidPoolKey();

        // Update fees using this.
        this.updateDynamicFeeIfNeeded(poolId, key);

        // Record the update time - This seems redundant now as updates are timestamped inside _updateBaseFeeAndFrequency
        // PoolState storage pool = poolStates[poolId]; // Already declared if uncommenting rate limit
        // pool.lastFeeUpdate = uint48(block.timestamp);
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
     * @return newBase The current base fee in PPM
     * @return newSurge The current surge fee in PPM
     * @return didUpdate Whether the base fee calculation logic ran in this call
     */
    function updateDynamicFeeIfNeeded(PoolId poolId, PoolKey calldata key)
        external override
        returns (uint256 newBase, uint256 newSurge, bool didUpdate)
    {
        PoolState storage pool = poolStates[poolId];

        // when we first come online, we need to seed both the oracle
        // and the dynamic-fee state.
        if (pool.lastUpdateTimestamp == 0) {
            pool.lastCapTimestamp    = 0; // Initialize new field
            pool.isInCapEvent        = false;
            pool.freqScaled          = 0;
            pool.freqLastUpdate      = 0;

            pool.baseFeePpm          = uint128(policy.getDefaultDynamicFee());
            pool.lastUpdateTimestamp = uint48(block.timestamp);
        }

        // Pull in new oracle data, determine tickCapped…
        bool tickCapped = _syncOracleData(poolId, key);

        // update cap status and potentially lastCapTimestamp
        _updateCapEventStatus(poolId, tickCapped);

        // …then recalc the base fee and return both pieces
        ( newBase, newSurge, didUpdate ) =
            _updateBaseFeeAndFrequency(poolId, key);
    }

    /**
     * @notice Updates the CAP event status for a pool based ONLY on tick capping.
     * @param poolId The ID of the pool
     * @param tickCapped Whether the tick was capped in the current update
     */
    function _updateCapEventStatus(PoolId poolId, bool tickCapped) internal {
        PoolState storage pool     = poolStates[poolId];
        uint48            nowTs    = uint48(block.timestamp);

        bool previous            = pool.isInCapEvent;
        bool isNow               = tickCapped;

        // 1) If we're entering (or re-entering) a CAP event...
        if (isNow) {
            // stamp when surge was kicked off
            pool.lastCapTimestamp = nowTs;
            if (!previous) {
               emit SurgeFeeUpdated(poolId, policy.getInitialSurgeFeePpm(poolId), true);
            }
        }
        // 2) If we're exiting a CAP event...
        else if (previous && !isNow) {
            // we no longer need capEventEndTime for decay...
            emit SurgeFeeUpdated(poolId, _calculateCurrentDecayedSurgeFee(poolId), false);
        }

        if (previous != isNow) {
            pool.isInCapEvent = isNow;
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
         if (tickScalingFactor <= 0) return 0; // Avoid division by zero or negative scaling issues

        uint256 maxChangeUint = MathUtils.calculateFeeWithScale(
            currentFeePpm,
            uint256(uint24(tickScalingFactor)), // Safe conversion to uint256
            1e6 // PPM denominator
        );

        int256 maxChangeScaled = int256(maxChangeUint);

        // Clamp to int24 bounds
        if (maxChangeScaled > type(int24).max) return type(int24).max;
        // No need to check min as result should be positive
        // if (maxChangeScaled < type(int24).min) return type(int24).min;

        return int24(maxChangeScaled);
    }

    /**
     * @notice Calculates the current surge fee, applying decay if the CAP event has ended.
     * @param poolId The ID of the pool.
     * @return The current surge fee component in PPM.
     */
    function _calculateCurrentDecayedSurgeFee(PoolId poolId) internal view returns (uint256) {
        PoolState storage pool = poolStates[poolId];
        uint256 initialSurge    = policy.getInitialSurgeFeePpm(poolId);
        uint256 decayPeriod     = policy.getSurgeDecayPeriodSeconds(poolId);
        uint48  startTs         = pool.lastCapTimestamp;

        // If we are *currently* in a cap event, the surge is the full initial surge.
        // The decay only applies *after* the cap event ends (isNow becomes false).
        if (pool.isInCapEvent) {
             return initialSurge;
        }

        // never triggered OR cap event just ended this block -> zero (or full if decay=0)
        if (startTs == 0 || startTs == block.timestamp) {
             // If decay period is 0, surge is only non-zero *exactly* at the cap timestamp.
             // Since we are past that point if !isInCapEvent, return 0.
             return 0;
        }

        // Handle zero decay period after the initial cap block
        if (decayPeriod == 0) {
             return 0; // Instant decay after the cap block
        }

        uint256 sinceCap = block.timestamp > startTs
                         ? block.timestamp - startTs
                         : 0; // Should not happen if startTs > 0 and startTs != block.timestamp

        if (sinceCap >= decayPeriod) {
            return 0; // Decay finished
        }

        // linear decay: initialSurge × (remaining / total)
        return (initialSurge * (decayPeriod - sinceCap)) / decayPeriod;
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
        uint256 maxFee = policy.getMaxBaseFee(poolId) + policy.getInitialSurgeFeePpm(poolId); // A reasonable upper bound
        if (totalFee > maxFee) {
            totalFee = maxFee; // Cap at a reasonable max total fee
        }
        // Clamp to uint128 if needed for consistency, though totalFee is uint256
        // if (totalFee > type(uint128).max) {
        //     totalFee = type(uint128).max;
        // }

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
        pool.lastCapTimestamp = 0; // Initialize cap timestamp
        pool.freqScaled = 0; // Initialize frequency state
        pool.freqLastUpdate = 0; // Initialize frequency state

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
            // Don't initialize isInCapEvent here, let fee initialization or sync handle it
            // pool.isInCapEvent = false;

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
        // Allow zero tick threshold?
        // if (tickThreshold <= 0) revert Errors.ParameterOutOfRange(uint256(uint24(tickThreshold)), 1, type(uint24).max);
         if (tickThreshold < 0) revert Errors.ParameterOutOfRange(uint256(uint24(tickThreshold)), 0, type(uint24).max);

        thresholds.blockUpdateThreshold = blockThreshold;
        thresholds.tickDiffThreshold = tickThreshold;

        emit ThresholdsUpdated(blockThreshold, tickThreshold);
    }

    /**
     * @notice Checks if a pool is currently in a CAP event state.
     * @dev Renamed from isPoolInCapEvent to match IFullRangeDynamicFeeManager interface
     * @param poolId The ID of the pool.
     * @return True if the pool is in a CAP event state, false otherwise.
     */
    function isCAPEventActive(PoolId poolId) external view override returns (bool) {
        return poolStates[poolId].isInCapEvent;
    }

    /**
     * @notice Checks if a pool's tick movement is currently capped.
     * @dev This is a view function and might be slightly out of sync if state hasn't been updated recently.
     *      It calculates based on the last *recorded* oracle tick vs current pool tick.
     * @param poolId The ID of the pool.
     * @return True if the tick movement is capped, false otherwise.
     */
    function isTickCapped(PoolId poolId) external view returns (bool) {
        PoolState storage pool = poolStates[poolId];

        // Get current tick from pool manager
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);

        // Get last recorded tick
        int24 lastRecordedTick = pool.lastOracleTick;
        if (pool.lastOracleUpdateBlock == 0) {
            // If oracle not initialized, cannot determine if capped
            return false;
        }

        // Calculate max allowed tick change based on dynamic fee and scaling factor
        int24 tickScalingFactor = policy.getTickScalingFactor();
        // Use the current base fee for the calculation
        int24 maxTickChange = _calculateMaxTickChange(pool.baseFeePpm, tickScalingFactor);

        // Check if tick change exceeds the maximum allowed
        return MathUtils.absDiff(currentTick, lastRecordedTick) > uint24(maxTickChange);
    }

    // --- Helper functions for policy access --- REMOVED
    /*
    function getInitialSurgeFeePpm(PoolId poolId) internal view returns (uint256) {
        // TODO: Replace with actual call to policy.getInitialSurgeFeePpm(poolId)
        // Assuming a default value for now if not in policy
        // return 5000; // Example: 0.5%
        return policy.getInitialSurgeFeePpm(poolId);
    }

    function getSurgeDecayPeriodSeconds(PoolId poolId) internal view returns (uint256) {
         // TODO: Replace with actual call to policy.getSurgeDecayPeriodSeconds(poolId)
        // Assuming a default value for now if not in policy
        // return 3600; // Example: 1 hour
        return policy.getSurgeDecayPeriodSeconds(poolId);
    }
    */
    // ----------------------------------------------------------------
    // Helper Getter
    // ----------------------------------------------------------------

    /**
     * @notice Returns the current base-fee (PPM) for a pool.
     * @param poolId The ID of the pool.
     * @return baseFeePpm The current base fee in PPM.
     */
    function getBaseFee(PoolId poolId) external view returns (uint256 baseFeePpm) {
        return poolStates[poolId].baseFeePpm;
    }

    /// @dev Updates the base fee based on cap frequency, and returns
    ///      (newBaseFeePpm, currentSurgeFeePpm, didBaseFeeUpdate)
    function _updateBaseFeeAndFrequency(
        PoolId poolId,
        PoolKey memory /*key*/
    )
        internal
        returns (
            uint256 newBase,
            uint256 surgeFee,
            bool didUpdate
        )
    {
        PoolState storage pool = poolStates[poolId];
        uint48 nowTs = uint48(block.timestamp);

        // ── DEBUG LOGGING ───────────────────────────────────────────────────
        console.log("_updateBaseFee >> nowTs:", nowTs);
        console.log("  lastUpdateTimestamp:", pool.lastUpdateTimestamp);
        console.log("  freqLastUpdate:", pool.freqLastUpdate);
        console.log("  freqScaled before snapshot:", pool.freqScaled);

        // 1) compute current decayed surge
        surgeFee = _calculateCurrentDecayedSurgeFee(poolId);

        // 2) snapshot pre-decay frequency (for base-fee calculation)
        uint256 rawFreq = pool.freqScaled;
        console.log("  rawFreq snapshot:", rawFreq);

        // 3) decay the frequency counter
        uint256 window = policy.getCapFreqDecayWindow(poolId);
        console.log("  decay window:", window);
        if (pool.freqLastUpdate != 0 && pool.freqScaled > 0 && window > 0) {
            uint256 elapsed = nowTs - pool.freqLastUpdate;
            console.log("  elapsed since last freqUpdate:", elapsed);
            if (elapsed < window) {
                uint256 decayAmt = (uint256(pool.freqScaled) * elapsed) / window;
                console.log("  decayAmt:", decayAmt);
                pool.freqScaled = uint128(pool.freqScaled > decayAmt ? pool.freqScaled - decayAmt : 0);
                console.log("  freqScaled after decay:", pool.freqScaled);
            } else {
                pool.freqScaled = 0;
                console.log("  freqScaled reset to 0 (elapsed >= window)");
            }
        }

        // 4) if we just triggered a cap, bump freqScaled
        if (pool.lastCapTimestamp == nowTs) {
            console.log("  cap just triggered this block; bumping freqScaled");
            uint256 scale = policy.getFreqScaling(poolId);
            uint256 updated = uint256(pool.freqScaled) + scale;
            pool.freqScaled = updated > type(uint128).max ? type(uint128).max : uint128(updated);
            console.log("  freqScaled after bump:", pool.freqScaled);
        }

        // update timestamp for frequency decay
        pool.freqLastUpdate = nowTs;

        console.log("  freqLastUpdate updated to nowTs");

        // 5) enforce minimum update interval for base-fee recalculation.
        //    Frequency update above happens regardless of this check.
        uint256 minInterval = policy.getBaseFeeUpdateIntervalSeconds(poolId);
        console.log("  minInterval:", minInterval);
        if (nowTs < pool.lastUpdateTimestamp + minInterval) {
            console.log("  too soon to recompute base-fee (skipping)");
            // too soon, so skip base‐fee change
            return (pool.baseFeePpm, surgeFee, false);
        }


        // 6) apply dynamic‑fee formula based on rawFreq snapshot
        uint256 defaultFee = policy.getDefaultDynamicFee();
        uint256 targetCaps = policy.getTargetCapsPerDay(poolId);
        console.log("  defaultFee:", defaultFee);
        console.log("  targetCaps/day:", targetCaps);
        uint256 minFee     = policy.getMinBaseFee(poolId);
        uint256 maxFee     = policy.getMaxBaseFee(poolId);

        uint256 num   = rawFreq * 86400;
        console.log("  num (rawFreq*86400):", num);
        uint256 den   = targetCaps * window;
        console.log("  den (targetCaps*window):", den);
        int256  diff;
        if (den == 0) {
            diff = 0;
        } else {
            int256 ratioPpm = int256((num * 1e6) / den);
            console.log("  ratioPpm:", ratioPpm);
            diff = (int256(defaultFee) * (ratioPpm - int256(1e6))) / int256(1e6);
            console.log("  diff:", diff);
        }

        int256 interim = int256(defaultFee) + diff;
        console.log("  interim fee:", interim);
        uint256 clamped = interim < 0 ? 0 : uint256(interim);
        if (clamped < minFee) clamped = minFee;
        if (clamped > maxFee) clamped = maxFee;
        console.log("  clamped newBase (min/max):", clamped);
        newBase = clamped;

        // 7) write state & emit if changed
        if (newBase != pool.baseFeePpm) {
            emit FeeAdjustmentApplied(
                poolId,
                pool.baseFeePpm,
                newBase,
                newBase > pool.baseFeePpm ? uint8(AdjustmentType.Increase) : uint8(AdjustmentType.Decrease)
            );
            pool.baseFeePpm         = uint128(newBase);
            pool.lastUpdateTimestamp = nowTs;
            didUpdate = true;
        } else {
            didUpdate = false;
        }
        return (newBase, surgeFee, didUpdate);
    }

    // --- Implementations for missing IFullRangeDynamicFeeManager functions ---

    /**
     * @notice Returns the current base and surge fee components for a pool.
     * @param poolId The ID of the pool.
     * @return baseFee The current base fee in PPM.
     * @return surgeFeeValue The current surge fee (potentially decayed) in PPM.
     */
    function getCurrentFees(PoolId poolId) external view override returns (uint256 baseFee, uint256 surgeFeeValue) {
        PoolState storage pool = poolStates[poolId];
        // Ensure pool is initialized before calculating total fee
        if (pool.lastUpdateTimestamp == 0) {
            return (policy.getDefaultDynamicFee(), 0);
        }
        baseFee = pool.baseFeePpm;
        surgeFeeValue = _calculateCurrentDecayedSurgeFee(poolId);
        return (baseFee, surgeFeeValue);
    }

    /**
     * @notice Placeholder/Compatibility function to handle fee updates as per the interface.
     * @dev Current design uses triggerFeeUpdate/updateDynamicFeeIfNeeded with PoolKey.
     *      This implementation attempts to fetch the key and call updateDynamicFeeIfNeeded.
     *      Consider revising interface or implementation if key fetching is not desired/possible.
     * @param poolId The ID of the pool.
     */
    function handleFeeUpdate(PoolId poolId) external override {
        // Reverted implementation: This function requires PoolKey which isn't provided by the interface.
        // Updates should be triggered via triggerFeeUpdate or updateDynamicFeeIfNeeded.
        revert("FullRangeDynamicFeeManager: handleFeeUpdate cannot execute without PoolKey. Use triggerFeeUpdate or updateDynamicFeeIfNeeded.");
        /*
        // Attempt to fetch the PoolKey - This might be complex or impossible depending on context
        // For now, revert as the direct mapping is unclear without the key.
        // A more robust solution would require knowing how this function is intended to be called
        // or adjusting the interface.
        // Alternatively, if it's meant for internal logic triggering, refactor might be needed.

        // Fetch PoolKey associated with PoolId - requires PoolManager lookup
        // ERROR: getPoolParameters is not in standard IPoolManager interface
        (Currency c0, Currency c1, uint24 fee, int24 tickSpacing, IHooks hooks) = poolManager.getPoolParameters(poolId);
        PoolKey memory key = PoolKey({ currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: hooks});

        // Call the internal update logic
        this.updateDynamicFeeIfNeeded(poolId, key);
        */
    }

    /**
     * @notice Placeholder/Compatibility function to update the oracle as per the interface.
     * @dev Reverts, as the current contract design uses a reverse authorization model (pulling data via _syncOracleData)
     *      rather than allowing external pushes via this function.
     */
    function updateOracle(PoolId /*poolId*/, int24 /*tick*/) external override {
        revert("FullRangeDynamicFeeManager: updateOracle not supported due to reverse authorization model. Use _syncOracleData internally.");
    }

    // --- End of IFullRangeDynamicFeeManager implementations ---
}
