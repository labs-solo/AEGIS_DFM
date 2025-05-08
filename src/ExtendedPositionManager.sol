pragma solidity 0.8.26;

// SPDX-License-Identifier: MIT

import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title ExtendedPositionManager
/// @notice Thin wrapper around Uniswap v4 PositionManager that exposes convenience
///         helpers `increaseLiquidity` and `decreaseLiquidity` so external
///         contracts do not need to craft router calldata manually.
contract ExtendedPositionManager is PositionManager {
    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        uint256 _unsubscribeGasLimit,
        IPositionDescriptor _tokenDescriptor,
        IWETH9 _weth9
    ) PositionManager(_poolManager, _permit2, _unsubscribeGasLimit, _tokenDescriptor, _weth9) {}

    /*──────────────────── helpers for NFT owners ───────────────────*/

    /// @notice Convenience wrapper to increase liquidity without manual action encoding.
    /// @param tokenId The NFT id whose liquidity to change
    /// @param liquidity Amount of v4 liquidity to add
    /// @param amount0Max Max token0 willing to deposit (slippage guard)
    /// @param amount1Max Max token1 willing to deposit (slippage guard)
    /// @param hookData Arbitrary bytes passed to hook during modifyLiquidity
    function increaseLiquidity(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) external payable returns (uint256) {
        // Retrieve the poolKey to know the token pair for settlement
        (PoolKey memory poolKey,) = IPositionManager(address(this)).getPoolAndPositionInfo(tokenId);

        // Build actions: INCREASE_LIQUIDITY followed by SETTLE_PAIR
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));

        // Build params array (length 2)
        bytes[] memory params = new bytes[](2);
        // params[0] → INCREASE_LIQUIDITY arguments
        params[0] = abi.encode(tokenId, liquidity, amount0Max, amount1Max, hookData);
        // params[1] → SETTLE_PAIR arguments (currency0, currency1)
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        // Encode combined payload and execute via PosM
        bytes memory unlockData = abi.encode(actions, params);
        this.modifyLiquidities{value: msg.value}(unlockData, block.timestamp + 300);
        return tokenId;
    }

    /// @notice Convenience wrapper to decrease liquidity without manual action encoding.
    /// @param tokenId The NFT id whose liquidity to modify
    /// @param liquidity Amount of v4 liquidity to remove
    /// @param amount0Min Min token0 expected (slippage guard)
    /// @param amount1Min Min token1 expected (slippage guard)
    /// @param hookData Arbitrary bytes passed to hook during modifyLiquidity
    function decreaseLiquidity(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Min,
        uint128 amount1Min,
        bytes calldata hookData
    ) external returns (uint256) {
        // Retrieve the poolKey to settle after decreasing
        (PoolKey memory poolKey,) = IPositionManager(address(this)).getPoolAndPositionInfo(tokenId);

        // Build actions: DECREASE_LIQUIDITY → SETTLE_PAIR
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, amount0Min, amount1Min, hookData);
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        bytes memory unlockData = abi.encode(actions, params);
        this.modifyLiquidities(unlockData, block.timestamp + 300);
        return tokenId;
    }
} 