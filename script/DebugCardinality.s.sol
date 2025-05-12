// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;
import "forge-std/Script.sol";
import "forge-std/Test.sol";

import {TruncGeoOracleMulti} from "src/TruncGeoOracleMulti.sol";
import {MockPolicyManager} from "mocks/MockPolicyManager.sol";
import {MockPoolManagerSettable as MockPoolManager} from "test/mocks/MockPoolManagerSettable.sol";
import {DummyFullRangeHook} from "utils/DummyFullRangeHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract DebugCardinality is Script, Test {
    function run() external {
        // replicate minimal environment like in setUp of test
        MockPolicyManager policy = new MockPolicyManager();
        MockPoolManager poolManager = new MockPoolManager();
        DummyFullRangeHook hook = new DummyFullRangeHook(address(0));

        address token0 = address(0xA11CE);
        address token1 = address(0xB0B);
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 5000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId pid = poolKey.toId();

        // set params minimal
        MockPolicyManager.Params memory p;
        p.minBaseFee = 100;
        p.maxBaseFee = 10000;
        p.stepPpm = 50000;
        p.freqScaling = 1e18;
        p.budgetPpm = 100000;
        p.decayWindow = 86400;
        p.updateInterval = 600;
        p.defaultMaxTicks = 50;
        policy.setParams(pid, p);

        TruncGeoOracleMulti oracle = new TruncGeoOracleMulti(
            IPoolManager(address(poolManager)),
            policy,
            address(hook),
            address(this)
        );
        hook.setOracle(address(oracle));
        vm.prank(address(hook));
        oracle.enableOracleForPool(poolKey);

        // now push 5 obs like testPaged loops but smaller
        uint24 cap = oracle.maxTicksPerBlock(PoolId.unwrap(pid));
        vm.roll(block.number + 1);
        for (uint16 i=1; i<=5; ++i) {
            vm.warp(block.timestamp + 1);
            poolManager.setTick(pid, int24(int256(uint256(cap) - 1)));
            vm.prank(address(hook));
            oracle.pushObservationAndCheckCap(pid, 0);
            (int24 t, uint32 ts) = oracle.getLatestObservation(pid);
            emit log_named_uint("iter", i);
            emit log_named_uint("block.ts", block.timestamp);
            emit log_named_uint("obs.ts", ts);
        }
        (,, , uint24 cap2) = oracle.getState(pid);
        uint16 card = oracle.cardinality(pid);
        emit log_named_uint("card", card);
        emit log_named_uint("cap", cap2);
    }
} 