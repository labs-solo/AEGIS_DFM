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
        require(minCap      > 0,                         "PV:min=0");
        require(stepPpm     > 0 && stepPpm < PPM,        "stepPpm-range");
        require(budgetPpm   > 0 && budgetPpm < PPM,      "PV:budget");
        require(maxCap      >= minCap,                   "PV:max<min");
        require(decayWindow > 0,                         "PV:decay");
        require(updateInterval > 0,                      "PV:updateInt");
    }

    /// --------------------------------------------------------------------
    /// @notice Clamp `currentCap` one "step" toward the policy bounds.
    /// @dev    Used by `TruncGeoOracleMulti` to reduce repetitive math.
    /// @param  currentCap  The present maxTicksPerBlock.
    /// @param  minCap      Minimum cap from policy.
    /// @param  maxCap      Maximum cap from policy.
    /// @param  stepPpm     Step size in ppm.
    /// @param  increase    Direction: true → loosen cap, false → tighten.
    /// @return newCap      The adjusted cap (never outside [minCap,maxCap]).
    /// @return diff        Absolute delta between old & new cap.
    /// --------------------------------------------------------------------
    function clampCap(
        uint24 currentCap,
        uint24 minCap,
        uint24 maxCap,
        uint32 stepPpm,
        bool   increase
    ) internal pure returns (uint24 newCap, uint24 diff) {
        // step = ceil(currentCap * stepPpm / 1e6, min 1)
        uint24 step = uint24(uint256(currentCap) * stepPpm / PPM);
        if (step == 0) step = 1;

        if (increase) {
            newCap = currentCap + step > maxCap ? maxCap : currentCap + step;
        } else {
            newCap = currentCap > step + minCap ? currentCap - step : minCap;
        }

        diff = currentCap > newCap ? currentCap - newCap : newCap - currentCap;
    }
}