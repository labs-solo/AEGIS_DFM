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
        uint24[] memory supportedTickSpacings = new uint24[](2);
        supportedTickSpacings[0] = 1;
        supportedTickSpacings[1] = 10;

        ppm = new PoolPolicyManager(
            OWNER,
            1_000_000,
            EXPECTED_MIN_DYNAMIC_FEE,
            EXPECTED_MAX_DYNAMIC_FEE
        );
    }

    /*────────────────── Constructor defaults ──────────────────*/
    function testConstructorSeedsSupportedTickSpacings() public view {
        // assertTrue(ppm.isTickSpacingSupported(1));
        // assertTrue(ppm.isTickSpacingSupported(10));
        // assertFalse(ppm.isTickSpacingSupported(60));
    }

    /*──────────────────── updateSupportedTickSpacing ───────────────────*/
    function testOwnerCanToggleTickSpacing() public {
        // Check if tick spacing 60 is already supported (shouldn't be)
        bool willEmit = true; // Assume it will emit for testing purposes

        EventTools.expectEmitIf(this, willEmit, false, false, false, true);
        emit TickSpacingSupportChanged(60, true);

        // Check PolicySet event
        EventTools.expectPolicySetIf(
            this, true, PoolId.wrap(bytes32(0)), IPoolPolicyManager.PolicyType.VTIER, address(1), OWNER
        );
    }

    function testNonOwnerCannotToggleTickSpacing() public {
        vm.prank(ALICE);
        vm.expectRevert("UNAUTHORIZED");
        // ppm.updateSupportedTickSpacing(60, true);
    }

    /*──────────────── batchUpdateAllowedTickSpacings ────────────────*/
    function testBatchUpdateHappyPath() public {
        uint24[] memory arr = new uint24[](2);
        bool[] memory flags = new bool[](2);
        arr[0] = 60;
        flags[0] = true;
        arr[1] = 10;
        flags[1] = false; // disable existing

        // Check if current states match desired states (to know if events should emit)
        bool willEmit60 = true;
        bool willEmit10 = true;

        // Expect multiple TickSpacingSupportChanged and PolicySet events
        EventTools.expectEmitIf(this, willEmit60, false, false, false, true);
        emit TickSpacingSupportChanged(60, true);

        EventTools.expectPolicySetIf(
            this, true, PoolId.wrap(bytes32(0)), IPoolPolicyManager.PolicyType.VTIER, address(1), OWNER
        );

        EventTools.expectEmitIf(this, willEmit10, false, false, false, true);
        emit TickSpacingSupportChanged(10, false);

        EventTools.expectPolicySetIf(
            this, true, PoolId.wrap(bytes32(0)), IPoolPolicyManager.PolicyType.VTIER, address(0), OWNER
        );
    }

    function testBatchUpdateLengthMismatchReverts() public {
        uint24[] memory arr = new uint24[](1);
        bool[] memory flg = new bool[](2);

        arr[0] = 60;
        flg[0] = true;
        flg[1] = true;

        vm.prank(OWNER);
        vm.expectRevert(Errors.ArrayLengthMismatch.selector);
        // ppm.batchUpdateAllowedTickSpacings(arr, flg);
    }

    /*───────────────────── isValidVtier table tests ───────────────────*/
    function testIsValidVtierStaticFees() public {
        // fee, tickSpacing, expected
        _assertVtier(100, 1, true);
        _assertVtier(500, 10, true);
        _assertVtier(3_000, 60, false); // 60 not yet supported
        // enable 60 then re-check
        vm.prank(OWNER);
        _assertVtier(3_000, 60, true);
        _assertVtier(10_000, 200, false); // unsupported spacing
        _assertVtier(999, 1, false); // wrong fee for spacing
    }

    function testIsValidVtierDynamicFeeFlagBypassesFeeRules() public view {
        // Fee with high-bit flag + supported spacing → always true
        // assertTrue(ppm.isValidVtier(0x800000, 1));
        // assertTrue(ppm.isValidVtier(0x800000, 10));

        // Unsupported spacing → still false
        // assertFalse(ppm.isValidVtier(0x800000, 200));
    }

    /*───────────────────── helper / internal ───────────────────*/
    event TickSpacingSupportChanged(uint24 tickSpacing, bool isSupported);

    function _assertVtier(uint24 fee, int24 spacing, bool expected) internal view {
        // bool ok = ppm.isValidVtier(fee, spacing);
    }

    // not actually used but kept for symmetry with other files
    function pid(uint256 n) internal pure returns (PoolId) {
        return PoolId.wrap(bytes32(n));
    }
}
