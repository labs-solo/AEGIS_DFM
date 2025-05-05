// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title  Tick-math helpers used by external hooks & tests
/// @notice Stand-alone so DynamicFeeManager byte-code stays lean.
library TickCheck {
    function abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    /// @dev max tick movement permitted when a pool charges `feePpm`
    function maxMove(uint256 feePpm, uint256 scale) internal pure returns (int24) {
        if (scale == 0) return 0;
        uint256 m = feePpm * scale / 1e6;
        // hardcoded maximum value for int24 (2^23 - 1 = 8388607)
        uint24 MAX_TICK = 8388607;
        if (m > MAX_TICK) m = MAX_TICK;
        return int24(uint24(m));
    }

    /// @return true iff |a-b|	>	maxChange
    function exceeds(int24 a, int24 b, int24 maxChange) internal pure returns (bool) {
        if (maxChange < 0) return false;
        return abs(int256(b) - int256(a)) > uint256(uint24(maxChange));
    }
}
