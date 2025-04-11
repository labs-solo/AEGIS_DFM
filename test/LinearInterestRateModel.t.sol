// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LinearInterestRateModel} from "../src/LinearInterestRateModel.sol";
import {IInterestRateModel} from "../src/interfaces/IInterestRateModel.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Errors} from "../src/errors/Errors.sol";
import "./MarginTestBase.t.sol";

contract LinearInterestRateModelTest is MarginTestBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    LinearInterestRateModel localModel;
    address owner = address(this);
    address nonOwner = address(0xDEAD);

    // Standard parameters for most tests
    uint256 constant PRECISION = 1e18;
    uint256 constant SECONDS_PER_YEAR = 365 days;
    uint256 baseRateYear = (2 * PRECISION) / 100; // 0.02 * PRECISION; // 2%
    uint256 kinkRateYear = (10 * PRECISION) / 100; // 0.10 * PRECISION; // 10%
    uint256 kinkUtil = (80 * PRECISION) / 100; // 0.80 * PRECISION; // 80%
    uint256 kinkMultiplier = 5 * PRECISION; // 5x
    uint256 maxUtil = (95 * PRECISION) / 100; // 0.95 * PRECISION; // 95%
    uint256 maxRateYear = 1 * PRECISION; // 1.00 * PRECISION; // 100%

    // Helper poolId
    PoolId testPoolId;

    function setUp() public override {
        // Call parent setup to initialize the shared infrastructure
        super.setUp();
        
        // Setup a local model instance for testing
        localModel = new LinearInterestRateModel(
            owner,
            baseRateYear,
            kinkRateYear,
            kinkUtil,
            kinkMultiplier,
            maxUtil,
            maxRateYear
        );

        // Create a test pool
        (testPoolId, ) = createPoolAndRegister(
            address(fullRange),
            address(liquidityManager),
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            DEFAULT_FEE,
            DEFAULT_TICK_SPACING,
            1 << 96 // SQRT_RATIO_1_1
        );
    }

    // --- Constructor Tests ---

    function test_Constructor_SetsParameters() public {
        (uint256 _base, uint256 _kinkR, uint256 _kinkU, uint256 _maxR, uint256 _kinkM) = localModel.getModelParameters();
        assertEq(_base, baseRateYear, "Base rate mismatch");
        assertEq(_kinkR, kinkRateYear, "Kink rate mismatch");
        assertEq(_kinkU, kinkUtil, "Kink util mismatch");
        assertEq(_maxR, maxRateYear, "Max rate mismatch");
        assertEq(_kinkM, kinkMultiplier, "Kink multiplier mismatch");
        assertEq(localModel.maxUtilizationRate(), maxUtil, "Max util mismatch");
        assertEq(localModel.owner(), owner, "Owner mismatch");
    }

    function test_Revert_Constructor_InvalidMaxUtil() public {
        vm.expectRevert(bytes("IRM: Max util <= 100%"));
        new LinearInterestRateModel(owner, baseRateYear, kinkRateYear, kinkUtil, kinkMultiplier, PRECISION + 1, maxRateYear);
    }

    function test_Revert_Constructor_InvalidKinkUtil() public {
        vm.expectRevert(bytes("IRM: Kink util <= max util"));
        new LinearInterestRateModel(owner, baseRateYear, kinkRateYear, maxUtil + 1, kinkMultiplier, maxUtil, maxRateYear);
    }

     function test_Revert_Constructor_InvalidKinkMultiplier() public {
        vm.expectRevert(bytes("IRM: Kink mult >= 1x"));
        new LinearInterestRateModel(owner, baseRateYear, kinkRateYear, kinkUtil, PRECISION - 1, maxUtil, maxRateYear);
    }

    function test_Revert_Constructor_InvalidKinkRate() public {
        vm.expectRevert(bytes("IRM: Kink rate >= base rate"));
        new LinearInterestRateModel(owner, baseRateYear, baseRateYear - 1, kinkUtil, kinkMultiplier, maxUtil, maxRateYear);
    }

    function test_Revert_Constructor_InvalidMaxRate() public {
        vm.expectRevert(bytes("IRM: Max rate >= kink rate"));
        new LinearInterestRateModel(owner, baseRateYear, kinkRateYear, kinkUtil, kinkMultiplier, maxUtil, kinkRateYear - 1);
    }

    // --- getUtilizationRate Tests ---

    function test_GetUtilization_ZeroSupply() public {
        assertEq(localModel.getUtilizationRate(testPoolId, 100, 0), 0);
    }

     function test_GetUtilization_ZeroBorrowed() public {
        assertEq(localModel.getUtilizationRate(testPoolId, 0, 1000), 0);
    }

    function test_GetUtilization_Half() public {
        assertEq(localModel.getUtilizationRate(testPoolId, 500, 1000), (50 * PRECISION) / 100); // 0.5 * PRECISION);
    }

    function test_GetUtilization_Full() public {
        assertEq(localModel.getUtilizationRate(testPoolId, 1000, 1000), PRECISION);
    }

     function test_GetUtilization_Over() public {
        // Should still calculate correctly, capping happens in getBorrowRate
        assertEq(localModel.getUtilizationRate(testPoolId, 1200, 1000), (120 * PRECISION) / 100); // 1.2 * PRECISION);
    }

    // --- getBorrowRate Tests ---

    function calculateExpectedRate(uint256 util) internal view returns (uint256) {
        uint256 ratePerYear;
        uint256 cappedUtil = util > maxUtil ? maxUtil : util;

        if (cappedUtil <= kinkUtil) {
            if (kinkRateYear < baseRateYear) {
                ratePerYear = baseRateYear;
            } else {
                if (kinkUtil == 0) {
                    ratePerYear = baseRateYear;
                } else {
                    uint256 slope1 = ((kinkRateYear - baseRateYear) * PRECISION) / kinkUtil;
                    ratePerYear = baseRateYear + (slope1 * cappedUtil) / PRECISION;
                }
            }
        } else {
            uint256 excessUtil = cappedUtil - kinkUtil;
            uint256 maxExcessUtil = maxUtil - kinkUtil;

            if (maxRateYear < kinkRateYear || maxExcessUtil == 0) {
                ratePerYear = kinkRateYear;
            } else {
                uint256 slope2_base = ((maxRateYear - kinkRateYear) * PRECISION) / maxExcessUtil;
                uint256 slope2_actual = (slope2_base * kinkMultiplier) / PRECISION;
                ratePerYear = kinkRateYear + (slope2_actual * excessUtil) / PRECISION;
            }
        }

        if (ratePerYear > maxRateYear) {
            ratePerYear = maxRateYear;
        }

        return ratePerYear / SECONDS_PER_YEAR;
    }

    function test_GetBorrowRate_ZeroUtil() public {
        uint256 util = 0;
        uint256 expectedRate = calculateExpectedRate(util);
        assertEq(localModel.getBorrowRate(testPoolId, util), expectedRate, "Rate at 0% util");
    }

    function test_GetBorrowRate_BelowKink() public {
        uint256 util = (40 * PRECISION) / 100; // 0.4 * PRECISION; // 40%
        uint256 expectedRate = calculateExpectedRate(util);
        assertEq(localModel.getBorrowRate(testPoolId, util), expectedRate, "Rate at 40% util");
    }

     function test_GetBorrowRate_AtKink() public {
        uint256 util = kinkUtil; // 80%
        uint256 expectedRate = calculateExpectedRate(util);
        // Expect rate to be exactly kinkRateYear / SECONDS_PER_YEAR
        uint256 expectedKinkRateSec = kinkRateYear / SECONDS_PER_YEAR;
        assertEq(localModel.getBorrowRate(testPoolId, util), expectedKinkRateSec, "Rate at kink util (direct calc)");
        assertEq(localModel.getBorrowRate(testPoolId, util), expectedRate, "Rate at kink util (helper func)");
    }

    function test_GetBorrowRate_AboveKink() public {
        uint256 util = (90 * PRECISION) / 100; // 0.9 * PRECISION; // 90%
        uint256 expectedRate = calculateExpectedRate(util);
        assertEq(localModel.getBorrowRate(testPoolId, util), expectedRate, "Rate at 90% util");
    }

    function test_GetBorrowRate_AtMaxUtil() public {
        uint256 util = maxUtil; // 95%
        uint256 expectedRate = calculateExpectedRate(util);
         assertEq(localModel.getBorrowRate(testPoolId, util), expectedRate, "Rate at max util (95%)");
    }

     function test_GetBorrowRate_AboveMaxUtil() public {
        // Should be capped at the rate corresponding to maxUtil
        uint256 util = (98 * PRECISION) / 100; // 0.98 * PRECISION; // 98%
        uint256 expectedRateAtMaxUtil = calculateExpectedRate(maxUtil); // Calculate expected rate AT maxUtil
        assertEq(localModel.getBorrowRate(testPoolId, util), expectedRateAtMaxUtil, "Rate above max util (should be capped)");
    }

    function test_GetBorrowRate_AtMaxRateLimit() public {
         // Set up parameters where the rate hits maxRateYear before maxUtil
         uint256 highKinkMult = 50 * PRECISION;
         LinearInterestRateModel tempModel = new LinearInterestRateModel(
            owner, baseRateYear, kinkRateYear, kinkUtil, highKinkMult, maxUtil, maxRateYear
         );
         uint256 util = (85 * PRECISION) / 100; // 0.85 * PRECISION; // Should hit max rate before 95% util
         uint256 expectedRate = maxRateYear / SECONDS_PER_YEAR;
         assertEq(tempModel.getBorrowRate(testPoolId, util), expectedRate, "Rate capped by maxRateYear");
    }

    // --- Governance Tests ---

    function test_UpdateParameters_Success() public {
        uint256 newBase = (3 * PRECISION) / 100; // 0.03 * PRECISION;
        uint256 newKinkR = (15 * PRECISION) / 100; // 0.15 * PRECISION;
        uint256 newKinkU = (75 * PRECISION) / 100; // 0.75 * PRECISION;
        uint256 newKinkM = 6 * PRECISION;
        uint256 newMaxU = (98 * PRECISION) / 100; // 0.98 * PRECISION;
        uint256 newMaxR = (120 * PRECISION) / 100; // 1.2 * PRECISION;

        vm.expectEmit(true, true, true, true);
        emit LinearInterestRateModel.ParametersUpdated(
            newBase, newKinkR, newKinkU, newKinkM, newMaxU, newMaxR
        );

        localModel.updateParameters(newBase, newKinkR, newKinkU, newKinkM, newMaxU, newMaxR);

        (uint256 _base, uint256 _kinkR, uint256 _kinkU, uint256 _maxR, uint256 _kinkM) = localModel.getModelParameters();
        assertEq(_base, newBase, "Updated Base rate mismatch");
        assertEq(_kinkR, newKinkR, "Updated Kink rate mismatch");
        assertEq(_kinkU, newKinkU, "Updated Kink util mismatch");
        assertEq(_maxR, newMaxR, "Updated Max rate mismatch");
        assertEq(_kinkM, newKinkM, "Updated Kink multiplier mismatch");
        assertEq(localModel.maxUtilizationRate(), newMaxU, "Updated Max util mismatch");
    }

    function test_Revert_UpdateParameters_NotOwner() public {
         vm.prank(nonOwner);
         vm.expectRevert(bytes("UNAUTHORIZED"));
         localModel.updateParameters(baseRateYear, kinkRateYear, kinkUtil, kinkMultiplier, maxUtil, maxRateYear);
    }

     function test_Revert_UpdateParameters_InvalidParams() public {
        // Example: kink rate < base rate
        vm.expectRevert(bytes("IRM: Kink rate >= base rate"));
        localModel.updateParameters((5 * PRECISION) / 100, (4 * PRECISION) / 100, kinkUtil, kinkMultiplier, maxUtil, maxRateYear);
    }

    // --- Test shared model from MarginTestBase ---
    
    function test_SharedModel_Parameters() public {
        // Verify the shared model from MarginTestBase has proper parameters
        (uint256 _base, uint256 _kinkR, uint256 _kinkU, uint256 _maxR, uint256 _kinkM) = interestRateModel.getModelParameters();
        assertEq(_kinkU, 80 * 1e16, "Shared model kink util");
        assertEq(_base, 2 * 1e16, "Shared model base rate");
        assertEq(_kinkR, 10 * 1e16, "Shared model kink rate"); 
        assertEq(_kinkM, 5 * 1e18, "Shared model kink multiplier");
        assertEq(_maxR, 1 * 1e18, "Shared model max rate");
        assertEq(interestRateModel.maxUtilizationRate(), 95 * 1e16, "Shared model max util");
    }

    function test_SharedModel_GetBorrowRate() public {
        // Test that the shared model works with poolId
        uint256 util = (50 * PRECISION) / 100; // 50%
        uint256 rate = interestRateModel.getBorrowRate(testPoolId, util);
        assertGt(rate, 0, "Shared model rate should be > 0");
        
        // Simple sanity check - rate should be between base and kink rates
        uint256 baseSec = (2 * 1e16) / SECONDS_PER_YEAR;
        uint256 kinkSec = (10 * 1e16) / SECONDS_PER_YEAR;
        assertGt(rate, baseSec, "Rate should be > base rate");
        assertLt(rate, kinkSec, "Rate should be < kink rate");
    }
}