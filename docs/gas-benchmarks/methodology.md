# Gas Benchmarking Methodology

## Overview

This document outlines the methodology used for gas benchmarking in the SoloHook project. The goal is to provide consistent, reliable, and comparable gas cost measurements across different versions of the codebase.

## Testing Environment

1. **Local Test Environment**
   - Solidity version: 0.8.26
   - Foundry framework
   - Local test network

2. **Test Data**
   - Standard test amounts
   - Representative token pairs
   - Multiple test iterations

## Measurement Process

### 1. Contract Deployment Costs
- Measure gas costs for deploying each contract
- Include constructor parameters
- Account for contract size limitations
- Document deployment dependencies

### 2. Core Operations
- Measure gas costs for each major operation
- Include setup costs (approvals, etc.)
- Account for state changes
- Document edge cases

### 3. Test Scenarios
- Standard operations
- Edge cases
- Multiple operations in sequence
- Error cases
- Operation ordering variations
  - Same operations in different orders
  - Small operations before large operations
  - Large operations before small operations
  - Measuring "warmup" costs for first operations
- First-time vs. subsequent operations
  - First operation with cold storage
  - Subsequent operations with warm storage
  - Isolate initialization costs from recurring costs
  - Measure percentage overhead for first-time operations
- Amount variations
  - Test different amount sizes with warm storage
  - Verify independence of gas costs from amount size
  - Document any amount-dependent patterns

## Data Collection

### 1. Running Tests
```bash
# Run all tests with gas reporting
forge test --gas-report

# Run specific test with gas reporting
forge test --gas-report --match-test test_addLiquidity
forge test --gas-report --match-test test_swap
forge test --gas-report --match-test test_compareSwapsReversed
forge test --gas-report --match-test test_compareAddLiquidity
```

### 2. Snapshot Management
```bash
# Create/update gas snapshot
forge snapshot

# Compare against previous snapshot
forge snapshot --diff
```

### 3. Data Recording
- Record all gas costs
- Note number of calls
- Document test conditions
- Include relevant metadata
- Track operation ordering effects
- Document storage slot warming patterns
- Record first-time vs. subsequent operation costs
- Calculate initialization overhead percentages
- Separate one-time costs from recurring costs

## Analysis Process

### 1. Data Processing
- Calculate averages
- Identify outliers
- Compare with previous versions
- Document significant changes
- Analyze operation ordering impact
- Calculate storage warmup costs
- Identify patterns in first vs. subsequent operations
- Isolate initialization costs from recurring costs
- Analyze whether cost is dependent on amount size
- Compare different operation types (swaps vs. liquidity)

### 2. Optimization Opportunities
- Identify high-cost operations
- Analyze patterns
- Suggest improvements
- Track optimization progress
- Document optimal operation ordering
- Design storage warming strategies
- Develop initialization optimization strategies
- Focus on both one-time and recurring costs

### 3. Reporting
- Update current benchmarks
- Maintain historical records
- Document methodology changes
- Track optimization results
- Report operation ordering effects
- Document warmup cost analysis
- Show first-time vs. subsequent operation costs
- Present initialization overhead percentages
- Document operation type differences

## Maintenance

### 1. Regular Updates
- After code changes
- Before/after optimizations
- When adding features
- When gas costs change significantly

### 2. Version Control
- Tag benchmark versions
- Document methodology changes
- Track optimization history
- Maintain changelog

### 3. Quality Control
- Verify test consistency
- Validate measurements
- Cross-reference results
- Document anomalies

## Best Practices

1. **Consistency**
   - Use same test environment
   - Maintain test data
   - Follow methodology strictly
   - Document deviations

2. **Accuracy**
   - Multiple test runs
   - Account for variations
   - Document conditions
   - Verify results

3. **Documentation**
   - Update all relevant files
   - Maintain changelog
   - Document methodology changes
   - Track optimization progress

4. **Analysis**
   - Identify trends
   - Compare versions
   - Track improvements
   - Document findings
   - Analyze operation ordering
   - Study storage access patterns
   - Compare first-time vs. subsequent operations
   - Evaluate initialization overhead impact
   - Distinguish one-time costs from recurring costs 