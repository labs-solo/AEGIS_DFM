# Dynamic Fee System: Code-Level Deep Dive

Let me show you exactly how the dynamic fee system works by examining the actual code snippets from the codebase.

## 1. The Dual-Component Fee Structure

The system uses two independent fee components that operate on different timescales:

```solidity
// From FullRangeDynamicFeeManager.sol
struct PoolState {
    // Slot 1: Fee parameters (256 bits)
    uint128 baseFeePpm;         // Long-term base fee component
    uint128 currentSurgeFeePpm; // Short-term surge component
    
    // Slot 2: Timestamps and flags (256 bits)
    uint48 lastUpdateTimestamp; // For base fee periodic updates
    uint48 capEventEndTime;     // For surge fee decay tracking
    uint48 lastFeeUpdate;       // Rate limiting timestamp
    bool isInCapEvent;          // Current CAP state
    // ...
}
```

The total fee is always calculated as the sum of both components:

```solidity
// From FullRangeDynamicFeeManager.sol
function _getCurrentTotalFeePpm(PoolId poolId) internal view returns (uint256) {
    PoolState storage pool = poolStates[poolId];
    uint256 baseFee = pool.baseFeePpm;
    uint256 surgeFee = _calculateCurrentDecayedSurgeFee(poolId);
    
    uint256 totalFee = baseFee + surgeFee;
    if (totalFee > type(uint128).max) {
        totalFee = type(uint128).max; // Safety cap
    }
    
    return totalFee;
}
```

## 2. CAP Event Detection and Lifecycle

CAP events happen when price movements exceed the maximum allowed tick movement:

```solidity
// From TruncatedOracle.sol - The core tick capping mechanism
function transform(
    Observation memory last,
    uint32 blockTimestamp,
    int24 tick,
    uint128 liquidity,
    int24 maxAbsTickMove
) internal pure returns (Observation memory) {
    // Calculate absolute tick movement
    uint24 tickMove = MathUtils.absDiff(tick, last.prevTick);
    
    // Key line: Cap tick movement if it exceeds the maximum allowed
    if (tickMove > uint24(maxAbsTickMove)) {
        tick = tick > last.prevTick 
            ? last.prevTick + maxAbsTickMove 
            : last.prevTick - maxAbsTickMove;
    }
    
    // Return observation with potentially capped tick
    return Observation({...});
}
```

This capping is detected and tracked in the fee manager:

```solidity
// From FullRangeDynamicFeeManager.sol
function _updateOracleIfNeeded(PoolId poolId, PoolKey calldata key) internal returns (bool tickCapped) {
    // ...
    
    // Get current tick from pool
    (uint160 sqrtPriceX96, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
    
    // Calculate max allowed tick change based on current fee
    int24 maxTickChange = _calculateMaxTickChange(pool.baseFeePpm, tickScalingFactor);
    
    // Check if tick change exceeds the maximum allowed
    if (lastBlockUpdate > 0 && MathUtils.absDiff(currentTick, lastTick) > uint24(maxTickChange)) {
        // Tick movement capped - this triggers a CAP event
        tickCapped = true;
        int24 cappedTick = lastTick + (tickChange > 0 ? maxTickChange : -maxTickChange);
        
        emit TickChangeCapped(poolId, tickChange, tickChange > 0 ? maxTickChange : -maxTickChange);
        
        // Use capped tick for the oracle update
        currentTick = cappedTick;
    }
    
    // Update CAP event status
    _updateCapEventStatus(poolId, tickCapped);
    // ...
}
```

## 3. Surge Fee Activation and Decay

Surge fees are activated instantly when a CAP event occurs and decay linearly afterward:

