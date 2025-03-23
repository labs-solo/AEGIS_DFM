# MathUtils Library Documentation

## Overview
The MathUtils library provides a comprehensive set of mathematical utilities for the FullRange protocol. This consolidated library centralizes all mathematical operations that were previously scattered across multiple math-specific libraries.

## Version: 1.0.0

## Categories

### Core Math Operations
- Basic arithmetic with appropriate overflow/underflow protection
- Square root implementation optimized for gas using the Babylonian method
- Min/max functions for comparing values
- Absolute difference calculations

### Tick and Price Operations
- Functions for calculating tick values from prices
- Price conversion utilities
- Range calculations

### Liquidity Calculations
- Functions for calculating liquidity from token amounts
- Geometric mean-based liquidity calculations
- Share-to-liquidity conversions

### Share Calculations
- Initial share calculation using geometric mean
- Proportional share calculation for subsequent deposits
- Minimum liquidity locking for first deposits
- Withdrawal amount calculations

### Fee Calculations
- Fee distribution logic compliant with governance parameters
- Reinvestment calculations that maintain price ratio
- Surge fee calculation based on market conditions
- Dynamic fee adjustments

## Usage Examples

### Calculating Deposit Amounts

```solidity
// Example of calculating deposit amounts for a pool
(uint256 actual0, uint256 actual1, uint256 shares, uint256 locked) = 
    MathUtils.computeDepositAmountsAndShares(
        totalShares, // Current total shares in the pool
        amount0Desired, // User's desired token0 input
        amount1Desired, // User's desired token1 input
        reserve0, // Current reserve of token0
        reserve1 // Current reserve of token1
    );
```

High-precision version:

```solidity
(uint256 actual0, uint256 actual1, uint256 shares, uint256 locked) = 
    MathUtils.computeDepositAmountsAndSharesWithPrecision(
        totalShares,
        amount0Desired,
        amount1Desired,
        reserve0,
        reserve1
    );
```

### Calculating Withdrawal Amounts

```solidity
// Calculate token amounts for a withdrawal
(uint256 amount0Out, uint256 amount1Out) = 
    MathUtils.computeWithdrawAmounts(
        totalShares, // Current total shares in the pool
        sharesToBurn, // Amount of shares user is burning
        reserve0, // Current reserve of token0
        reserve1 // Current reserve of token1
    );
```

### Distributing Fees

```solidity
// Distribute fees according to policy
(
    uint256 pol0, // Protocol-owned liquidity token0 share
    uint256 pol1, // Protocol-owned liquidity token1 share
    uint256 fullRange0, // Full range token0 share
    uint256 fullRange1, // Full range token1 share
    uint256 lp0, // LP token0 share
    uint256 lp1 // LP token1 share
) = MathUtils.distributeFees(
    totalFee0, // Total token0 fees to distribute
    totalFee1, // Total token1 fees to distribute
    200000, // POL share (20% in PPM)
    300000, // Full range share (30% in PPM)
    500000 // LP share (50% in PPM)
);
```

### Calculating Reinvestable Fees

```solidity
// Calculate fees that can be reinvested into the pool
(uint256 investable0, uint256 investable1) = 
    MathUtils.calculateReinvestableFees(
        fee0, // Total token0 fees
        fee1, // Total token1 fees
        reserve0, // Current reserve of token0
        reserve1 // Current reserve of token1
    );
```

### Dynamic Fee Calculation

```solidity
// Calculate new dynamic fee based on market conditions
uint256 newFee = MathUtils.calculateDynamicFee(
    currentFee, // Current fee rate
    capEventOccurred, // Whether a CAP event occurred
    deviation, // Price deviation
    maxIncreaseLimit, // Maximum fee increase limit
    maxDecreaseLimit, // Maximum fee decrease limit
    minFee, // Minimum allowed fee
    maxFee // Maximum allowed fee
);
```

## Gas Optimizations

The library implements several gas optimizations:

1. **Unchecked blocks** for arithmetic operations that cannot overflow
   ```solidity
   unchecked {
       shares = totalShares - MINIMUM_LIQUIDITY;
       lockedShares = MINIMUM_LIQUIDITY;
   }
   ```

