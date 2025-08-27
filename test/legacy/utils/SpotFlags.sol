// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice bit-mask the mined hook address must satisfy.
///         Matches `Spot.getHookPermissions()` exactly:
///           ‣ afterInitialize
///           ‣ beforeSwap
///           ‣ afterSwap
///           ‣ beforeSwapReturnDelta
///           ‣ afterSwapReturnDelta
library SpotFlags {
    function required() internal pure returns (uint160) {
        return uint160(
            /* AFTER_INITIALIZE              */
            Hooks.AFTER_INITIALIZE_FLAG
            /* BEFORE_SWAP                   */
            | Hooks.BEFORE_SWAP_FLAG
            /* AFTER_SWAP                    */
            | Hooks.AFTER_SWAP_FLAG
            /* BEFORE_SWAP_RETURN_DELTA      */
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            /* AFTER_SWAP_RETURN_DELTA       */
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
    }
}
