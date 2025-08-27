// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {IPoolPolicyManager} from "../interfaces/IPoolPolicyManager.sol";
import {IDynamicFeeManager} from "../interfaces/IDynamicFeeManager.sol";
import {TruncGeoOracleMulti} from "../TruncGeoOracleMulti.sol";

type DynamicFeeState is uint256;

using DynamicFeeStateLibrary for DynamicFeeState global;

/// @title DynamicFeeStateLibrary
/// @notice Library for packing/unpacking pool state into a single uint256 slot for gas optimization
/// @dev Optimized layout (73 bits used, 183 bits available for future expansion):
///      ┌──32──┬──40──┬─1─┬────183────┐
///      │baseFee│capStart│inCap│ unused │
///      └─────────────────────────────┘
///
///      Fields:
///      - baseFee (32 bits): Current base fee value in PPM
///      - capStart (40 bits): Timestamp when capping mechanism started
///      - inCap (1 bit): Boolean flag indicating if currently in capped state
library DynamicFeeStateLibrary {
    // Bit offsets
    uint256 private constant CAP_START_OFFSET = 32;
    uint256 private constant IN_CAP_OFFSET = 72; // 32 + 40

    // Bit masks
    uint256 private constant MASK_BASE_FEE = (uint256(1) << 32) - 1; // 32 bits
    uint256 private constant MASK_CAP_START = ((uint256(1) << 40) - 1) << CAP_START_OFFSET; // 40 bits
    uint256 private constant MASK_IN_CAP = uint256(1) << IN_CAP_OFFSET; // 1 bit

    /// @notice Creates an empty DynamicFeeState with all fields set to zero
    /// @return state New empty state
    function empty() internal pure returns (DynamicFeeState state) {
        return DynamicFeeState.wrap(uint256(0));
    }

    /// @notice Checks if a state is completely empty (all fields zero)
    /// @param state The state to check
    /// @return isEmpty True if all fields are zero
    function isEmpty(DynamicFeeState state) internal pure returns (bool) {
        return DynamicFeeState.unwrap(state) == 0;
    }

    // - - - Getter functions - - -

    /// @notice Gets the base fee value
    /// @param state The packed state
    /// @return fee The base fee value in PPM (32 bits)
    function baseFee(DynamicFeeState state) internal pure returns (uint32 fee) {
        return uint32(DynamicFeeState.unwrap(state) & MASK_BASE_FEE);
    }

    /// @notice Gets the timestamp when capping mechanism started
    /// @param state The packed state
    /// @return startTime The cap start timestamp (40 bits)
    function capStart(DynamicFeeState state) internal pure returns (uint40 startTime) {
        return uint40((DynamicFeeState.unwrap(state) & MASK_CAP_START) >> CAP_START_OFFSET);
    }

    /// @notice Gets the capped state flag
    /// @param state The packed state
    /// @return capped True if currently in capped state
    function inCap(DynamicFeeState state) internal pure returns (bool capped) {
        return (DynamicFeeState.unwrap(state) & MASK_IN_CAP) != 0;
    }

    // - - - Setter functions - - -

    /// @notice Sets the base fee value
    /// @param state The current state
    /// @param value The new base fee value in PPM
    /// @return newState Updated state with new base fee
    function setBaseFee(DynamicFeeState state, uint32 value) internal pure returns (DynamicFeeState newState) {
        return DynamicFeeState.wrap(_setBits(DynamicFeeState.unwrap(state), MASK_BASE_FEE, value, 0));
    }

    /// @notice Sets the timestamp when capping mechanism started
    /// @param state The current state
    /// @param value The new cap start timestamp
    /// @return newState Updated state with new cap start time
    function setCapStart(DynamicFeeState state, uint40 value) internal pure returns (DynamicFeeState newState) {
        return DynamicFeeState.wrap(_setBits(DynamicFeeState.unwrap(state), MASK_CAP_START, value, CAP_START_OFFSET));
    }

    /// @notice Sets the capped state flag
    /// @param state The current state
    /// @param value The new capped state flag
    /// @return newState Updated state with new capped flag
    function setInCap(DynamicFeeState state, bool value) internal pure returns (DynamicFeeState newState) {
        uint256 word = DynamicFeeState.unwrap(state);
        return DynamicFeeState.wrap(value ? word | MASK_IN_CAP : word & ~MASK_IN_CAP);
    }

    /// @notice Batch update for cap-related state changes
    /// @param state The current state
    /// @param inCapValue The new capped state flag
    /// @param capStartValue The new cap start timestamp (ignored if inCapValue is false)
    /// @return newState Updated state with new cap-related values
    function updateCapState(DynamicFeeState state, bool inCapValue, uint40 capStartValue)
        internal
        pure
        returns (DynamicFeeState newState)
    {
        uint256 word = DynamicFeeState.unwrap(state);

        // Update inCap flag
        word = inCapValue ? word | MASK_IN_CAP : word & ~MASK_IN_CAP;

        // Update capStart only if entering cap state
        if (inCapValue) {
            word = _setBits(word, MASK_CAP_START, capStartValue, CAP_START_OFFSET);
        }

        return DynamicFeeState.wrap(word);
    }

    // - - - Private helpers - - -

    /// @notice Internal helper function for setting bits in the packed word
    /// @param word The current packed word
    /// @param mask The bit mask for the field
    /// @param value The new value to set
    /// @param shift The bit shift offset
    /// @return newWord The updated packed word
    function _setBits(uint256 word, uint256 mask, uint256 value, uint256 shift)
        private
        pure
        returns (uint256 newWord)
    {
        return (word & ~mask) | (value << shift);
    }
}
