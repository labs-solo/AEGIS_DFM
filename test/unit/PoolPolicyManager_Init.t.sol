// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {PoolPolicyManager} from "src/PoolPolicyManager.sol";
import {PoolId}            from "v4-core/src/types/PoolId.sol";

contract PoolPolicyManagerInitTest is Test {
    PoolPolicyManager ppm;

    address constant OWNER         = address(0xBEEF);
    address constant FEE_COLLECTOR = address(0xFEE);
    uint256 constant PROTOCOL_FEE  = 0.05e18;   // 5 % (scaled by 1e18)

    uint24[] internal _tickSpacings;

    function setUp() public {
        _tickSpacings       = new uint24[](2);
        _tickSpacings[0]    = 1;
        _tickSpacings[1]    = 10;

        ppm = new PoolPolicyManager(
            OWNER,
            5_000,          // defaultDynamicFeePpm = 0.50 %
            _tickSpacings,
            PROTOCOL_FEE,
            FEE_COLLECTOR
        );
    }

    /* -------------------------------------------------------------------------- */
    /*                              Constructor checks                            */
    /* -------------------------------------------------------------------------- */

    function testConstructorSetsOwner() public {
        assertEq(ppm.owner(), OWNER);
    }

    function testConstructorSetsDefaultFeeAllocations() public {
        // (POL share, full-range share, LP share)
        (uint256 pol, uint256 fr, uint256 lp) = ppm.getFeeAllocations(pid(1));
        assertEq(pol, 100_000);   // 10 %
        assertEq(fr ,       0);   // 0  %
        assertEq(lp , 900_000);   // 90 %
    }

    function testConstructorSetsOtherGlobalDefaults() public {
        assertEq(ppm.getMinimumTradingFee() , 100);          // 0.01 %
        assertEq(ppm.getFeeClaimThreshold() , 10_000);       // 1 %
        assertEq(ppm.getDefaultDynamicFee() , 5_000);        // 0.50 %
        assertEq(ppm.defaultPolMultiplier() , 10);           // 10×
        assertEq(ppm.getTickScalingFactor() , 1);
        assertEq(ppm.protocolInterestFeePercentage(), PROTOCOL_FEE);
        assertEq(ppm.getFeeCollector()       , FEE_COLLECTOR);
    }

    function testSupportedTickSpacingsInitialised() public {
        assertTrue (ppm.isTickSpacingSupported(1));
        assertTrue (ppm.isTickSpacingSupported(10));
        assertFalse(ppm.isTickSpacingSupported(60));         // not whitelisted
    }

    function testGetMinimumPOLTarget_UsesDefaultMultiplier() public {
        uint256 tl  = 1e18;      // total liquidity
        uint256 dyn = 3_000;     // 0.30 %
        uint256 exp = tl * dyn * 10 / 1e12;  // tl * fee * mult ÷ 1e12
        assertEq(ppm.getMinimumPOLTarget(pid(7), tl, dyn), exp);
    }

    function testDailyBudgetAndDecayWindowDefaults() public {
        (uint32 budget, uint32 window) = ppm.getBudgetAndWindow(pid(0));
        assertEq(budget, 1e6);          // 1 cap-event per day (ppm)
        assertEq(window, 180 days);     // six-month linear decay
    }

    function testDefaultGetterFallbacks() public {
        PoolId p = pid(42);
        assertEq(ppm.getFreqScaling(p)              , 1e18);
        assertEq(ppm.getMinBaseFee(p)               , 100);
        assertEq(ppm.getMaxBaseFee(p)               , 30_000);
        assertEq(ppm.getSurgeDecayPeriodSeconds(p)  , 3_600);
        assertEq(ppm.getSurgeFeeMultiplierPpm(p)    , 3_000_000);
        assertEq(ppm.getBaseFeeStepPpm(p)           , 20_000);
        assertEq(ppm.getBaseFeeUpdateIntervalSeconds(p), 1 days);
    }

    /* -------------------------------------------------------------------------- */
    /*                                   Helper                                   */
    /* -------------------------------------------------------------------------- */

    function pid(uint256 n) internal pure returns (PoolId) {
        return PoolId.wrap(bytes32(n));
    }
}
