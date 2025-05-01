// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/**
 * @notice Interface for FullRangeLiquidityManager (Phase 1: POL-Only)
 */
interface IFullRangeLiquidityManager {

    /* ───────── GOVERNANCE-ONLY API ───────── */

    function deposit(
        PoolId poolId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external payable returns (uint256 shares, uint256 amount0, uint256 amount1);

    function withdraw(
        PoolId poolId,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external returns (uint256 amount0, uint256 amount1);

    /* ───────── HOOK-ONLY API ───────── */

    function storePoolKey(PoolId poolId, PoolKey calldata key) external;

    function reinvest(PoolId poolId, uint256 use0, uint256 use1, uint128 liq)
        external
        payable
        returns (uint128 sharesMinted); // Note: Implementation returns V2 shares

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
     * @notice Combined helper used by test-suite to fetch reserves and share
     *         counter in a single call.
     */
    function getPoolReservesAndShares(PoolId poolId)
        external
        view
        returns (uint256 reserve0, uint256 reserve1, uint128 totalShares);

    /**
     * @notice Return an account's share balance for a pool.
     * @dev Keeps the `initialized` boolean to avoid breaking existing test
     *      expectations.
     */
    function getAccountPosition(PoolId poolId, address account)
        external
        view
        returns (bool initialized, uint256 shares);

}
