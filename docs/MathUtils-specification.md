# MathUtils Technical Specification

## Version 1.0.0

## 1. System Overview

The MathUtils library provides a centralized set of mathematical functions for the FullRange protocol. This document specifies the mathematical operations, their requirements, and implementation details.

## 2. Design Goals

- **Centralization**: Single source of truth for all math operations
- **Gas Efficiency**: Optimized implementations for minimal gas usage
- **Safety**: Comprehensive validation and error handling
- **Precision**: Balance between gas costs and arithmetic precision
- **Maintainability**: Clear, well-documented codebase

## 3. Implementation Requirements

### 3.1 Function Categories

#### 3.1.1 Core Math Operations
- Basic arithmetic with appropriate overflow/underflow protection
- Square root implementation optimized for gas using the Babylonian method
- Min/max functions
- Absolute difference calculation

#### 3.1.2 Share Calculations
- Initial share calculation using geometric mean
- Proportional share calculation for subsequent deposits
- Special handling for minimum liquidity locking
- Withdrawal amount calculation based on share proportion

#### 3.1.3 Fee Calculations
- Fee distribution logic compliant with governance parameters
- Reinvestment calculations that maintain price ratio
- Surge fee calculation based on market conditions
- Dynamic fee adjustment with bounds enforcement
- Time-based decay of surge fees

### 3.2 Error Handling Requirements

All functions must implement appropriate error handling:
- Input validation with specific error types
- Descriptive error messages with context
- Custom error types for each category of operation

### 3.3 Gas Optimization Requirements

- Use of unchecked blocks for safe operations
- Assembly optimization for bit manipulation
- Minimal storage reads and writes
- Efficient algorithm selection for common operations

## 4. Mathematical Formulas

### 4.1 Geometric Share Calculation

```
shares = sqrt(amount0 * amount1)
```

For first deposits, a minimum liquidity amount is permanently locked:
```
if (totalShares > MINIMUM_LIQUIDITY) {
    lockedShares = MINIMUM_LIQUIDITY
    shares = totalShares - MINIMUM_LIQUIDITY
} else {
    lockedShares = totalShares / 10
    shares = totalShares - lockedShares
}
```

### 4.2 Proportional Share Calculation

```
share0 = (amount0 * totalShares) / reserve0
share1 = (amount1 * totalShares) / reserve1
shares = min(share0, share1)
```

For high precision:
```
scaleFactor = 1e18
liquidityFromToken0 = (amount0 * totalShares * scaleFactor) / reserve0
liquidityFromToken1 = (amount1 * totalShares * scaleFactor) / reserve1
liquidityFromToken0 = liquidityFromToken0 / scaleFactor
liquidityFromToken1 = liquidityFromToken1 / scaleFactor
shares = min(liquidityFromToken0, liquidityFromToken1)
```

### 4.3 Withdrawal Amount Calculation

```
shareRatio = sharesToBurn / totalShares
amount0Out = reserve0 * shareRatio
amount1Out = reserve1 * shareRatio
```

### 4.4 Fee Distribution

```
polAmount0 = fee0 * polSharePpm / 1000000
polAmount1 = fee1 * polSharePpm / 1000000
fullRangeAmount0 = fee0 * fullRangeSharePpm / 1000000
fullRangeAmount1 = fee1 * fullRangeSharePpm / 1000000
lpAmount0 = fee0 * lpSharePpm / 1000000
lpAmount1 = fee1 * lpSharePpm / 1000000
```

With rounding correction:
```
totalAllocated0 = polAmount0 + fullRangeAmount0 + lpAmount0
if (totalAllocated0 < fee0) {
    lpAmount0 += fee0 - totalAllocated0
}
```

### 4.5 Reinvestable Fee Calculation

```
targetRatio = reserve0 / reserve1

if ((fee0 / fee1) > targetRatio) {
    // Limited by token1
    investable0 = fee1 * targetRatio
    investable1 = fee1
} else {
    // Limited by token0
    investable0 = fee0
    investable1 = fee0 / targetRatio
}
```

### 4.6 Dynamic Fee Calculation

```
if (capEventOccurred) {
    // Increase fee
    increase = min(abs(deviation), maxIncreaseLimit)
    newFee = currentFee + increase
} else {
    // Decrease fee
    decrease = min(abs(deviation), maxDecreaseLimit)
    newFee = max(currentFee - decrease, minFee)
}

// Apply bounds
newFee = clamp(newFee, minFee, maxFee)
```

### 4.7 Surge Fee Calculation

```
// If no surge or fully decayed, just return base fee
if (surgeMultiplierPpm <= PPM_SCALE || decayFactor == 0) {
    return baseFee;
}

// Calculate surge amount (amount above base fee)
surgeAmount = baseFee * (surgeMultiplierPpm - PPM_SCALE) / PPM_SCALE;

// Apply decay factor
if (decayFactor < PRECISION) {
    surgeAmount = surgeAmount * decayFactor / PRECISION;
}

// Return base fee plus (potentially decayed) surge amount
return baseFee + surgeAmount;
```

### 4.8 Decay Factor Calculation

```
// If beyond duration, fully decayed
if (secondsElapsed >= totalDuration) {
    return 0;
}

// Linear decay: 1 - (elapsed/total)
return PRECISION - (secondsElapsed * PRECISION / totalDuration);
```

## 5. Function Specifications

### 5.1 Core Math Functions

#### 5.1.1 `sqrt(uint256 x) → uint256`
- **Purpose**: Calculate square root using Babylonian method
- **Input Validation**: Return 0 for input 0
- **Edge Cases**: Returns floor of square root for non-perfect squares
- **Gas Optimization**: Uses unchecked block for gas efficiency

