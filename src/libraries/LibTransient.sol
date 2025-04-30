// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title LibTransient
 * @notice Minimal wrapper for EIP-1153 transient storage operations
 */
library LibTransient {
    function setUint256(bytes32 key, uint256 value) internal {
        assembly {
            tstore(key, value)
        }
    }

    function getUint256(bytes32 key) internal view returns (uint256 value) {
        assembly {
            value := tload(key)
        }
    }
}
