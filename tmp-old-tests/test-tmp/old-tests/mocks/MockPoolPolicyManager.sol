// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolPolicy} from "../../src/interfaces/IPoolPolicy.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import "forge-std/console2.sol";

// Basic mock for IPoolPolicy focused on Phase 4 getters
abstract contract MockPoolPolicyManager is IPoolPolicy {
    using PoolIdLibrary for PoolId;

    uint256 public constant PRECISION = 1e18;

    uint256 public mockProtocolFeePercentage = (10 * PRECISION) / 100; // 0.1 * PRECISION; // 10% default
    mapping(address => bool) public mockAuthorizedReinvestors;
    address public mockGovernance = address(0x5); // Match base test

    // --- NEW: Mapping to store policies ---
    mapping(PoolId => mapping(PolicyType => address)) public policies;

    function getProtocolFeePercentage(PoolId poolId) external view override returns (uint256 feePercentage) {
        poolId;
        return mockProtocolFeePercentage;
    }

    function getFeeCollector() external view override returns (address) {
        return address(0); // Not used in these tests
    }

    function isAuthorizedReinvestor(address reinvestor) external view override returns (bool isAuthorized) {
        return mockAuthorizedReinvestors[reinvestor];
    }

    function getSoloGovernance() external view override returns (address) {
        return mockGovernance;
    }

    // --- Mock Setters ---
    function setMockProtocolFeePercentage(uint256 _percentage) external {
        mockProtocolFeePercentage = _percentage;
    }

    function setMockAuthorizedReinvestor(address _reinvestor, bool _isAuthorized) external {
        mockAuthorizedReinvestors[_reinvestor] = _isAuthorized;
    }

    // --- NEW: Implementation for setPolicy ---
    function setPolicy(PoolId poolId, PolicyType policyType, address policyAddress) external {
        // console2.log("MockPoolPolicyManager.setPolicy: poolId (bytes32)=", PoolId.unwrap(poolId)); // Commented out
        // console2.log("MockPoolPolicyManager.setPolicy: policyType=", uint256(policyType)); // Commented out
        // console2.log("  policyAddress=", policyAddress); // Commented out
        policies[poolId][policyType] = policyAddress;
    }

    // --- Unimplemented IPoolPolicy functions (add as needed) ---
    // --- UPDATED: getPolicy implementation ---
    function getPolicy(PoolId poolId, PolicyType policyType) external view override returns (address policyAddress) { 
        address storedPolicy = policies[poolId][policyType]; // Get stored policy
        // console2.log("MockPoolPolicyManager.getPolicy: poolId (bytes32)=", PoolId.unwrap(poolId)); // Commented out
        // console2.log("MockPoolPolicyManager.getPolicy: Looking up policyType (uint256)=", uint256(policyType)); // Commented out
        // console2.log("  Found policyAddress=", storedPolicy); // Commented out
        return storedPolicy; // Return stored policy
    }
    function getPolSharePpm(PoolId poolId) external view returns (uint32 polSharePpm) { return 0; }
    function getFullRangeSharePpm(PoolId poolId) external view returns (uint32 fullRangeSharePpm) { return 0; }
    function getLpSharePpm(PoolId poolId) external view returns (uint32 lpSharePpm) { return 0; }
    function getMinTradingFeePpm(PoolId poolId) external view returns (uint32 minFeePpm) { return 0; }
    function getFeeClaimThresholdPpm(PoolId poolId) external view returns (uint32 thresholdPpm) { return 0; }
    function getDefaultPolMultiplier(PoolId poolId) external view returns (uint8 polMultiplier) { return 0; }
    function getDefaultDynamicFeePpm(PoolId poolId) external view returns (uint32 defaultFeePpm) { return 0; }
    function getTickScalingFactor(PoolId poolId) external view returns (int24 tickScalingFactor) { return 0; }
    function getSupportedTickSpacings() external view returns (uint24[] memory spacings) { return new uint24[](0); }
    function isSupportedPool(PoolKey calldata key) external view returns (bool supported) { return true; } // Assume supported for simplicity

} 