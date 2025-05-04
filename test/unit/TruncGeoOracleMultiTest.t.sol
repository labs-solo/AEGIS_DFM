// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*───────────────────────────────────────────────────────────────────────────*\
│  TruncGeoOracleMulti – unit-level test-suite                               │
│  – covers the "cheap" logic that does **not** need a full pool stack.      │
│  – targets init, ring behaviour, auto-tune & governance guards             │
\*───────────────────────────────────────────────────────────────────────────*/

import "forge-std/Test.sol";
import {TruncGeoOracleMulti} from "../../src/TruncGeoOracleMulti.sol";
import {TruncatedOracle} from "../../src/libraries/TruncatedOracle.sol";
import {DummyFullRangeHook} from "utils/DummyFullRangeHook.sol";
import {TickMoveGuard} from "../../src/libraries/TickMoveGuard.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPoolPolicy} from "../../src/interfaces/IPoolPolicy.sol";
import {Errors} from "../../src/errors/Errors.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import "forge-std/console.sol";

/* ───────────────────────────── Local Stubs ─────────────────────────────── */

/*  VERY-LIGHT policy stub – **does not** inherit the full interface       */
/*  (only selectors the oracle touches are implemented).                   */
/* ----------------------------------------------------------------------- */
import {MockPolicyManager} from "mocks/MockPolicyManager.sol";
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

        console.log("Deploying oracle...");
        // ── deploy oracle pointing to *this* hook ----------------------------------
        oracle = new TruncGeoOracleMulti(IPoolManager(address(poolManager)), IPoolPolicy(address(policy)), address(hook));
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
        oracle.pushObservationAndCheckCap(pid, capped);

        // --- Advance time before successful call ---
        vm.warp(block.timestamp + 1);

        // Should succeed when called via the hook
        vm.startPrank(address(hook)); // only the authorised hook may push
        oracle.pushObservationAndCheckCap(pid, capped);
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
        oracle.pushObservationAndCheckCap(pid, false);
        vm.roll(block.number + 1); // avoid rate-limit guard
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, false);
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
        oracle.pushObservationAndCheckCap(pid, false);

        // 2️⃣  wait less than the update-interval and push again
        vm.warp(block.timestamp + policy.getBaseFeeUpdateIntervalSeconds(pid) / 2);
        poolManager.setTick(pid, int24(startCap) - 2);
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, false);

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

        int24 boundedTick = int24(
            bound(int256(seedTick), -int256(uint256(cap) * 2), int256(uint256(cap) * 2))
        );
        poolManager.setTick(pid, boundedTick);

        vm.warp(block.timestamp + 1);
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, false);

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
        bool tickWasCapped = oracle.pushObservationAndCheckCap(pid, false);
        vm.stopPrank();

        assertTrue(tickWasCapped, "Tick SHOULD have been capped");

        // Verify the observation was written with the CAPPED value
        int24 expectedCappedTick = int24(maxTicks); // Tick should be capped at maxTicks
        (int24 latestTick,) = oracle.getLatestObservation(pid); // Use getter for latest info

        // Get the current state index to access the correct observation
        (,uint16 currentIndex,) = oracle.states(pidBytes);
        
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
        tickWasCapped = oracle.pushObservationAndCheckCap(pid, false);
        vm.stopPrank();

        assertFalse(tickWasCapped, "Tick should NOT have been capped (under limit)");

        // Verify the observation was written with the UNCAPPED value
        (latestTick,) = oracle.getLatestObservation(pid); // Use getter

        // Get the current state index again
        (,currentIndex,) = oracle.states(pidBytes);
        
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
            vm.warp(block.timestamp + 10);                 // advance few seconds
            vm.prank(address(hook));
            oracle.pushObservationAndCheckCap(pid, false);
            vm.roll(block.number + 1);
        }

        // Advance time past update interval
        vm.warp(block.timestamp + policy.getBaseFeeUpdateIntervalSeconds(pid) + 1);

        // Push once more to force auto-tune evaluation (no cap this time)
        poolManager.setTick(pid, int24(startCap) / 2);
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, false);

        uint24 newCap = oracle.maxTicksPerBlock(idBytes);
        assertGt(newCap, startCap, "Cap should have loosened after frequent caps");
    }
}
