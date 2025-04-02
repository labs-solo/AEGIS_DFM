## Overview
This PR enhances the oracle implementation with configurable price movement truncation to protect against price manipulation attacks, and simplifies the CAP event handling mechanism by removing the DefaultCAPEventDetector.

## Key Changes
- Added customizable maximum tick movement threshold per pool
- Improved TruncatedOracle library to support configurable truncation parameters
- Created new TruncGeoOracleMulti contract with enhanced interfaces
- Added benchmark test for gas usage and oracle behavior
- Updated documentation throughout the codebase
- Removed DefaultCAPEventDetector in favor of direct oracle-based CAP event detection
- Implemented surge fee and decay mechanism in FullRangeDynamicFeeManager

## Why These Changes Are Needed
Price oracles are susceptible to manipulation via flash loans or other attack vectors. By implementing truncation of extreme price movements, we can provide better security guarantees while maintaining the accuracy of the oracle for legitimate price changes. Additionally, the removal of DefaultCAPEventDetector simplifies the codebase and reduces gas costs by eliminating redundant checks.

## Technical Implementation
- Pool-specific maximum tick movement thresholds with fallback to global default
- Truncation logic applied consistently across time-weighted averages
- Improved gas efficiency through storage optimizations
- Direct CAP event detection based on oracle tick movement
- Surge fee implementation with linear decay over time

## Testing
The changes have been validated through:
- Unit tests for correct truncation behavior
- Gas benchmarking to ensure performance is maintained
- Integration tests with the full Uniswap V4 stack
- Comprehensive tests for surge fee and decay functionality

## Chronological History of Changes

### Phase 1: Analysis
1. Analyzed relevant contracts:
   - FullRangeDynamicFeeManager.sol
   - TruncatedOracle.sol
   - TruncGeoOracleMulti.sol
   - FullRange.sol
2. Identified redundancy in CAP event detection
3. Confirmed opportunity to simplify by using oracle truncation directly

### Phase 2: Remove DefaultCAPEventDetector
1. Removed DefaultCAPEventDetector.sol and ICAPEventDetector.sol
2. Modified FullRangeDynamicFeeManager.sol:
   - Removed capEventDetector state variable
   - Removed initialization in constructor
   - Removed detectCAPEvent call in _updateCapEventStatus
3. Modified FullRange.sol:
   - Removed capEventDetector state variable
   - Updated constructor parameters
   - Simplified afterSwap function

### Phase 3: Implement Surge Fee and Decay
1. Added to PoolState struct:
   - currentSurgeFeePpm
   - capEventEndTime
2. Defined constants:
   - INITIAL_SURGE_FEE_PPM
   - SURGE_DECAY_PERIOD_SECONDS
3. Modified _updateCapEventStatus:
   - Added surge fee updates
   - Added event emissions
4. Implemented _calculateCurrentDecayedSurgeFee
5. Created _getCurrentTotalFeePpm

### Phase 4: Update Tests and Deployment
1. Modified deployment scripts:
   - Removed DefaultCAPEventDetector deployment
   - Updated constructor calls
   - Fixed deployment order
2. Updated test files:
   - LocalUniswapV4TestBase.t.sol
   - SimpleV4Test.t.sol
   - SwapGasPlusOracleBenchmark.sol
   - GasBenchmarkTest.t.sol
3. Updated documentation:
   - README.md
   - bytecode-size-summary.md
4. Added new test cases for surge fee and decay

## Impact Analysis
- **Gas Efficiency**: Removal of DefaultCAPEventDetector reduces deployment and runtime gas costs
- **Code Simplicity**: Eliminated redundant CAP event detection logic
- **Maintainability**: Reduced number of contracts and dependencies
- **Security**: Maintained same level of price manipulation protection through oracle-based detection
