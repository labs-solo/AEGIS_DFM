// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/* Mock PoolManager – implements **only** the getters the oracle touches.   */
contract MockPoolManager {
    /* minimal subset */
    function getSlot0(PoolId) external pure returns (uint160, int24, uint16, uint8) {
        return (0, 0, 0, 0);
    }
    function getLiquidity(PoolId) external pure returns (uint128) {
        return 1e18;
    }
} 