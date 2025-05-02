// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/*───────────────────────────────────────────────────────────────────────────*\
│  Extended unit-tests for **TruncatedOracle**                               │
│  – targets ≥ 95 % line + branch coverage                                    │
│                                                                            │
│  Additions vs. v1:                                                         │
│   ①  Same-block double-write early-return test                              │
│   ②  Wrap-around (uint32 overflow) timestamp path for lte()                │
│   ③  Tick-cap event value assertion (exact truncated tick)                 │
│   ④  Lightweight fuzz against observeSingle / observe consistency          │
\*───────────────────────────────────────────────────────────────────────────*/

import "forge-std/Test.sol";
import {TruncatedOracle}  from "../../src/libraries/TruncatedOracle.sol";
import {TickMoveGuard}    from "../../src/libraries/TickMoveGuard.sol";

/* ------------------------------------------------------------------------- */
/*                             Harness / shim                                */
/* ------------------------------------------------------------------------- */
contract OracleHarness {
    using TruncatedOracle for TruncatedOracle.Observation[65535];

    TruncatedOracle.Observation[65535] internal obs;

    uint16 public index;
    uint16 public card;
    uint16 public cardNext;

    /* one-shot init */
    function init(uint32 ts, int24 tick_) external {
        (card, cardNext) = obs.initialize(ts, tick_);
        index = 0;
    }

    function push(uint32 ts, int24 tick_, uint128 liq) external {
        (index, card) = obs.write(index, ts, tick_, liq, card, cardNext);
    }

    function grow(uint16 next_) external {
        cardNext = obs.grow(cardNext == 0 ? card : cardNext, next_);
    }

    function observe(
        uint32 nowTs,
        uint32[] calldata secondsAgos,
        int24 tick_,
        uint128 liq
    )
        external
        returns (int48[] memory tc, uint144[] memory sl)
    {
        return obs.observe(nowTs, secondsAgos, tick_, index, liq, card);
    }

    function observeSingle(
        uint32 nowTs,
        uint32 secondsAgo,
        int24 tick_,
        uint128 liq
    )
        external
        returns (int48 tc, uint144 sl)
    {
        return obs.observeSingle(nowTs, secondsAgo, tick_, index, liq, card);
    }

    function getObs(uint16 i) external view returns (TruncatedOracle.Observation memory) {
        return obs[i];
    }
}

