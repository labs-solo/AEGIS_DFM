// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IFullRangePositions} from "./IFullRangePositions.sol";
import {FullRangePositions} from "../token/FullRangePositions.sol";
import {ExtendedPositionManager} from "../ExtendedPositionManager.sol";

/**
 * @notice Interface for FullRangeLiquidityManager (Phase 1: POL-Only)
 */
interface IFullRangeLiquidityManager {
    /// @notice the PoolManager this contract is bound to
    function manager() external view returns (IPoolManager);

    /// @notice address of the hook that is currently authorised
    function authorizedHookAddress() external view returns (address);

    /// @notice ERC-6909 share token contract that tracks pool-wide positions
    function positions() external view returns (IFullRangePositions);

    /* ───────── GOVERNANCE-ONLY API ───────── */

    function deposit(
        PoolId poolId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external payable returns (uint256 shares, uint256 amount0, uint256 amount1);

    function withdraw(PoolId poolId, uint256 sharesToBurn, uint256 amount0Min, uint256 amount1Min, address recipient)
        external
        returns (uint256 amount0, uint256 amount1);

    /* ───────── HOOK-ONLY API ───────── */

    function storePoolKey(PoolId poolId, PoolKey calldata key) external;

    function reinvest(PoolId poolId, uint256 use0, uint256 use1, uint128 liq)
        external
        payable
        returns (uint128 sharesMinted);

    /* ───────── MUTABLE STATE CONFIG ───────── */

    function setAuthorizedHookAddress(address hookAddress) external;

    /* ───────── VIEWS ───────── */

    function poolKeys(PoolId poolId) external view returns (PoolKey memory);

    function getPoolReserves(PoolId poolId) external view returns (uint256 reserve0, uint256 reserve1);

    function positionTotalShares(PoolId poolId) external view returns (uint128);

    /* ------------------------------------------------------------------ */
    /*  Helpers still used by tests & Spot (read-only, safe to keep)       */
    /* ------------------------------------------------------------------ */

    /**
     * @notice Return an account's share balance for a pool.
     * @dev Keeps the `initialized` boolean to avoid breaking existing test
     *      expectations.
     */
    function getAccountPosition(PoolId poolId, address account)
        external
        view
        returns (bool initialized, uint256 shares);

    /// @notice Returns the total number of ERC-6909 shares minted for the
    /// pool-wide position.
    function getShares(PoolId poolId) external view returns (uint256 shares);

    /// @notice Returns the ERC-721 tokenId of the full-range position for the pool.
    /// @dev Added to expose NFT id for off-chain analytics.
    function positionTokenId(PoolId poolId) external view returns (uint256 tokenId);

    /// @notice Returns the ExtendedPositionManager contract used by this manager.
    function posManager() external view returns (ExtendedPositionManager);

    // Removed old positions() returning address
    // Removed positionLiquidity(bytes32 poolId)
}
