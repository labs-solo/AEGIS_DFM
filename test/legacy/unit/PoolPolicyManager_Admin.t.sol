// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "../lib/EventTools.sol";

import {PoolPolicyManager, IPoolPolicyManager} from "src/PoolPolicyManager.sol";
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

    address constant RVSTR = address(0xDEAD); // reinvestor

    /*────────────────── setup ──────────────────*/
    function setUp() public {
        uint24[] memory supportedTickSpacings = new uint24[](2);
        supportedTickSpacings[0] = 1;
        supportedTickSpacings[1] = 10;

        ppm = new PoolPolicyManager(
            OWNER,
            1_000_000, // dailyBudget
            EXPECTED_MIN_DYNAMIC_FEE,
            EXPECTED_MAX_DYNAMIC_FEE
        );
    }

    /*──────────────── setProtocolFeePercentage ───────────────*/
    function testOwnerUpdatesProtocolFeePercentage() public {
        uint256 newPpm = 80_000; // 8 %

        // Get current value to determine if event should emit
        (uint256 prevPpm,,) = ppm.getFeeAllocations(pid(0));
        bool willEmit = (prevPpm != newPpm);

        EventTools.expectEmitIf(this, willEmit, false, false, false, true);
        emit FeeConfigChanged(newPpm, 0, 1_000_000 - newPpm, EXPECTED_MIN_DYNAMIC_FEE);

        // Also expect the PolicySet event
        EventTools.expectPolicySetIf(
            this, true, PoolId.wrap(bytes32(0)), IPoolPolicyManager.PolicyType.FEE, address(0), OWNER
        );

        vm.prank(OWNER);
        ppm.setFeeConfig(newPpm, 0, 1_000_000 - newPpm, EXPECTED_MIN_DYNAMIC_FEE, 10_000);

        (uint256 actualPpm,,) = ppm.getFeeAllocations(pid(0));
        assertEq(actualPpm, newPpm);
    }

    function testProtocolFeeAbove100Reverts() public {
        vm.prank(OWNER);
        // Test with a value above MAX_PPM (1_000_000)
        vm.expectRevert(abi.encodeWithSelector(Errors.AllocationSumError.selector, 1_100_000, 0, 0, 1_000_000));
        ppm.setFeeConfig(1_100_000, 0, 0, EXPECTED_MIN_DYNAMIC_FEE, 10_000); // 110% PPM
    }

    function testProtocolFeeMax100IsAllowed() public {
        vm.prank(OWNER);
        // This should now succeed since 1e6 (100%) is allowed
        ppm.setFeeConfig(EventTools.MAX_PPM, 0, 0, EXPECTED_MIN_DYNAMIC_FEE, 10_000);
        (uint256 actualPpm,,) = ppm.getFeeAllocations(pid(0));
        assertEq(actualPpm, EventTools.MAX_PPM);
    }

    function testProtocolFeeSetterNonOwnerReverts() public {
        vm.prank(ALICE);
        vm.expectRevert("UNAUTHORIZED"); // Keep existing correct revert string
        ppm.setFeeConfig(20_000, 0, 980_000, EXPECTED_MIN_DYNAMIC_FEE, 10_000); // 2% PPM
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
    event FeeConfigChanged(
        uint256 polSharePpm, uint256 fullRangeSharePpm, uint256 lpSharePpm, uint256 minimumTradingFeePpm
    );

    event AuthorizedReinvestorSet(address indexed reinvestor, bool isAuthorized);

    function _implArray() internal pure returns (address[] memory) {
        address[] memory impls = new address[](4);
        impls[0] = address(0xF001);
        impls[1] = address(0xF002);
        impls[2] = address(0xF003);
        impls[3] = address(0xF004);
        return impls;
    }

    function pid(uint256 n) internal pure returns (PoolId) {
        return PoolId.wrap(bytes32(n));
    }
}
