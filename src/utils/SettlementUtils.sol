// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Errors} from "../errors/Errors.sol";
import {FullRangeLiquidityManager} from "../FullRangeLiquidityManager.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SettlementUtils
 * @notice Utility functions for handling Uniswap V4 flash accounting settlements
 * @dev These utilities abstract the settlement logic for handling BalanceDelta
 */
library SettlementUtils {
    using SafeTransferLib for ERC20;
    using CurrencyLibrary for Currency;

    /**
     * @notice Handles settlement for a BalanceDelta after a pool operation
     * @dev Handles token transfers based on the delta (positive means take, negative means pay)
     * @param manager The PoolManager address
     * @param delta The balance delta to settle
     * @param token0 Address of token0
     * @param token1 Address of token1
     * @param recipientOrSender Address to send tokens to (for positive deltas) or take from (for negative deltas)
     */
    function settleBalanceDelta(
        IPoolManager manager,
        BalanceDelta delta,
        address token0,
        address token1,
        address recipientOrSender
    ) internal {
        // Decode delta values
        int256 delta0 = delta.amount0();
        int256 delta1 = delta.amount1();

        // Handle token0 settlement
        if (delta0 > 0) {
            // Take tokens from the pool (pool owes tokens to us)
            manager.take(Currency.wrap(token0), recipientOrSender, uint256(int256(delta0)));
        } else if (delta0 < 0) {
            // Pay tokens to the pool (we owe tokens to the pool)
            uint256 amountToSend = uint256(-delta0);
            ERC20(token0).safeTransferFrom(recipientOrSender, address(this), amountToSend);
            ERC20(token0).safeApprove(address(manager), amountToSend);
            manager.settle();
        }

        // Handle token1 settlement
        if (delta1 > 0) {
            // Take tokens from the pool (pool owes tokens to us)
            manager.take(Currency.wrap(token1), recipientOrSender, uint256(int256(delta1)));
        } else if (delta1 < 0) {
            // Pay tokens to the pool (we owe tokens to the pool)
            uint256 amountToSend = uint256(-delta1);
            ERC20(token1).safeTransferFrom(recipientOrSender, address(this), amountToSend);
            ERC20(token1).safeApprove(address(manager), amountToSend);
            manager.settle();
        }
    }

    /**
     * @notice Collects tokens from a BalanceDelta into this contract
     * @dev Similar to settleBalanceDelta but always takes tokens to the contract itself
     * @param manager The PoolManager address
     * @param key The PoolKey to operate on
     * @param delta The balance delta from operation
     */
    function collectDeltas(IPoolManager manager, PoolKey memory key, BalanceDelta delta) internal {
        // Decode delta values
        int256 delta0 = delta.amount0();
        int256 delta1 = delta.amount1();

        // Handle token0 collection if positive (we get tokens from pool)
        if (delta0 > 0) {
            manager.take(key.currency0, address(this), uint256(delta0));
        }

        // Handle token1 collection if positive (we get tokens from pool)
        if (delta1 > 0) {
            manager.take(key.currency1, address(this), uint256(delta1));
        }

        // Handle negative deltas (we owe tokens to pool)
        if (delta0 < 0 || delta1 < 0) {
            // We need to settle negative delta values
            if (delta0 < 0) {
                uint256 amountToSend = uint256(-delta0);
                ERC20(Currency.unwrap(key.currency0)).safeApprove(address(manager), amountToSend);
            }

            if (delta1 < 0) {
                uint256 amountToSend = uint256(-delta1);
                ERC20(Currency.unwrap(key.currency1)).safeApprove(address(manager), amountToSend);
            }

            // Call settle once for both currencies if needed
            manager.settle();
        }
    }

    /**
     * @notice Validates and settles a balance delta for a contract that already holds the tokens
     * @dev Used when contract already has the tokens and needs to settle with the PoolManager
     * @param manager The PoolManager address
     * @param delta The balance delta to settle
     * @param token0 Address of token0
     * @param token1 Address of token1
     * @param recipient Address to send tokens to (for positive deltas)
     */
    function settleBalanceDeltaFromContract(
        IPoolManager manager,
        BalanceDelta delta,
        address token0,
        address token1,
        address recipient
    ) internal {
        // Decode delta values
        int256 delta0 = delta.amount0();
        int256 delta1 = delta.amount1();

        // Handle token0 settlement
        if (delta0 > 0) {
            // Take tokens from the pool (pool owes tokens to us)
            manager.take(Currency.wrap(token0), recipient, uint256(int256(delta0)));
        }

        // Handle token1 settlement
        if (delta1 > 0) {
            // Take tokens from the pool (pool owes tokens to us)
            manager.take(Currency.wrap(token1), recipient, uint256(int256(delta1)));
        }

        // Handle negative deltas (we owe tokens to pool)
        if (delta0 < 0 || delta1 < 0) {
            // We need to settle negative delta values
            if (delta0 < 0) {
                uint256 amountToSend = uint256(-delta0);
                ERC20(token0).safeApprove(address(manager), amountToSend);
            }

            if (delta1 < 0) {
                uint256 amountToSend = uint256(-delta1);
                ERC20(token1).safeApprove(address(manager), amountToSend);
            }

            // Call settle once for both currencies if needed
            manager.settle();
        }
    }

    /**
     * @notice Calculate fee share distribution for position token holders
     * @param poolId The pool ID
     * @param feeAmount0 Token0 fee amount
     * @param feeAmount1 Token1 fee amount
     * @param liquidityManager The LiquidityManager to get pool liquidity from
     * @return sharesFromFees Shares to mint from fee reinvestment
     */
    function calculateFeeShares(
        PoolId poolId,
        uint256 feeAmount0,
        uint256 feeAmount1,
        FullRangeLiquidityManager liquidityManager
    ) internal view returns (uint256 sharesFromFees) {
        uint128 totalLiquidity = liquidityManager.positionTotalShares(poolId);
        if (totalLiquidity == 0) return 0;

        // use OpenZeppelin Math.sqrt for geometric mean
        sharesFromFees = Math.sqrt(feeAmount0 * feeAmount1);

        return sharesFromFees;
    }

    /**
     * @notice Validates and returns the total shares for a given pool
     * @param poolId The pool ID
     * @param liquidityManager The LiquidityManager contract to query shares from
     * @return totalShares The total number of shares for the pool
     */
    function _validateAndGetTotalShares(PoolId poolId, FullRangeLiquidityManager liquidityManager)
        internal
        view
        returns (uint256)
    {
        uint256 totalShares = liquidityManager.positionTotalShares(poolId);
        if (totalShares == 0) revert Errors.ZeroLiquidity();
        return totalShares;
    }
}
