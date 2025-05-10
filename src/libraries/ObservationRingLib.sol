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
    /// @param stateIndex Current global cursor **before** calling `write`
    /// @param localIdx    Local index fed *into* `write`
    /// @param newLocalIdx Local index returned *from* `write`
    /// @param cardinality Current ring cardinality
    /// @param MAX_CARDINALITY_ALLOWED Constant propagated from caller
    /// @param ringFull  `true` when `cardinality == MAX_CARDINALITY_ALLOWED`
    /// @return newIndex Updated global cursor pointing to the freshly written
    ///                  observation—whether that lives in the same page, the
    ///                  next page, or after a full wrap.
    /// -----------------------------------------------------------------------
    function copyAndAdvance(
        mapping(bytes32 => mapping(uint16 => TruncatedOracle.Observation[PAGE_SIZE])) storage pages,
        bytes32 id,
        uint16 stateIndex,
        uint16 localIdx,
        uint16 newLocalIdx,
        uint16 cardinality,
        uint16 MAX_CARDINALITY_ALLOWED,
        bool   ringFull
    ) internal returns (uint16 newIndex) {
        uint16 pageBase  = stateIndex - (stateIndex % PAGE_SIZE);
        uint16 pageNo    = pageBase / PAGE_SIZE;

        // Cross-boundary?  (localIdx was the last slot & write() wrapped to 0)
        if (localIdx == PAGE_SIZE - 1 && newLocalIdx == 0) {
            TruncatedOracle.Observation[PAGE_SIZE] storage currentPage = pages[id][pageNo];

            if (!ringFull) {
                // (a) Still growing – allocate / use next page, copy obs[0]
                TruncatedOracle.Observation storage written = currentPage[0];
                TruncatedOracle.Observation[PAGE_SIZE] storage nextPage = pages[id][pageNo + 1];
                nextPage[0] = written;
                newIndex = pageBase + PAGE_SIZE; // first slot of next page
            } else {
                // (b) Ring saturated – wrap to page-0 after copying obs[0]
                pages[id][0][0] = currentPage[0];
                newIndex = 0;
            }
        } else {
            // No boundary crossed – simple in-page advance
            newIndex = pageBase + newLocalIdx;
        }
    }
} 