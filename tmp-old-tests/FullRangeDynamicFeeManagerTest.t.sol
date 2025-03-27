// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/*
 * This test file has been moved to old-tests and commented out.
 * It is kept for reference but is no longer used in the project.
 * The new testing approach uses LocalUniswapV4TestBase.t.sol for local deployments.
 */

/*

import "forge-std/Test.sol";
import {FullRangeDynamicFeeManager} from "../src/FullRangeDynamicFeeManager.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IFeePolicy} from "../src/interfaces/IFeePolicy.sol";
import {MathUtils} from "../src/libraries/MathUtils.sol";
import {IFullRangeOracleManager} from "../src/interfaces/IFullRangeOracleManager.sol";

// Mock Fee Policy for testing
contract MockFeePolicy is IFeePolicy {
    uint256 public defaultFee = 3000; // 0.3%
    uint256 public minFee = 100; // 0.01%
    uint256 public maxFee = 100000; // 10%
    uint256 public feeUpdateInterval = 86400; // 24 hours
    uint256 public maxIncrease = 10; // 10%
    uint256 public maxDecrease = 5; // 5%
    uint256 public targetEventRate = 1000;
    mapping(PoolId => int256) public eventDeviations;
    
    function setEventDeviation(PoolId poolId, int256 deviation) external {
        eventDeviations[poolId] = deviation;
    }
    
    function getDefaultDynamicFee() external view returns (uint256) {
        return defaultFee;
    }
    
    function getFeeUpdateInterval() external view returns (uint256) {
        return feeUpdateInterval;
    }
    
    function getMaxFeeIncrease() external view returns (uint256) {
        return maxIncrease;
    }
    
    function getMaxFeeDecrease() external view returns (uint256) {
        return maxDecrease;
    }
    
    function getMinFeePpm() external view returns (uint256) {
        return minFee;
    }
    
    function getMaxFeePpm() external view returns (uint256) {
        return maxFee;
    }
    
    function getTargetEventRate() external view returns (uint256) {
        return targetEventRate;
    }
    
    function getEventRateDeviation(PoolId poolId) external view returns (int256) {
        return eventDeviations[poolId];
    }
    
    function getMinimumTradingFee() external view returns (uint256) {
        return minFee;
    }
    
    // Other functions required by the interface
    function getLPFeeShare() external pure returns (uint256) { return 0; }
    function getFullRangeFeeShare() external pure returns (uint256) { return 0; }
    function getPOLFeeShare() external pure returns (uint256) { return 0; }
    function getPOLMultiplier() external pure returns (uint256) { return 0; }
    function getDefaultDynamicOverrideFee() external pure returns (uint256) { return 0; }
    function getGlobalDynamicOverrideFee() external pure returns (uint256) { return 0; }
    function getPoolOverrideFee(PoolId) external pure returns (uint256) { return 0; }
    function isDynamicFeeGloballyOverridden() external pure returns (bool) { return false; }
    function isPoolDynamicFeeOverridden(PoolId) external pure returns (bool) { return false; }
    function getPoolSpread(PoolId) external pure returns (uint256) { return 0; }
    function getPoolStartingLimitPrice(PoolId) external pure returns (uint256) { return 0; }
}

// Mock Oracle Manager for testing
contract MockOracleManager is IFullRangeOracleManager {
    mapping(PoolId => bool) public capEventStatus;
    
    function setCapEventStatus(PoolId poolId, bool status) external {
        capEventStatus[poolId] = status;
    }
    
    function isPoolInCapEvent(PoolId poolId) external view returns (bool) {
        return capEventStatus[poolId];
    }
    
    // Other functions required by the interface
    function getLatestPrice(PoolId) external pure returns (uint256) { return 0; }
    function getLatestTimeWeightedPrice(PoolId, uint32) external pure returns (uint256) { return 0; }
    function getPriceDeviationPercent(PoolId, uint32) external pure returns (uint256) { return 0; }
    function getCapEventStatus(PoolId) external pure returns (bool) { return false; }
    function getWindowPriceVolatilityInBips(PoolId) external pure returns (uint32) { return 0; }
    function updatePrice(PoolId, uint160) external {}
}

contract FullRangeDynamicFeeManagerTest is Test {
    FullRangeDynamicFeeManager manager;
    MockFeePolicy feePolicy;
    MockOracleManager oracleManager;
    
    address fullRangeAddress = address(0x123);
    address owner = address(0x456);
    
    // Test PoolId
    bytes32 poolIdBytes = bytes32(uint256(1));
    PoolId poolId;
    
    function setUp() public {
        feePolicy = new MockFeePolicy();
        oracleManager = new MockOracleManager();
        
        // Create manager with owner, policy, and fullRange address
        manager = new FullRangeDynamicFeeManager(owner, feePolicy, fullRangeAddress);
        
        // Setup pool ID
        poolId = PoolId.wrap(poolIdBytes);
        
        // Set up oracleManager
        vm.startPrank(fullRangeAddress);
        oracleManager.setCapEventStatus(poolId, false);
        vm.stopPrank();
    }
    
    function testInitialState() public {
        assertEq(manager.surgePriceMultiplier(), 2000000); // 2x default
        assertEq(manager.surgeDuration(), 86400); // 24h default
        assertEq(manager.surgeTriggerLevel(), 200000); // 20% default
        assertEq(address(manager.feePolicy()), address(feePolicy));
        assertEq(manager.fullRangeAddress(), fullRangeAddress);
    }
    
    function testUpdateDynamicFeeIfNeeded_Initialization() public {
        // Call as fullRange
        vm.startPrank(fullRangeAddress);
        
        (uint256 baseFee, uint256 surgeFee, bool wasUpdated) = 
            manager.updateDynamicFeeIfNeeded(poolId, address(oracleManager));
        
        // Should initialize with default values
        assertEq(baseFee, 3000); // 0.3% default from policy
        assertEq(surgeFee, 3000); // Same as base fee (no surge)
        assertTrue(wasUpdated);
        
        vm.stopPrank();
    }
    
    function testUpdateDynamicFee_WithCapEvent() public {
        // Set up CAP event and deviation
        vm.startPrank(fullRangeAddress);
        oracleManager.setCapEventStatus(poolId, true);
        vm.stopPrank();
        
        // Set significant positive deviation
        feePolicy.setEventDeviation(poolId, 500);
        
        // Call as owner
        vm.startPrank(owner);
        (uint256 newFee, bool surgeEnabled) = manager.updateDynamicFee(poolId, true);
        vm.stopPrank();
        
        // Should apply significant increase
        assertEq(newFee, 3300); // 3000 + 10% = 3300
        assertTrue(surgeEnabled);
        
        // Get current fees
        (uint256 baseFee, uint256 surgeFee) = manager.getCurrentFees(poolId);
        
        // Should have base fee and surge fee
        assertEq(baseFee, 3300);
        assertEq(surgeFee, 6600); // 3300 * 2x = 6600
    }
    
    function testSurgeDecay() public {
        // Set up CAP event and deviation
        vm.startPrank(fullRangeAddress);
        oracleManager.setCapEventStatus(poolId, true);
        vm.stopPrank();
        
        // Set significant positive deviation
        feePolicy.setEventDeviation(poolId, 500);
        
        // Call as owner to trigger surge
        vm.startPrank(owner);
        manager.updateDynamicFee(poolId, true);
        vm.stopPrank();
        
        // Initial surge fee check
        (uint256 initialBaseFee, uint256 initialSurgeFee) = manager.getCurrentFees(poolId);
        assertEq(initialBaseFee, 3300);
        assertEq(initialSurgeFee, 6600); // 3300 * 2x = 6600
        
        // Warp forward 25% of decay time
        vm.warp(block.timestamp + 21600); // 6 hours = 25% of 24 hours
        
        // Check fees after 25% decay
        (uint256 baseFee25, uint256 surgeFee25) = manager.getCurrentFees(poolId);
        assertEq(baseFee25, 3300); // Base fee unchanged
        assertEq(surgeFee25, 5775); // 3300 + (3300 * 75% = 2475) = 5775
        
        // Warp forward to 50% of decay time
        vm.warp(block.timestamp + 21600); // Another 6 hours
        
        // Check fees after 50% decay
        (uint256 baseFee50, uint256 surgeFee50) = manager.getCurrentFees(poolId);
        assertEq(baseFee50, 3300); // Base fee unchanged
        assertEq(surgeFee50, 4950); // 3300 + (3300 * 50% = 1650) = 4950
        
        // Warp forward to 100% decay
        vm.warp(block.timestamp + 43200); // Another 12 hours
        
        // Check fees after full decay
        (uint256 baseFee100, uint256 surgeFee100) = manager.getCurrentFees(poolId);
        assertEq(baseFee100, 3300); // Base fee unchanged
        assertEq(surgeFee100, 3300); // Fully decayed to base fee
    }
    
    function testSetSurgeDuration() public {
        // Only owner can update surge duration
        vm.startPrank(owner);
        manager.setSurgeDuration(12 hours);
        assertEq(manager.surgeDuration(), 12 hours);
        vm.stopPrank();
        
        // Non-owner shouldn't be able to update
        vm.startPrank(address(0xBEEF));
        vm.expectRevert("UNAUTHORIZED");
        manager.setSurgeDuration(6 hours);
        vm.stopPrank();
        
        // Duration should be within bounds
        vm.startPrank(owner);
        vm.expectRevert("Invalid duration");
        manager.setSurgeDuration(30 minutes); // Too short
        
        vm.expectRevert("Invalid duration");
        manager.setSurgeDuration(8 days); // Too long
        vm.stopPrank();
    }
    
    function testMultipleUpdates() public {
        // Initial setup with CAP event
        vm.startPrank(fullRangeAddress);
        oracleManager.setCapEventStatus(poolId, true);
        vm.stopPrank();
        
        feePolicy.setEventDeviation(poolId, 500);
        
        // First update
        vm.startPrank(owner);
        manager.updateDynamicFee(poolId, true);
        vm.stopPrank();
        
        // Check initial fees
        (uint256 baseFee1, uint256 surgeFee1) = manager.getCurrentFees(poolId);
        assertEq(baseFee1, 3300);
        assertEq(surgeFee1, 6600);
        
        // Change to no CAP event
        vm.startPrank(fullRangeAddress);
        oracleManager.setCapEventStatus(poolId, false);
        vm.stopPrank();
        
        // Fast forward past update interval
        vm.warp(block.timestamp + 86401); // Just over 24 hours
        
        // Second update
        vm.startPrank(fullRangeAddress);
        (uint256 baseFee2, uint256 surgeFee2, bool wasUpdated) = 
            manager.updateDynamicFeeIfNeeded(poolId, address(oracleManager));
        vm.stopPrank();
        
        // Should decrease fee and disable surge
        assertTrue(wasUpdated);
        assertEq(baseFee2, 3135); // 3300 - 5% = 3135
        assertEq(surgeFee2, 3135); // No surge
    }
    
    function testHandleFeeUpdate() public {
        // Set up for update
        vm.startPrank(fullRangeAddress);
        oracleManager.setCapEventStatus(poolId, true);
        
        // Call handleFeeUpdate
        manager.handleFeeUpdate(poolId, address(oracleManager));
        
        // Check that fees were updated
        (uint256 baseFee, uint256 surgeFee) = manager.getCurrentFees(poolId);
        assertEq(baseFee, 3300); // Increased from default
        assertEq(surgeFee, 6600); // With surge
        
        vm.stopPrank();
    }
} 
*/
