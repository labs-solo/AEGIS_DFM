# Breaking Circular Dependencies in Contract Initialization

This PR refactors the initialization flow of `FullRange` and `TruncGeoOracleMulti` to eliminate circular dependencies during deployment and setup. The changes improve the robustness of contract initialization while maintaining security guarantees.

## Key Changes

### 1. Refactored `FullRange.sol`
- Removed `dynamicFeeManager` from constructor arguments
- Added `setDynamicFeeManager` governance setter
- Added initialization checks in hooks that use `dynamicFeeManager`
- Maintains security through governance-only setter and initialization guards

### 2. Refactored `TruncGeoOracleMulti.sol`
- Removed `fullRangeHook` from constructor arguments
- Made `fullRangeHook` mutable (removed `immutable`)
- Added `setFullRangeHook` governance setter
- Added `onlyFullRangeHook` modifier with initialization check
- Maintains security through bilateral authentication pattern

### 3. Updated Test Infrastructure
- Fixed `HookMiner.find` usage in `LocalUniswapV4TestBase` to use correct deployer address
- Updated deployment scripts to use new initialization flow
- Added detailed logging for better debugging
- Fixed test setup to properly initialize contracts in correct order

## Technical Details

The changes resolve three key issues:

1. **Constructor Circular Dependency**
   - `FullRange` needed `DynamicFeeManager`'s address
   - `DynamicFeeManager` needed `FullRange`'s address
   - Solved by moving `DynamicFeeManager` initialization to post-deployment setter

2. **Oracle Authentication**
   - `TruncGeoOracleMulti` needed `FullRange`'s address for auth checks
   - `FullRange` needed oracle for initialization
   - Solved by implementing bilateral authentication with post-deployment setters

3. **Hook Address Validation**
   - `HookMiner.find` calculations needed to match actual deployment
   - Fixed by using consistent deployer address (`governance`) in both calculation and deployment

## Security Considerations

The new initialization pattern maintains security through:
- Governance-only setters
- One-time initialization checks
- Proper authorization checks in all sensitive functions
- Bilateral authentication between `FullRange` and `TruncGeoOracleMulti`

## Testing

All test suites now pass:
- `CompilerVersionCheck.t.sol`
- `SimpleV4Test.t.sol`
- `GasBenchmarkTest.t.sol`
- `SwapGasPlusOracleBenchmark.sol`

The changes resolve the previous test failures:
- `InvalidHookResponse` in `SimpleV4Test`
- `HookAddressNotValid` in gas benchmark tests
- `NotInitialized("DynamicFeeManager")` in initialization

## Next Steps

Consider:
1. Adding events for initialization steps
2. Enhancing initialization status checks
3. Adding integration tests specifically for initialization flows
4. Documenting the initialization sequence in deployment guides 