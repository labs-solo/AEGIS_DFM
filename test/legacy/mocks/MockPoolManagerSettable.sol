// SPDX-License-Identifier: UNLICENSED
// Note: Changed license to UNLICENSED as per the diff's header
pragma solidity ^0.8.25;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IExtsload} from "v4-core/src/interfaces/IExtsload.sol";
import {TruncGeoOracleMulti} from "src/TruncGeoOracleMulti.sol";

/**
 * @title MockPoolManagerSettable
 * @notice Test-only PoolManager stub for testing TruncGeoOracleMulti
 */
contract MockPoolManagerSettable is IExtsload {
    // Direct mapping for specific storage slots that the oracle reads
    mapping(bytes32 => bytes32) private _storage;

    // The two slots the oracle accesses in tests
    bytes32 constant SLOT0_KEY = 0xb300e9e7edeec6623b4f59dc4321ef9c72bf05581c7862acc08edf08bc51e004;
    bytes32 constant SLOT1_KEY = 0xb300e9e7edeec6623b4f59dc4321ef9c72bf05581c7862acc08edf08bc51e007;

    /**
     * @notice Set the tick value in the mock storage
     * @dev This directly sets the tick in the slot that the oracle reads from
     */
    function setTick(PoolId pid, int24 tick) external {
        // Pack the tick into bits 160-183 (Uniswap V4 Slot0 layout)
        uint256 packedWord = uint256(uint24(tick)) << 160;

        // Store at the exact slot the oracle queries
        _storage[SLOT0_KEY] = bytes32(packedWord);

        // Now also prep the second storage slot
        _storage[SLOT1_KEY] = bytes32(uint256(0));

        emit TickSet(pid, tick, SLOT0_KEY, bytes32(packedWord));
    }

    /**
     * @notice Intercept the specific keys the oracle reads from
     */
    function extsload(bytes32 key) external view returns (bytes32) {
        return _storage[key];
    }

    // Other required functions
    function extsload(bytes32, uint256 nSlots) external pure returns (bytes32[] memory values) {
        values = new bytes32[](nSlots);
        return values;
    }

    function extsload(bytes32[] calldata) external pure returns (bytes32[] memory values) {
        values = new bytes32[](0);
        return values;
    }

    function getLiquidity(PoolId) external pure returns (uint128) {
        return 1e18;
    }

    // Debugging events
    event TickSet(PoolId indexed pid, int24 tick, bytes32 slotKey, bytes32 valueWritten);
}
