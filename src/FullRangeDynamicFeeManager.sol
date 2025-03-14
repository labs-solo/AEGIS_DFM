// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Owned} from "solmate/src/auth/Owned.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/**
 * @title FullRangeDynamicFeeManager
 * @notice Autonomous system for:
 *  - Tracking the frequency of "cap events" in the truncated oracle
 *  - Updating the dynamic fee rate (in ppm)
 *  - Updating the maxAbsTickMove for the oracle
 */
contract FullRangeDynamicFeeManager is Owned {
    // Using PPM (parts per million) for fee and multiplier values where 1e6 = 100%.
    
    struct PoolState {
        uint256 currentFeePpm;    // Last applied fee (after surge if any).
        uint256 dynamicFeePpm;    // Baseline dynamic fee (adjusts gradually).
        uint256 eventRatePpm;     // Smoothed cap event occurrence rate (0 to 1e6).
        uint256 lastUpdateBlock;  // Last block when fee was updated.
        uint256 overrideFeePpm;   // If non-zero, dynamic fee is overridden by this fixed fee.
    }
    
    // Governance parameters (configurable via owner)
    uint256 public minFeePpm;
    uint256 public maxFeePpm;
    uint256 public surgeMultiplierPpm;
    bool public dynamicFeePaused;
    
    // Target cap event frequency (in PPM of updates, e.g., 50000 = 5%)
    uint256 public constant TARGET_EVENT_RATE_PPM = 50000;
    // Decay factor per update for event rate (in PPM, e.g., 800000 = 0.80 retention)
    uint256 public constant DECAY_PPM = 800000;
    // Proportional gain for fee adjustment (Kp = KP_NUM / KP_DEN)
    uint256 public constant KP_NUM = 1;
    uint256 public constant KP_DEN = 2;
    // Derived baseline decay factor per no-event interval (1 - Kp*target)
    uint256 public constant BASELINE_DECAY_PPM = 1000000 - (KP_NUM * TARGET_EVENT_RATE_PPM) / KP_DEN;
    
    // Pool states, identified by PoolId
    mapping(bytes32 => PoolState) public pools;
    
    // Events
    event DynamicFeeUpdated(bytes32 indexed pid, uint256 oldFeePpm, uint256 newFeePpm);
    event DynamicFeeOverrideSet(bytes32 indexed pid, uint256 feePpm);
    event SurgeMultiplierSet(uint256 multiplierPpm);
    event FeeBoundsSet(uint256 minFeePpm, uint256 maxFeePpm);
    event DynamicFeePaused(bool paused);
    
    /**
     * @notice Constructor to initialize fee bounds and surge multiplier
     * @param _minFeePpm Minimum fee (in PPM)
     * @param _maxFeePpm Maximum fee (in PPM)
     * @param _initialSurgeMultiplierPpm Initial surge multiplier (in PPM, e.g., 2000000 = 200%)
     */
    constructor(uint256 _minFeePpm, uint256 _maxFeePpm, uint256 _initialSurgeMultiplierPpm) Owned(msg.sender) {
        require(_minFeePpm <= _maxFeePpm, "minFee must be <= maxFee");
        minFeePpm = _minFeePpm;
        maxFeePpm = _maxFeePpm;
        // Ensure surge multiplier is at least 100% (1.0x) to avoid reducing fees during events
        surgeMultiplierPpm = _initialSurgeMultiplierPpm >= 1000000 ? _initialSurgeMultiplierPpm : 1000000;
    }
    
    /**
     * @notice Update the dynamic fee for a given pool based on recent volatility.
     * @param pid The identifier of the pool
     * @param capEventOccurred True if a cap event (extreme volatility event) occurred since last update.
     * @return newFeePpm The updated fee (in PPM) to apply for the pool.
     * 
     * This function should be called by the FullRange contract **before** deposits or withdrawals.
     * It adjusts the pool's fee to maintain the target cap-event frequency. On a cap event, it 
     * applies surge pricing (temporary fee increase) to protect liquidity providers, then reverts 
     * to the baseline fee on the next update. If dynamic fees are paused or an override is set, 
     * this returns the current fee without adjustment.
     */
    function updateDynamicFee(bytes32 pid, bool capEventOccurred) external returns (uint256 newFeePpm) {
        PoolState storage pool = pools[pid];
        uint256 oldFee = pool.currentFeePpm;
        
        // Initialize pool state on first use
        if (pool.lastUpdateBlock == 0) {
            uint256 initialFee = (minFeePpm + maxFeePpm) / 2;  // start at mid-point of allowed range
            pool.currentFeePpm = initialFee;
            pool.dynamicFeePpm = initialFee;
            pool.eventRatePpm = TARGET_EVENT_RATE_PPM;  // assume normal event frequency initially
            pool.lastUpdateBlock = block.number;
            oldFee = initialFee;
        }
        
        // Skip dynamic adjustment if globally paused or if this pool has an override
        if (dynamicFeePaused || pool.overrideFeePpm != 0) {
            if (pool.overrideFeePpm != 0) {
                // If override active, ensure current fee reflects the override value
                pool.currentFeePpm = pool.overrideFeePpm;
            }
            // Update lastUpdateBlock to "freeze" state (prevent huge catch-up decay later)
            pool.lastUpdateBlock = block.number;
            return pool.currentFeePpm;
        }
        
        // Calculate blocks elapsed since last update
        uint256 blocksElapsed = block.number - pool.lastUpdateBlock;
        if (blocksElapsed > 0) {
            // Decay event rate over (blocksElapsed - 1) intervals with no updates
            if (blocksElapsed > 1) {
                uint256 eventDecayFactor = _powPpm(DECAY_PPM, blocksElapsed - 1);
                pool.eventRatePpm = (pool.eventRatePpm * eventDecayFactor) / 1000000;
                // Simultaneously decay baseline fee for those intervals (assuming no cap events in between)
                uint256 baseDecayFactor = _powPpm(BASELINE_DECAY_PPM, blocksElapsed - 1);
                pool.dynamicFeePpm = (pool.dynamicFeePpm * baseDecayFactor) / 1000000;
                if (pool.dynamicFeePpm < minFeePpm) {
                    pool.dynamicFeePpm = minFeePpm;
                }
            }
            // Decay event rate for the current interval (before applying current observation)
            pool.eventRatePpm = (pool.eventRatePpm * DECAY_PPM) / 1000000;
        }
        // Apply current cap event observation
        if (capEventOccurred) {
            // Increase event rate by (1 - decay) = instantaneous contribution of a cap event
            uint256 addRate = 1000000 - DECAY_PPM;
            pool.eventRatePpm += addRate;
            if (pool.eventRatePpm > 1000000) {
                pool.eventRatePpm = 1000000;  // cap at 100%
            }
        }
        
        // Calculate error between observed cap-event frequency and target frequency
        int256 error = int256(pool.eventRatePpm) - int256(TARGET_EVENT_RATE_PPM);
        // Proportional adjustment to baseline fee: delta = Kp * error * currentFee
        int256 delta = (int256(pool.dynamicFeePpm) * int256(KP_NUM) * error) / (int256(1000000) * int256(KP_DEN));
        if (delta != 0) {
            if (delta > 0) {
                // Positive error (cap events too frequent) – increase fee
                uint256 increase = uint256(delta);
                uint256 newDynFee = pool.dynamicFeePpm + increase;
                if (newDynFee < pool.dynamicFeePpm) {
                    newDynFee = type(uint256).max;  // overflow guard (should not happen in practice)
                }
                pool.dynamicFeePpm = newDynFee;
            } else {
                // Negative error (cap events too infrequent) – decrease fee
                uint256 decrease = uint256(-delta);
                if (decrease >= pool.dynamicFeePpm) {
                    pool.dynamicFeePpm = 0;
                } else {
                    pool.dynamicFeePpm -= decrease;
                }
            }
        }
        // Enforce fee bounds
        if (pool.dynamicFeePpm < minFeePpm) {
            pool.dynamicFeePpm = minFeePpm;
        }
        if (pool.dynamicFeePpm > maxFeePpm) {
            pool.dynamicFeePpm = maxFeePpm;
        }
        
        // Determine actual fee to apply: use surge multiplier if a cap event occurred
        uint256 newFee = pool.dynamicFeePpm;
        if (capEventOccurred) {
            uint256 surgedFee = (pool.dynamicFeePpm * surgeMultiplierPpm) / 1000000;
            if (surgedFee < pool.dynamicFeePpm) {
                // Protect against rounding issues (ensure not less than baseline)
                surgedFee = pool.dynamicFeePpm;
            }
            if (surgedFee > maxFeePpm) {
                // Surge fee cannot exceed max bound
                surgedFee = maxFeePpm;
            }
            newFee = surgedFee;
        }
        
        // Update current fee and timestamp
        pool.currentFeePpm = newFee;
        pool.lastUpdateBlock = block.number;
        
        // Emit an event if the fee change is significant (>5% up or down)
        if (newFee * 100 > oldFee * 105 || newFee * 100 < oldFee * 95) {
            emit DynamicFeeUpdated(pid, oldFee, newFee);
        }
        return newFee;
    }
    
    /**
     * @notice Manually override the dynamic fee for a specific pool. Set a fixed fee or clear the override.
     * @param pid The pool identifier.
     * @param feePpm The fee in PPM to enforce (within bounds). Use 0 to disable the override.
     */
    function setDynamicFeeOverride(bytes32 pid, uint256 feePpm) external onlyOwner {
        require(feePpm == 0 || (feePpm >= minFeePpm && feePpm <= maxFeePpm), "Override fee out of bounds");
        PoolState storage pool = pools[pid];
        pool.overrideFeePpm = feePpm;
        if (feePpm != 0) {
            // Activate override: set current fee to the override and freeze dynamic tracking
            pool.currentFeePpm = feePpm;
            pool.eventRatePpm = TARGET_EVENT_RATE_PPM;  // reset event rate to target to avoid skew when resuming
        } else {
            // Remove override: resume dynamic fee from the last known current fee (within bounds)
            if (pool.currentFeePpm < minFeePpm) {
                pool.currentFeePpm = minFeePpm;
            }
            if (pool.currentFeePpm > maxFeePpm) {
                pool.currentFeePpm = maxFeePpm;
            }
            pool.dynamicFeePpm = pool.currentFeePpm;
        }
        pool.lastUpdateBlock = block.number;
        emit DynamicFeeOverrideSet(pid, feePpm);
    }
    
    /**
     * @notice Set the surge pricing multiplier (e.g., 200% = 2x) applied during cap events.
     * @param multiplierPpm Multiplier in PPM (1e6 = 100%, 2e6 = 200%, etc.). Must be >= 100%.
     */
    function setSurgeMultiplier(uint256 multiplierPpm) external onlyOwner {
        require(multiplierPpm >= 1000000, "Multiplier must be >= 100%");
        surgeMultiplierPpm = multiplierPpm;
        emit SurgeMultiplierSet(multiplierPpm);
    }
    
    /**
     * @notice Update the minimum and maximum fee bounds (in PPM).
     * @param _minFeePpm Minimum fee (in PPM).
     * @param _maxFeePpm Maximum fee (in PPM).
     */
    function setFeeBounds(uint256 _minFeePpm, uint256 _maxFeePpm) external onlyOwner {
        require(_minFeePpm <= _maxFeePpm, "minFee must be <= maxFee");
        minFeePpm = _minFeePpm;
        maxFeePpm = _maxFeePpm;
        emit FeeBoundsSet(_minFeePpm, _maxFeePpm);
    }
    
    /**
     * @notice Pause or unpause dynamic fee adjustments globally.
     * @param pause True to pause dynamic updates (freeze fees), False to resume.
     */
    function pauseDynamicFee(bool pause) external onlyOwner {
        dynamicFeePaused = pause;
        emit DynamicFeePaused(pause);
    }
    
    /**
     * @dev Internal function to compute base^exp in PPM (fixed-point 1e6) without loops.
     *      Uses binary exponentiation to efficiently compute (basePpm)^(exp).
     */
    function _powPpm(uint256 basePpm, uint256 exp) internal pure returns (uint256 resultPpm) {
        resultPpm = 1000000;  // start with 1.0 in PPM
        uint256 b = basePpm;
        while (exp > 0) {
            if (exp % 2 == 1) {
                resultPpm = (resultPpm * b) / 1000000;
            }
            b = (b * b) / 1000000;
            exp /= 2;
        }
    }
    
    /**
     * @notice Public wrapper for _powPpm to be used in testing
     * @dev This function exposes the internal _powPpm for testing purposes
     * @param basePpm The base value in PPM (e.g., 800000 = 80%)
     * @param exp The exponent
     * @return The result of basePpm^exp in PPM format
     */
    function testPowPpmPublic(uint256 basePpm, uint256 exp) public pure returns (uint256) {
        return _powPpm(basePpm, exp);
    }
} 