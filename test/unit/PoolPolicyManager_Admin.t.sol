// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "../lib/EventTools.sol";

import {PoolPolicyManager, IPoolPolicy} from "src/PoolPolicyManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Errors} from "src/errors/Errors.sol";
import {PrecisionConstants} from "src/libraries/PrecisionConstants.sol";

contract PoolPolicyManager_Admin_Test is Test {
    uint24 constant EXPECTED_MIN_DYNAMIC_FEE = 100; // 0.01 %
    uint24 constant EXPECTED_MAX_DYNAMIC_FEE = 50000; // 5 %
    uint24 constant EXPECTED_DEFAULT_DYNAMIC_FEE = 5000; // 0.5 %

    using EventTools for Test;

    PoolPolicyManager ppm;

    address constant OWNER = address(0xBEEF);
    address constant GOVERNANCE = address(0xCAFE);
    address constant ALICE = address(0xA11CE); // unauthorized
    address constant NEW_FEE_CO = address(0xF00D);
    address constant RVSTR = address(0xDEAD); // reinvestor

    /*────────────────── setup ──────────────────*/
    function setUp() public {
        uint24[] memory supportedTickSpacings = new uint24[](2);
        supportedTickSpacings[0] = 1;
        supportedTickSpacings[1] = 10;

        ppm = new PoolPolicyManager(
            OWNER,
            EXPECTED_DEFAULT_DYNAMIC_FEE,
            supportedTickSpacings,
            1_000_000,
            address(this),
            EXPECTED_MIN_DYNAMIC_FEE,
            EXPECTED_MAX_DYNAMIC_FEE
        );
    }

    /*──────────────── setProtocolFeePercentage ───────────────*/
    function testOwnerUpdatesProtocolFeePercentage() public {
        uint256 newPpm = 80_000; // 8 %

        // Get current value to determine if event should emit
        uint256 prevPpm = ppm.getProtocolFeePercentage(pid(0));
        bool willEmit = (prevPpm != newPpm);

        EventTools.expectEmitIf(this, willEmit, false, false, false, true);
        emit ProtocolInterestFeePercentageChanged(newPpm);

        // Also expect the PolicySet event
        EventTools.expectPolicySetIf(
            this, true, PoolId.wrap(bytes32(0)), IPoolPolicy.PolicyType.INTEREST_FEE, address(0), OWNER
        );

        vm.prank(OWNER);
        ppm.setProtocolFeePercentage(newPpm);

        assertEq(ppm.getProtocolFeePercentage(pid(0)), newPpm);
    }

    function testProtocolFeeAbove100Reverts() public {
        vm.prank(OWNER);
        // Updated revert message check and test value to be above MAX_PPM
        vm.expectRevert("PPM: <= 1e6");
        ppm.setProtocolFeePercentage(EventTools.MAX_PPM + 1); // > 100% PPM
    }

    function testProtocolFeeMax100IsAllowed() public {
        vm.prank(OWNER);
        // This should now succeed since 1e6 (100%) is allowed
        ppm.setProtocolFeePercentage(EventTools.MAX_PPM);
        assertEq(ppm.getProtocolFeePercentage(pid(0)), EventTools.MAX_PPM);
    }

    function testProtocolFeeSetterNonOwnerReverts() public {
        vm.prank(ALICE);
        vm.expectRevert("UNAUTHORIZED"); // Keep existing correct revert string
        ppm.setProtocolFeePercentage(20_000); // 2% PPM
    }

    /*──────────────────── setFeeCollector ────────────────────*/
    function testOwnerUpdatesFeeCollector() public {
        // Check if current collector matches desired value
        address prevCollector = ppm.getFeeCollector();
        bool willEmit = (prevCollector != NEW_FEE_CO);

        EventTools.expectEmitIf(this, willEmit, false, false, false, true);
        emit FeeCollectorChanged(NEW_FEE_CO);

        // Also expect the PolicySet event
        EventTools.expectPolicySetIf(
            this, true, PoolId.wrap(bytes32(0)), IPoolPolicy.PolicyType.INTEREST_FEE, NEW_FEE_CO, OWNER
        );

        vm.prank(OWNER);
        ppm.setFeeCollector(NEW_FEE_CO);

        assertEq(ppm.getFeeCollector(), NEW_FEE_CO);
    }

    function testSetFeeCollectorZeroReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(Errors.ZeroAddress.selector);
        ppm.setFeeCollector(address(0));
    }

    function testSetFeeCollectorNonOwnerReverts() public {
        vm.prank(ALICE);
        vm.expectRevert("UNAUTHORIZED");
        ppm.setFeeCollector(NEW_FEE_CO);
    }

    /*────────────────── setAuthorizedReinvestor ───────────────*/
    function testOwnerAuthorisesReinvestor() public {
        // Check if reinvestor is already authorized
        bool isAlreadyAuthorized = ppm.authorizedReinvestors(RVSTR);
        bool willEmit = !isAlreadyAuthorized;

        EventTools.expectEmitIf(this, willEmit, true, true, true, false);
        emit AuthorizedReinvestorSet(RVSTR, true);

        // Also expect the PolicySet event
        EventTools.expectPolicySetIf(
            this, true, PoolId.wrap(bytes32(0)), IPoolPolicy.PolicyType.REINVESTOR_AUTH, RVSTR, OWNER
        );

        vm.prank(OWNER);
        ppm.setAuthorizedReinvestor(RVSTR, true);

        assertTrue(ppm.authorizedReinvestors(RVSTR));
    }

    function testReinvestorZeroAddressReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(Errors.ZeroAddress.selector);
        ppm.setAuthorizedReinvestor(address(0), true);
    }

    function testReinvestorSetterNonOwnerReverts() public {
        vm.prank(ALICE);
        vm.expectRevert("UNAUTHORIZED");
        ppm.setAuthorizedReinvestor(RVSTR, true);
    }

    /*────────────────── initializePolicies access ─────────────*/
    function testInitializePoliciesByOwner() public {
        PoolId pool = pid(1);
        address[] memory impls = _implArray();

        // Expect multiple PolicySet events
        EventTools.expectPolicySetIf(this, true, pool, IPoolPolicy.PolicyType(0), impls[0], OWNER);
        EventTools.expectPolicySetIf(this, true, pool, IPoolPolicy.PolicyType(1), impls[1], OWNER);
        EventTools.expectPolicySetIf(this, true, pool, IPoolPolicy.PolicyType(2), impls[2], OWNER);
        EventTools.expectPolicySetIf(this, true, pool, IPoolPolicy.PolicyType(3), impls[3], OWNER);

        vm.prank(OWNER);
        ppm.initializePolicies(pool, GOVERNANCE, impls);
    }

    function testInitializePoliciesByGovernance() public {
        PoolId pool = pid(2);
        address[] memory impls = _implArray();

        // Expect multiple PolicySet events
        EventTools.expectPolicySetIf(this, true, pool, IPoolPolicy.PolicyType(0), impls[0], GOVERNANCE);
        EventTools.expectPolicySetIf(this, true, pool, IPoolPolicy.PolicyType(1), impls[1], GOVERNANCE);
        EventTools.expectPolicySetIf(this, true, pool, IPoolPolicy.PolicyType(2), impls[2], GOVERNANCE);
        EventTools.expectPolicySetIf(this, true, pool, IPoolPolicy.PolicyType(3), impls[3], GOVERNANCE);

        vm.prank(GOVERNANCE);
        ppm.initializePolicies(pool, GOVERNANCE, impls);
    }

    function testInitializePoliciesWrongLengthReverts() public {
        address[] memory impls = new address[](3); // should be 4
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidPolicyImplementationsLength.selector, 3));
        ppm.initializePolicies(pid(3), GOVERNANCE, impls);
    }

    function testInitializePoliciesZeroImplReverts() public {
        address[] memory impls = _implArray();
        impls[2] = address(0);

        vm.prank(OWNER);
        vm.expectRevert(Errors.ZeroAddress.selector);
        ppm.initializePolicies(pid(4), GOVERNANCE, impls);
    }

    function testInitializePoliciesUnauthorizedSenderReverts() public {
        address[] memory impls = _implArray();

        vm.prank(ALICE);
        vm.expectRevert(Errors.Unauthorized.selector);
        ppm.initializePolicies(pid(5), GOVERNANCE, impls);
    }

    /*────────────────── Daily budget & decay window ───────────*/
    function testOwnerUpdatesBudgetAndWindow() public {
        // Get current values to determine if events should emit
        ppm.getBudgetAndWindow(pid(0)); // call to read state, discard return values - silence 2072

        // Set the new values
        vm.prank(OWNER);
        ppm.setDailyBudgetPpm(2_000_000); // 2 caps/day

        vm.prank(OWNER);
        ppm.setDecayWindow(90 days);

        (uint32 budget, uint32 window) = ppm.getBudgetAndWindow(pid(0));
        assertEq(budget, 2_000_000);
        assertEq(window, 90 days);
    }

    /*───────────────── helpers & events ─────────────────*/
    event ProtocolInterestFeePercentageChanged(uint256 newPpm);
    event FeeCollectorChanged(address newCollector);
    event AuthorizedReinvestorSet(address indexed reinvestor, bool isAuthorized);

    function _implArray() internal pure returns (address[] memory arr) {
        arr = new address[](4);
        arr[0] = address(0x01);
        arr[1] = address(0x02);
        arr[2] = address(0x03);
        arr[3] = address(0x04);
    }

    function pid(uint256 n) internal pure returns (PoolId) {
        return PoolId.wrap(bytes32(n));
    }
}
