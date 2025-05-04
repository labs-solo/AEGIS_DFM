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

    /// @notice Dummy hook stub that fulfils the interface but performs no action.  
    /// @dev `capped` is intentionally ignored; removing its identifier + making the
    ///      function `pure` eliminates both warnings (5667 & 2018) without changing
    ///      behaviour or byte-code size.
    function notifyOracle(bool /* capped */) external pure {
        // no-op
    }
}
