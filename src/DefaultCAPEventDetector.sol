// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {ICAPEventDetector} from "./interfaces/ICAPEventDetector.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {Errors} from "./errors/Errors.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/**
 * @title DefaultCAPEventDetector
 * @notice Default implementation for detecting price volatility (CAP) events
 * @dev Monitors significant price movements to identify unusual volatility
 */
contract DefaultCAPEventDetector is ICAPEventDetector, Owned {
    // Reference to pool manager
    IPoolManager public immutable poolManager;
    
    // Volatility thresholds for each pool
    mapping(PoolId => uint256) public volatilityThresholds;
    
    // Default volatility threshold (in basis points)
    uint256 public defaultVolatilityThreshold = 500; // 5%
    
    // Historical price observations for volatility detection
    struct PriceObservation {
        uint256 timestamp;
        uint160 sqrtPriceX96;
    }
    
    // Store recent price observations for each pool
    mapping(PoolId => PriceObservation[]) public priceObservations;
    
    // Maximum number of observations to store per pool
    uint256 public constant MAX_OBSERVATIONS = 5;
    
    // Minimum time between observations
    uint256 public minObservationInterval = 5 minutes;
    
    // Event for threshold updates
    event VolatilityThresholdUpdated(PoolId indexed poolId, uint256 threshold);
    event DefaultVolatilityThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event PriceObservationAdded(PoolId indexed poolId, uint160 sqrtPriceX96);
    event MinObservationIntervalUpdated(uint256 oldInterval, uint256 newInterval);
    event CAPEventDetected(PoolId indexed poolId, uint256 volatilityBps);
    
    /**
     * @notice Constructor
     * @param _poolManager The Uniswap V4 pool manager
     * @param _owner The owner of the contract
     */
    constructor(IPoolManager _poolManager, address _owner) Owned(_owner) {
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();
        poolManager = _poolManager;
    }
    
    /**
     * @notice Sets a custom volatility threshold for a specific pool
     * @param poolId The pool ID
     * @param thresholdBps The volatility threshold in basis points (e.g., 500 = 5%)
     */
    function setPoolVolatilityThreshold(PoolId poolId, uint256 thresholdBps) external onlyOwner {
        if (thresholdBps == 0) revert Errors.ParameterOutOfRange(thresholdBps, 1, 10000);
        volatilityThresholds[poolId] = thresholdBps;
        emit VolatilityThresholdUpdated(poolId, thresholdBps);
    }
    
    /**
     * @notice Sets the default volatility threshold for all pools
     * @param thresholdBps The default volatility threshold in basis points
     */
    function setDefaultVolatilityThreshold(uint256 thresholdBps) external onlyOwner {
        if (thresholdBps == 0) revert Errors.ParameterOutOfRange(thresholdBps, 1, 10000);
        uint256 oldThreshold = defaultVolatilityThreshold;
        defaultVolatilityThreshold = thresholdBps;
        emit DefaultVolatilityThresholdUpdated(oldThreshold, thresholdBps);
    }
    
    /**
     * @notice Sets the minimum time between price observations
     * @param intervalSeconds The minimum interval in seconds
     */
    function setMinObservationInterval(uint256 intervalSeconds) external onlyOwner {
        if (intervalSeconds < 60 || intervalSeconds > 1 days) {
            revert Errors.ParameterOutOfRange(intervalSeconds, 60, 1 days);
        }
        uint256 oldInterval = minObservationInterval;
        minObservationInterval = intervalSeconds;
        emit MinObservationIntervalUpdated(oldInterval, intervalSeconds);
    }
    
    /**
     * @notice Adds a price observation for a pool
     * @param poolId The pool ID
     */
    function addPriceObservation(PoolId poolId) external {
        // Get current price from pool manager
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        
        PriceObservation[] storage observations = priceObservations[poolId];
        
        // Check if enough time has passed since last observation
        if (observations.length > 0) {
            PriceObservation storage lastObs = observations[observations.length - 1];
            if (block.timestamp < lastObs.timestamp + minObservationInterval) {
                return; // Skip if not enough time has passed
            }
        }
        
        // Add new observation
        if (observations.length >= MAX_OBSERVATIONS) {
            // Shift array to remove oldest observation
            for (uint256 i = 0; i < MAX_OBSERVATIONS - 1; i++) {
                observations[i] = observations[i + 1];
            }
            observations[MAX_OBSERVATIONS - 1] = PriceObservation({
                timestamp: block.timestamp,
                sqrtPriceX96: sqrtPriceX96
            });
        } else {
            // Add to array
            observations.push(PriceObservation({
                timestamp: block.timestamp,
                sqrtPriceX96: sqrtPriceX96
            }));
        }
        
        emit PriceObservationAdded(poolId, sqrtPriceX96);
    }
    
    /**
     * @inheritdoc ICAPEventDetector
     */
    function detectCAPEvent(PoolId poolId) external view override returns (bool) {
        PriceObservation[] storage observations = priceObservations[poolId];
        
        // Need at least 2 observations to detect volatility
        if (observations.length < 2) {
            return false;
        }
        
        // Get current price
        (uint160 currentSqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        
        // Get the volatility threshold for this pool
        uint256 threshold = volatilityThresholds[poolId];
        if (threshold == 0) {
            threshold = defaultVolatilityThreshold;
        }
        
        // Get most recent observation
        PriceObservation storage lastObs = observations[observations.length - 1];
        
        // Calculate price change percentage in basis points
        uint256 volatilityBps = calculatePriceChangeBps(lastObs.sqrtPriceX96, currentSqrtPriceX96);
        
        // Check if volatility exceeds threshold
        if (volatilityBps >= threshold) {
            return true;
        }
        
        // Also check for rapid changes over the last few observations
        if (observations.length >= 3) {
            // Get oldest available observation
            PriceObservation storage oldestObs = observations[0];
            
            // Calculate longer-term price change
            volatilityBps = calculatePriceChangeBps(oldestObs.sqrtPriceX96, currentSqrtPriceX96);
            
            // Higher threshold for longer term movement (2x the normal threshold)
            if (volatilityBps >= threshold * 2) {
                return true;
            }
        }
        
        return false;
    }
    
    /**
     * @notice Calculate price change between two sqrt prices in basis points
     * @param oldSqrtPriceX96 The earlier sqrt price
     * @param newSqrtPriceX96 The later sqrt price
     * @return The price change in basis points (e.g., 500 = 5%)
     */
    function calculatePriceChangeBps(uint160 oldSqrtPriceX96, uint160 newSqrtPriceX96) public pure returns (uint256) {
        // Convert sqrt prices to regular prices (proportional to price, exact conversion not needed)
        uint256 oldPrice = uint256(oldSqrtPriceX96) * uint256(oldSqrtPriceX96);
        uint256 newPrice = uint256(newSqrtPriceX96) * uint256(newSqrtPriceX96);
        
        // Calculate change percentage
        if (newPrice > oldPrice) {
            return ((newPrice - oldPrice) * 10000) / oldPrice;
        } else {
            return ((oldPrice - newPrice) * 10000) / oldPrice;
        }
    }
    
    /**
     * @notice Get all price observations for a pool
     * @param poolId The pool ID
     * @return Array of price observations
     */
    function getPoolPriceObservations(PoolId poolId) external view returns (PriceObservation[] memory) {
        return priceObservations[poolId];
    }
} 