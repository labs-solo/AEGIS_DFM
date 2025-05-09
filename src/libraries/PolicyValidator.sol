// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

/// @title PolicyValidator
/// @notice Re-usable runtime-validation for fee-cap policy structs
/// @dev   Pulled into its own library so production code, mocks and fuzz harness
///        all share one single source of truth (Rule 6 & 7: avoid duplicated
///        invariants and keep tests in lock-step with implementation).
library PolicyValidator {
    uint32 internal constant PPM = 1_000_000;

    /// @dev Thin value-object used only for mocks & off-chain tooling
    struct Params {
        uint24 minCap;
        uint24 maxCap;
        uint32 stepPpm;
        uint32 budgetPpm;
        uint32 decayWindow;
        uint32 updateInterval;
    }

    /// @notice Reverts when *any* invariant is violated.
    /// @dev    Kept `internal` so the revert reasons bubble up unchanged.
    function validate(
        uint24 minCap,
        uint24 maxCap,
        uint32 stepPpm,
        uint32 budgetPpm,
        uint32 decayWindow,
        uint32 updateInterval
    ) internal pure {
        require(stepPpm        != 0 && stepPpm   <= PPM, "stepPpm-range");
        require(budgetPpm      != 0 && budgetPpm <= PPM, "budgetPpm-range");
        require(minCap         != 0,                    "minCap=0");
        require(maxCap         >= minCap,               "cap-bounds");
        require(decayWindow    >  0,                    "decayWindow=0");
        require(updateInterval >  0,                    "updateInterval=0");
    }
}