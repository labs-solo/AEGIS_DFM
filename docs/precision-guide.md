# Precision Model Guide

This document explains the standardized precision model used throughout the SoloHook protocol codebase.

## Core Precision Constants

All precision constants are now centralized in the `PrecisionConstants.sol` library to ensure consistency across the protocol.

### `PRECISION` (1e18)

- **Value**: 10^18 (1,000,000,000,000,000,000)
- **Use cases**:
  - High-precision financial calculations
  - Interest rates and interest multipliers
  - Loan-to-Value (LTV) ratios
  - Price ratios
  - Percentages that require more than 6 decimal places of precision

### `PPM_SCALE` (1e6)

- **Value**: 10^6 (1,000,000)
- **Use cases**:
  - Parts-per-million (PPM) calculations
  - Fee percentages (e.g., 1% = 10,000 PPM)
  - Allocation shares (e.g., 50% = 500,000 PPM)
  - Protocol parameters that represent percentages

## When to Use Each Precision Constant

### Use `PRECISION` (1e18) when:

1. Dealing with interest rates or time-based accumulation
2. Performing calculations where high precision is critical
3. Working with fractional values that could be very small
4. Implementing financial formulas that expect 18 decimal precision

### Use `PPM_SCALE` (1e6) when:

1. Representing percentages where 6 decimal places are sufficient
2. Allocating or splitting values (like fee distribution)
3. Defining protocol parameters that are conceptually percentages
4. Working with values that are commonly expressed in basis points (1 bp = 100 PPM)

## Converting Between Precision Models

To convert between precision models:

```solidity
// Convert from PPM_SCALE to PRECISION
uint256 valueInPrecision = (valueInPpm * PRECISION) / PPM_SCALE;

// Convert from PRECISION to PPM_SCALE
uint256 valueInPpm = (valueInPrecision * PPM_SCALE) / PRECISION;
```

## Best Practices

1. **Always use the constants**: Never hardcode `1e18` or `1e6` - always reference the constants from `PrecisionConstants.sol`

2. **Document scaling**: When defining parameters or return values, document the scaling factor:
   ```solidity
   // Good
   * @param interestRate The interest rate (scaled by PrecisionConstants.PRECISION)
   
   // Bad
   * @param interestRate The interest rate
   ```

3. **Use `FullMath` for multiplication/division**: When performing calculations, use `FullMath.mulDiv` to prevent overflow:
   ```solidity
   // Good
   uint256 interestAmount = FullMath.mulDiv(principal, interestRate, PrecisionConstants.PRECISION);
   
   // Bad
   uint256 interestAmount = (principal * interestRate) / PrecisionConstants.PRECISION;
   ```

4. **Be consistent**: Don't mix precision models in the same calculation

5. **Prefer higher precision for intermediate calculations**: When in doubt, use the higher precision mode for intermediate calculations, then convert to the required precision for the final result

## Common Patterns

### Calculating a Percentage

```solidity
// Calculate 10% of amount
uint256 tenPercent = MathUtils.calculateFeePpm(amount, 100_000); // 10% = 100,000 PPM
```

### Proportional Calculation

```solidity
// Calculate proportional value (e.g., shares based on deposit amount)
uint256 shares = MathUtils.calculateProportional(
    depositAmount,
    totalShares,
    totalValue,
    false // don't round up
);
```

### Interest Calculation

```solidity
// Calculate interest over time
uint256 interestFactor = FullMath.mulDiv(
    interestRatePerSecond * timeElapsed,
    PrecisionConstants.PRECISION,
    PrecisionConstants.PRECISION
);
```

## File-Specific Precision Models

In rare cases, certain files may have domain-specific precision requirements. These have been modified to make their intent clearer:

- `FullRangeLiquidityManager.sol`: Uses `PERCENTAGE_PRECISION` (1,000,000) instead of `PRECISION` to clarify it's using PPM-scale precision for percentage calculations.

## Testing Precision

When writing tests involving precision calculations:

1. Validate edge cases (very small and very large values)
2. Check for rounding errors in sequences of operations
3. Verify calculations against expected results with high precision 