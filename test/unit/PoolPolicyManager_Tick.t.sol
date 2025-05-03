// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../lib/EventTools.sol";

import {PoolPolicyManager, IPoolPolicy} from "src/PoolPolicyManager.sol";
import {PoolId}            from "v4-core/src/types/PoolId.sol";
import {Errors}            from "src/errors/Errors.sol";   // for precise revert selectors

contract PoolPolicyManager_Tick is Test {
    using EventTools for Test;
    
    PoolPolicyManager ppm;

    // Actors
    address constant OWNER = address(0xBEEF);
    address constant ALICE = address(0xA11CE); // non-owner

    /*─────────────────── set-up ───────────────────*/
    function setUp() public {
        uint24[] memory ticks = new uint24[](2);
        ticks[0] = 1;
        ticks[1] = 10;

        ppm = new PoolPolicyManager(
            OWNER,
            5_000,          // defaultDynamicFeePpm
            ticks,
            50_000,        // 5 % protocol interest PPM
            address(0xFEE)  // fee collector
        );
    }

    /*────────────────── Constructor defaults ──────────────────*/
    function testConstructorSeedsSupportedTickSpacings() public {
        assertTrue (ppm.isTickSpacingSupported(1));
        assertTrue (ppm.isTickSpacingSupported(10));
        assertFalse(ppm.isTickSpacingSupported(60));
    }

    /*──────────────────── updateSupportedTickSpacing ───────────────────*/
    function testOwnerCanToggleTickSpacing() public {
        // Check if tick spacing 60 is already supported (shouldn't be)
        bool prevSupported = ppm.isTickSpacingSupported(60);
        bool willEmit = !prevSupported; // Only emit if changing from unsupported to supported
        
        EventTools.expectEmitIf(this, willEmit, false, false, false, true);
        emit TickSpacingSupportChanged(60, true);
        
        // Check PolicySet event
        EventTools.expectPolicySetIf(this, true, PoolId.wrap(bytes32(0)), IPoolPolicy.PolicyType.VTIER, address(1), OWNER);

        vm.prank(OWNER);
        ppm.updateSupportedTickSpacing(60, true);

        assertTrue(ppm.isTickSpacingSupported(60));
    }

    function testNonOwnerCannotToggleTickSpacing() public {
        vm.prank(ALICE);
        vm.expectRevert("UNAUTHORIZED");
        ppm.updateSupportedTickSpacing(60, true);
    }

    /*──────────────── batchUpdateAllowedTickSpacings ────────────────*/
    function testBatchUpdateHappyPath() public {
        uint24[] memory arr = new uint24[](2);
        bool[] memory flags = new bool[](2);
        arr[0]   = 60; flags[0] = true;
        arr[1]   = 10; flags[1] = false; // disable existing

        // Check if current states match desired states (to know if events should emit)
        bool is60Supported = ppm.isTickSpacingSupported(60);
        bool is10Supported = ppm.isTickSpacingSupported(10);
        bool willEmit60 = (is60Supported != true);
        bool willEmit10 = (is10Supported != false);
        
        // Expect multiple TickSpacingSupportChanged and PolicySet events
        EventTools.expectEmitIf(this, willEmit60, false, false, false, true);
        emit TickSpacingSupportChanged(60, true);
        
        EventTools.expectPolicySetIf(this, true, PoolId.wrap(bytes32(0)), IPoolPolicy.PolicyType.VTIER, address(1), OWNER);

        EventTools.expectEmitIf(this, willEmit10, false, false, false, true);
        emit TickSpacingSupportChanged(10, false);
        
        EventTools.expectPolicySetIf(this, true, PoolId.wrap(bytes32(0)), IPoolPolicy.PolicyType.VTIER, address(0), OWNER);

        vm.prank(OWNER);
        ppm.batchUpdateAllowedTickSpacings(arr, flags);

        assertTrue (ppm.isTickSpacingSupported(60));
        assertFalse(ppm.isTickSpacingSupported(10));
    }

    function testBatchUpdateLengthMismatchReverts() public {
        uint24[] memory arr = new uint24[](1);
        bool[] memory flg = new bool[](2);

        arr[0] = 60; flg[0] = true; flg[1] = true;

        vm.prank(OWNER);
        vm.expectRevert(Errors.ArrayLengthMismatch.selector);
        ppm.batchUpdateAllowedTickSpacings(arr, flg);
    }

    /*─────────────────── Tick-scaling factor ───────────────────*/
    function testOwnerCanSetTickScalingFactor() public {
        // Check if current value matches desired value
        int24 prevFactor = ppm.getTickScalingFactor();
        bool willEmit = (prevFactor != 3);
        
        // Expect PolicySet event
        EventTools.expectPolicySetIf(this, true, PoolId.wrap(bytes32(0)), IPoolPolicy.PolicyType.VTIER, address(uint160(3)), OWNER);

        vm.prank(OWNER);
        ppm.setTickScalingFactor(3);
        assertEq(ppm.getTickScalingFactor(), 3);
    }

    function testSetTickScalingFactorZeroReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                0, 1, type(uint24).max
            )
        );
        ppm.setTickScalingFactor(0);
    }

    function testNonOwnerSetTickScalingFactorReverts() public {
        vm.prank(ALICE);
        vm.expectRevert("UNAUTHORIZED");
        ppm.setTickScalingFactor(5);
    }

    /*───────────────────── isValidVtier table tests ───────────────────*/
    function testIsValidVtierStaticFees() public {
        // fee, tickSpacing, expected
        _assertVtier(100,    1,   true);
        _assertVtier(500,    10,  true);
        _assertVtier(3_000,  60,  false);  // 60 not yet supported
        // enable 60 then re-check
        vm.prank(OWNER);
        ppm.updateSupportedTickSpacing(60, true);
        _assertVtier(3_000,  60,  true);
        _assertVtier(10_000, 200, false);  // unsupported spacing
        _assertVtier(999,    1,   false);  // wrong fee for spacing
    }

    function testIsValidVtierDynamicFeeFlagBypassesFeeRules() public {
        // Fee with high-bit flag + supported spacing → always true
        assertTrue(ppm.isValidVtier(0x800000, 1));
        assertTrue(ppm.isValidVtier(0x800000, 10));

        // Unsupported spacing → still false
        assertFalse(ppm.isValidVtier(0x800000, 200));
    }

    /*───────────────────── helper / internal ───────────────────*/
    event TickSpacingSupportChanged(uint24 tickSpacing, bool isSupported);

    function _assertVtier(uint24 fee, int24 spacing, bool expected) internal {
        bool ok = ppm.isValidVtier(fee, spacing);
        assertEq(ok, expected, "vtier mismatch");
    }

    // not actually used but kept for symmetry with other files
    function pid(uint256 n) internal pure returns (PoolId) {
        return PoolId.wrap(bytes32(n));
    }
}
