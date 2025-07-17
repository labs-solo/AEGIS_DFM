// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

/// @title  LiquidityQ96 – strongly-typed wrapper for Uniswap V4 liquidity
/// @dev    Stores liquidity as a uint256 Q64.96 fixed-point.
///         Prevents accidental mixing with plain integers.
/* solhint-disable max-line-length */
type LiquidityQ96 is uint256;

library LiquidityQ96Lib {
    function unwrap(LiquidityQ96 l) internal pure returns (uint256) {
        return LiquidityQ96.unwrap(l);
    }

    /// @dev Convert Q64.96 liquidity -> uint128 for PoolManager calls.
    function toUint128(LiquidityQ96 l) internal pure returns (uint128) {
        return uint128(LiquidityQ96.unwrap(l) >> 96);
    }

    /// @dev Convert ERC-6909 `shares` -> Q64.96 liquidity.
    function fromShares(uint128 shares) internal pure returns (LiquidityQ96) {
        return LiquidityQ96.wrap(uint256(shares) << 96);
    }
}
