## Overview
This PR enhances the oracle implementation with configurable price movement truncation to protect against price manipulation attacks.

## Key Changes
- Added customizable maximum tick movement threshold per pool
- Improved TruncatedOracle library to support configurable truncation parameters
- Created new TruncGeoOracleMulti contract with enhanced interfaces
- Added benchmark test for gas usage and oracle behavior
- Updated documentation throughout the codebase

## Why These Changes Are Needed
Price oracles are susceptible to manipulation via flash loans or other attack vectors. By implementing truncation of extreme price movements, we can provide better security guarantees while maintaining the accuracy of the oracle for legitimate price changes.

## Technical Implementation
- Pool-specific maximum tick movement thresholds with fallback to global default
- Truncation logic applied consistently across time-weighted averages
- Improved gas efficiency through storage optimizations

## Testing
The changes have been validated through:
- Unit tests for correct truncation behavior
- Gas benchmarking to ensure performance is maintained
- Integration tests with the full Uniswap V4 stack
