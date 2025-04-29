// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/**
 * @title PoolTokenIdUtils
 * @notice Utilities for converting between PoolId and TokenId
 */
library PoolTokenIdUtils {
    /**
     * @notice Convert PoolId to TokenId
     * @param poolId Pool ID
     * @return TokenId for ERC6909
     */
    function toTokenId(PoolId poolId) internal pure returns (uint256) {
        return uint256(PoolId.unwrap(poolId)) & 0x00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    }

    /**
     * @notice Convert TokenId to PoolId
     * @param tokenId TokenId from ERC6909
     * @return Pool ID
     */
    function toPoolId(uint256 tokenId) internal pure returns (PoolId) {
        return PoolId.wrap(bytes32(tokenId));
    }
}