#### 5.1.2 `absDiff(int24 a, int24 b) → uint24`
- **Purpose**: Calculate absolute difference between two int24 values
- **Implementation**: Uses assembly for maximum gas efficiency
- **Edge Cases**: Handles negative values correctly

### 5.2 Share Calculation Functions

#### 5.2.1 `calculateGeometricShares(uint256 amount0, uint256 amount1, bool withMinimumLiquidity) → uint256, uint256`
- **Purpose**: Calculate shares based on geometric mean with optional liquidity locking
- **Input Validation**: Return (0, 0) if either input is 0
- **Returns**: (shares, lockedShares)

#### 5.2.2 `calculateProportionalShares(...) → uint256`
- **Purpose**: Calculate proportional shares for subsequent deposits
- **Input Validation**: Return 0 if any required input is 0
- **Parameters**: Includes high-precision flag for better precision with small amounts

#### 5.2.3 `computeDepositAmounts(...) → uint256, uint256, uint256, uint256`
- **Purpose**: Combined function for calculating deposits for new or existing pools
- **Input Validation**: Various validations depending on first deposit or subsequent
- **Returns**: (actual0, actual1, sharesMinted, lockedShares)
- **Gas Optimization**: Consolidated implementation with precision flag

#### 5.2.4 `computeWithdrawAmounts(...) → uint256, uint256`
- **Purpose**: Calculate withdrawal amounts based on shares to burn
- **Input Validation**: Return (0, 0) if totalShares or sharesToBurn is 0
- **Edge Cases**: Handle shares greater than totalShares
- **Returns**: (amount0Out, amount1Out)

### 5.3 Fee Calculation Functions

#### 5.3.1 `calculateFeeWithScale(uint256 amount, uint256 feeRate, uint256 scale) → uint256`
- **Purpose**: Calculate fee with custom scaling factor
- **Input Validation**: Return 0 if amount or feeRate is 0
- **Returns**: Fee amount

#### 5.3.2 `distributeFees(...) → uint256, uint256, uint256, uint256, uint256, uint256`
- **Purpose**: Distribute fees according to policy shares
- **Input Validation**: Validate shares sum to 100%
- **Edge Cases**: Handle rounding errors by assigning remainder to LP share
- **Returns**: (pol0, pol1, fullRange0, fullRange1, lp0, lp1)

#### 5.3.3 `calculateReinvestableFees(...) → uint256, uint256`
- **Purpose**: Calculate reinvestable fees
- **Input Validation**: Handle zero reserves as special case
- **Edge Cases**: Ensure outputs don't exceed inputs
- **Returns**: (investable0, investable1)

#### 5.3.4 `calculateDynamicFee(...) → uint256, bool, FeeAdjustmentType`
- **Purpose**: Calculate dynamic fee based on CAP event and deviation
- **Input Validation**: None required (all inputs valid)
- **Edge Cases**: Apply min/max bounds to result
- **Returns**: 
  - newFeePpm: New fee value in PPM
  - surgeEnabled: Whether surge pricing should be enabled
  - adjustmentType: Enum indicating reason for fee change

#### 5.3.5 `calculateSurgeFee(uint256 baseFeePpm, uint256 surgeMultiplierPpm, uint256 decayFactor) → uint256`
- **Purpose**: Calculate surge fee with optional linear decay
- **Input Validation**: Fast-path return for no surge cases
- **Edge Cases**: Handle different decay scenarios
- **Returns**: surgeFee: The calculated surge fee after decay

#### 5.3.6 `calculateDecayFactor(uint256 secondsElapsed, uint256 totalDuration) → uint256`
- **Purpose**: Calculate linear decay factor based on elapsed time
- **Input Validation**: Return 0 if beyond duration (fully decayed)
- **Returns**: decayFactor: Value between 0 (fully decayed) and PRECISION (no decay)

## 6. Validation and Testing Requirements

- Unit tests for all functions
- Fuzzing tests for complex operations
- Invariant testing for mathematical properties
- Gas benchmarking for optimization validation
- Time-based decay testing with different timestamps

## 7. Security Considerations

- Arithmetic overflow/underflow protection
- Precision loss mitigation
- Reentrancy considerations (where applicable)
- Input validation for all functions
- Timestamp manipulation resistance

## 8. Implementation Notes

### 8.1 Constants

```solidity
uint256 internal constant PRECISION = 1e18;
uint256 internal constant PPM_SCALE = 1e6;
uint256 internal constant MINIMUM_LIQUIDITY = 1000;
```

### 8.2 Library Dependencies

- FullMath: Used for safe multiplication and division
- TickMath: Used for tick/sqrt price conversions
- SqrtPriceMath: Used for price calculations
- MathErrors: Custom error types for the library

### 8.3 Structs and Enums

```solidity
struct FeeBounds {
    uint256 minFeePpm;        // Minimum fee (PPM)
    uint256 maxFeePpm;        // Maximum fee (PPM)
}

enum FeeAdjustmentType {
    NO_CHANGE,
    SIGNIFICANT_INCREASE,
    MODERATE_INCREASE,
    GRADUAL_DECREASE,
    MINIMUM_ENFORCED,
    MAXIMUM_ENFORCED
}
```

### 8.4 Code Style Guidelines

- NatSpec comments for all functions
- Clear variable naming
- Consistent error handling
- Gas optimization annotations

## 9. Version Control

The library follows semantic versioning:
- **Major version**: Breaking changes
- **Minor version**: New functionality, non-breaking
- **Patch version**: Bug fixes, optimizations

Current version: 1.0.0 