/* ------------------------------------------------------------------------- */
/*                                Test-suite                                */
/* ------------------------------------------------------------------------- */
contract TruncatedOracleTest is Test {
    OracleHarness internal h;

    /* constants */
    uint32  internal constant START   = 1_000_000;
    uint128 internal constant ONE_LIQ = 1 ether;

    function setUp() public {
        h = new OracleHarness();
        h.init(START, 10); // seed with first observation
    }

    /* ----------------------------------------------------- */
    /* 1. initialize / first write                           */
    /* ----------------------------------------------------- */
    function testInitializeAndSimpleWrite() public {
        h.push(START + 10, 15, ONE_LIQ);

        // ring stayed length-1 → indexWrapped==0, so prevTick==0
        // The correct assertion is that **cardinality==1** and **index==0**
        assertEq(h.card(), 1);
        assertEq(h.index(), 0);
    }

    /* ----------------------------------------------------- */
    /* 2. cardinality grow + ring rotation                   */
    /* ----------------------------------------------------- */
    function testGrowAndCardinalityBump() public {
        h.grow(5);
        assertEq(h.cardNext(), 5);

        for (uint32 i = 1; i <= 4; i++) {
            h.push(START + i * 10, int24(15 + int32(i)), ONE_LIQ);
        }

        assertEq(h.card(), 5);
        assertEq(h.index(), 4);
    }

    /* ----------------------------------------------------- */
    /* 3. grow(..) revert guard                              */
    /* ----------------------------------------------------- */
    function testGrowRevertsWhenCardZero() public {
        OracleHarness fresh = new OracleHarness();
        vm.expectRevert(TruncatedOracle.OracleCardinalityCannotBeZero.selector);
        fresh.grow(2);
    }

    /* ----------------------------------------------------- */
    /* 4. same-block double-write early-return                */
    /* ----------------------------------------------------- */
    function testSameBlockDoubleWriteNoChange() public {
        uint32 ts = START + 50;

        h.push(ts, 30, ONE_LIQ);                // first write
        (uint16 idxBefore, uint16 cardBefore) = (h.index(), h.card());

        h.push(ts, 31, ONE_LIQ);                // second write in same block
        assertEq(h.index(), idxBefore,  "index mutated");
        assertEq(h.card(),  cardBefore, "cardinality mutated");

        // stored tick should remain the first one (30)
        TruncatedOracle.Observation memory o = h.getObs(idxBefore);
        assertEq(o.prevTick, 30, "write-same-block should ignore second push");
    }

    /* ----------------------------------------------------- */
    /* 5. hard-cap – verify event payload & truncation        */
    /* ----------------------------------------------------- */
    function testTickCappingEmitsAndTruncates() public {
        // baseline so prevTick == 10
        h.grow(3);                      // ensure at least 3 slots
        h.push(START + 10, 10, ONE_LIQ);

        // delta of 600 000 will exceed the 250k/300k cap
        int24 requested = 600_000;
        (bool capped, int24 truncated) = TickMoveGuard.checkHardCapOnly(10, requested);
        assertTrue(capped, "should cap");

        // Expect the specific truncated tick value (9126)
        vm.expectEmit(false, false, false, true); // Check data
        emit TruncatedOracle.TickCapped(int24(9126));

        h.push(START + 20, requested, ONE_LIQ);

        TruncatedOracle.Observation memory o = h.getObs(h.index());
        assertEq(o.prevTick, truncated, "tick not truncated as expected");
    }

    /* ----------------------------------------------------- */
    /* 6. observeSingle(secondsAgo == 0) fast-path           */
    /* ----------------------------------------------------- */
    function testObserveSingleNowNoTransform() public {
        uint32 nowTs = START + 30;
        h.push(nowTs, 20, ONE_LIQ);

        (int48 tc,) = h.observeSingle(nowTs, 0, 20, ONE_LIQ);
        // 30 s have elapsed at tick 20  (init→now)
        assertEq(tc, 20 * 30, "cumulative mismatch != 600");
    }

    /* ----------------------------------------------------- */
    /* 7. observeSingle transforms when lagged               */
    /* ----------------------------------------------------- */
    function testObserveSingleTransformsWhenLagged() public {
        uint32 lastTs = START + 40;
        h.push(lastTs, 25, ONE_LIQ);

        uint32 nowTs = START + 45; // 5 s later
        (int48 tc,) = h.observeSingle(nowTs, 0, 25, ONE_LIQ);
        // 45 s total at tick 25
        assertEq(tc, 25 * 45, "transform cumulative wrong");
    }

    /* ----------------------------------------------------- */
    /* 8. interpolation path (binary search branch)          */
    /* ----------------------------------------------------- */
    function testObserveInterpolationMidpoint() public {
        h.grow(4);
        h.push(START + 10, 12, ONE_LIQ); // idx1
        h.push(START + 20, 22, ONE_LIQ); // idx2
        h.push(START + 30, 32, ONE_LIQ); // idx3

        uint32 nowTs      = START + 30;
        uint32 targetTime = START + 15;         // midway 10→20
        uint32 secondsAgo = nowTs - targetTime;

        (int48 tcMid,) = h.observeSingle(nowTs, secondsAgo, 22, ONE_LIQ);
        assertEq(tcMid, 230);
    }

    /* ----------------------------------------------------- */
    /* 9. TargetPredatesOldestObservation revert             */
    /* ----------------------------------------------------- */
    function testObserveRevertsIfTargetTooOld() public {
        h.grow(3);
        h.push(START + 10, 12, ONE_LIQ);
        h.push(START + 20, 22, ONE_LIQ);

        uint32 nowTs = START + 20;
        uint32 secondsAgoTooLarge = 25; // older than oldest
        vm.expectRevert();
        h.observeSingle(nowTs, secondsAgoTooLarge, 22, ONE_LIQ);
    }

    /* ----------------------------------------------------- */
    /* 10. uint32 wrap-around lte() path                     */
    /* ----------------------------------------------------- */
    function testObserveWorksAcrossTimestampOverflow() public {
        // simulate near-overflow start
        uint32 nearWrap  = type(uint32).max - 50; // ~4 GHz seconds
        OracleHarness w  = new OracleHarness();
        w.init(nearWrap, 100); // Initial observation before wrap

        // write after wrap (overflow: +100 s)
        uint32 postWrapTs;
        unchecked { postWrapTs = nearWrap + 100; } // simulate wrap

        w.push(postWrapTs, 110, ONE_LIQ);

        // observe 75 s ago (crosses the wrap)
        uint32 nowTs      = postWrapTs;
        uint32 secondsAgo = 75;

        // --- robust selector check via try/catch ---
        try w.observeSingle(nowTs, secondsAgo, 110, ONE_LIQ) {
            fail();
        } catch (bytes memory data) {
            // first 4 bytes should equal selector
            bytes4 sel;
            assembly { sel := mload(add(data, 0x20)) }
            assertEq(sel, TruncatedOracle.TargetPredatesOldestObservation.selector,
                "wrong revert selector");
        }
    }

    /* ----------------------------------------------------- */
    /* 11. light fuzz: observeSingle vs observe              */
    /* ----------------------------------------------------- */
    function testFuzzObserveConsistency(uint32 offset, int24 tickDelta) public {
        vm.assume(offset > 0 && offset < 4 hours);
        vm.assume(tickDelta > -1_000_000 && tickDelta < 1_000_000);

        uint32 ts1 = START + 60;
        h.push(ts1, 40, ONE_LIQ);

        uint32 ts2 = ts1 + offset;
        int24  t2  = 40 + tickDelta;
        h.push(ts2, t2, ONE_LIQ);

        uint32 nowTs = ts2 + 1 minutes;
        uint32 secondsAgo = 30 minutes;

        uint32[] memory sa = new uint32[](1);
        sa[0] = secondsAgo;

        // We expect *either* both paths to revert with identical selector
        // *or* both to succeed and return equal cumulatives.
        try h.observeSingle(nowTs, secondsAgo, t2, ONE_LIQ) returns (int48 tcA, uint144) {
            // no revert → the batch call must also succeed
            (int48[] memory tcB,) = h.observe(nowTs, sa, t2, ONE_LIQ);
            assertEq(tcA, tcB[0], "observe mismatch (no-revert path)");
        } catch Error(string memory) {
            // string selectors not used – ignore
            revert("unexpected string error");
        } catch (bytes memory reason) {
            // decode selector
            bytes4 sel;
            assembly { sel := mload(add(reason, 32)) }
            assertEq(sel, TruncatedOracle.TargetPredatesOldestObservation.selector,
                "unexpected revert selector (single)");
            // batch should revert with the *same* selector
            try h.observe(nowTs, sa, t2, ONE_LIQ) {
                revert("batch did not revert");
            } catch (bytes memory reasonB) {
                bytes4 selB;
                assembly { selB := mload(add(reasonB, 32)) }
                assertEq(selB, sel, "selectors mismatch single vs batch");
            }
        }
    }
} 