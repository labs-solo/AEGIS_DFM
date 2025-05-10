// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {TruncGeoOracleMulti} from "../src/TruncGeoOracleMulti.sol";
import {MockPolicyManager} from "mocks/MockPolicyManager.sol";
import {MockPoolManagerSettable as MockPoolManager} from "test/mocks/MockPoolManagerSettable.sol";
import {DummyFullRangeHook} from "utils/DummyFullRangeHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary, PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract DebugOracleTest is Test {
    using PoolIdLibrary for PoolKey;
    TruncGeoOracleMulti oracle;
    MockPolicyManager policy;
    MockPoolManager pool;
    DummyFullRangeHook hook;
    PoolKey key;
    PoolId pid;

    function setUp() public {
        policy = new MockPolicyManager();
        pool = new MockPoolManager();
        hook = new DummyFullRangeHook(address(0));
        key = PoolKey({currency0: Currency.wrap(address(1)), currency1: Currency.wrap(address(2)), fee: 5000, tickSpacing: 60, hooks: IHooks(address(hook))});
        pid = key.toId();
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
        oracle = new TruncGeoOracleMulti(IPoolManager(address(pool)), policy, address(hook), address(this));
        hook.setOracle(address(oracle));
        vm.prank(address(hook));
        oracle.enableOracleForPool(key);
    }

    function testCardinalityGrowth() public {
        for(uint i = 0; i < 10; i++) {
            pool.setTick(pid, 0);
            vm.warp(block.timestamp + 1);
            vm.prank(address(hook));
            oracle.pushObservationAndCheckCap(pid, 0);
            emit log_string("idx");
            emit log_uint(oracle.index(pid));
            emit log_string("card");
            emit log_uint(oracle.cardinality(pid));
            emit log_uint(block.timestamp);
            (int24 ltick, uint32 lts) = oracle.getLatestObservation(pid);
            emit log_uint(uint256(lts));
            (int24 ltickBefore, uint32 beforeTs) = oracle.getLatestObservation(pid);
            emit log_uint(uint256(beforeTs));
        }
    }
} 