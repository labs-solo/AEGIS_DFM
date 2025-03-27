# Advanced Gas Benchmarking Proposal: Realistic Transaction Sequence Testing

## 1. Introduction

This proposal outlines the implementation of a comprehensive gas benchmarking framework that simulates real-world pool usage through sequences of 200-500 mixed transactions. Current benchmarking tests focus on isolated operations or small sequences, which may not reveal optimization opportunities or bottlenecks that emerge in production environments with varied transaction patterns.

## 2. Objectives

- Create statistically significant gas data based on realistic usage patterns
- Identify optimization opportunities that only emerge in extended transaction sequences
- Compare Hooked vs. Regular pool performance across varied transaction types
- Measure the effect of storage warming over extended periods
- Provide baseline metrics for future optimizations

## 3. Implementation Plan

### 3.1 New Test File

Create a new test file: `test/AdvancedGasBenchmarkTest.t.sol` that inherits from `LocalUniswapV4TestBase` with the following structure:

```solidity
contract AdvancedGasBenchmarkTest is LocalUniswapV4TestBase {
    // Configuration constants
    uint constant TOTAL_TRANSACTIONS = 300;
    uint constant SWAP_WEIGHT = 70;  // 70% of transactions are swaps
    uint constant DEPOSIT_WEIGHT = 20; // 20% of transactions are deposits
    uint constant WITHDRAW_WEIGHT = 10; // 10% of transactions are withdrawals
    
    // Test pools (similar to GasBenchmarkTest)
    PoolKey public regularPoolKey;
    PoolId public regularPoolId;
    
    // Test users
    address[] testUsers;
    
    // Operation trackers
    struct OperationGas {
        uint256 operationCount;
        uint256 totalGas;
        uint256 minGas;
        uint256 maxGas;
    }
    
    mapping(string => OperationGas) public regularPoolGas;
    mapping(string => OperationGas) public hookedPoolGas;
    
    function setUp() public override {
        // Setup code with pool initialization
        // Create test users
    }
    
    function test_realisticTransactionSequence() public {
        // Core benchmark implementation
    }
    
    // Helper functions for specific operations
}
```

### 3.2 Transaction Types and Distribution

Implement realistic transaction types with the following distribution:

#### 3.2.1 Swap Operations (70% of transactions)
- Random zeroForOne direction (50/50 split)
- Amount distribution:
  - Micro swaps (0.1-1% of liquidity): 20%
  - Small swaps (1-5% of liquidity): 40%
  - Medium swaps (5-15% of liquidity): 30%
  - Large swaps (15-30% of liquidity): 10%
- Random price limits (within reasonable ranges)

#### 3.2.2 Deposit Operations (20% of transactions)
- Amount distribution:
  - Small deposits (0.1-1% of existing liquidity): 40%
  - Medium deposits (1-5% of existing liquidity): 40%
  - Large deposits (5-15% of existing liquidity): 20%
- Random user selection from user pool

#### 3.2.3 Withdrawal Operations (10% of transactions)
- Amount distribution:
  - Partial withdrawals (10-50% of user position): 80%
  - Full withdrawals (90-100% of position): 20%
- User selection based on those with existing positions

### 3.3 Data Collection

For each operation, collect:
- Operation type and parameters
- Gas used
- Storage state before/after (relevant parameters)
- Position in sequence (to analyze trends over time)

### 3.4 Statistical Analysis

Implement aggregation of results:
- Gas per operation type and size
- Moving averages (per 50 operations)
- Variance analysis
- Comparison between hooked and regular pools

## 4. Implementation Details

### 4.1 Core Test Execution

```solidity
function test_realisticTransactionSequence() public {
    // Initialize pools with substantial liquidity
    _initializePoolsWithLiquidity();
    
    // Create deterministic but seemingly random sequence
    uint[] operationSequence = _generateOperationSequence();
    
    // Execute all operations
    for (uint i = 0; i < operationSequence.length; i++) {
        uint256 opType = operationSequence[i];
        
        if (opType < SWAP_WEIGHT) {
            _executeRandomSwap(i);
        } else if (opType < SWAP_WEIGHT + DEPOSIT_WEIGHT) {
            _executeRandomDeposit(i);
        } else {
            _executeRandomWithdrawal(i);
        }
        
        // Periodically output statistics (every 50 operations)
        if (i % 50 == 0) {
            _outputIntermediateStats(i);
        }
    }
    
    // Output final statistics
    _outputFinalStats();
}
```

### 4.2 Randomization Functions

Use a deterministic pseudo-random approach to ensure reproducibility:

```solidity
function _deterministicRandom(uint seed) internal pure returns (uint) {
    return uint(keccak256(abi.encodePacked(seed))) % 100;
}

function _generateOperationSequence() internal view returns (uint[] memory) {
    uint[] memory sequence = new uint[](TOTAL_TRANSACTIONS);
    
    for (uint i = 0; i < TOTAL_TRANSACTIONS; i++) {
        sequence[i] = _deterministicRandom(i);
    }
    
    return sequence;
}
```

