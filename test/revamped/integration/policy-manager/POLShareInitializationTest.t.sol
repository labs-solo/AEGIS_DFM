// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/console2.sol";

// - - - v4-core src imports - - -

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

// - - - local test imports - - -

import {Base_Test} from "../../Base_Test.sol";

// - - - local src imports - - -

import {IPoolPolicyManager} from "src/interfaces/IPoolPolicyManager.sol";

/// @title POLShareInitializationTest
/// @notice Tests that verify pools are initialized with the correct default POL share
contract POLShareInitializationTest is Base_Test {
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        Base_Test.setUp();
    }

    function test_PoolsGetInitializedWith10PercentPOLShare() public {
        // Test that pools get initialized with exactly 10% POL share
        
        // Check the existing pool from setUp
        uint256 polShare = policyManager.getPoolPOLShare(poolId);
        uint256 expectedDefaultPolShare = 100_000; // 10% = 100,000 PPM
        
        assertEq(polShare, expectedDefaultPolShare, "Pool should be initialized with 10% POL share");
        
        console2.log("Pool initialized with correct 10% POL share");
        console2.log("Expected: 100,000 PPM (10%)");
        console2.log("Actual:   ", polShare, " PPM");
    }

    function test_POLShareIsCorrectlyStoredAndRetrieved() public {
        // Test that the POL share value is correctly stored and can be retrieved
        
        uint256 polShare = policyManager.getPoolPOLShare(poolId);
        uint256 expectedDefaultPolShare = 100_000; // 10% = 100,000 PPM
        
        // Verify the default value
        assertEq(polShare, expectedDefaultPolShare, "Default POL share should be 10%");
        
        // Test setting and retrieving different values
        vm.startPrank(owner);
        
        // Test 5% POL share
        policyManager.setPoolPOLShare(poolId, 50_000);
        polShare = policyManager.getPoolPOLShare(poolId);
        assertEq(polShare, 50_000, "POL share should be set to 5%");
        
        // Test 25% POL share
        policyManager.setPoolPOLShare(poolId, 250_000);
        polShare = policyManager.getPoolPOLShare(poolId);
        assertEq(polShare, 250_000, "POL share should be set to 25%");
        
        // Test 100% POL share
        policyManager.setPoolPOLShare(poolId, 1_000_000);
        polShare = policyManager.getPoolPOLShare(poolId);
        assertEq(polShare, 1_000_000, "POL share should be set to 100%");
        
        // Reset back to default
        policyManager.setPoolPOLShare(poolId, expectedDefaultPolShare);
        vm.stopPrank();
        
        // Verify it's back to default
        polShare = policyManager.getPoolPOLShare(poolId);
        assertEq(polShare, expectedDefaultPolShare, "POL share should be reset to default 10%");
        
        console2.log("POL share storage and retrieval working correctly");
    }

    function test_DefaultPOLShareIs10Percent() public {
        // Explicitly test that the default POL share is exactly 10%
        
        uint256 polShare = policyManager.getPoolPOLShare(poolId);
        
        // 10% = 100,000 PPM (parts per million)
        uint256 tenPercentPPM = 100_000;
        
        assertEq(polShare, tenPercentPPM, "Default POL share must be exactly 10%");
        
        // Verify this is indeed 10% by checking the percentage calculation
        // 100,000 PPM = 100,000 / 1,000,000 = 0.1 = 10%
        uint256 percentage = (polShare * 100) / 1_000_000;
        assertEq(percentage, 10, "POL share should represent exactly 10%");
        
        console2.log("Default POL share is confirmed to be 10%");
        console2.log("Value: ", polShare, " PPM");
        console2.log("Percentage: ", percentage, "%");
    }
} 