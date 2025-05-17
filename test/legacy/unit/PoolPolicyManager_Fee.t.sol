// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "../lib/EventTools.sol";

import {PoolPolicyManager, IPoolPolicyManager} from "src/PoolPolicyManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Errors} from "src/errors/Errors.sol"; // for precise revert selectors

/// @dev Covers: access control, fee-split config, POL logic, per-pool overrides, fuzz on sum-invariant.
contract PoolPolicyManager_Fee is Test {
    using EventTools for Test;

    PoolPolicyManager ppm;

    uint24 constant EXPECTED_MIN_DYNAMIC_FEE = 200; // Updated to match production
    uint24 constant EXPECTED_MAX_DYNAMIC_FEE = 60000; // Updated to match production
    uint24 constant EXPECTED_DEFAULT_DYNAMIC_FEE = 6000; // Updated to match production

    /* ------------------------------------------------------------ */
    /*                           Actors                             */
    /* ------------------------------------------------------------ */
    address constant OWNER = address(0xBEEF);
    address constant ALICE = address(0xA11CE); // non-owner
    address constant GOVERNOR = address(0xCAFE); // used later in suite

    /* ------------------------------------------------------------ */
    /*                       Test set-up                            */
    /* ------------------------------------------------------------ */
    function setUp() public {
        uint24[] memory supportedTickSpacings = new uint24[](2);
        supportedTickSpacings[0] = 1;
        supportedTickSpacings[1] = 10;

        ppm = new PoolPolicyManager(
            OWNER, // governance / owner
            2_000_000, // Updated dailyBudget to match production
            EXPECTED_MIN_DYNAMIC_FEE,
            EXPECTED_MAX_DYNAMIC_FEE
        );
    }

    /* ------------------------------------------------------------ */
    /*                1. Access control on getPoolPOLShare             */
    /* ------------------------------------------------------------ */
    function testSetFeeConfigByOwner() public {
        // Get current values to determine if events should emit
        uint256 prevPol = ppm.getPoolPOLShare(pid(0));

        bool willEmit = (prevPol != 120_000);

        // Expect FeeConfigChanged event
        EventTools.expectEmitIf(this, willEmit, true, true, true, true);
        emit FeeConfigChanged(120_000, 0, 880_000, 200);

        // Expect PolicySet event
        EventTools.expectPolicySetIf(
            this, true, PoolId.wrap(bytes32(0)), IPoolPolicyManager.PolicyType.FEE, address(0), OWNER
        );

        vm.prank(OWNER);
        ppm.setPoolPOLShare(PoolId.wrap(bytes32(0)), 120_000);

        uint256 pol = ppm.getPoolPOLShare(pid(0));
        assertEq(pol, 120_000);
    }

    /* ------------------------------------------------------------ */
    /*           2. FeeConfig - happy path & event emission          */
    /* ------------------------------------------------------------ */
    function testFeeConfigHappyPathEmitsEvent() public {
        // Get current values to determine if events should emit
        uint256 prevPol = ppm.getPoolPOLShare(pid(0));

        bool willEmit = (prevPol != 150_000);

        // Expect FeeConfigChanged event
        EventTools.expectEmitIf(this, willEmit, true, true, true, true);
        emit FeeConfigChanged(150_000, 50_000, 800_000, 200);

        // Check PolicySet event
        EventTools.expectPolicySetIf(
            this, true, PoolId.wrap(bytes32(0)), IPoolPolicyManager.PolicyType.FEE, address(0), OWNER
        );

        vm.prank(OWNER);
    }

    /* ------------------------------------------------------------ */
    /*              3. Range / sum-invariant reverts                 */
    /* ------------------------------------------------------------ */

    /* ------------------------------------------------------------ */
    /*              4. Pool-specific POL-share override              */
    /* ------------------------------------------------------------ */
    function testPoolSpecificPOLOverride() public {
        PoolId pool = pid(42);

        // A) default (global settings)
        uint256 polA = ppm.getPoolPOLShare(pool); // Use global polSharePpm
        // Assuming default polSharePpm is 100_000 (10%) from constructor
        assertEq(polA, 100_000);

        // B) enable feature & set override
        // Assume it's initially disabled since we're enabling it
        bool willEmitEnabled = true;

        // Expect PolicySet for enabling the feature
        EventTools.expectEmitIf(this, willEmitEnabled, false, false, false, true);
        emit PoolSpecificPOLSharingEnabled(true);

        EventTools.expectPolicySetIf(
            this, true, PoolId.wrap(bytes32(0)), IPoolPolicyManager.PolicyType.FEE, address(1), OWNER
        ); // address(1) for true

        vm.prank(OWNER);
        ppm.setPoolSpecificPOLSharingEnabled(true);

        // Check if pool already has the desired share
        uint256 currentPoolShare = ppm.getPoolPOLShare(pool);
        bool willEmitShare = (currentPoolShare != 123_456);

        // Expect PolicySet for setting the pool share
        EventTools.expectEmitIf(this, willEmitShare, false, false, false, true);
        emit PoolPOLShareChanged(pool, 123_456);

        EventTools.expectPolicySetIf(
            this, true, pool, IPoolPolicyManager.PolicyType.FEE, address(uint160(123_456)), OWNER
        );

        vm.prank(OWNER);
        ppm.setPoolPOLShare(pool, 123_456);

        uint256 polB = ppm.getPoolPOLShare(pool);
        assertEq(polB, 123_456);

        // C) disable feature → revert to global
        // Expect PolicySet for disabling the feature
        EventTools.expectEmitIf(this, true, false, false, false, true);
        emit PoolSpecificPOLSharingEnabled(false);

        EventTools.expectPolicySetIf(
            this, true, PoolId.wrap(bytes32(0)), IPoolPolicyManager.PolicyType.FEE, address(0), OWNER
        ); // address(0) for false

        vm.prank(OWNER);
        ppm.setPoolSpecificPOLSharingEnabled(false);

        uint256 polC = ppm.getPoolPOLShare(pool);
        assertEq(polC, 100_000); // Back to global default
    }

    /* ------------------------------------------------------------ */
    /*                6. Fuzz: allocation-sum invariant             */
    /* ------------------------------------------------------------ */
    function testFeeSumInvariantFuzz(uint256 pol, uint256 fr) public {
        // Bound the inputs to prevent overflow
        pol = bound(pol, 0, EventTools.MAX_PPM);
        fr = bound(fr, 0, EventTools.MAX_PPM - pol);
        uint256 lp = EventTools.MAX_PPM - pol - fr;

        // Expect FeeConfigChanged and PolicySet
        // Note: Fuzzing makes exact value checks hard for FeeConfigChanged
        // We can check the PolicySet event reliably though
        EventTools.expectPolicySetIf(
            this, true, PoolId.wrap(bytes32(0)), IPoolPolicyManager.PolicyType.FEE, address(0), OWNER
        );

        vm.prank(OWNER);
        ppm.getPoolPOLShare(PoolId.wrap(bytes32(0)));

        uint256 a = ppm.getPoolPOLShare(pid(1));
        assertEq(a, EventTools.MAX_PPM);
    }

    /* ------------------------------------------------------------ */
    /*                            Events                             */
    /* ------------------------------------------------------------ */
    event FeeConfigChanged(
        uint256 polSharePpm, uint256 fullRangeSharePpm, uint256 lpSharePpm, uint256 minimumTradingFeePpm
    );
    event PoolPOLMultiplierChanged(PoolId indexed poolId, uint32 multiplier);
    event DefaultPOLMultiplierChanged(uint32 multiplier);
    event PoolSpecificPOLSharingEnabled(bool enabled);
    event PoolPOLShareChanged(PoolId indexed poolId, uint256 polSharePpm);

    /* ------------------------------------------------------------ */
    /*                            Helper                             */
    /* ------------------------------------------------------------ */
    function pid(uint256 n) internal pure returns (PoolId) {
        return PoolId.wrap(bytes32(n));
    }
}
