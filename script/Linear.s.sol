// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import {TruncGeoOracleMulti} from "src/TruncGeoOracleMulti.sol";
import {MockPolicyManager} from "mocks/MockPolicyManager.sol";
import {MockPoolManagerSettable as MockPoolManager} from "test/mocks/MockPoolManagerSettable.sol";
import {DummyFullRangeHook} from "utils/DummyFullRangeHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolPolicy} from "src/interfaces/IPoolPolicy.sol";

contract LinearScript is Script {
    function run() external {
        vm.startBroadcast();
        MockPolicyManager policy = new MockPolicyManager();
        MockPoolManager poolManager = new MockPoolManager();
        DummyFullRangeHook hook = new DummyFullRangeHook(address(0));
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0xA11CE)),
            currency1: Currency.wrap(address(0xB0B)),
            fee: 5000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId pid = poolKey.toId();
        MockPolicyManager.Params memory p;
        p.minBaseFee=100;
        p.maxBaseFee=10000;
        p.stepPpm=50000;
        p.freqScaling=1e18;
        p.budgetPpm=100000;
        p.decayWindow=86400;
        p.updateInterval=600;
        p.defaultMaxTicks=50;
        policy.setParams(pid, p);
        TruncGeoOracleMulti oracle = new TruncGeoOracleMulti(poolManager, policy, address(hook), address(this));
        hook.setOracle(address(oracle));
        vm.prank(address(hook));
        oracle.enableOracleForPool(poolKey);

        // push 10 at t=11
        vm.warp(11);
        poolManager.setTick(pid, 10);
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, 0);
        vm.roll(block.number+1);

        // push 30 at t=21
        vm.warp(21);
        poolManager.setTick(pid, 30);
        vm.prank(address(hook));
        oracle.pushObservationAndCheckCap(pid, 0);

        int56 tc = oracle.debugLatestTickCum(pid);
        console2.log("latest tickCumulative", tc);
        vm.stopBroadcast();
    }
} 