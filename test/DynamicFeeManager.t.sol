// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {DynamicFeeManager} from "src/DynamicFeeManager.sol";
import {TruncGeoOracleMulti} from "src/TruncGeoOracleMulti.sol";

contract DynamicFeeManagerTest is Test {
    using PoolIdLibrary for PoolId;

    TruncGeoOracleMulti oracle;
    DynamicFeeManager dfm;

    struct CapTestCase {
        uint24 cap;
        uint256 expectPpm;
        string note;
    }

    function setUp() external {
        // minimal stub objects for unit-test
        IPoolManager dummyPM = IPoolManager(address(1));
        IPoolPolicy dummyPolicy = IPoolPolicy(address(2));

        oracle = new TruncGeoOracleMulti(
            dummyPM,                // pool-manager
            address(this),          // governance
            dummyPolicy             // policy-mgr
        );

        dfm = new DynamicFeeManager(
            dummyPolicy,            // IPoolPolicy
            address(this),          // authorised hook (tests)
            address(oracle)         // TruncGeoOracleMulti
        );
    }

    function _setCap(bytes32 poolId, uint24 cap) internal {
        // storage layout: mapping(bytes32 => uint24) maxTicksPerBlock
        // slot number can be fetched at compile-time with yolov2, here hard-code 7
        bytes32 slot = keccak256(abi.encode(poolId, uint256(7)));
        vm.store(address(oracle), slot, bytes32(uint256(cap)));
    }

    function testCapMapping() external {
        PoolId pid = PoolId.wrap(bytes32(uint256(1)));
        
        CapTestCase[] memory cases = new CapTestCase[](4);
        cases[0] = CapTestCase(42, 4200, "typical small cap");
        cases[1] = CapTestCase(1000, 100000, "medium cap");
        cases[2] = CapTestCase(16_777_215, 1_677_721_500, "uint24 upper-bound");
        cases[3] = CapTestCase(1, 100, "minimum cap");

        for (uint i; i < cases.length; ++i) {
            CapTestCase memory tc = cases[i];
            _setCap(PoolId.unwrap(pid), tc.cap);
            assertEq(dfm.baseFeeFromCap(pid), tc.expectPpm, tc.note);
        }
    }
}

// Legacy step-based tests removed as they no longer apply to the new fee model
// which derives fees directly from oracle caps (1 tick = 100 ppm = 0.01%) 