// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

// Core Contract Interfaces
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

// Project-Specific Implementations
import {Spot} from "src/Spot.sol";
import {IPoolPolicy} from "src/interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "src/interfaces/IFullRangeLiquidityManager.sol";

/**
 * @title MineSalt
 * @notice Script utility to mine for valid hook salts before deployment
 * @dev Run with `forge script script/MineSalt.s.sol --rpc-url <your_rpc>
 */
contract MineSalt is Script {
    // Mining parameters
    uint256 public constant MAX_ITERATIONS = 200000;
    uint256 public constant PROJECT_SEED = 20250415; // Unique seed for this project (date based)

    // Hook flags we need for the Spot hook
    uint160 public constant SPOT_HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
    );

    function run() public pure {
        // Use exact checksummed address literal (final attempt)
        address deployer = 0x7777777f279eba2a8fDba8036083534A5A82258B;
        bytes memory creationCode =
            hex"604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

        // Construct placeholder contract arguments - these should match real deployment
        bytes memory constructorArgs = abi.encode(
            address(0x1F98400000000000000000000000000000000004), // PoolManager
            address(0), // Policy Manager (placeholder)
            address(0) // Liquidity Manager (placeholder)
        );

        // Get the creation code
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);

        console.log("=== Starting Salt Mining Process ===");
        console.log("Deployer address:", deployer);
        console.log("Hook flags:", uint256(SPOT_HOOK_FLAGS));
        console.log("Bytecode length:", creationCode.length, "bytes");
        console.log("Starting search with project seed:", PROJECT_SEED);

        // Find a valid salt
        (address hookAddress, bytes32 salt) = findSalt(deployer, SPOT_HOOK_FLAGS, creationCodeWithArgs, PROJECT_SEED);

        // Print salt configuration values for use in deployment
        console.log("\n===============================");
        console.log("=== SALT MINING SUCCESSFUL ===");
        console.log("===============================");
        console.log("Salt value (decimal): ", uint256(salt));
        console.log("Salt value (hex): 0x", vm.toString(bytes32(salt)));
        console.log("Expected hook address: ", hookAddress);
        console.log("Hook flags needed: ", uint256(SPOT_HOOK_FLAGS));
        console.log("Deployer address: ", deployer);
        console.log("===============================");
        console.log("Copy these values to use in your deployment script");
    }

    // Find a valid salt that produces an address with the desired hook flags
    function findSalt(
        address /* deployer */,
        uint160 desiredFlags,
        bytes memory creationCode,
        uint256 startingSalt
    ) public pure returns (address hookAddress, bytes32 salt) {
        // Apply mask to keep only the hook flag bits
        desiredFlags = desiredFlags & uint160(Hooks.ALL_HOOK_MASK);

        // Start searching from the project seed
        uint256 candidate = startingSalt;
        uint256 attempts = 0;

        console.log("Searching for valid salt...");

        for (uint256 i = 0; i < MAX_ITERATIONS; i++) {
            salt = bytes32(candidate);
            hookAddress = computeCreate2Address(address(0), salt, creationCode);

            // Check if address has the right hook flags
            if ((uint160(hookAddress) & uint160(Hooks.ALL_HOOK_MASK)) == desiredFlags) {
                console.log("Found valid salt after", i, "iterations");
                return (hookAddress, salt);
            }

            candidate++;
            attempts++;

            // Log progress occasionally
            if (attempts % 10000 == 0) {
                console.log("Tried", attempts, "salts so far...");
            }
        }

        revert("Failed to find valid salt within iteration limit");
    }

    // Calculate CREATE2 address
    function computeCreate2Address(address deployer, bytes32 salt, bytes memory initCode)
        public
        pure
        returns (address addr)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(initCode))))));
    }
}
