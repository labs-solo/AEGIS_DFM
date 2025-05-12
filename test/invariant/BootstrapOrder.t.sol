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

/// @notice Invariant: after the first page rollover the bootstrap slot (0)
///         must be older than slot-1.
contract BootstrapOrder is Test {
    using PoolIdLibrary for PoolKey;

    TruncGeoOracleMulti internal oracle;
    MockPolicyManager   internal policy;
    MockPoolManager     internal poolManager;
    DummyFullRangeHook  internal hook;

    PoolKey internal poolKey;
    PoolId  internal pid;

    function setUp() public {
        policy      = new MockPolicyManager();
        poolManager = new MockPoolManager();
        hook        = new DummyFullRangeHook(address(0));

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0xA11CE)),
            currency1: Currency.wrap(address(0xB0B)),
            fee: 5_000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        pid = poolKey.toId();

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
    }

    /// @dev forge invariant – after arbitrary pushes, slot-0 timestamp < slot-1
    function invariant_bootstrapOrdering() public {
        // fuzz tick between –2000 and 2000
        int24 tick = int24(bound(int256(uint256(block.timestamp)), -2000, 2000));
        poolManager.setTick(pid, tick);

        vm.warp(block.timestamp + 1);
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, int24(0));

        (uint32 ts0, bool init0, uint32 ts1, bool init1) = oracle.debugLeaf0(PoolId.unwrap(pid));
        if (init1) {
            assertTrue(init0, "slot-0 not initialised");
            assertLt(ts0, ts1, "bootstrap ordering violated (ts0 >= ts1)");
        }
    }
} 