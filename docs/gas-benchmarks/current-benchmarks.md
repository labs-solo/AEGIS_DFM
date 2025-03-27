# Current Gas Benchmarks

Last Updated: March 31, 2023

## Test Results

### Add Liquidity Test
- First-time vs. Subsequent Operations:
  - Regular pool first-time: 274,621 gas
  - Regular pool subsequent: 59,014 gas
  - Initialization overhead: 215,607 gas (365% increase)
  - Hooked pool first-time: 379,350 gas
  - Hooked pool subsequent: 72,938 gas
  - Initialization overhead: 306,412 gas (420% increase)

- Different Amount Sizes (with warm storage):
  - Regular pool (small 1e9): 59,014 gas
  - Regular pool (medium 1e12): 59,030 gas
  - Regular pool (large 1e18): 59,011 gas
  - Hooked pool (small 1e9): 72,938 gas
  - Hooked pool (medium 1e12): 72,897 gas
  - Hooked pool (large 1e18): 72,894 gas

- Approval costs:
  - Regular pool first-time approval: 61,055 gas
  - Regular pool subsequent approval: 6,065 gas
  - Approval overhead: 54,990 gas (906% increase)
  - Hooked pool first-time approval: 52,025 gas
  - Hooked pool subsequent approval: 6,043 gas
  - Approval overhead: 45,982 gas (761% increase)

### Swap Test
- Total gas: 1,004,021
- Key operations:
  - Regular pool small swap: 92,922 gas
  - Regular pool large swap: 82,047 gas
  - Hooked pool swap: 101,472 gas
  - Small swap after large swap: 39,175 gas
  - Large swap as first operation: 116,835 gas

## Swap Operation Patterns

### First Operation Costs
- Initial swap operations incur significant "warmup" costs
- First operations cost 50-100% more gas than subsequent operations
- Regular pool small swap (first): 92,922 gas
- Regular pool small swap (second): 39,175 gas (57.8% reduction)

### Swap Ordering Effects
- Large swap first: 116,835 gas
- Large swap second: 82,047 gas (29.8% reduction)
- Order of operations has a substantial impact on overall gas usage
- Difference between optimal/suboptimal ordering: 77,660 gas

### Tick Space Crossing
- Small swap (no tick crossing): 92,922 gas
- Large swap (crosses 2 tick spaces): 82,047 gas
- Tick space crossing appears less significant than operation ordering
- Hooked pool swap overhead vs small swap: 8,550 gas
- Hooked pool swap overhead vs large swap: 19,425 gas

## Liquidity Operation Patterns

### First-Time vs. Subsequent Operations
- First-time operations incur massive initialization costs
- Regular pool initialization overhead: 215,607 gas (365%)
- Hooked pool initialization overhead: 306,412 gas (420%)
- Approval operations show similar patterns (761-906% overhead)
- Subsequent operations stabilize at much lower costs

### Amount Size Effects
- Once storage is warmed, amount size has negligible impact on gas costs
- Small (1e9), medium (1e12), and large (1e18) amounts all use similar gas
- Difference between smallest and largest amount: <0.2%
- This confirms that higher costs in first operations are due to storage initialization, not amount size

### Comparison to Swap Operations
- Both swaps and liquidity operations show significant first-time costs
- Liquidity operations have much larger initialization overhead (365-420%) vs. swaps (50-100%)
- Swap operations show order-dependent effects even after initialization
- Liquidity operations stabilize regardless of amount size after initialization

## Contract Deployment Costs
- PoolManager: 3,787,049 gas
- FullRange: 4,324,091 gas
- FullRangeLiquidityManager: 3,708,131 gas
- PoolPolicyManager: 1,123,350 gas
- MockERC20: 711,094 gas

## Detailed Function Analysis

### FullRange Contract
| Function | Gas Cost | Calls | Average |
|----------|----------|-------|---------|
| deposit (first-time) | 379,350 | 1 | 379,350 |
| deposit (subsequent) | 72,894-72,938 | 1 | 72,916 |
| getPoolReservesAndShares | 1,406 | 1 | 1,406 |

### PoolManager Contract
| Function | Gas Cost | Calls | Average |
|----------|----------|-------|---------|
| extsload | 2,378 | 1 | 2,378 |
| initialize | 183,051 | 1 | 183,051 |
| modifyLiquidity (first-time) | 274,621 | 1 | 274,621 |
| modifyLiquidity (subsequent) | 59,011-59,030 | 1 | 59,018 |

### MockERC20 Contract
| Function | Gas Cost | Calls | Average |
|----------|----------|-------|---------|
| approve (first-time) | 41,274-61,055 | 8 | 51,165 |
| approve (subsequent) | 6,043-6,065 | 8 | 6,054 |
| balanceOf | 1,440 | 18 | 1,440 |
| mint | 56,514 | 9 | 56,514 |

## Gas Optimization Targets

1. **High Priority**
   - First-time initialization costs: 215,607-306,412 gas
   - Contract deployment costs
   - First swap operation costs

2. **Medium Priority**
   - Subsequent operation costs (72,938 gas for hooked pool)
   - `approve` operations
   - `mint` operations
   - Swap operation ordering optimization

3. **Low Priority**
   - `balanceOf` calls
   - View functions

## Historical Comparison

[To be filled with comparison against previous benchmarks]

## Notes

- All tests were run with Solidity 0.8.26
- Gas costs are measured in a local test environment
- Numbers represent average gas costs across multiple runs
- First-time operations incur massive storage initialization costs (365-420%)
- Amount size has negligible impact once storage is warmed
- Both swaps and liquidity operations show first-time cost effects, but with different patterns
- Storage slot warming is a critical factor in gas optimization 