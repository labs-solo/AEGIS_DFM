// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20; // Using a recent compatible version

/**
 * @title PolicyType
 * @notice Defines the different types of policies managed by PoolPolicyManager.
 */
enum PolicyType {
    FEE,          // Index 0
    TICK_SCALING, // Index 1
    VTIER,        // Index 2
    ORACLE        // Index 3 (Assumption for the 4th type)
} 