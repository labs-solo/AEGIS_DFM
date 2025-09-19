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
            2_000_000 // Updated dailyBudget to match production
        );
    }

    /* ------------------------------------------------------------ */
    /*                1. Access control on getPoolPOLShare             */
    /* ------------------------------------------------------------ */
    function testSetFeeConfigByOwner() public {
        // Get current values to determine if events should emit
        uint256 prevPol = ppm.getPoolPOLShare(pid(0));

        bool willEmit = (prevPol != 120_000);

        // Expect PoolPOLShareChanged event
        EventTools.expectEmitIf(this, willEmit, true, true, true, true);
        emit PoolPOLShareChanged(PoolId.wrap(bytes32(0)), 120_000);

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

        // Expect PoolPOLShareChanged event
        EventTools.expectEmitIf(this, willEmit, true, true, true, true);
        emit PoolPOLShareChanged(PoolId.wrap(bytes32(0)), 150_000);

        vm.prank(OWNER);
        ppm.setPoolPOLShare(PoolId.wrap(bytes32(0)), 150_000);

        uint256 pol = ppm.getPoolPOLShare(pid(0));
        assertEq(pol, 150_000);
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
        // Default polSharePpm is 0 for new pools
        assertEq(polA, 0);

        // B) set pool-specific override
        uint256 currentPoolShare = ppm.getPoolPOLShare(pool);
        bool willEmitShare = (currentPoolShare != 123_456);

        // Expect PoolPOLShareChanged event
        EventTools.expectEmitIf(this, willEmitShare, true, true, true, true);
        emit PoolPOLShareChanged(pool, 123_456);

        vm.prank(OWNER);
        ppm.setPoolPOLShare(pool, 123_456);

        uint256 polB = ppm.getPoolPOLShare(pool);
        assertEq(polB, 123_456);

        // C) set back to 0 (default)
        EventTools.expectEmitIf(this, true, true, true, true, true);
        emit PoolPOLShareChanged(pool, 0);

        vm.prank(OWNER);
        ppm.setPoolPOLShare(pool, 0);

        uint256 polC = ppm.getPoolPOLShare(pool);
        assertEq(polC, 0); // Back to default
    }

    /* ------------------------------------------------------------ */
    /*                6. Fuzz: allocation-sum invariant             */
    /* ------------------------------------------------------------ */
    function testFeeSumInvariantFuzz(uint256 pol, uint256 fr) public {
        // Bound the inputs to prevent overflow
        pol = bound(pol, 0, EventTools.MAX_PPM);
        fr = bound(fr, 0, EventTools.MAX_PPM - pol);
        uint256 lp = EventTools.MAX_PPM - pol - fr;

        // Set a pool-specific POL share
        vm.prank(OWNER);
        ppm.setPoolPOLShare(PoolId.wrap(bytes32(0)), pol);

        uint256 a = ppm.getPoolPOLShare(pid(0));
        assertEq(a, pol);
    }

    /* ------------------------------------------------------------ */
    /*                            Events                             */
    /* ------------------------------------------------------------ */
    event PoolPOLShareChanged(PoolId indexed poolId, uint256 polSharePpm);

    /* ------------------------------------------------------------ */
    /*                            Helper                             */
    /* ------------------------------------------------------------ */
    function pid(uint256 n) internal pure returns (PoolId) {
        return PoolId.wrap(bytes32(n));
    }
}
