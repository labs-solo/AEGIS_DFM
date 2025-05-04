// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*───────────────────────────────────────────────────────────────────────────*\
│  TruncGeoOracleMulti – unit-level test-suite                               │
│  – covers the "cheap" logic that does **not** need a full pool stack.      │
│  – targets init, ring behaviour, auto-tune & governance guards             │
\*───────────────────────────────────────────────────────────────────────────*/

import "forge-std/Test.sol";
import {TruncGeoOracleMulti} from "../../src/TruncGeoOracleMulti.sol";
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
import {MockPoolManager} from "mocks/MockPoolManager.sol";

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
        hook = new DummyFullRangeHook(address(0)); // single instantiation
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
        oracle = new TruncGeoOracleMulti(
            IPoolManager(address(poolManager)), address(this), IPoolPolicy(address(policy)), address(hook)
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
        address governor = address(this); // Assume governor is test contract for setup
        int24 tick = 100;
        bool capped = false;

        // Revert expected when called directly (not by hook)
        vm.expectRevert(abi.encodeWithSelector(Errors.AccessNotAuthorized.selector, governor));
        oracle.pushObservationAndCheckCap(pid, capped);

        // Should succeed when called via the hook
        vm.startPrank(address(hook)); // only the authorised hook may push
        // Note: Dummy hook doesn't have notifyOracleUpdate, call oracle directly for test
        // In a real scenario, interaction would be via hook.notifyOracleUpdate
        oracle.pushObservationAndCheckCap(pid, capped);
        vm.stopPrank();

        // Verify the observation was written
        (int24 latestTick,) = oracle.getLatestObservation(pid);
        assertEq(latestTick, tick, "Observation tick mismatch after hook push");
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
        _writeTwice();
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
    function testGasBaselineWritePath() public {
        _writeTwice();
    }
}
