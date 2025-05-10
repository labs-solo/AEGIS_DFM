// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {TruncGeoOracleMulti} from "../../src/TruncGeoOracleMulti.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {MockPolicyManager} from "mocks/MockPolicyManager.sol";
import {MockPoolManagerSettable as MockPoolManager} from "../mocks/MockPoolManagerSettable.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {DummyFullRangeHook} from "utils/DummyFullRangeHook.sol";

contract CardinalityDebug is Test {
    TruncGeoOracleMulti oracle;
    MockPolicyManager policy;
    MockPoolManager poolManager;
    DummyFullRangeHook hook;
    PoolKey poolKey;
    PoolId pid;

    function setUp() public {
        policy = new MockPolicyManager();
        poolManager = new MockPoolManager();
        hook = new DummyFullRangeHook(address(0));

        address token0 = address(0x1);
        address token1 = address(0x2);
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 5000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        pid = poolKey.toId();
        {
            MockPolicyManager.Params memory p;
            p.minBaseFee=100;
            p.maxBaseFee=10_000;
            p.stepPpm=50_000;
            p.freqScaling=1e18;
            p.budgetPpm=100_000;
            p.decayWindow=86_400;
            p.updateInterval=600;
            p.defaultMaxTicks=50;
            policy.setParams(pid,p);
        }
        oracle = new TruncGeoOracleMulti(IPoolManager(address(poolManager)), policy, address(hook), address(this));
        hook.setOracle(address(oracle));
        vm.prank(address(hook));
        oracle.enableOracleForPool(poolKey);
    }

    function test_debug() public {
        for(uint256 i=0;i<10;i++){
            uint256 beforeTs = block.timestamp;
            vm.warp(block.timestamp+1);
            // timestamp BEFORE external call (not updated yet)
            emit log_named_uint("ts_before", block.timestamp);
            vm.prank(address(hook));
            oracle.pushObservationAndCheckCap(pid,0);
            emit log_named_uint("ts_after", block.timestamp);
            uint16 card = oracle.cardinality(pid);
            uint16 idx = oracle.index(pid);
            emit log_named_uint("card",card);
            emit log_named_uint("idx", idx);
        }
    }
} 