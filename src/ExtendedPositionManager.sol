pragma solidity 0.8.26;

// SPDX-License-Identifier: MIT

import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

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
        // Build the canonical (actions, params[]) payload expected by PositionManager.modifyLiquidities.
        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId, liquidity, amount0Max, amount1Max, hookData);

        // Encode into unlockData so PositionManager handles PoolManager.unlock/lock cycle internally.
        bytes memory unlockData = abi.encode(actions, params);

        // Delegate to the canonical router – this guarantees the PoolManager is unlocked again afterwards.
        this.modifyLiquidities{value: msg.value}(unlockData, block.timestamp + 300);
        return tokenId; // convenient in scripts
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
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY));
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(tokenId, liquidity, amount0Min, amount1Min, hookData);

        bytes memory unlockData = abi.encode(actions, params);

        this.modifyLiquidities(unlockData, block.timestamp + 300);
        return tokenId;
    }
} 