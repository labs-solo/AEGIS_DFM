// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../lib/EventTools.sol";

import {PoolPolicyManager, IPoolPolicyManager} from "src/PoolPolicyManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

contract PoolPolicyManager_Step is Test {
    using EventTools for Test;

    PoolPolicyManager ppm;

    address constant OWNER = address(0xBEEF);
    address constant ALICE = address(0xA11CE);

    uint24 constant EXPECTED_MIN_DYNAMIC_FEE = 100; // 0.01 %
    uint24 constant EXPECTED_MAX_DYNAMIC_FEE = 50000; // 5 %
    uint24 constant EXPECTED_DEFAULT_DYNAMIC_FEE = 5000; // 0.5 %

    // Add event definition for testing
    event PolicySet(PoolId indexed poolId, address implementation, address indexed setter);

    /*─────────────────── set-up ───────────────────*/
    function setUp() public {
        uint24[] memory supportedTickSpacings = new uint24[](2);
        supportedTickSpacings[0] = 1;
        supportedTickSpacings[1] = 10;

        ppm = new PoolPolicyManager(OWNER, 1_000_000);
    }

    /*────────────────── Defaults ──────────────────*/
    function testDefaultStepEngineAndSurge() public view {
        PoolId pool = pid(1);

        assertEq(ppm.getBaseFeeStepPpm(pool), 20_000);
        assertEq(ppm.getBaseFeeUpdateIntervalSeconds(pool), 1 days);

        // Surge defaults
        assertEq(ppm.getSurgeFeeMultiplierPpm(pool), 3_000_000);
        assertEq(ppm.getSurgeDecayPeriodSeconds(pool), 3_600);
    }

    /*──────────────── setBaseFeeParams ────────────────*/
    function testOwnerCanOverrideBaseFeeParams() public {
        PoolId pool = pid(42);

        // Check current values to know if event should emit
        uint32 prevStep = ppm.getBaseFeeStepPpm(pool);
        uint32 prevInterval = ppm.getBaseFeeUpdateIntervalSeconds(pool);
        bool willEmit = (prevStep != 15_000 || prevInterval != 2 days);

        EventTools.expectEmitIf(this, willEmit, true, true, true, false);
        emit BaseFeeParamsSet(pool, 15_000, 2 days);

        EventTools.expectPolicySetIf(this, true, pool, address(0), OWNER);

        vm.prank(OWNER);
        ppm.setBaseFeeParams(pool, 15_000, 2 days);

        assertEq(ppm.getBaseFeeStepPpm(pool), 15_000);
        assertEq(ppm.getBaseFeeUpdateIntervalSeconds(pool), 2 days);

        // Another pool stays on defaults
        assertEq(ppm.getBaseFeeStepPpm(pid(99)), 20_000);
    }

    function testSetBaseFeeParamsStepTooLargeReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Errors.ParameterOutOfRange.selector, 120_000, 0, 100_000));
        ppm.setBaseFeeParams(pid(1), 120_000, 1 days); // >100 000
    }

    function testNonOwnerSetBaseFeeParamsReverts() public {
        vm.prank(ALICE);
        vm.expectRevert("UNAUTHORIZED");
        ppm.setBaseFeeParams(pid(1), 15_000, 2 days);
    }

    /*──────────────── Surge decay period ────────────────*/
    function testOwnerCanOverrideSurgeDecay() public {
        PoolId pool = pid(7);

        // Set decay to 12h, check event
        vm.expectEmit(true, true, true, true);
        emit PolicySet(pool, address(uint160(12 hours)), OWNER);
        vm.prank(OWNER);
        ppm.setSurgeDecayPeriodSeconds(pool, 12 hours);
        assertEq(ppm.getSurgeDecayPeriodSeconds(pool), 12 hours, "Surge decay not set");
    }

    function testSurgeDecayTooShortReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Errors.ParameterOutOfRange.selector, 59, 60, 86400));
        ppm.setSurgeDecayPeriodSeconds(pid(7), 59);
    }

    function testSurgeDecayTooLongReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Errors.ParameterOutOfRange.selector, 86401, 60, 86400));
        ppm.setSurgeDecayPeriodSeconds(pid(7), 1 days + 1);
    }

    function testNonOwnerSetSurgeDecayReverts() public {
        vm.prank(ALICE);
        vm.expectRevert("UNAUTHORIZED");
        ppm.setSurgeDecayPeriodSeconds(pid(1), 2 hours);
    }

    /*──────────────── Surge fee multiplier ─────────────*/
    function testOwnerCanOverrideSurgeMultiplier() public {
        PoolId pool = pid(9);

        // Set multiplier to 2x, check event
        vm.expectEmit(true, true, true, true);
        emit PolicySet(pool, address(uint160(2_000_000)), OWNER);
        vm.prank(OWNER);
        ppm.setSurgeFeeMultiplierPpm(pool, 2_000_000);
        assertEq(ppm.getSurgeFeeMultiplierPpm(pool), 2_000_000, "Surge mult not set");
    }

    function testSurgeMultiplierZeroReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Errors.ParameterOutOfRange.selector, 0, 1, 3_000_000));
        ppm.setSurgeFeeMultiplierPpm(pid(1), 0);
    }

    function testSurgeMultiplierTooHighReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Errors.ParameterOutOfRange.selector, 3_000_001, 1, 3_000_000));
        ppm.setSurgeFeeMultiplierPpm(pid(1), 3_000_001);
    }

    /*──────────────── Helper ─────────────────*/
    event BaseFeeParamsSet(PoolId indexed poolId, uint32 stepPpm, uint32 updateIntervalSecs);

    function pid(uint256 n) internal pure returns (PoolId) {
        return PoolId.wrap(bytes32(n));
    }
}
