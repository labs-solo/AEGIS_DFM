# Gas Benchmarks Documentation

This directory contains comprehensive gas benchmarking data and analysis for the SoloHook project.

## Directory Structure

- `README.md` - This file, containing overview and navigation
- `current-benchmarks.md` - Latest gas benchmark results
- `historical-benchmarks/` - Historical benchmark data organized by date
- `methodology.md` - Detailed explanation of benchmarking methodology
- `optimization-opportunities.md` - Identified areas for gas optimization

## Quick Links

- [Current Benchmarks](./current-benchmarks.md)
- [Benchmarking Methodology](./methodology.md)
- [Optimization Opportunities](./optimization-opportunities.md)

## Running Benchmarks

To run gas benchmarks:

```bash
# Run all tests with gas reporting
forge test --gas-report

# Run specific test with gas reporting
forge test --gas-report --match-test test_addLiquidity
forge test --gas-report --match-test test_swap

# Create/update gas snapshot
forge snapshot

# Compare against previous snapshot
forge snapshot --diff
```

## Benchmark Categories

1. **Contract Deployment Costs**
   - Initial deployment gas costs
   - Contract size analysis

2. **Core Operations**
   - Liquidity provision
   - Swaps
   - Token approvals
   - Balance checks

3. **Edge Cases**
   - Large amounts
   - Small amounts
   - Multiple operations in sequence

## Maintenance

This documentation should be updated:
- After each significant code change
- Before and after optimization attempts
- When new features are added
- When gas costs change by more than 5% 