// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {FullRangeDynamicFeeManager} from "../src/FullRangeDynamicFeeManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

contract FullRangeDynamicFeeManagerTest is Test {
    FullRangeDynamicFeeManager manager;
    
    // Define some pool identifiers for testing
    bytes32 constant PID_A = bytes32(uint256(1));
    bytes32 constant PID_B = bytes32(uint256(2));
    
    // Example fee bounds and surge multiplier for initialization
    uint256 constant MIN_FEE = 500;      // 0.05%
    uint256 constant MAX_FEE = 10000;    // 1.0%
    uint256 constant INITIAL_SURGE = 2000000; // 200% (2x)
    
    function setUp() public {
        // Deploy the contract with initial parameters
        manager = new FullRangeDynamicFeeManager(MIN_FEE, MAX_FEE, INITIAL_SURGE);
    }
    
    function testInitialStateAndOwnership() public {
        // The deployer (this contract) should be the owner
        assertEq(manager.owner(), address(this));
        // Fee bounds and surge multiplier should match constructor inputs
        assertEq(manager.minFeePpm(), MIN_FEE);
        assertEq(manager.maxFeePpm(), MAX_FEE);
        assertEq(manager.surgeMultiplierPpm(), INITIAL_SURGE);
        assertFalse(manager.dynamicFeePaused());
        
        // On first update call for a new pool, it should initialize to midpoint fee and target event rate
        uint256 returnedFee = manager.updateDynamicFee(PID_A, false);
        (uint256 currentFee, uint256 dynamicFee, , uint256 lastBlock, uint256 overrideFee) = manager.pools(PID_A);
        assertEq(currentFee, dynamicFee, "Current fee should equal baseline on init");
        assertEq(dynamicFee, (MIN_FEE + MAX_FEE) / 2, "Initial baseline fee not at midpoint");
        assertEq(returnedFee, currentFee, "Returned fee should match current fee");
        assertEq(overrideFee, 0, "Override should be 0 initially");
        // Event rate should start at target (no cap event on first call)
        (, , uint256 eventRate,,) = manager.pools(PID_A);
        assertEq(eventRate, manager.TARGET_EVENT_RATE_PPM(), "Initial eventRate should start at target");
    }
    
    function testOnlyOwnerRestrictions() public {
        // Verify that only the owner can call governance functions
        address nonOwner = address(0xBEEF);
        
        vm.startPrank(nonOwner);
        vm.expectRevert("UNAUTHORIZED");
        manager.setSurgeMultiplier(1500000);
        
        vm.expectRevert("UNAUTHORIZED");
        manager.setFeeBounds(1000, 2000);
        
        vm.expectRevert("UNAUTHORIZED");
        manager.setDynamicFeeOverride(PID_A, 1000);
        
        vm.expectRevert("UNAUTHORIZED");
        manager.pauseDynamicFee(true);
        vm.stopPrank();
    }
    
    function testSetFeeBoundsAndEnforcement() public {
        // Update fee bounds to new values
        uint256 newMin = 1000;
        uint256 newMax = 50000;
        manager.setFeeBounds(newMin, newMax);
        assertEq(manager.minFeePpm(), newMin);
        assertEq(manager.maxFeePpm(), newMax);
        // Expect an event on setting bounds
        vm.expectEmit(false, false, false, true);
        emit FeeBoundsSet(newMin, newMax);
        manager.setFeeBounds(newMin, newMax);  // calling again with same values to trigger the event for test
        
        // Attempt to set invalid bounds (min > max) and expect revert
        vm.expectRevert("minFee must be <= maxFee");
        manager.setFeeBounds(6000, 5000);
    }
    
    function testSurgeMultiplierGovernance() public {
        // Setting a multiplier below 100% should revert
        vm.expectRevert("Multiplier must be >= 100%");
        manager.setSurgeMultiplier(800000);  // 80%
        
        // Set a new valid surge multiplier
        manager.setSurgeMultiplier(3000000);  // 300% (3x)
        assertEq(manager.surgeMultiplierPpm(), 3000000);
        // Expect event emission
        vm.expectEmit(false, false, false, true);
        emit SurgeMultiplierSet(3000000);
        manager.setSurgeMultiplier(3000000);
    }
    
    function testPauseFunctionality() public {
        // Pause dynamic fee adjustments
        manager.pauseDynamicFee(true);
        assertTrue(manager.dynamicFeePaused());
        // While paused, calling update should not change the fee
        manager.updateDynamicFee(PID_A, true);  // even if a cap event is signaled, it should be ignored
        (uint256 currFee, uint256 dynFee, uint256 eventRate,,) = manager.pools(PID_A);
        assertEq(currFee, dynFee, "Fee changed despite pause");
        // Event rate should remain at initial target (no update to volatility tracking while paused)
        assertEq(eventRate, manager.TARGET_EVENT_RATE_PPM(), "Event rate changed during pause");
        
        // Unpause and verify dynamic updates resume
        manager.pauseDynamicFee(false);
        assertFalse(manager.dynamicFeePaused());
        uint256 oldFee = currFee;
        vm.recordLogs();
        manager.updateDynamicFee(PID_A, false);
        // Expect no event emitted for a small fee change
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 0, "Unexpected DynamicFeeUpdated event after small change");
        (uint256 currFee2,, , ,) = manager.pools(PID_A);
        // Fee should not change drastically after one update post-unpause (likely remains very close to oldFee)
        assertTrue(currFee2 <= oldFee * 105 / 100 && currFee2 >= oldFee * 95 / 100, "Fee changed too much after unpause");
    }
    
    function testDynamicFeeOverrideFeature() public {
        // Perform a couple of updates to change the fee from its initial state
        manager.updateDynamicFee(PID_A, false);
        manager.updateDynamicFee(PID_A, true);  // simulate a cap event to adjust fee upwards
        (uint256 feeAfterEvent, , , ,) = manager.pools(PID_A);
        
        // Set an override fee
        uint256 overrideFee = 7000;
        manager.setDynamicFeeOverride(PID_A, overrideFee);
        (uint256 currFee, uint256 dynFee, , , uint256 overrideVal) = manager.pools(PID_A);
        assertEq(currFee, overrideFee, "Current fee not overridden correctly");
        assertEq(overrideVal, overrideFee, "Override value not stored");
        // Baseline dynamic fee should remain at the last computed value (not forced to override value immediately)
        assertTrue(dynFee != 0 && dynFee <= manager.maxFeePpm() && dynFee >= manager.minFeePpm(), "Baseline fee was incorrectly modified on override");
        
        // While override is active, updateDynamicFee should just return the override fee and not alter state
        uint256 returnedFee = manager.updateDynamicFee(PID_A, true);
        assertEq(returnedFee, overrideFee, "updateDynamicFee did not return override fee");
        (uint256 currFee2, uint256 dynFee2, uint256 eventRate2, , uint256 overrideVal2) = manager.pools(PID_A);
        // State should remain the same under override
        assertEq(currFee2, overrideFee);
        assertEq(overrideVal2, overrideFee);
        assertEq(dynFee2, dynFee, "Baseline fee changed during override");
        assertEq(eventRate2, manager.TARGET_EVENT_RATE_PPM(), "Event rate changed during override");
        
        // Remove override (set feePpm to 0) and confirm dynamic control resumes from the override value
        manager.setDynamicFeeOverride(PID_A, 0);
        (uint256 currFee3, uint256 dynFee3, , , uint256 overrideVal3) = manager.pools(PID_A);
        assertEq(overrideVal3, 0, "Override flag not cleared");
        assertEq(dynFee3, overrideFee, "Baseline fee not reset to last override fee");
        assertEq(currFee3, overrideFee, "Current fee changed unexpectedly when override removed");
        
        // After removing override, the next dynamic update should adjust from the current baseline
        vm.recordLogs();
        uint256 newFee = manager.updateDynamicFee(PID_A, false);
        (,,,, uint256 overrideFeePpm) = manager.pools(PID_A);
        assertEq(overrideFeePpm, 0);
        assertTrue(newFee <= overrideFee, "Fee should stay the same or decrease slightly after override removal");
        // The change should be minor (no event log expected if <=5%)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "Unexpected DynamicFeeUpdated event after override removal");
    }
    
    function testDynamicFeeIncreaseAndSurge() public {
        // Initialize a second pool and simulate consecutive cap events to drive the fee up
        manager.updateDynamicFee(PID_B, false);  // initialize pool B
        // Ensure surge multiplier is set to 2x for predictable behavior
        manager.setSurgeMultiplier(2000000);
        
        (uint256 lastFee, , , ,) = manager.pools(PID_B);
        uint256 iterations = 10;
        for (uint256 i = 0; i < iterations; ++i) {
            vm.recordLogs();
            uint256 newFee = manager.updateDynamicFee(PID_B, true);
            // Fee should never decrease on a cap event
            assertTrue(newFee >= lastFee, "Fee did not increase on cap event");
            // Check for event emission on significant increases
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (newFee * 100 > lastFee * 105) {
                // If fee jumped by more than 5%, an event should be emitted
                assertGt(logs.length, 0, "Expected DynamicFeeUpdated event not emitted for >5% increase");
            }
            lastFee = newFee;
        }
        // After many consecutive events, the fee should hit the maximum bound
        (uint256 finalFee, , , ,) = manager.pools(PID_B);
        assertEq(finalFee, manager.maxFeePpm(), "Fee did not reach the max bound after sustained events");
        // The measured event rate should be very high (near 100%) due to continuous cap events
        (, , uint256 eventRate,,) = manager.pools(PID_B);
        assertTrue(eventRate >= 900000, "Event rate should be >=90% after consecutive events");
    }
    
    function testDynamicFeeDecreaseAndBounds() public {
        // Ramp up the fee for pool A with a few cap events
        manager.updateDynamicFee(PID_A, false);
        for (uint256 i = 0; i < 3; ++i) {
            manager.updateDynamicFee(PID_A, true);
        }
        (uint256 elevatedFee, , , ,) = manager.pools(PID_A);
        assertTrue(elevatedFee > (MIN_FEE + MAX_FEE) / 2, "Fee did not increase above midpoint after events");
        
        // Simulate a long period of inactivity (no cap events) by advancing blocks
        uint256 skipBlocks = 200;
        vm.roll(block.number + skipBlocks);
        // Next update with no event should trigger a significant fee decay
        (uint256 feeBefore, , , ,) = manager.pools(PID_A);
        uint256 newFee = manager.updateDynamicFee(PID_A, false);
        assertTrue(newFee <= feeBefore, "Fee did not decrease after prolonged no-event period");
        assertTrue(newFee >= manager.minFeePpm(), "Fee fell below the minimum bound");
        // After enough no-event updates, the fee should bottom out at the minimum
        for (uint256 i = 0; i < 20; ++i) {
            manager.updateDynamicFee(PID_A, false);
        }
        (uint256 bottomFee, , , ,) = manager.pools(PID_A);
        assertEq(bottomFee, manager.minFeePpm(), "Fee did not floor at the minimum bound after extended inactivity");
    }

    function testPowPpmEfficiency() public {
        // Test the exponentiation by squaring for gas efficiency
        
        // Test with various base values and exponents
        _testPowCase(900000, 10); // 90% base, 10 exponent
        _testPowCase(500000, 100); // 50% base, 100 exponent
        _testPowCase(990000, 1000); // 99% base, 1000 exponent (large exponent)
        
        // Check that the algorithm gives the right results compared to a brute force approach
        uint256 base = 800000; // 80%
        uint256 exp = 5;
        
        // Calculate with _powPpm
        uint256 efficient = _callPowPpm(base, exp);
        
        // Calculate brute force
        uint256 bruteForce = 1000000; // 1.0 in PPM
        for (uint256 i = 0; i < exp; i++) {
            bruteForce = (bruteForce * base) / 1000000;
        }
        
        assertEq(efficient, bruteForce, "Efficient pow calculation doesn't match brute force");
    }
    
    function _testPowCase(uint256 base, uint256 exp) internal {
        uint256 gasBefore = gasleft();
        uint256 result = _callPowPpm(base, exp);
        uint256 gasUsed = gasBefore - gasleft();
        
        // Ensure the result is within reasonable bounds (0 to 1.0)
        assertTrue(result <= 1000000, "Result exceeds 100%");
        
        // Log the gas usage (for informational purposes)
        // console2.log("Gas used for _powPpm(", base, ",", exp, "):", gasUsed);
    }
    
    // Helper to call the internal _powPpm function
    function _callPowPpm(uint256 base, uint256 exp) internal returns (uint256) {
        // Manually construct the calldata for the internal function
        bytes memory callData = abi.encodeWithSignature("testPowPpmPublic(uint256,uint256)", base, exp);
        
        (bool success, bytes memory returnData) = address(manager).call(callData);
        require(success, "Call to powPpm failed");
        
        return abi.decode(returnData, (uint256));
    }

    // Events for testing
    event DynamicFeeUpdated(bytes32 indexed pid, uint256 oldFeePpm, uint256 newFeePpm);
    event DynamicFeeOverrideSet(bytes32 indexed pid, uint256 feePpm);
    event SurgeMultiplierSet(uint256 multiplierPpm);
    event FeeBoundsSet(uint256 minFeePpm, uint256 maxFeePpm);
    event DynamicFeePaused(bool paused);
} 