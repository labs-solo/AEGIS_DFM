// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

/*───────────────────────────────────────────────────────────────────────────*\
│  TruncGeoOracleMulti – unit-level test-suite                               │
│  – covers the "cheap" logic that does **not** need a full pool stack.      │
│  – targets init, ring behaviour, auto-tune & governance guards             │
\*───────────────────────────────────────────────────────────────────────────*/

import "forge-std/Test.sol";
import {TruncGeoOracleMulti} from "src/TruncGeoOracleMulti.sol";
import {TruncatedOracle} from "src/libraries/TruncatedOracle.sol";
import {DummyFullRangeHook} from "test/legacy/utils/DummyFullRangeHook.sol";
import {TickMoveGuard} from "src/libraries/TickMoveGuard.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPoolPolicyManager} from "src/interfaces/IPoolPolicyManager.sol";
import {Errors} from "src/errors/Errors.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import "forge-std/console.sol";

/* ───────────────────────────── Local Stubs ─────────────────────────────── */

/*  VERY-LIGHT policy stub – **does not** inherit the full interface       */
/*  (only selectors the oracle touches are implemented).                   */
/* ----------------------------------------------------------------------- */
import {MockPolicyManager} from "test/legacy/mocks/MockPolicyManager.sol";
import {MockPoolManagerSettable as MockPoolManager} from "../mocks/MockPoolManagerSettable.sol";

/* Mock PoolManager – implements **only** the getters the oracle touches.   */
// Definition removed, now imported

/* ───────────────────────── Constants ───────────────────────── */

// Constant HOOK_ADDR removed as per previous diff

