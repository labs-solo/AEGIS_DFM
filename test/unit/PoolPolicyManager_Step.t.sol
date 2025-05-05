// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../lib/EventTools.sol";

import {PoolPolicyManager, IPoolPolicy} from "src/PoolPolicyManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

contract PoolPolicyManager_Step is Test {
    using EventTools for Test;

    PoolPolicyManager ppm;

    address constant OWNER = address(0xBEEF);
    address constant ALICE = address(0xA11CE);

    // Add event definition for testing
    event PolicySet(
        PoolId          indexed poolId,
        IPoolPolicy.PolicyType indexed policyType,
        address         implementation,
        address         indexed setter
    );

    /*─────────────────── set-up ───────────────────*/
    function setUp() public {
        uint24[] memory ticks = new uint24[](2);
        ticks[0] = 1;
        ticks[1] = 10;

        ppm = new PoolPolicyManager(
            OWNER,
            5_000,
            ticks,
            50_000, // 5% PPM
            address(0xFEE)
        );
    }

    /*────────────────── Defaults ──────────────────*/
    function testDefaultStepEngineAndSurge() public view {
        PoolId pool = pid(1);

        assertEq(ppm.getBaseFeeStepPpm(pool), 20_000);
        assertEq(ppm.getBaseFeeUpdateIntervalSeconds(pool), 1 days);

        // Surge defaults
        assertEq(ppm.getSurgeFeeMultiplierPpm(pool), 3_000_000);
        assertEq(ppm.getSurgeDecaySeconds(pool), 3_600);
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

        EventTools.expectPolicySetIf(this, true, pool, IPoolPolicy.PolicyType.FEE, address(0), OWNER);

        vm.prank(OWNER);
        ppm.setBaseFeeParams(pool, 15_000, 2 days);

        assertEq(ppm.getBaseFeeStepPpm(pool), 15_000);
        assertEq(ppm.getBaseFeeUpdateIntervalSeconds(pool), 2 days);

        // Another pool stays on defaults
        assertEq(ppm.getBaseFeeStepPpm(pid(99)), 20_000);
    }

    function testSetBaseFeeParamsStepTooLargeReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(bytes("stepPpm too large"));
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
        emit PolicySet(pool, IPoolPolicy.PolicyType.FEE, address(uint160(12 hours)), OWNER);
        vm.prank(OWNER);
        ppm.setSurgeDecayPeriodSeconds(pool, 12 hours);
        assertEq(ppm.getSurgeDecaySeconds(pool), 12 hours, "Surge decay not set");
    }

    function testSurgeDecayTooShortReverts() public {
        vm.expectRevert(bytes("min 60s"));
        vm.prank(OWNER);
        ppm.setSurgeDecayPeriodSeconds(pid(7), 59);
    }

    function testSurgeDecayTooLongReverts() public {
        vm.expectRevert(bytes("max 1 day"));
        vm.prank(OWNER);
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
        emit PolicySet(pool, IPoolPolicy.PolicyType.FEE, address(uint160(2_000_000)), OWNER);
        vm.prank(OWNER);
        ppm.setSurgeFeeMultiplierPpm(pool, 2_000_000);
        assertEq(ppm.getSurgeFeeMultiplierPpm(pool), 2_000_000, "Surge mult not set");
    }

    function testSurgeMultiplierZeroReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(bytes("must be positive"));
        ppm.setSurgeFeeMultiplierPpm(pid(1), 0);
    }

    function testSurgeMultiplierTooHighReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(bytes("max 300%"));
        ppm.setSurgeFeeMultiplierPpm(pid(1), 3_000_001);
    }

    function testNonOwnerSetSurgeMultiplierReverts() public {
        vm.prank(ALICE);
        vm.expectRevert("UNAUTHORIZED");
        ppm.setSurgeFeeMultiplierPpm(pid(1), 2_000_000);
    }

    /*──────────────── Helper ─────────────────*/
    event BaseFeeParamsSet(PoolId indexed poolId, uint32 stepPpm, uint32 updateIntervalSecs);

    function pid(uint256 n) internal pure returns (PoolId) {
        return PoolId.wrap(bytes32(n));
    }
}
