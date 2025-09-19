// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {TruncGeoOracleMulti} from "src/TruncGeoOracleMulti.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title Dummy hook used only in unit-tests – now hardened with ownership
contract DummyFullRangeHook {
    /* --------------------------------------------------------------------- */
    /*  Ownership & one-time oracle binding                                  */
    /* --------------------------------------------------------------------- */
    address public immutable owner;
    address public oracle;

    constructor(address _oracle) {
        owner = msg.sender;
        if (_oracle != address(0)) {
            oracle = _oracle;
        }
    }

    /// @notice One-time setter used only in tests to wire the oracle.
    function setOracle(address _oracle) external {
        require(msg.sender == owner, "DummyHook: not-owner");
        require(oracle == address(0), "DummyHook: oracle-set");
        oracle = _oracle;
    }

    /// @notice Dummy hook stub that fulfils the interface but performs no action.
    /// @dev `capped` is intentionally ignored; removing its identifier + making the
    ///      function `pure` eliminates both warnings (5667 & 2018) without changing
    ///      behaviour or byte-code size.
    function notifyOracle(bool /* capped */ ) external pure {
        // no-op
    }

    /// @notice Test helper to call updateCapFrequency on the oracle
    function updateCapFrequency(bytes32 poolId, bool capOccurred) external {
        require(msg.sender == owner, "DummyHook: not-owner");
        require(oracle != address(0), "DummyHook: oracle-not-set");
        TruncGeoOracleMulti(oracle).updateCapFrequency(PoolId.wrap(poolId), capOccurred);
    }
}
