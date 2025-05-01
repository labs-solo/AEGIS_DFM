// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @title HookMiner
/// @notice a minimal library for mining hook addresses
library HookMiner {
    // mask to slice out the bottom 14 bit of the address
    uint160 constant FLAG_MASK = Hooks.ALL_HOOK_MASK; // 0000 ... 0000 0011 1111 1111 1111

    // Maximum number of iterations to find a salt, avoid infinite loops or MemoryOOG
    // (arbitrarily set)
    uint256 constant MAX_LOOP = 200_000;

    // Fixed salts that are known to work with Spot and Margin contracts with most common configurations
    bytes32 constant SPOT_DEFAULT_SALT = bytes32(uint256(0x2aa)); // For flags 4549 (full set)
    bytes32 constant MARGIN_DEFAULT_SALT = bytes32(uint256(0x1956));

    // Additional known working salts for specific use cases
    // Currently none needed

    /// @notice Find a salt that produces a hook address with the desired `flags`
    /// @param deployer The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address
    /// In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)
    /// @param flags The desired flags for the hook address. Example `uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | ...)`
    /// @param creationCode The creation code of a hook contract. Example: `type(Counter).creationCode`
    /// @param constructorArgs The encoded constructor arguments of a hook contract. Example: `abi.encode(address(manager))`
    /// @return (hookAddress, salt) The hook deploys to `hookAddress` when using `salt` with the syntax: `new Hook{salt: salt}(<constructor arguments>)`
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address, bytes32)
    {
        flags = flags & FLAG_MASK; // mask for only the bottom 14 bits
        bytes memory creationCodeWithArgs = abi.encodePacked(creationCode, constructorArgs);

        // Try hardcoded salts
        bytes32[] memory knownSalts = new bytes32[](6);
        knownSalts[0] = SPOT_DEFAULT_SALT; // Then default Spot salt
        knownSalts[1] = MARGIN_DEFAULT_SALT; // Margin salt
        knownSalts[2] = bytes32(uint256(0x1)); // Fallback salts
        knownSalts[3] = bytes32(uint256(0x1234));
        knownSalts[4] = bytes32(uint256(0x12345));
        knownSalts[5] = bytes32(uint256(0x123456));

        for (uint256 i = 0; i < knownSalts.length; i++) {
            address testHookAddress = computeAddress(deployer, uint256(knownSalts[i]), creationCodeWithArgs);
            if (uint160(testHookAddress) & FLAG_MASK == flags && testHookAddress.code.length == 0) {
                return (testHookAddress, knownSalts[i]);
            }
        }

        // Regular salt mining loop
        address hookAddress;
        for (uint256 salt; salt < MAX_LOOP; salt++) {
            hookAddress = computeAddress(deployer, salt, creationCodeWithArgs);

            // if the hook's bottom 14 bits match the desired flags AND the address does not have bytecode, we found a match
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(salt));
            }
        }

        revert("HookMiner: could not find salt");
    }

    /// @notice Precompute a contract address deployed via CREATE2
    /// @param deployer The address that will deploy the hook. In `forge test`, this will be the test contract `address(this)` or the pranking address
    /// In `forge script`, this should be `0x4e59b44847b379578588920cA78FbF26c0B4956C` (CREATE2 Deployer Proxy)
    /// @param salt The salt used to deploy the hook
    /// @param creationCodeWithArgs The creation code of a hook contract, with encoded constructor arguments appended. Example: `abi.encodePacked(type(Counter).creationCode, abi.encode(constructorArg1, constructorArg2))`
    function computeAddress(address deployer, uint256 salt, bytes memory creationCodeWithArgs)
        internal
        pure
        returns (address hookAddress)
    {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, keccak256(creationCodeWithArgs)))))
        );
    }

    /// @notice Verifies if an address has the correct hook permissions
    /// @param hookAddress The address to verify
    /// @param flags The expected hook flags
    /// @return true if the address has the correct flags
    function verifyHookAddress(address hookAddress, uint160 flags) internal pure returns (bool) {
        flags = flags & FLAG_MASK; // mask for only the bottom 14 bits
        return (uint160(hookAddress) & FLAG_MASK) == flags;
    }
}
