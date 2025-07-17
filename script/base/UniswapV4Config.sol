// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

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

        revert("Unsupported chain");
    }
}