2. **Assembly optimizations** for bit manipulation operations
   ```solidity
   function absDiff(int24 a, int24 b) internal pure returns (uint24 diff) {
       assembly {
           // Calculate difference (a - b)
           let x := sub(a, b)
           
           // Get sign bit by shifting right by 31 positions
           let sign := shr(31, x)
           
           // If sign bit is 1 (negative), negate x
           // Otherwise keep x as is
           diff := xor(x, mul(sign, not(0)))
           
           // If sign bit is 1, add 1 to complete two's complement negation
           diff := add(diff, sign)
       }
   }
   ```

3. **Early returns** for common cases to avoid unnecessary calculations
   ```solidity
   if (fee0 == 0 && fee1 == 0) {
       return (0, 0);
   }
   ```

4. **Function consolidation** with optional parameters
   ```solidity
   function computeDepositAmounts(
       uint128 totalShares,
       uint256 amount0Desired,
       uint256 amount1Desired,
       uint256 reserve0,
       uint256 reserve1,
       bool highPrecision
   ) internal pure returns (...) {
       // Implementation that handles both precision modes
   }
   ```

## Benchmarks

> **Note**: The following benchmarks are projected estimates. Actual values will be measured using Foundry's gas reporting tools.

| Function                        | Projected Gas | Projected Comparison to Previous |
|---------------------------------|----------|------------------------|
| calculateGeometricShares        | 932      | 25.1% reduction        |
| computeDepositAmountsAndShares  | 3,541    | 18.3% reduction        |
| computeWithdrawAmounts          | 1,721    | 19.3% reduction        |
| calculateReinvestableFees       | 2,115    | 15.7% reduction        |
| distributeFees                  | 2,847    | 11.4% reduction        |

Once testing is complete with Foundry, these benchmarks will be updated with actual measurements from the test environment.

## Error Handling

The library uses custom error types defined in `MathErrors.sol` for better error handling:

```solidity
// Example of input validation with specific error
if (amount0Desired > type(uint128).max || amount1Desired > type(uint128).max) {
    revert MathErrors.AmountTooLarge(
        amount0Desired > amount1Desired ? amount0Desired : amount1Desired, 
        type(uint128).max
    );
}
```

## Best Practices

1. **Always validate inputs**: Use explicit checks even though MathUtils includes validation
2. **Handle all errors**: Catch and handle specific MathErrors to provide better user feedback
3. **Choose precision appropriately**: Use high-precision variants only when necessary for large numbers or critical calculations
4. **Optimize gas usage**: For frequently called functions, prefer the gas-optimized versions
5. **Test edge cases**: Particularly test boundary conditions (zero values, maximum values)

## Common Pitfalls

1. **Precision Loss**: Be aware that some calculations may experience precision loss, especially with very small or large numbers
2. **Rounding Behavior**: Different functions may round up or down; check documentation for specific behavior
3. **Token Decimals**: Remember that token decimal differences can affect calculations when using raw amounts
4. **Gas Estimation**: Always include a buffer when estimating gas costs for transactions using math functions

## Migration Guide

If you were using one of the deprecated math libraries, here's how to migrate to MathUtils:

| Old Library           | Function                 | New MathUtils Function        |
|-----------------------|--------------------------|-------------------------------|
| LiquidityMath.sol     | getAmount0ForLiquidity   | MathUtils.getAmount0ForLiquidity |
| LiquidityMath.sol     | getAmount1ForLiquidity   | MathUtils.getAmount1ForLiquidity |
| Fees.sol              | calculateFee             | MathUtils.calculateFeePpm     |
| PodsLibrary.sol       | calculateShares          | MathUtils.calculatePodShares  |
| FullRangeMathLib.sol  | calculateGeometricMean   | MathUtils.calculateGeometricMean |
| FullRangeMathLib.sol  | computeDeposit           | MathUtils.computeDepositAmountsAndShares |
| FullRangeMathLib.sol  | computeWithdraw          | MathUtils.computeWithdrawAmounts |
| FullRangeMathLib.sol  | distributeFees           | MathUtils.distributeFees      | 