// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/**
 * @title IFullRangeLiquidityManager
 * @notice Public API exposed to Spot and the test-suite
 *
 *  ▸ functions marked *NEW* were added so that every call Spot makes
 *    is defined on the interface, and to expose the public-getter that
 *    the implementation already provides (`poolTotalShares`).
 */
interface IFullRangeLiquidityManager {
    /* ---------------------------------------------------------- */
    /*  Previously‑existing API                                   */
    /* ---------------------------------------------------------- */

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

    /* ---------------------------------------------------------- */
    /*  ➜  NEW helper the tests rely on                           */
    /* ---------------------------------------------------------- */

    /**
     * @notice Return pool reserves *and* the current total‑share counter
     * @dev Implemented in `FullRangeLiquidityManager` – added here so casting
     *      to the interface in the test file compiles.
     */
    function getPoolReservesAndShares(PoolId poolId)
        external
        view
        returns (uint256 reserve0, uint256 reserve1, uint128 totalShares);

    /*──────────────────────────── Functions Spot calls ──────────────────────*/

    /// full-range Spot hook stores the key here on `afterInitialize`
    function storePoolKey(PoolId poolId, PoolKey calldata key) external;

    /// view helper – Spot & front-ends fetch it
    function poolKeys(PoolId poolId) external view returns (PoolKey memory);

    /// lightweight reserve query that Spot uses on hot-path
    function getPoolReserves(PoolId poolId) external view returns (uint256 reserve0, uint256 reserve1);

    /// expose the public getter for the mapping
    function poolTotalShares(PoolId poolId) external view returns (uint128);

    /// used in tests to verify balances
    function getAccountPosition(PoolId poolId, address account)
        external
        view
        returns (bool initialized, uint256 shares);

    /// @notice Reinvests fees by adding liquidity to the pool.
    /// @dev Called by Spot hook. Assumes Spot holds necessary funds.
    /// @param poolId The ID of the pool to reinvest into.
    /// @param total0 Amount of token0 provided for reinvestment.
    /// @param total1 Amount of token1 provided for reinvestment.
    /// @param liquidity The calculated liquidity amount corresponding to total0/total1.
    /// @return liquidityMinted Amount of liquidity token minted representing the POL.
    function reinvest(PoolId poolId, uint256 total0, uint256 total1, uint128 liquidity)
        external
        payable
        returns (uint128 liquidityMinted);
}
