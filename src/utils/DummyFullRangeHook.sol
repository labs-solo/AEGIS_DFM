// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @dev minimal full-range hook that is forever paired with a given oracle
contract DummyFullRangeHook {
    address public oracle;

    constructor(address _oracle) {
        oracle = _oracle;
    }

    function setOracle(address _oracle) external {
        require(oracle == address(0), "oracle already set");
        oracle = _oracle;
    }

    /// called by PoolManager after every swap / liquidity update
    function notifyOracle(bool capped) external {
        // NOTE: This is a placeholder and needs the actual TruncGeoOracleMulti interface and PoolId logic
        // TruncGeoOracleMulti(oracle).recordCapEvent(PoolId.wrap(bytes32(0)), capped);
        // For now, just use a basic check to avoid compilation errors if TruncGeoOracleMulti is not imported
        require(oracle != address(0), "Oracle address not set");
    }
}
