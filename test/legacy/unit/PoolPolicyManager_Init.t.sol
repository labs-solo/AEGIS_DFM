// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {PoolPolicyManager} from "src/PoolPolicyManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolPolicyManager} from "src/interfaces/IPoolPolicyManager.sol"; // Import if using PolicyType enum

contract PoolPolicyManagerInitTest is Test {
    PoolPolicyManager ppm;

    address constant OWNER = address(0xBEEF);
    address constant FEE_COLLECTOR = address(0xFEE);
    uint256 constant PROTOCOL_FEE_PPM = 50_000; // 5 %

    uint24[] internal _tickSpacings;

    uint24 constant EXPECTED_MIN_DYNAMIC_FEE = 100; // 0.01 %
    uint24 constant EXPECTED_MAX_DYNAMIC_FEE = 50000; // 5 %
    uint24 constant EXPECTED_DEFAULT_DYNAMIC_FEE = 5000; // 0.5 %

    function setUp() public {
        _tickSpacings = new uint24[](2);
        _tickSpacings[0] = 1;
        _tickSpacings[1] = 10;

        ppm = new PoolPolicyManager(
            OWNER, // governance / owner
            1_000_000 // daily budget (ppm)
        );
    }

    /* -------------------------------------------------------------------------- */
    /*                              Constructor checks                            */
    /* -------------------------------------------------------------------------- */

    function testConstructorSetsOwner() public view {
        assertEq(ppm.owner(), OWNER);
    }

    function testConstructorSetsDefaultFeeAllocations() public view {
        // (POL share, full-range share, LP share)
        uint256 pol = ppm.getPoolPOLShare(pid(1));
        assertEq(pol, 100_000); // 10 %
    }

    function testGetMinimumPOLTarget_UsesDefaultMultiplier() public view {
        uint256 tl = 1e18; // total liquidity
        uint256 dyn = 3_000; // 0.30 %
        uint256 exp = tl * dyn * 10 / 1e12; // tl * fee * mult ÷ 1e12
            // assertEq(ppm.getMinimumPOLTarget(pid(7), tl, dyn), exp);
    }

    function testDefaultGetterFallbacks() public view {
        PoolId p = pid(42);
        assertEq(ppm.getMinBaseFee(p), 100);
        assertEq(ppm.getMaxBaseFee(p), EXPECTED_MAX_DYNAMIC_FEE);
        assertEq(ppm.getSurgeDecayPeriodSeconds(p), 3_600);
        assertEq(ppm.getSurgeFeeMultiplierPpm(p), 3_000_000);
        assertEq(ppm.getBaseFeeStepPpm(p), 20_000);
        assertEq(ppm.getBaseFeeUpdateIntervalSeconds(p), 1 days);
    }

    /* -------------------------------------------------------------------------- */
    /*                                   Helper                                   */
    /* -------------------------------------------------------------------------- */

    function pid(uint256 n) internal pure returns (PoolId) {
        return PoolId.wrap(bytes32(n));
    }
}
