// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title  Minimal interface for Full-Range share token
/// @notice We purposefully stay **ERC-6909-only** – no ERC-1155 surface.
interface IFullRangePositions {
    /// -----------------------------------------------------------------------
    /// Read-only helpers needed by production & tests
    /// -----------------------------------------------------------------------

    /// @notice total ERC-6909 shares for a given pool-wide token id
    function totalSupply(bytes32 id) external view returns (uint256);

    /// @notice Uniswap-V4 liquidity held by the pool-wide position
    function positionLiquidity(bytes32 id) external view returns (uint128);

    /// @notice share balance for a specific owner (ERC-6909)
    function shareBalance(bytes32 id, address owner) external view returns (uint256);
}
