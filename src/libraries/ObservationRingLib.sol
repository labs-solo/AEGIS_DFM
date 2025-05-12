// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {TruncatedOracle} from "./TruncatedOracle.sol";

/// @notice Helper that owns the "copy-into-next-/wrap-page" routine used by
///         `TruncGeoOracleMulti._recordObservation`.  Isolating the logic here
///         trims runtime lines from the main contract while leaving all
///         semantics unchanged.
library ObservationRingLib {
    uint16 internal constant PAGE_SIZE = 512;

    /// -----------------------------------------------------------------------
    /// @param pages   2-level mapping inherited from the parent oracle
    /// @param id      Pool identifier (bytes32-wrapped)
    /// @param globalIdx Current global cursor **before** calling `write`
    /// @param localIdx    Local index fed *into* `write`
    /// @param newLocalIdx Local index returned *from* `write`
    /// @param ringFull  `true` when the ring is already saturated (cardinality == MAX_CARDINALITY_ALLOWED)`
    /// @return newGlobalIdx Updated global cursor pointing to the freshly written
    ///                  observation—whether that lives in the same page, the
    ///                  next page, or after a full wrap.
    /// @return newLocalIdxOut Local index returned from the function
    /// @return copiedBoot    `true` if a bootstrapping copy was performed
    /// -----------------------------------------------------------------------
    function copyAndAdvance(
        mapping(bytes32 => mapping(uint16 => TruncatedOracle.Observation[PAGE_SIZE])) storage pages,
        bytes32 id,
        uint16 globalIdx,
        uint16 localIdx,
        uint16 newLocalIdx,
        bool   ringFull
    ) internal returns (uint16 newGlobalIdx, uint16 newLocalIdxOut, bool copiedBoot) {
        copiedBoot      = false;
        // Default path (staying on the same 512-slot leaf): simply increment
        // the *global* cursor by one. This avoids subtle off-by-one issues and
        // guarantees that `state.index` always tracks the newest write.
        unchecked {
            newGlobalIdx = globalIdx + 1;
        }
        newLocalIdxOut  = newLocalIdx; // default: stayed within same leaf

        // Detect leaf boundary crossing: wrapped from slot 511 → slot 0
        bool crossedLeaf = (localIdx == PAGE_SIZE - 1 && newLocalIdx == 0);

        if (crossedLeaf) {
            // Determine the target leaf index (wrap to 0 when ring already full)
            uint16 newLeaf = ringFull ? 0 : (globalIdx >> 9) + 1;

            // Bootstrap: duplicate the last observation of the previous leaf into
            // slot-0 of the new leaf so time-weighted math remains continuous.
            pages[id][newLeaf][0] = pages[id][globalIdx >> 9][PAGE_SIZE - 1];

            copiedBoot     = true;
            newGlobalIdx   = uint16(newLeaf << 9); // cursor at slot-0 of new leaf
            newLocalIdxOut = 0;
        }

        return (newGlobalIdx, newLocalIdxOut, copiedBoot);
    }
} 