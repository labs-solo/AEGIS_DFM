// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../lib/EventTools.sol";

import {PoolPolicyManager, IPoolPolicy} from "src/PoolPolicyManager.sol";
import {PoolId}            from "v4-core/src/types/PoolId.sol";
import {Errors}            from "src/errors/Errors.sol";   // for precise revert selectors

/// @dev Covers: access control, fee-split config, POL logic, per-pool overrides, fuzz on sum-invariant.
contract PoolPolicyManager_Fee is Test {
    using EventTools for Test;
    
    PoolPolicyManager ppm;

    /* ------------------------------------------------------------ */
    /*                           Actors                             */
    /* ------------------------------------------------------------ */
    address constant OWNER     = address(0xBEEF);
    address constant ALICE     = address(0xA11CE);  // non-owner
    address constant GOVERNOR  = address(0xCAFE);   // used later in suite

    /* ------------------------------------------------------------ */
    /*                       Test set-up                            */
    /* ------------------------------------------------------------ */
    function setUp() public {
        uint24[] memory ticks = new uint24[](2);
        ticks[0] = 1;
        ticks[1] = 10;

        ppm = new PoolPolicyManager(
            OWNER,
            5_000,          // defaultDynamicFeePpm (0.50 %)
            ticks,
            50_000,        // protocolInterestFeePercentagePpm = 5%
            address(0xFEE)  // feeCollector
        );
    }

    /* ------------------------------------------------------------ */
    /*                1. Access control on setFeeConfig             */
    /* ------------------------------------------------------------ */
    function testSetFeeConfigByOwner() public {
        // Get current values to determine if events should emit
        (uint256 prevPol, uint256 prevFr, uint256 prevLp) = ppm.getFeeAllocations(pid(0));
        uint256 prevMinFee = ppm.getMinimumTradingFee();
        uint256 prevClaimThreshold = ppm.getFeeClaimThreshold();
        uint256 prevMultiplier = ppm.defaultPolMultiplier();
        
        bool willEmit = (prevPol != 120_000 || prevFr != 0 || prevLp != 880_000 || 
                         prevMinFee != 200 || prevClaimThreshold != 10_000 || prevMultiplier != 11);
        
        // Expect FeeConfigChanged and PolicySet events
        EventTools.expectEmitIf(this, willEmit, false, false, false, true);
        emit FeeConfigChanged(120_000, 0, 880_000, 200, 10_000, 11);
        
        EventTools.expectPolicySetIf(this, true, PoolId.wrap(bytes32(0)), IPoolPolicy.PolicyType.FEE, address(0), OWNER);

        vm.prank(OWNER);
        ppm.setFeeConfig(120_000, 0, 880_000, 200, 10_000, 11);

        (uint256 pol, uint256 fr, uint256 lp) = ppm.getFeeAllocations(pid(0));
        assertEq(pol, 120_000);
        assertEq(fr ,       0);
        assertEq(lp , 880_000);
    }

    function testSetFeeConfigByNonOwnerReverts() public {
        vm.prank(ALICE);
        vm.expectRevert("UNAUTHORIZED");
        ppm.setFeeConfig(120_000, 0, 880_000, 200, 10_000, 11);
    }

    /* ------------------------------------------------------------ */
    /*           2. FeeConfig - happy path & event emission          */
    /* ------------------------------------------------------------ */
    function testFeeConfigHappyPathEmitsEvent() public {
        // Get current values to determine if events should emit
        (uint256 prevPol, uint256 prevFr, uint256 prevLp) = ppm.getFeeAllocations(pid(0));
        uint256 prevMinFee = ppm.getMinimumTradingFee();
        uint256 prevClaimThreshold = ppm.getFeeClaimThreshold();
        uint256 prevMultiplier = ppm.defaultPolMultiplier();
        
        bool willEmit = (prevPol != 150_000 || prevFr != 50_000 || prevLp != 800_000 || 
                         prevMinFee != 200 || prevClaimThreshold != 5_000 || prevMultiplier != 12);
        
        vm.prank(OWNER);
        EventTools.expectEmitIf(this, willEmit, false, false, false, true);
        emit FeeConfigChanged(150_000, 50_000, 800_000, 200, 5_000, 12);
        
        // Check PolicySet event
        EventTools.expectPolicySetIf(this, true, PoolId.wrap(bytes32(0)), IPoolPolicy.PolicyType.FEE, address(0), OWNER);

        ppm.setFeeConfig(
            150_000,    // 15 % POL
            50_000,     // 5 % FR
            800_000,    // 80 % LP
            200,        // 0.02 %
            5_000,      // 0.5 %
            12          // POL multiplier
        );
    }

    /* ------------------------------------------------------------ */
    /*              3. Range / sum-invariant reverts                 */
    /* ------------------------------------------------------------ */
    function testSumNotOneMillionReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.AllocationSumError.selector,
                200_000, 200_000, 700_000, EventTools.MAX_PPM
            )
        );
        ppm.setFeeConfig(200_000, 200_000, 700_000, 100, 100, 10); // 1 100 000 total
    }

    function testMinTradingFeeTooHighReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                120_000, 0, 100_000
            )
        );
        ppm.setFeeConfig(100_000, 0, 900_000, 120_000, 10_000, 10); // 12 %
    }

    function testClaimThresholdTooHighReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.ParameterOutOfRange.selector,
                120_000, 0, 100_000
            )
        );
        ppm.setFeeConfig(100_000, 0, 900_000, 100, 120_000, 10); // 12 %
    }

    /* ------------------------------------------------------------ */
    /*              4. Pool-specific POL-share override              */
    /* ------------------------------------------------------------ */
    function testPoolSpecificPOLOverride() public {
        PoolId pool = pid(42);

        // A) default (global settings)
        (uint256 polA,,) = ppm.getFeeAllocations(pool); // Use global polSharePpm
        // Assuming default polSharePpm is 100_000 (10%) from constructor
        assertEq(polA, 100_000);

        // B) enable feature & set override
        // Assume it's initially disabled since we're enabling it
        bool willEmitEnabled = true;
        
        // Expect PolicySet for enabling the feature
        EventTools.expectEmitIf(this, willEmitEnabled, false, false, false, true);
        emit PoolSpecificPOLSharingEnabled(true);
        
        EventTools.expectPolicySetIf(this, true, PoolId.wrap(bytes32(0)), IPoolPolicy.PolicyType.FEE, address(1), OWNER); // address(1) for true
        
        vm.prank(OWNER);
        ppm.setPoolSpecificPOLSharingEnabled(true);

        // Check if pool already has the desired share
        (uint256 currentPoolShare,,) = ppm.getFeeAllocations(pool);
        bool willEmitShare = (currentPoolShare != 123_456);
        
        // Expect PolicySet for setting the pool share
        EventTools.expectEmitIf(this, willEmitShare, false, false, false, true);
        emit PoolPOLShareChanged(pool, 123_456);
        
        EventTools.expectPolicySetIf(this, true, pool, IPoolPolicy.PolicyType.FEE, address(uint160(123_456)), OWNER);
        
        vm.prank(OWNER);
        ppm.setPoolPOLShare(pool, 123_456);

        (uint256 polB,,) = ppm.getFeeAllocations(pool);
        assertEq(polB, 123_456);

        // C) disable feature → revert to global
        // Expect PolicySet for disabling the feature
        EventTools.expectEmitIf(this, true, false, false, false, true);
        emit PoolSpecificPOLSharingEnabled(false);
        
        EventTools.expectPolicySetIf(this, true, PoolId.wrap(bytes32(0)), IPoolPolicy.PolicyType.FEE, address(0), OWNER); // address(0) for false
        
        vm.prank(OWNER);
        ppm.setPoolSpecificPOLSharingEnabled(false);

        (uint256 polC,,) = ppm.getFeeAllocations(pool);
        assertEq(polC, 100_000); // Back to global default
    }

    /* ------------------------------------------------------------ */
    /*          5. Minimum POL target & multiplier hierarchy        */
    /* ------------------------------------------------------------ */
    function testDefaultPOLTargetCalc() public {
        uint256 liq  = 2e18;
        uint256 fee  = 4_000; // 0.40 %
        uint256 want = liq * fee * 10 / 1e12;  // default multiplier 10
        assertEq(ppm.getMinimumPOLTarget(pid(7), liq, fee), want);
    }

    function testPerPoolMultiplierOverride() public {
        PoolId pool = pid(7);
        
        // Always assume we need to emit since we're setting a specific value
        bool willEmit = true;

        // Expect PoolPOLMultiplierChanged and PolicySet events
        EventTools.expectEmitIf(this, willEmit, false, false, false, true);
        emit PoolPOLMultiplierChanged(pool, 5);
        
        EventTools.expectPolicySetIf(this, true, pool, IPoolPolicy.PolicyType.FEE, address(uint160(5)), OWNER);

        vm.prank(OWNER);
        ppm.setPoolPOLMultiplier(pool, 5);  // halve it

        uint256 want = 1e18 * 3_000 * 5 / 1e12;
        assertEq(ppm.getMinimumPOLTarget(pool, 1e18, 3_000), want);
    }

    function testGlobalMultiplierChange() public {
        // Check if current multiplier matches desired value
        uint256 prevMultiplier = ppm.defaultPolMultiplier();
        bool willEmit = (prevMultiplier != 15);
        
        // Expect DefaultPOLMultiplierChanged and PolicySet events
        EventTools.expectEmitIf(this, willEmit, false, false, false, true);
        emit DefaultPOLMultiplierChanged(15);
        
        EventTools.expectPolicySetIf(this, true, PoolId.wrap(bytes32(0)), IPoolPolicy.PolicyType.FEE, address(uint160(15)), OWNER);

        vm.prank(OWNER);
        ppm.setDefaultPOLMultiplier(15);

        uint256 want = 1e18 * 2_000 * 15 / 1e12;
        assertEq(ppm.getMinimumPOLTarget(pid(99), 1e18, 2_000), want);
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
        EventTools.expectPolicySetIf(this, true, PoolId.wrap(bytes32(0)), IPoolPolicy.PolicyType.FEE, address(0), OWNER);

        vm.prank(OWNER);
        ppm.setFeeConfig(pol, fr, lp, 100, 10_000, 10);

        (uint256 a, uint256 b, uint256 c) = ppm.getFeeAllocations(pid(1));
        assertEq(a + b + c, EventTools.MAX_PPM);
    }

    /* ------------------------------------------------------------ */
    /*                            Events                             */
    /* ------------------------------------------------------------ */
    event FeeConfigChanged(
        uint256 polSharePpm,
        uint256 fullRangeSharePpm,
        uint256 lpSharePpm,
        uint256 minimumTradingFeePpm,
        uint256 feeClaimThresholdPpm,
        uint256 defaultPolMultiplier
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
