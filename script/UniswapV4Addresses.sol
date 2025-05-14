// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";

contract UniswapV4Addresses {
    // Uniswap V4 Canonical Contracts
    mapping(uint256 => address) private poolManagers;
    mapping(uint256 => address) private positionManagers;

    function setUp() internal {
        // Eth mainnet
        poolManagers[130] = 0x1F98400000000000000000000000000000000004;
        positionManagers[130] = 0x4529A01c7A0410167c5740C487A8DE60232617bf;

        // Unichain
        poolManagers[130] = 0x1F98400000000000000000000000000000000004;
        positionManagers[130] = 0x4529A01c7A0410167c5740C487A8DE60232617bf;
    }

    function getPoolManager() internal view returns (PoolManager poolManager) {
        uint256 chainId = block.chainid;
        address _poolManager = poolManagers[chainId];

        // Ensure we have a configured address for this chain
        require(_poolManager != address(0), "No pool manager address configured for this chain");
        poolManager = PoolManager(_poolManager);
    }

    function getPositionManager() internal view returns (PositionManager positionManager) {
        uint256 chainId = block.chainid;
        address payable _positionManager = payable(positionManagers[chainId]);

        // Ensure we have a configured address for this chain
        require(_positionManager != address(0), "No position manager address configured for this chain");
        positionManager = PositionManager(_positionManager);
    }
}