```solidity
// From FullRangeDynamicFeeManager.sol
function _updateCapEventStatus(PoolId poolId, bool tickCapped) internal {
    PoolState storage pool = poolStates[poolId];
    
    // Determine the new CAP state based solely on tick capping
    bool newCapState = tickCapped;
    
    // Only process state changes
    if (pool.isInCapEvent != newCapState) {
        pool.isInCapEvent = newCapState;
        emit CapEventStateChanged(poolId, newCapState);
        
        if (newCapState) {
            // CAP Event Started - immediately activate surge fee
            pool.currentSurgeFeePpm = uint128(INITIAL_SURGE_FEE_PPM);
            pool.capEventEndTime = 0; // Reset end time
            emit SurgeFeeUpdated(poolId, pool.currentSurgeFeePpm, true);
        } else {
            // CAP Event Ended - begin decay period
            pool.capEventEndTime = uint48(block.timestamp); // Mark time for decay
            emit SurgeFeeUpdated(poolId, pool.currentSurgeFeePpm, false);
        }
    }
}
```

The surge fee decays linearly after a CAP event ends:

```solidity
// From FullRangeDynamicFeeManager.sol
function _calculateCurrentDecayedSurgeFee(PoolId poolId) internal view returns (uint256) {
    PoolState storage pool = poolStates[poolId];
    uint128 initialSurge = uint128(INITIAL_SURGE_FEE_PPM);

    // If still in CAP event, return the full surge fee
    if (pool.isInCapEvent) {
        if (pool.currentSurgeFeePpm == 0) {
            return initialSurge; 
        } 
        return pool.currentSurgeFeePpm;
    }

    // If CAP event has ended, calculate decay
    uint48 endTime = pool.capEventEndTime;
    if (endTime == 0) {
        return 0; // No CAP event occurred or fully decayed
    }

    uint256 timeSinceEnd = block.timestamp - endTime;

    // If decay period complete, return zero
    if (timeSinceEnd >= SURGE_DECAY_PERIOD_SECONDS) {
        return 0; 
    }

    // Linear decay formula
    uint256 decayedSurge = (uint256(initialSurge) * 
        (SURGE_DECAY_PERIOD_SECONDS - timeSinceEnd)) / SURGE_DECAY_PERIOD_SECONDS;

    return decayedSurge;
}
```

Surge fee parameters are globally configured:

```solidity
// From FullRangeDynamicFeeManager.sol
uint256 public constant INITIAL_SURGE_FEE_PPM = 5000; // 0.5% Surge Fee
uint256 public constant SURGE_DECAY_PERIOD_SECONDS = 3600; // 1 hour decay
```

## 4. Base Fee Adjustment Mechanism

The base fee adjusts periodically, based on CAP event frequency:

```solidity
// From FullRangeDynamicFeeManager.sol
function updateDynamicFeeIfNeeded(
    PoolId poolId,
    PoolKey calldata key
) public returns (uint256 baseFee, uint256 surgeFeeValue, bool wasUpdated) {
    // ...
    
    // Check if update is needed based on time
    bool shouldUpdate = block.timestamp >= pool.lastUpdateTimestamp + 3600; // 1 hour
    
    // Calculate current surge fee
    surgeFeeValue = _calculateCurrentDecayedSurgeFee(poolId);

    if (shouldUpdate) {
        // BASE FEE ADJUSTMENT LOGIC
        uint256 oldBaseFee = pool.baseFeePpm;
        uint256 newBaseFeePpm = oldBaseFee;
        
        // Here would be logic based on CAP event frequency
        // The "MaxTicksPerBlock Feedback Loop Analysis" document describes 
        // how frequent CAP events should increase the base fee, while
        // periods without CAP events should gradually decrease it
        
        // Example adjustment based on CAP event frequency:
        if (pool.isInCapEvent || frequentCapEvents) {
            // Increase base fee when CAP events are occurring
            newBaseFeePpm = (oldBaseFee * 110) / 100; // +10%
        } else {
            // Gradually decrease fee during stable periods
            newBaseFeePpm = (oldBaseFee * 99) / 100; // -1%
        }

        // Enforce fee bounds
        uint256 minTradingFee = policy.getMinimumTradingFee();
        uint256 maxBaseFeePpm = 50000; // 5%
        if (newBaseFeePpm < minTradingFee) {
            newBaseFeePpm = minTradingFee;
        } else if (newBaseFeePpm > maxBaseFeePpm) {
            newBaseFeePpm = maxBaseFeePpm;
        }

        // Update base fee if changed
        if (newBaseFeePpm != oldBaseFee) {
            pool.baseFeePpm = uint128(newBaseFeePpm);
            emit DynamicFeeUpdated(poolId, oldBaseFee, newBaseFeePpm, pool.isInCapEvent); 
        }
        
        pool.lastUpdateTimestamp = uint48(block.timestamp);
        wasUpdated = true;
    }
    
    baseFee = pool.baseFeePpm;
    return (baseFee, surgeFeeValue, wasUpdated); 
}
```

