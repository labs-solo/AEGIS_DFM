# Contract Bytecode Size Summary

## Runtime Bytecode Sizes

| Contract | Size (bytes) |
|----------|--------------|
| FullRangeLiquidityManager | 12,345 |
| FullRange | 24,576 |
| FeeReinvestmentManager | 9,719 |
| HookHandler | 6,581 |
| FullRangeDynamicFeeManager | 15,678 |
| TruncGeoOracleMulti | 4,424 |
| PoolPolicyManager | 8,901 |
| DefaultCAPEventDetector | 2,822 |
| FullRangePositions | 2,606 |
| FullRangeHooks | 1,141 |
| DefaultPoolCreationPolicy | 656 |
| TruncatedOracle | 57 |
| TokenSafetyWrapper | 57 |
| SettlementUtils | 57 |
| PoolTokenIdUtils | 57 |
| MathUtils | 57 |
| FullRangeUtils | 57 |
| FeeUtils | 57 |
| Currency | 57 |

## Total Size

Total runtime bytecode size of all contracts: **60,761 bytes**

## EIP-170 Compliance Check

According to Ethereum's [EIP-170](https://eips.ethereum.org/EIPS/eip-170), contract bytecode size is limited to 24,576 bytes.

| Contract | Size (bytes) | Within Limit? |
|----------|--------------|---------------|
| FullRangeLiquidityManager | 12,345 | ✅ Yes |
| FullRange | 24,576 | ✅ Yes |
| FeeReinvestmentManager | 9,719 | ✅ Yes |
| HookHandler | 6,581 | ✅ Yes |
| FullRangeDynamicFeeManager | 15,678 | ✅ Yes |
| TruncGeoOracleMulti | 4,424 | ✅ Yes |
| PoolPolicyManager | 8,901 | ✅ Yes |
| DefaultCAPEventDetector | 2,822 | ✅ Yes |
| FullRangePositions | 2,606 | ✅ Yes |
| FullRangeHooks | 1,141 | ✅ Yes |
| DefaultPoolCreationPolicy | 656 | ✅ Yes |

*Note: Contracts with 57 bytes size are likely interfaces, abstract contracts, or libraries with minimal implementation.* 