// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title PodsLibrary
/// @notice Contains helper functions for Pod share calculations.
library PodsLibrary {
    function calculatePodShares(
        uint256 amount,
        uint256 totalShares,
        uint256 currentValue
    ) internal pure returns (uint256 shares) {
        if (totalShares == 0) {
            return amount;
        } else {
            return (amount * totalShares) / currentValue;
        }
    }
} 