### 4.3 Gas Tracking

Implement detailed gas tracking:

```solidity
function _trackGasUsage(string memory operationType, string memory poolType, uint256 gasUsed) internal {
    OperationGas storage tracker = poolType == "regular" ? regularPoolGas[operationType] : hookedPoolGas[operationType];
    
    tracker.operationCount++;
    tracker.totalGas += gasUsed;
    
    if (gasUsed < tracker.minGas || tracker.minGas == 0) {
        tracker.minGas = gasUsed;
    }
    
    if (gasUsed > tracker.maxGas) {
        tracker.maxGas = gasUsed;
    }
}
```

## 5. Output Format

Create standardized output format for result analysis:

### 5.1 Operation-Specific Metrics

```
OPERATION TYPE: [swap/deposit/withdraw]
SIZE: [micro/small/medium/large]
                Regular Pool          Hooked Pool          Difference
Count:          [count]              [count]              -
Avg Gas:        [avg]                [avg]                [diff] ([%])
Min Gas:        [min]                [min]                [diff] ([%])
Max Gas:        [max]                [max]                [diff] ([%])
Total Gas:      [total]              [total]              [diff] ([%])
```

### 5.2 Sequence Position Analysis

```
POSITION IN SEQUENCE: [0-50] [51-100] ... [451-500]
Avg Gas Regular:     [avg1]  [avg2]   ... [avgN]
Avg Gas Hooked:      [avg1]  [avg2]   ... [avgN]
Difference (%):      [diff1] [diff2]  ... [diffN]
```

## 6. Integration with Existing Documentation

The benchmark will align with existing gas benchmarking documentation:

### 6.1 Methodology Integration

This approach extends the methodology.md approach with:
- Long-running sequence testing
- Statistical distribution analysis
- Realistic transaction patterns
- Multi-user simulation

### 6.2 Data Export

Implement export functions to add results to current-benchmarks.md:
- Overall averages to be added to the main benchmark tables
- Operation sequence effects to be added to a new "Extended Sequence Effects" section
- Storage warming patterns over long sequences

### 6.3 Optimization Opportunities

Identify new optimization opportunities that emerge from sequence testing:
- Patterns that only appear after multiple operations
- User-specific patterns
- Direction-change optimizations
- Time-dependent gas patterns

## 7. Implementation Timeline (1-Day Plan)

### Morning (9:00 AM - 12:00 PM)
1. **9:00 - 10:00 AM**: Create test file structure and implement core functions
   - Set up contract structure
   - Define basic data structures
   - Implement framework for generating transaction sequences

2. **10:00 - 11:00 AM**: Implement core transaction types
   - Swap implementation with randomization
   - Deposit implementation with randomization
   - Withdrawal implementation with randomization

3. **11:00 - 12:00 PM**: Create gas tracking and analysis functions
   - Implement gas tracking mechanisms
   - Define output formats
   - Create statistical aggregation functions

### Afternoon (1:00 PM - 5:00 PM)
1. **1:00 - 2:30 PM**: Execute first test run and refine implementation
   - Run initial test with 100 transactions
   - Debug any issues
   - Optimize performance

2. **2:30 - 3:30 PM**: Full test execution and data collection
   - Run complete 300-transaction test
   - Collect comprehensive metrics
   - Generate statistical analysis

3. **3:30 - 5:00 PM**: Documentation and integration
   - Update benchmark documentation with results
   - Identify key insights and optimization opportunities
   - Prepare visualizations of the data

### Evening (If Needed)
- Address any remaining issues
- Perform additional test runs with different parameters
- Further refine documentation

## 8. References

### Existing Documentation
- [Current Benchmarks](./current-benchmarks.md)
- [Benchmarking Methodology](./methodology.md)
- [Optimization Opportunities](./optimization-opportunities.md)

### Relevant Test Files
- [GasBenchmarkTest.t.sol](../test/GasBenchmarkTest.t.sol)
- [LocalUniswapV4TestBase.t.sol](../test/LocalUniswapV4TestBase.t.sol)
- [SimpleV4Test.t.sol](../test/SimpleV4Test.t.sol)

## 9. Expected Outcomes

1. Comprehensive gas usage profile across diverse operation sequences
2. Identification of sequence-dependent optimization opportunities
3. Verification of storage warming benefits in production-like environments
4. Baseline metrics for future optimization efforts
5. Detection of potential gas usage anomalies in specific scenarios

## 10. Future Extensions

1. Multi-pool interaction simulation
2. MEV simulation (sandwich attacks, etc.)
3. High-frequency period simulations (e.g., swap storms)
4. Network congestion simulation

This proposal provides a framework to significantly enhance our understanding of gas usage patterns in realistic scenarios, enabling targeted optimizations that will benefit users in production environments. 