/* ───────────────────────────── Test-suite ─────────────────────────────── */
contract TruncGeoOracleMultiTest is Test {
    using TickMoveGuard for int24;
    using PoolIdLibrary for PoolKey;

    /* ------------------------------------------------------- */
    /*  state & constants                                      */
    /* ------------------------------------------------------- */
    TruncGeoOracleMulti internal oracle;
    MockPolicyManager internal policy;
    MockPoolManager internal poolManager;
    DummyFullRangeHook internal hook;

    PoolKey internal poolKey;
    PoolId internal pid;
    uint24 internal constant DEF_FEE = 5_000; // 0.5 %
    uint32 internal constant START_TS = 1_000_000; // base timestamp

    // Test addresses
    address internal alice = makeAddr("alice");

    /* ------------------------------------------------------- */
    /*  setup                                                  */
    /* ------------------------------------------------------- */
    function setUp() public {
        console.log("Setting up test...");
        policy = new MockPolicyManager();
        poolManager = new MockPoolManager();

        console.log("Deploying hook...");
        // ── deploy hook FIRST ------------------------------------------------------
        hook = new DummyFullRangeHook(address(0));
        console.log("Hook deployed at:", address(hook));

        // Create mock tokens for the PoolKey *after* hook exists so we can embed it
        address token0 = address(0xA11CE);
        address token1 = address(0xB0B);

        console.log("Creating PoolKey...");
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: DEF_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(hook)) // ← must equal fullRangeHook
        });

        pid = poolKey.toId();
        console.log("PoolKey created with hooks address:", address(poolKey.hooks));

        /* ------------------------------------------------------------------ *
         *  Configure mock policy with non-zero params so oracle invariants   *
         *  hold during enableOracleForPool().                                *
         * ------------------------------------------------------------------ */
        MockPolicyManager.Params memory p;
        p.minBaseFee = 100; // 1 tick
        p.maxBaseFee = 10_000; // 100 ticks
        p.stepPpm = 50_000; // 5 %
        p.freqScaling = 1e18; // no scaling
        p.budgetPpm = 100_000; // 10 %
        p.decayWindow = 86_400; // 1 day
        p.updateInterval = 600; // 10 min
        p.defaultMaxTicks = 50;
        policy.setParams(pid, p);

        console.log("Deploying oracle...");
        // ── deploy oracle pointing to *this* hook ----------------------------------
        oracle = new TruncGeoOracleMulti(
            IPoolManager(address(poolManager)),
            IPoolPolicyManager(address(policy)),
            address(hook),
            address(this) // Test contract as owner
        );
        console.log("Oracle deployed at:", address(oracle));

        console.log("Setting oracle in hook...");
        // ── set oracle address in hook (one-time operation) -----------------------
        hook.setOracle(address(oracle));
        console.log("Oracle address set in hook");

        console.log("Enabling oracle for pool...");
        // ── enable oracle for the pool (must be called by *that* hook) --------------
        vm.prank(address(hook)); // msg.sender == fullRangeHook
        oracle.enableOracleForPool(poolKey);
        console.log("Oracle enabled for pool");
    }

    /* gas logger helper (does not fail CI) */
    function _logGas(string memory tag, uint256 beforeGas) internal {
        emit log_named_uint(tag, beforeGas - gasleft());
    }

    /* ------------------------------------------------------------ *
     * 1. Initialization paths                                      *
     * ------------------------------------------------------------ */
    function testEnablePoolSetsDefaults() public view {
        bytes32 poolIdBytes = PoolId.unwrap(pid);
        assertEq(
            oracle.maxTicksPerBlock(poolIdBytes),
            policy.getDefaultMaxTicksPerBlock(pid) // Should be 50 ticks
        );

        (, uint16 card,) = oracle.states(poolIdBytes);
        assertEq(card, 1, "cardinality should equal 1 after init");
    }

    /* ------------------------------------------------------------ *
     * 2. Governance mutators                                       *
     * ------------------------------------------------------------ */
    function testOnlyHookCanPushObservation() public {
        int24 tickToSetInMock = 100;
        int24 expectedTickAfterCap = 50; // Oracle's internal cap is 50
        bool capped = false;

        // Seed the mock with the tick we expect the oracle to record *before* capping
        poolManager.setTick(pid, tickToSetInMock);

        // Revert expected when called directly (not by hook)
        vm.expectRevert(TruncGeoOracleMulti.OnlyHook.selector);
        oracle.pushObservationAndCheckCap(pid, int24(0)); // revert path

        // --- Advance time before successful call ---
        vm.warp(block.timestamp + 1);

        // Should succeed when called via the hook
        vm.startPrank(address(hook)); // only the authorised hook may push
        oracle.pushObservationAndCheckCap(pid, int24(0)); // authorised path
        vm.stopPrank();

        // Verify the observation was written (it should be the CAPPED value)
        (int24 latestTick,) = oracle.getLatestObservation(pid);
        assertEq(latestTick, expectedTickAfterCap, "Observation tick mismatch after hook push");
    }

    /* ------------------------------------------------------------ *
     * 3. Auto-tune : too many CAPS → loosen cap                    *
     * ------------------------------------------------------------ */
    function _writeTwice() internal {
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, int24(0));
        vm.roll(block.number + 1); // avoid rate-limit guard
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, int24(0));
    }

    function testAutoTuneIncreasesCap() public {
        _writeTwice();
    }

    /* ------------------------------------------------------------ *
     * 4. Rate-limit & step clamp – candidate inside band → skip    *
     * ------------------------------------------------------------ */
    function testAutoTuneSkippedInsideBand() public {
        bytes32 idBytes = PoolId.unwrap(pid);
        uint24 startCap = oracle.maxTicksPerBlock(idBytes);

        // 1️⃣  stay just under the cap so no CAP event is registered
        poolManager.setTick(pid, int24(startCap) - 1);
        vm.warp(block.timestamp + 1);
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, int24(0));

        // 2️⃣  wait less than the update-interval and push again
        vm.warp(block.timestamp + policy.getBaseFeeUpdateIntervalSeconds(pid) / 2);
        poolManager.setTick(pid, int24(startCap) - 2);
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, int24(0));

        uint24 endCap = oracle.maxTicksPerBlock(idBytes);
        assertEq(endCap, startCap, "Cap should remain unchanged when frequency is inside budget");
    }

    /* ------------------------------------------------------------ *
     * 5. getLatestObservation fast-path                            *
     * ------------------------------------------------------------ */
    function testGetLatestObservation() public view {
        (int24 tick, uint32 ts) = oracle.getLatestObservation(pid);
        assertEq(tick, 0);
        assertEq(ts, uint32(block.timestamp));
    }

    /* ------------------------------------------------------------ *
     * 6. observe* revert for non-enabled pool                       *
     * ------------------------------------------------------------ */
    function testObserveRevertsForUnknownPool() public {
        // PoolKey for a non-existent pool
        PoolKey memory unknownKey = PoolKey({
            currency0: Currency.wrap(address(0xDEAD)),
            currency1: Currency.wrap(address(0xBEEF)),
            fee: DEF_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        PoolId unknownId = unknownKey.toId();

        vm.expectRevert(); // Expect revert because pool is not enabled
        oracle.getLatestObservation(unknownId);
    }

    /* ------------------------------------------------------------ *
     * 7. Gas baseline demo                                         *
     * ------------------------------------------------------------ */
    /// @dev Fuzz: every observation must be clamped to ±cap
    function testFuzz_PushObservationWithinCap(int24 seedTick) public {
        bytes32 idBytes = PoolId.unwrap(pid);
        uint24 cap = oracle.maxTicksPerBlock(idBytes);

        int24 boundedTick = int24(bound(int256(seedTick), -int256(uint256(cap) * 2), int256(uint256(cap) * 2)));
        poolManager.setTick(pid, boundedTick);

        vm.warp(block.timestamp + 1);
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, int24(0));

        (int24 latestTick,) = oracle.getLatestObservation(pid);
        int24 absVal = latestTick >= 0 ? latestTick : -latestTick;
        assertLe(uint256(uint24(absVal)), uint256(cap), "Observation exceeds cap");
    }

    function testPushObservationAndCheckCap_EnforcesMaxTicks() public {
        // 1. Enable Oracle for the pool (already done in setUp)
        bytes32 pidBytes = PoolId.unwrap(pid); // Define pidBytes

        // 2. Check initial cap (should be > 0)
        uint24 maxTicks = oracle.maxTicksPerBlock(pidBytes);
        assertTrue(maxTicks > 0, "Max ticks should be initialized");

        // 3. Set tick far above the cap
        int24 overLimitTick = int24(maxTicks) + 100; // Go well over the limit
        poolManager.setTick(pid, overLimitTick);

        // --- Test capping logic ---
        // Advance time to ensure observation is written
        vm.warp(block.timestamp + 1);

        // DEBUG: Log prevTick before the call
        (int24 tickBefore,) = oracle.getLatestObservation(pid);
        console.log("prevTick before capping call:", tickBefore);

        // Expect the call via hook to succeed, but the tick to be capped
        vm.startPrank(address(hook)); // Use the correct 'hook' variable
        bool tickWasCapped = oracle.pushObservationAndCheckCap(pid, int24(0));
        vm.stopPrank();

        assertTrue(tickWasCapped, "Tick SHOULD have been capped");

        // Verify the observation was written with the CAPPED value
        int24 expectedCappedTick = int24(maxTicks); // Tick should be capped at maxTicks
        (int24 latestTick,) = oracle.getLatestObservation(pid); // Use getter for latest info

        // Get the current state index to access the correct observation
        (, uint16 currentIndex,) = oracle.states(pidBytes);

        // Verify using getLatestObservation instead, which should correctly return the capped value
        (int24 observedTick,) = oracle.getLatestObservation(pid);
        assertEq(observedTick, expectedCappedTick, "Latest observation tick should match capped value");

        // --- Test logic when tick is UNDER cap ---
        // Set tick below the cap
        int24 underLimitTick = int24(maxTicks) - 10;
        poolManager.setTick(pid, underLimitTick);

        // Advance time again
        vm.warp(block.timestamp + 1);

        // Expect the call via hook to succeed, tick should NOT be capped
        vm.startPrank(address(hook)); // Use the correct 'hook' variable
        tickWasCapped = oracle.pushObservationAndCheckCap(pid, int24(0));
        vm.stopPrank();

        assertFalse(tickWasCapped, "Tick should NOT have been capped (under limit)");

        // Verify the observation was written with the UNCAPPED value
        (latestTick,) = oracle.getLatestObservation(pid); // Use getter

        // Get the current state index again
        (, currentIndex,) = oracle.states(pidBytes);

        // Use getLatestObservation instead, which returns the correct value:
        (int24 observedUncappedTick,) = oracle.getLatestObservation(pid);
        assertEq(observedUncappedTick, underLimitTick, "Latest observation tick should match uncapped value");
    }

    /* ------------------------------------------------------------ *
     * 8. Explicit auto-tune path                                   *
     * ------------------------------------------------------------ */
    function testAutoTuneLoosensCapAfterFrequentHits() public {
        bytes32 idBytes = PoolId.unwrap(pid);
        uint24 startCap = oracle.maxTicksPerBlock(idBytes);

        // Hit the cap 5 times quickly (simulate heavy volatility)
        for (uint8 i; i < 5; ++i) {
            poolManager.setTick(pid, int24(startCap) * 2); // trigger cap
            vm.warp(block.timestamp + 10); // advance few seconds
            vm.prank(address(hook));
            oracle.pushObservationAndCheckCap(pid, int24(0));
            vm.roll(block.number + 1);
        }

        // Advance time past update interval
        vm.warp(block.timestamp + policy.getBaseFeeUpdateIntervalSeconds(pid) + 1);

        // Push once more to force auto-tune evaluation (no cap this time)
        poolManager.setTick(pid, int24(startCap) / 2);
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, int24(0));

        uint24 newCap = oracle.maxTicksPerBlock(idBytes);
        assertGt(newCap, startCap, "Cap should have loosened after frequent caps");
    }

    /* ------------------------------------------------------------ *
     * 9.  📦  **NEW TESTS** – multi-page ring, policy refresh …    *
     * ------------------------------------------------------------ */

    /// @notice Push >512 observations to prove the ring really pages
    function testPagedRingStoresAcrossPages() public {
        uint16 pushes = 530; // crosses page boundary (PAGE_SIZE = 512)
        uint24 cap = oracle.maxTicksPerBlock(PoolId.unwrap(pid));

        for (uint16 i = 1; i <= pushes; ++i) {
            // safe ladder-cast: uint24 -> uint256 -> int256 -> int24
            poolManager.setTick(pid, int24(int256(uint256(cap) - 1))); // stay under cap
            vm.warp(block.timestamp + 1); // guarantee new ts
            vm.prank(address(hook));
            oracle.pushObservationAndCheckCap(pid, int24(0));
        }

        //  Bootstrap slot (index 0) + our `pushes` writes
        (, uint16 cardinality,) = oracle.states(PoolId.unwrap(pid));
        assertEq(cardinality, pushes + 1, "cardinality wrong after multi-page growth (must include bootstrap slot)");

        // ── latest observation must be the last one we wrote ──
        (int24 tick,) = oracle.getLatestObservation(pid);
        assertEq(tick, int24(int256(uint256(cap) - 1)), "latest tick mismatch after paging");
    }

    /// @notice Owner can refresh the cached policy; cap is clamped into new bounds
    function testPolicyRefreshAdjustsCap() public {
        bytes32 idBytes = PoolId.unwrap(pid);
        uint24 oldCap = oracle.maxTicksPerBlock(idBytes);

        //  set new *higher* minBaseFee so old cap is now too small
        policy.setMinBaseFee(pid, (oldCap + 10) * 100); // oracle divides by 100

        //  non-owner should fail
        vm.prank(alice);
        vm.expectRevert(TruncGeoOracleMulti.OnlyOwner.selector);
        oracle.refreshPolicyCache(pid);

        //  owner succeeds
        vm.expectEmit(true, false, false, false);
        emit TruncGeoOracleMulti.PolicyCacheRefreshed(pid);
        oracle.refreshPolicyCache(pid);

        uint24 newCap = oracle.maxTicksPerBlock(idBytes);
        assertGt(newCap, oldCap, "cap should have been clamped up to new minCap");
    }

    /// non-owner cannot call refreshPolicyCache (isolated)
    function testPolicyRefreshOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(TruncGeoOracleMulti.OnlyOwner.selector);
        oracle.refreshPolicyCache(pid);
    }

    /// @notice Fuzz safe-cast helper – any value within int24 bounds must not revert
    function testFuzz_TickCastBounds(int256 raw) public {
        raw = bound(raw, -9_000_000, 9_000_000); // narrower than int24 max
        poolManager.setTick(pid, int24(0));
        vm.warp(block.timestamp + 1);
        vm.prank(address(hook));

        // should never revert for values within ±8 388 607
        poolManager.setTick(pid, int24(raw));
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, int24(0));
    }

    /* ------------------------------------------------------------ *
     * 10.  Fuzz regression for extreme policy params               *
     * ------------------------------------------------------------ */
    function testFuzz_PolicyValidation(uint24 minCap) public {
        // stepPpm = 1e9  ➜ should revert (out of 1e6 range)
        MockPolicyManager.Params memory p;
        p.minBaseFee = uint256(minCap == 0 ? 1 : minCap) * 100;
        p.maxBaseFee = 10_000; // sane default
        p.stepPpm = 1_000_000_000; // invalid (>1 e6)
        p.freqScaling = 1e18;
        p.budgetPpm = 0; // invalid (0)
        p.decayWindow = 86_400;
        p.updateInterval = 600;
        p.defaultMaxTicks = 50;

        vm.expectRevert("stepPpm-range");
        policy.setParams(pid, p);
    }

    /* ------------------------------------------------------------ *
     * 11.  🔍  **Oracle observation API**                          *
     * ------------------------------------------------------------ */

    /// helper – push a new observation at `dt` seconds from now with `tick`
    function _advanceAndPush(int24 tick_, uint32 dt) internal {
        vm.warp(block.timestamp + dt);
        poolManager.setTick(pid, tick_);
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, int24(0));
    }

    /// @dev 3-point window – check that observe() returns exact cumulatives
    ///      0 s   : tick = 0      (bootstrap written by enableOracleForPool)
    ///      10 s  : tick = 10
    ///      20 s  : tick = 30
    ///
    ///  expect cumulatives:
    ///      t(now)   =  400   (30 * 10  + 10 * 10)
    ///      t(now-10)=  100   (10 * 10)
    ///      t(now-20)=    0
    function testOracleObserveLinearAccumulation() public {
        bytes memory encKey = abi.encode(poolKey);

        // ── write second & third observations ──
        _advanceAndPush(10, 10); // 10 s after bootstrap
        _advanceAndPush(30, 10); // another 10 s later (now total 20 s)

        // build query [0,10,20]
        uint32[] memory sa = new uint32[](3);
        sa[0] = 0;
        sa[1] = 10;
        sa[2] = 20;

        // call observe()
        (int56[] memory tc,) = oracle.observe(encKey, sa);

        // tick-seconds cumulatives should be increasing with age
        assertEq(tc.length, 3, "length mismatch");
        assertEq(tc[0], 400, "cum@now   wrong");
        assertEq(tc[1], 100, "cum@now-10 wrong");
        assertEq(tc[2], 0, "cum@now-20 wrong");

        // ⏱️  fast-path cross-check (secondsAgo == 0)
        uint32[] memory zero = new uint32[](1);
        zero[0] = 0;
        (int56[] memory tcNow,) = oracle.observe(encKey, zero);
        assertEq(tcNow.length, 1);
        assertEq(tcNow[0], 400, "observe(0) cumulative mismatch");

        // latest-tick sanity
        (int24 latestTick,) = oracle.getLatestObservation(pid);
        assertEq(latestTick, 30, "latest tick sanity");
    }
}
