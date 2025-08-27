// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IExtsload} from "v4-core/src/interfaces/IExtsload.sol";

/* Mock PoolManager – implements **only** the getters the oracle touches.   */
contract MockPoolManager is IExtsload {
    /* minimal subset */
    function getSlot0(PoolId) external pure returns (uint160, int24, uint16, uint8) {
        return (0, 0, 0, 0);
    }

    function getLiquidity(PoolId) external pure returns (uint128) {
        return 1e18;
    }

    // Implement IExtsload interface
    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(0); // Return default values for all slots
    }

    function extsload(bytes32, uint256 nSlots) external pure returns (bytes32[] memory values) {
        values = new bytes32[](nSlots);
        // Return array of default values
        for (uint256 i = 0; i < nSlots; i++) {
            values[i] = bytes32(0);
        }
        return values;
    }

    function extsload(bytes32[] calldata slots) external pure returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        // Return array of default values
        for (uint256 i = 0; i < slots.length; i++) {
            values[i] = bytes32(0);
        }
        return values;
    }
}
