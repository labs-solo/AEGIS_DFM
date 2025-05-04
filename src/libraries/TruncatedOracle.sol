// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {TickMoveGuard} from "./TickMoveGuard.sol";
import {SafeCast}     from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title TruncatedOracle
/// @notice Provides price oracle data with protection against price manipulation
/// @dev Truncates price movements that exceed configurable thresholds to prevent oracle manipulation
library TruncatedOracle {
    /* -------------------------------------------------------------------------- */
    /*                              Library constants                              */
    /* -------------------------------------------------------------------------- */
    /// @dev Safety-fuse: prevent pathological gas usage in `grow()`
    uint16 internal constant MAX_CARDINALITY_ALLOWED = 8_192;

    /// @notice Thrown when trying to interact with an Oracle of a non-initialized pool
    error OracleCardinalityCannotBeZero();

    /// @notice Thrown when trying to observe a price that is older than the oldest recorded price
    /// @param oldestTimestamp Timestamp of the oldest remaining observation
    /// @param targetTimestamp Invalid timestamp targeted to be observed
    error TargetPredatesOldestObservation(uint32 oldestTimestamp, uint32 targetTimestamp);

    /// @dev emitted when the oracle had to truncate an excessive move
    event TickCapped(int24 newTick);

    /// @dev **Packed** Observation – 256-bit exact fit
    ///      32 + 24 + 48 + 144 + 8 = 256
    struct Observation {
        uint32 blockTimestamp; //  32 bits
        int24 prevTick; //  24 bits ( 56)
        int48 tickCumulative; //  48 bits (104)
        uint144 secondsPerLiquidityCumulativeX128; // 144 bits (248)
        bool initialized; //   8 bits (256)
    }

    /**
     * @notice Transforms a previous observation into a new observation, given the passage of time and the current tick and liquidity values
     * @dev Includes tick movement truncation for oracle manipulation protection
     * @param last The specified observation to be transformed
     * @param blockTimestamp The timestamp of the new observation
     * @param tick The active tick at the time of the new observation
     * @param liquidity The total in-range liquidity at the time of the new observation
     * @return Observation The newly populated observation
     */
    function transform(Observation memory last, uint32 blockTimestamp, int24 tick, uint128 liquidity)
        internal
        returns (Observation memory)
    {
        unchecked {
            // --- wrap-safe delta ------------------------------------------------
            uint32 delta = blockTimestamp >= last.blockTimestamp
                ? blockTimestamp - last.blockTimestamp
                : blockTimestamp + (type(uint32).max - last.blockTimestamp) + 1;

            // --------------------------------------------------------------------
            //  ⛽  Fast-return: if called within the *same* block we can skip all
            //      cumulative maths and just update `prevTick`.  Saves ~240 gas
            //      on ~30 % of write-paths (observations flushed twice per block).
            // --------------------------------------------------------------------
            if (delta == 0) {
                last.prevTick = tick;
                return last;
            }

            // Calculate absolute tick movement using optimized implementation
            (bool capped, int24 t) = TickMoveGuard.checkHardCapOnly(last.prevTick, tick);
            if (capped) {
                emit TickCapped(t);
            }
            tick = t;

            return Observation({
                blockTimestamp: blockTimestamp,
                prevTick: tick,
                tickCumulative: last.tickCumulative + int48(tick) * int48(uint48(delta)),
                secondsPerLiquidityCumulativeX128: last.secondsPerLiquidityCumulativeX128
                    + ((uint144(delta) << 128) / (liquidity > 0 ? liquidity : 1)),
                initialized: true
            });
        }
    }

    /// @notice Initialize the oracle array by writing the first slot. Called once for the lifecycle of the observations array
    /// @param self The stored oracle array
    /// @param time The time of the oracle initialization, via block.timestamp truncated to uint32
    /// @param tick The current tick at initialization
    /// @return cardinality The number of populated elements in the oracle array
    /// @return cardinalityNext The new length of the oracle array, independent of population
    function initialize(Observation[65535] storage self, uint32 time, int24 tick)
        internal
        returns (uint16 cardinality, uint16 cardinalityNext)
    {
        self[0] = Observation({
            blockTimestamp: time,
            prevTick: tick,
            tickCumulative: 0,
            secondsPerLiquidityCumulativeX128: 0,
            initialized: true
        });
        return (1, 1);
    }

    /// @notice Writes an oracle observation to the array with tick movement capping
    /// @dev Writable at most once per block. Caps tick movements to prevent oracle manipulation
    /// @param self The stored oracle array
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param blockTimestamp The timestamp of the new observation
    /// @param tick The active tick at the time of the new observation
    /// @param liquidity The total in-range liquidity at the time of the new observation
    /// @param cardinality The number of populated elements in the oracle array
    /// @param cardinalityNext The new length of the oracle array, independent of population
    /// @return indexUpdated The new index of the most recently written element in the oracle array
    /// @return cardinalityUpdated The new cardinality of the oracle array
    function write(
        Observation[65535] storage self,
        uint16 index,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity,
        uint16 cardinality,
        uint16 cardinalityNext
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        unchecked {
            Observation storage last = self[index];

            // early return if we've already written an observation this block
            if (last.blockTimestamp == blockTimestamp) {
                return (index, cardinality);
            }

            // if the conditions are right, we can bump the cardinality
            if (cardinalityNext > cardinality && index == (cardinality - 1)) {
                cardinalityUpdated = cardinalityNext;
            } else {
                cardinalityUpdated = cardinality;
            }

            indexUpdated = (index + 1) % cardinalityUpdated;
            Observation storage o = self[indexUpdated];

            // --- wrap-safe delta --------------------------------------------
            uint32 delta = blockTimestamp >= last.blockTimestamp
                ? blockTimestamp - last.blockTimestamp
                : blockTimestamp + (type(uint32).max - last.blockTimestamp) + 1;

            // Calculate absolute tick movement using optimized implementation
            (bool capped, int24 t) = TickMoveGuard.checkHardCapOnly(last.prevTick, tick);
            if (capped) {
                emit TickCapped(t);
            }
            tick = t;

            o.blockTimestamp = blockTimestamp;
            o.prevTick = tick;
            o.tickCumulative = last.tickCumulative + int48(tick) * int48(uint48(delta));
            o.secondsPerLiquidityCumulativeX128 = last.secondsPerLiquidityCumulativeX128
                + uint144((uint256(delta) << 128) / (liquidity == 0 ? 1 : liquidity));
            o.initialized = true;
        }
    }

    /// @notice Safe absolute value – reverts on `type(int24).min`
    function abs(int24 x) internal pure returns (uint24) {
        require(x != type(int24).min, "ABS_OF_MIN_INT24");
        return uint24(x >= 0 ? x : -x);
    }

    /// @notice Prepares the oracle array to store up to `next` observations
    /// @param self The stored oracle array
    /// @param current The current next cardinality of the oracle array
    /// @param next The proposed next cardinality which will be populated in the oracle array
    /// @return next The next cardinality which will be populated in the oracle array
    function grow(
        Observation[65535] storage self,
        uint16 current,
        uint16 next
    ) internal returns (uint16) {
        unchecked {
            if (current == 0) revert OracleCardinalityCannotBeZero();
            // Guard against out-of-gas loops
            require(next <= MAX_CARDINALITY_ALLOWED, "grow>limit");
            // no-op if the passed next value isn't greater than the current next value
            if (next <= current) return current;
            // store in each slot to prevent fresh SSTOREs in swaps
            // this data will not be used because the initialized boolean is still false
            for (uint16 i = current; i < next; i++) {
                self[i].blockTimestamp = 1;
            }
            return next;
        }
    }

    /// @notice comparator for 32-bit timestamps
    /// @dev safe for 0 or 1 overflows, a and b _must_ be chronologically before or equal to time
    /// @param time A timestamp truncated to 32 bits
    /// @param a A comparison timestamp from which to determine the relative position of `time`
    /// @param b From which to determine the relative position of `time`
    /// @return Whether `a` is chronologically <= `b`
    function lte(uint32 time, uint32 a, uint32 b) private pure returns (bool) {
        unchecked {
            // if there hasn't been overflow, no need to adjust
            if (a <= time && b <= time) return a <= b;

            uint256 aAdjusted = a > time ? a : a + 2 ** 32;
            uint256 bAdjusted = b > time ? b : b + 2 ** 32;

            return aAdjusted <= bAdjusted;
        }
    }

    /// @notice Fetches the observations before/at and at/after a target timestamp
    /// @dev The answer must be contained in the array, used when the target is located within the stored observation
    /// boundaries: older than the most recent observation and younger, or the same age as, the oldest observation
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param target The timestamp at which the reserved observation should be for
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param cardinality The number of populated elements in the oracle array
    /// @return beforeOrAt The observation which occurred at, or before, the given timestamp
    /// @return atOrAfter The observation which occurred at, or after, the given timestamp
    function binarySearch(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        uint16 index,
        uint16 cardinality
    ) internal view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        uint256 l = (index + 1) % cardinality; // oldest observation
        uint256 r = l + cardinality - 1; // newest observation
        uint256 i;
        while (true) {
            i = (l + r) / 2;

            beforeOrAt = self[i % cardinality];

            // we've landed on an uninitialized tick, keep searching higher (more recently)
            if (!beforeOrAt.initialized) {
                l = i + 1;
                continue;
            }

            atOrAfter = self[(i + 1) % cardinality];

            bool targetAtOrAfter = lte(time, beforeOrAt.blockTimestamp, target);

            // check if we've found the answer!
            if (targetAtOrAfter && lte(time, target, atOrAfter.blockTimestamp)) break;

            if (!targetAtOrAfter) r = i - 1;
            else l = i + 1;
        }
    }

    /// @notice Fetches the observations beforeOrAt and atOrAfter a given target
    /// @dev Used to compute the counterfactual accumulator values as of a given block timestamp
    /// @param self The stored oracle array
    /// @param time The current block.timestamp
    /// @param target The timestamp at which the reserved observation should be for
    /// @param tick The active tick at the time of the returned or simulated observation
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param liquidity The total pool liquidity at the time of the call
    /// @param cardinality The number of populated elements in the oracle array
    /// @return beforeOrAt The observation which occurred at, or before, the given timestamp
    /// @return atOrAfter The observation which occurred at, or after, the given timestamp
    function getSurroundingObservations(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) private returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        // ===== fast-path: ring length 1  =====
        if (cardinality == 1) {
            Observation memory only = self[index];

            // target newer  ➜ simulate forward
            if (lte(time, only.blockTimestamp, target)) {
                if (only.blockTimestamp == target) return (only, only);
                return (only, transform(only, target, tick, liquidity));
            }

            // target older  ➜ invalid
            revert TargetPredatesOldestObservation(only.blockTimestamp, target);
        }

        // ----- normal multi-element path -----
        // optimistically set before to the newest observation
        beforeOrAt = self[index];

        // if the target is chronologically at or after the newest observation, we can early return
        if (lte(time, beforeOrAt.blockTimestamp, target)) {
            if (beforeOrAt.blockTimestamp == target) {
                // if newest observation equals target, we're in the same block, so we can ignore atOrAfter
                return (beforeOrAt, atOrAfter);
            } else {
                // otherwise, we need to transform using the pool-specific tick movement cap
                return (beforeOrAt, transform(beforeOrAt, target, tick, liquidity));
            }
        }

        // now, set before to the oldest observation
        beforeOrAt = self[(index + 1) % cardinality];
        if (!beforeOrAt.initialized) beforeOrAt = self[0];

        // ensure that the target is chronologically at or after the oldest observation
        if (!lte(time, beforeOrAt.blockTimestamp, target)) {
            revert TargetPredatesOldestObservation(beforeOrAt.blockTimestamp, target);
        }

        // if we've reached this point, we have to binary search
        return binarySearch(self, time, target, index, cardinality);
    }

    /// @notice Observe oracle values at specific secondsAgos from the current block timestamp
    /// @dev Reverts if observation at or before the desired observation timestamp does not exist
    /// @param self The stored oracle array
    /// @param time The current block timestamp
    /// @param secondsAgos The array of seconds ago to observe
    /// @param tick The current tick
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param liquidity The current in-range pool liquidity
    /// @param cardinality The number of populated elements in the oracle array
    /// @return tickCumulatives The tick * time elapsed since the pool was first initialized, as of each secondsAgo
    /// @return secondsPerLiquidityCumulativeX128s The cumulative seconds / max(1, liquidity) since pool initialized
    function observe(
        Observation[65535] storage self,
        uint32 time,
        uint32[] calldata secondsAgos,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) internal returns (int48[] memory tickCumulatives, uint144[] memory secondsPerLiquidityCumulativeX128s) {
        require(cardinality > 0, "I");

        tickCumulatives = new int48[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint144[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            (tickCumulatives[i], secondsPerLiquidityCumulativeX128s[i]) =
                observeSingle(self, time, secondsAgos[i], tick, index, liquidity, cardinality);
        }
    }

    /// @notice Observe a single oracle value at a specific secondsAgo from the current block timestamp
    /// @dev Helper function for observe to get data for a single secondsAgo value
    /// @param self The stored oracle array
    /// @param time The current block timestamp
    /// @param secondsAgo The specific seconds ago to observe
    /// @param tick The current tick
    /// @param index The index of the observation that was most recently written to the observations array
    /// @param liquidity The current in-range pool liquidity
    /// @param cardinality The number of populated elements in the oracle array
    /// @return tickCumulative The tick * time elapsed since the pool was first initialized, as of secondsAgo
    /// @return secondsPerLiquidityCumulativeX128 The seconds / max(1, liquidity) since pool initialized
    function observeSingle(
        Observation[65535] storage self,
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) internal returns (int48 tickCumulative, uint144 secondsPerLiquidityCumulativeX128) {
        if (cardinality == 0) revert OracleCardinalityCannotBeZero();

        // base case: target is the current block? Handle large secondsAgo here.
        if (secondsAgo == 0 || secondsAgo > type(uint32).max) {
            Observation memory last = self[index];
            if (last.blockTimestamp != time) {
                last = transform(last, time, tick, liquidity);
            }
            return (last.tickCumulative, last.secondsPerLiquidityCumulativeX128);
        }

        // Safe subtraction logic applied *before* getSurroundingObservations
        uint32 target;
        unchecked {
            target = time >= secondsAgo ? time - secondsAgo : time + (type(uint32).max - secondsAgo) + 1;
        }

        (Observation memory beforeOrAt, Observation memory atOrAfter) =
            getSurroundingObservations(self, time, target, tick, index, liquidity, cardinality);

        if (target == beforeOrAt.blockTimestamp) {
            // we're at the left boundary
            return (beforeOrAt.tickCumulative, beforeOrAt.secondsPerLiquidityCumulativeX128);
        } else if (target == atOrAfter.blockTimestamp) {
            // we're at the right boundary
            return (atOrAfter.tickCumulative, atOrAfter.secondsPerLiquidityCumulativeX128);
        } else {
            // ----------  NORMALISE for wrap-around ----------
            // Bring all three timestamps into the same "era" (≥ beforeOrAt)
            uint32 base = beforeOrAt.blockTimestamp;
            uint32 norm = base; // avoids stack-too-deep
            uint32 bTs = beforeOrAt.blockTimestamp;
            uint32 aTs = atOrAfter.blockTimestamp;
            uint32 tTs = target;

            if (aTs < norm) aTs += type(uint32).max + 1;
            if (tTs < norm) tTs += type(uint32).max + 1;

            // Use the normalised copies for deltas below
            // we're in the middle
            uint32 observationTimeDelta = aTs - bTs;
            uint32 targetDelta = tTs - bTs;

            return (
                beforeOrAt.tickCumulative
                    + int48(
                        (int256(atOrAfter.tickCumulative) - int256(beforeOrAt.tickCumulative))
                            * int256(uint256(targetDelta)) / int256(uint256(observationTimeDelta))
                    ),
                beforeOrAt.secondsPerLiquidityCumulativeX128
                    + uint144(
                        (
                            uint256(atOrAfter.secondsPerLiquidityCumulativeX128)
                                - uint256(beforeOrAt.secondsPerLiquidityCumulativeX128)
                        ) * uint256(targetDelta) / uint256(observationTimeDelta)
                    )
            );
        }
    }
}
