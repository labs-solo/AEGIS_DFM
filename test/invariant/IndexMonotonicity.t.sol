// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {TruncGeoOracleMulti} from "../../src/TruncGeoOracleMulti.sol";
import {MockPolicyManager}   from "../mocks/MockPolicyManager.sol";
import {MockPoolManagerSettable as MockPoolManager} from "../mocks/MockPoolManagerSettable.sol";
import {DummyFullRangeHook} from "utils/DummyFullRangeHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPoolPolicy} from "../../src/interfaces/IPoolPolicy.sol";

/// @notice Invariant: `state.index` must progress monotonically (no backward jumps)
///         modulo 8_192.  The allowed per-call delta is 0 (same-second merge)
///         or 1 (fresh slot).  Wrap-around from 8_191 → 0 is therefore encoded
///         as a diff of 0 or 1 after modular normalisation.
contract IndexMonotonicity is Test {
    using PoolIdLibrary for PoolKey;

    TruncGeoOracleMulti internal oracle;
    MockPolicyManager   internal policy;
    MockPoolManager     internal poolManager;
    DummyFullRangeHook  internal hook;

    PoolKey internal poolKey;
    PoolId  internal pid;

    uint16  internal lastIdx;

    function setUp() public {
        policy      = new MockPolicyManager();
        poolManager = new MockPoolManager();
        hook        = new DummyFullRangeHook(address(0));

        // Construct PoolKey
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0xA11CE)),
            currency1: Currency.wrap(address(0xB0B)),
            fee: 5_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        pid = poolKey.toId();

        // Reasonable policy params
        MockPolicyManager.Params memory p;
        p.minBaseFee      = 100;
        p.maxBaseFee      = 10_000;
        p.stepPpm         = 50_000;
        p.freqScaling     = 1e18;
        p.budgetPpm       = 100_000;
        p.decayWindow     = 86_400;
        p.updateInterval  = 600;
        p.defaultMaxTicks = 50;
        policy.setParams(pid, p);

        oracle = new TruncGeoOracleMulti(
            IPoolManager(address(poolManager)),
            IPoolPolicy(address(policy)),
            address(hook),
            address(this)
        );
        hook.setOracle(address(oracle));

        vm.prank(address(hook));
        oracle.enableOracleForPool(poolKey);

        lastIdx = oracle.index(pid);
    }

    /// @dev fuzz-driven invariant executed by Forge after each call sequence
    function invariant_indexProgresses() public {
        // Bound pseudo-random tick within ±1000 to reduce capping noise
        int24 tick = int24(bound(int256(uint256(block.timestamp)), -1000, 1000));
        poolManager.setTick(pid, tick);

        vm.warp(block.timestamp + 1);
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, int24(0));

        uint16 cur = oracle.index(pid);
        uint16 diff = (cur + 8_192 - lastIdx) % 8_192;
        assertTrue(diff == 0 || diff == 1, "index jumped >1 slot backwards");
        lastIdx = cur;
    }
} 