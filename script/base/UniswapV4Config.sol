// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";

abstract contract UniswapV4Config {
    struct UniswapV4Raw {
        address poolManager;
        address positionManager;
    }

    struct UniswapV4 {
        PoolManager poolManager;
        PositionManager positionManager;
    }

    function getChainConfig() internal view returns (UniswapV4 memory config) {
        UniswapV4Raw memory rawConfig = getRawChainConfig();
        config = UniswapV4({
            poolManager: PoolManager(rawConfig.poolManager),
            positionManager: PositionManager(payable(rawConfig.positionManager))
        });
    }

    function getRawChainConfig() internal view returns (UniswapV4Raw memory) {
        uint256 chainId = block.chainid;

        if (chainId == 130) {
            // Unichain Mainnet
            return UniswapV4Raw({
                poolManager: 0x1F98400000000000000000000000000000000004,
                positionManager: 0x4529A01c7A0410167c5740C487A8DE60232617bf
            });
        }

        if (chainId == 1) {
            // Ethereum Mainnet
            return UniswapV4Raw({
                poolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90,
                positionManager: 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e
            });
        }

        if (chainId == 8453) {
            // Base Mainnet
            return UniswapV4Raw({
                poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
                positionManager: 0x7C5f5A4bBd8fD63184577525326123B519429bDc
            });
        }

        if (chainId == 143) {
            // Monad Mainnet
            return UniswapV4Raw({
                poolManager: 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e,
                positionManager: 0x5b7eC4a94fF9beDb700fb82aB09d5846972F4016
            });
        }
        if (chainId == 196) {
            // OKX Mainnet
            return UniswapV4Raw({
                poolManager: 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32,
                positionManager: 0xbc9f3A5D767dD46E040F1CA48Ab17f29F59DC806
            });
        }

        revert("Unsupported chain");
    }
}
