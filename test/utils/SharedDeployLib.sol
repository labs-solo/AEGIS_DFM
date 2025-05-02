// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/** ----------------------------------------------------------------
 * @title SharedDeployLib
 * @notice Tiny helper used by several fork-integration tests to
 *         do deterministic CREATE2 deployments without duplicating
 *         code.  It intentionally has *zero* external dependencies
 *         so that a missing import can never break the whole tree.
 * ---------------------------------------------------------------*/

/// @dev Temporary forwarder – lets historical `../utils/SharedDeployLib.sol`
///      imports keep compiling after we moved the real code to `src/utils/`.
///      Remove this file once all branches use the new path.

library SharedDeployLib {
    /* ---------- public deployment salts (constant so tests agree) ------- */
    bytes32 internal constant ORACLE_SALT = keccak256("ORACLE_DEPLOY_SALT");
    bytes32 internal constant DFM_SALT    = keccak256("DYNAMIC_FEE_V1");
    bytes32 internal constant SPOT_SALT   = keccak256("SPOT_DEPLOY_SALT");

    /* ---------- flags re-exported so tests don't need hard-coding ------- */
    uint24  public  constant POOL_FEE     = 3_000; // 0.30%
    int24   public  constant TICK_SPACING = 60;

    /* ------------------------------------------------------------- *
     *  Hook flag constant used by ForkSetup                         *
     * ------------------------------------------------------------- */
    uint160 internal constant SPOT_HOOK_FLAGS =
        (Hooks.AFTER_INITIALIZE_FLAG |
         Hooks.AFTER_ADD_LIQUIDITY_FLAG |
         Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
         Hooks.BEFORE_SWAP_FLAG |
         Hooks.AFTER_SWAP_FLAG |
         Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);

    function spotHookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
    }

    /* ---------- deterministic-address helpers -------------------------- */
    function _buildCreate2(
        bytes32 salt,
        bytes memory bytecode,
        bytes memory constructorArgs
    ) private view returns (bytes32 hash) {
        bytes memory all = abi.encodePacked(bytecode, constructorArgs);
        hash = keccak256(all);
        assembly {
            // Same formula solidity uses for CREATE2 addr calc:
            // keccak256(0xff ++ deployer ++ salt ++ keccak256(init_code))[12:]
            let encoded := mload(0x40)
            mstore(encoded, 0xff)
            mstore(add(encoded, 0x01), shl(96, caller()))
            mstore(add(encoded, 0x15), salt)
            mstore(add(encoded, 0x35), hash)
            hash := keccak256(encoded, 0x55)
        }
    }

    function predictDeterministicAddress(
        address deployer,
        bytes32 salt,
        bytes memory bytecode,
        bytes memory constructorArgs
    ) internal view returns (address) {
        bytes32 digest = _buildCreate2(salt, bytecode, constructorArgs);
        return address(uint160(uint256(digest)));
    }

    /** @dev Performs CREATE2 deploy and returns the address. Reverts on failure */
    function deployDeterministic(
        bytes32 salt,
        bytes memory bytecode,
        bytes memory constructorArgs
    ) internal returns (address addr) {
        bytes memory all = abi.encodePacked(bytecode, constructorArgs);
        assembly {
            addr := create2(0, add(all, 0x20), mload(all), salt)
            if iszero(addr) { revert(0, 0) }
        }
        // Deterministic address may drift whenever byte-code changes.
        // Business invariant is that the deployed address is *non-zero*
        // and correctly wired into hook & managers.
        require(addr != address(0), "Oracle deployment failed");
    }
} 