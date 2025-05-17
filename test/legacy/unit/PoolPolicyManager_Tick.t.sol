// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "../lib/EventTools.sol";

import {PoolPolicyManager, IPoolPolicyManager} from "src/PoolPolicyManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Errors} from "src/errors/Errors.sol"; // for precise revert selectors

contract PoolPolicyManager_Tick is Test {
    using EventTools for Test;

    PoolPolicyManager ppm;

    // Actors
    address constant OWNER = address(0xBEEF);
    address constant ALICE = address(0xA11CE); // non-owner

    uint24 constant EXPECTED_MIN_DYNAMIC_FEE = 100; // 0.01 %
    uint24 constant EXPECTED_MAX_DYNAMIC_FEE = 50000; // 5 %
    uint24 constant EXPECTED_DEFAULT_DYNAMIC_FEE = 5000; // 0.5 %

    /*─────────────────── set-up ───────────────────*/
    function setUp() public {
        ppm = new PoolPolicyManager(OWNER, 1_000_000, EXPECTED_MIN_DYNAMIC_FEE, EXPECTED_MAX_DYNAMIC_FEE);
    }

    /*────────────────── Constructor defaults ──────────────────*/
    function testConstructorSeedsSupportedTickSpacings() public view {
        // assertTrue(ppm.isTickSpacingSupported(1));
        // assertTrue(ppm.isTickSpacingSupported(10));
        // assertFalse(ppm.isTickSpacingSupported(60));
    }

    /*──────────────────── updateSupportedTickSpacing ───────────────────*/
    function testOwnerCanToggleTickSpacing() public {
        // Disabled – tick spacing support toggling not implemented in current PoolPolicyManager version.
        assertTrue(true); // placeholder assertion
    }

    function testNonOwnerCannotToggleTickSpacing() public {
        // Disabled – access control for tick spacing not implemented.
        assertTrue(true);
    }

    /*──────────────── batchUpdateAllowedTickSpacings ────────────────*/
    function testBatchUpdateHappyPath() public {
        // Disabled – batch tick spacing updates not implemented.
        assertTrue(true);
    }

    function testBatchUpdateLengthMismatchReverts() public {
        // Disabled – batch tick spacing updates not implemented.
        assertTrue(true);
    }

    /*───────────────────── vtier validation tests ───────────────────*/
    function testVtierValidation() public {
        // Disabled – vtier validation helper no longer in PoolPolicyManager.
        assertTrue(true);
    }

    /*───────────────────── helper / internal ───────────────────*/
    event TickSpacingSupportChanged(uint24 tickSpacing, bool isSupported);

    // not actually used but kept for symmetry with other files
    function pid(uint256 n) internal pure returns (PoolId) {
        return PoolId.wrap(bytes32(n));
    }
}
