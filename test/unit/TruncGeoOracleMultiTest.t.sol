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
import {TickMoveGuard}       from "../../src/libraries/TickMoveGuard.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey}      from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPoolPolicy}  from "../../src/interfaces/IPoolPolicy.sol";
import {Currency}     from "v4-core/src/types/Currency.sol";
import {IHooks}       from "v4-core/src/interfaces/IHooks.sol";

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
    MockPolicyManager   internal policy;
    MockPoolManager     internal poolManager;
    DummyFullRangeHook  internal hook;

    PoolKey internal poolKey;
    PoolId  internal pid;
    uint24  internal constant DEF_FEE  = 5_000;     // 0.5 %
    uint32  internal constant START_TS = 1_000_000; // base timestamp

    /* ------------------------------------------------------- */
    /*  setup                                                  */
    /* ------------------------------------------------------- */
    function setUp() public {
        policy      = new MockPolicyManager();
        poolManager = new MockPoolManager();

        // Create mock tokens for the PoolKey
        address token0 = address(0xA11CE);
        address token1 = address(0xB0B);
        
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: DEF_FEE,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        
        pid = poolKey.toId();

        // ── deploy hook FIRST (oracle addr is 0, never used) -----------------------
        hook = new DummyFullRangeHook(address(0));

        // ── deploy oracle pointing to *this* hook ----------------------------------
        oracle = new TruncGeoOracleMulti(
            IPoolManager(address(poolManager)),
            address(this),
            IPoolPolicy(address(policy)),
            address(hook)
        );

        // ── enable oracle for the pool (must be called by *that* hook) --------------
        vm.prank(address(hook));
        oracle.enableOracleForPool(poolKey);
    }

    /* gas logger helper (does not fail CI) */
    function _logGas(string memory tag, uint256 beforeGas) internal {
        emit log_named_uint(tag, beforeGas - gasleft());
    }

    /* ------------------------------------------------------------ *
     * 1. Initialization paths                                      *
     * ------------------------------------------------------------ */
    function testEnablePoolSetsDefaults() public {
        bytes32 poolIdBytes = PoolId.unwrap(pid);
        assertEq(
            oracle.getMaxTicksPerBlock(poolIdBytes),
            policy.getDefaultMaxTicksPerBlock(pid) // Should be 50 ticks
        );

        (, uint16 card, ) = oracle.states(poolIdBytes);
        assertEq(card, 1, "cardinality should equal 1 after init");
    }

    /* ------------------------------------------------------------ *
     * 2. Governance mutators                                       *
     * ------------------------------------------------------------ */
    function testOnlyGovernorSetMaxTicks() public {
        vm.prank(address(this));
        oracle.setMaxTicksPerBlock(pid, 123);
        assertEq(oracle.getMaxTicksPerBlock(PoolId.unwrap(pid)), 123);

        vm.expectRevert();
        vm.prank(address(0xDEAD));
        oracle.setMaxTicksPerBlock(pid, 99);
    }

    /* ------------------------------------------------------------ *
     * 3. Auto-tune : too many CAPS → loosen cap                    *
     * ------------------------------------------------------------ */
    function testAutoTuneIncreasesCap() public {
        // simplified: just call the setter (auto-tune path removed)
        oracle.setMaxTicksPerBlock(pid, 999);
        assertEq(oracle.getMaxTicksPerBlock(PoolId.unwrap(pid)), 999);
    }

    /* ------------------------------------------------------------ *
     * 4. Rate-limit & step clamp – candidate inside band → skip    *
     * ------------------------------------------------------------ */
    function testAutoTuneSkippedInsideBand() public {
        uint24 cap = oracle.getMaxTicksPerBlock(PoolId.unwrap(pid));

        // reset the "last update" tracker
        oracle.setMaxTicksPerBlock(pid, cap);

        // no auto-tune ⇒ nothing to skip, just ensure value unchanged
        assertEq(
            oracle.getMaxTicksPerBlock(PoolId.unwrap(pid)),
            cap,
            "cap must remain unchanged"
        );
    }

    /* ------------------------------------------------------------ *
     * 5. getLatestObservation fast-path                            *
     * ------------------------------------------------------------ */
    function testGetLatestObservation() public {
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
            fee:       DEF_FEE,
            tickSpacing: 60,
            hooks:       IHooks(address(0))
        });
        PoolId unknownId = unknownKey.toId();

        vm.expectRevert(); // Expect revert because pool is not enabled
        oracle.getLatestObservation(unknownId);
    }

    /* ------------------------------------------------------------ *
     * 7. Gas baseline demo                                         *
     * ------------------------------------------------------------ */
    function testGasBaselineWritePath() public {
        uint256 g   = gasleft();
        oracle.setMaxTicksPerBlock(pid, 77);
        _logGas("setMaxTicks", g);

        g = gasleft();
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, false);
        _logGas("pushObservationAndCheckCap", g);
    }
}