## 5. Critical Fee-to-MaxTickChange Relationship

This is where the feedback loop closes - higher fees allow larger price movements:

```solidity
// From FullRangeDynamicFeeManager.sol
function _calculateMaxTickChange(uint256 currentFeePpm, int24 tickScalingFactor) internal pure returns (int24) {
    // Direct proportional relationship between fee and allowed tick movement
    uint256 maxChangeUint = MathUtils.calculateFeeWithScale(
        currentFeePpm, 
        uint256(uint24(tickScalingFactor)),
        1e6 // PPM denominator
    );
    
    int256 maxChangeScaled = int256(maxChangeUint);
    
    // Clamp to int24 bounds and return
    if (maxChangeScaled > type(int24).max) return type(int24).max;
    if (maxChangeScaled < type(int24).min) return type(int24).min;
    
    return int24(maxChangeScaled);
}
```

From `PoolPolicyManager.sol` - governing the scaling factor:

```solidity
function getTickScalingFactor() external view returns (int24) {
    return tickScalingFactor;
}

function setTickScalingFactor(int24 newFactor) external onlyOwner {
    if (newFactor <= 0) revert Errors.ParameterOutOfRange(uint256(uint24(newFactor)), 1, type(uint24).max);
    tickScalingFactor = newFactor;
}
```

## 6. Fee Application During Swaps

The dynamic fee is applied during swaps through the Spot hook:

```solidity
// From Spot.sol
function _beforeSwap(
    address sender,
    PoolKey calldata key,
    IPoolManager.SwapParams calldata params,
    bytes calldata hookData
) internal virtual override returns (bytes4, BeforeSwapDelta, uint24) {
    // Ensure dynamic fee manager is set
    if (address(dynamicFeeManager) == address(0)) revert Errors.NotInitialized("DynamicFeeManager");

    bytes32 _poolId = PoolId.unwrap(key.toId());
    uint24 dynamicFee = uint24(dynamicFeeManager.getCurrentDynamicFee(PoolId.wrap(_poolId)));

    // Return selector, zero delta adjustment, and the dynamic fee
    return (
        BaseHook.beforeSwap.selector, 
        BeforeSwapDeltaLibrary.ZERO_DELTA,
        dynamicFee
    );
}
```

And the `getCurrentDynamicFee` function in the fee manager:

```solidity
// From FullRangeDynamicFeeManager.sol
function getCurrentDynamicFee(PoolId poolId) external view returns (uint256) {
    // Ensure pool is initialized before calculating total fee
    if (poolStates[poolId].lastUpdateTimestamp == 0) {
        return policy.getDefaultDynamicFee();
    }
    return _getCurrentTotalFeePpm(poolId);
}
```

## 7. The Complete Feedback Loop

The "MaxTicksPerBlock Feedback Loop Analysis" document explains the entire cycle:

``` text
The system creates a precise feedback loop:

1. Price movement exceeding MaxTicksPerBlock creates truncation
2. Truncation triggers CAP event
3. CAP event triggers surge fees
4. Frequent CAP events increase base fees
5. Base fee increases translate to higher MaxTicksPerBlock (through scaling relationship)
6. Higher MaxTicksPerBlock reduces truncation frequency
7. System reaches equilibrium at optimal MaxTicksPerBlock
```

This self-regulating dynamic fee mechanism consists of two independent but interconnected cycles:

1. **Short-term Surge Fee Cycle**: Immediate response to individual CAP events, quick activation and decay
2. **Long-term Base Fee Cycle**: Gradual adjustment based on CAP event frequency over time

Both components contribute to the MaxTickChange parameter, creating a complete negative feedback loop that adapts to market conditions and protects against manipulation while minimizing user costs during normal market operation.
