// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title  TickMoveGuard
/// @notice Single source-of-truth for "was the tick move excessive?" logic
///
/// Truncates tick moves to a caller-supplied absolute cap.
library TickMoveGuard {
    /// @dev legacy absolute cap ≈ 1 % of the full Uniswap-V4 tick range.
    int24 internal constant HARD_ABS_CAP = 9_116; // ± 9 116 ticks

    /* ---------- helpers -------------------------------------------------- */
    function _abs(int256 x) private pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    /* ---------- public API ----------------------------------------------- */
    /// @notice Truncate to a caller-supplied absolute cap (no dynamic part)
    function truncate(int24 lastTick, int24 currentTick, uint24 cap)
        internal
        pure
        returns (bool capped, int24 newTick)
    {
        uint256 diff = _abs(int256(currentTick) - int256(lastTick));
        if (diff <= cap) return (false, currentTick);

        capped = true;
        int24 capInt = int24(int256(uint256(cap))); // safe 2-step cast
        newTick = currentTick > lastTick ? lastTick + capInt : lastTick - capInt;
    }

    /* ------------------------------------------------------------------ */
    /*  --- Back-compat wrappers (unchanged external signature) ---        */
    /* ------------------------------------------------------------------ */

    /// @notice kept for binary compatibility – ignores any dynamic scale.
    function checkHardCapOnly(int24 lastTick, int24 currentTick) internal pure returns (bool capped, int24 newTick) {
        return truncate(lastTick, currentTick, uint24(HARD_ABS_CAP));
    }

    /// @notice thin wrapper maintaining the old `(last,current,fee,scale)` interface.
    ///         The dynamic part is gone; `scale`/`fee` are ignored.
    function check(int24 lastTick, int24 currentTick, uint256, /* feePpm – ignored */ uint256 /* scale   – ignored */ )
        internal
        pure
        returns (bool capped, int24 newTick)
    {
        return truncate(lastTick, currentTick, uint24(HARD_ABS_CAP));
    }
}
