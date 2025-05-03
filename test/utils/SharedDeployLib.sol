// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {ISpot} from "../../src/interfaces/ISpot.sol";

// Imports needed for predictSpotHookAddressForTest
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPoolPolicy} from "../../src/interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "../../src/interfaces/IFullRangeLiquidityManager.sol";
import {TruncGeoOracleMulti} from "../../src/TruncGeoOracleMulti.sol";
import {IDynamicFeeManager} from "../../src/interfaces/IDynamicFeeManager.sol";
import {Spot} from "../../src/Spot.sol";

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
    // --------------------------------------------------------------------- //
    //  Single-source constants for CREATE2 salts used across every test
    // --------------------------------------------------------------------- //
    bytes32 public constant ORACLE_SALT      = keccak256("TRUNC_GEO_ORACLE");
    
    /// @dev deprecated – kept so the selector hash stays constant for old tests
    bytes32 internal constant _SPOT_SALT_DEPRECATED = keccak256("full-range-spot-hook");

    /// @notice canonical salt for deterministic Spot hook deployments (v2+)
    bytes32 internal constant SPOT_HOOK_SALT  = keccak256("full-range-spot-hook:v2");
    
    bytes32 public constant DFM_SALT         = keccak256("DYNAMIC_FEE_MANAGER");

    // salt uses deployer so tests ≠ prod; keep predictable by forcing same address
    // The tests impersonate `DEPLOYER_EOA`, so we hard-code that here:
    address internal constant TEST_DEPLOYER = address(0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf);

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
    ) internal view returns (bytes32 hash) {
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
        require(addr != address(0), "Oracle deployment failed");
    }

    /// Derive salt **exactly** as before – tests and production infra rely on the
    /// original deterministic addresses.  Namespacing is left for a future
    /// migration; for now we return the raw userSalt.
    function _deriveSalt(bytes32 userSalt, uint8 /*objectClass*/ ) internal pure returns (bytes32) {
        return userSalt;
    }

    /// @notice Predicts the Spot hook address using the fixed TEST_DEPLOYER and known constructor args structure from ForkSetup
    /// @param _poolManager PoolManager instance
    /// @param _policyManager PolicyManager instance
    /// @param _liquidityManager LiquidityManager instance
    /// @param _oracle Oracle instance
    /// @param _dynamicFeeManager DynamicFeeManager instance
    /// @return predictedAddress The predicted deterministic address for the Spot hook
    function predictSpotHookAddressForTest(
        IPoolManager _poolManager,
        IPoolPolicy _policyManager,
        IFullRangeLiquidityManager _liquidityManager,
        TruncGeoOracleMulti _oracle,
        IDynamicFeeManager _dynamicFeeManager
    ) internal view returns (address) {
        bytes memory spotConstructorArgs = abi.encode(
            _poolManager,
            _policyManager,
            _liquidityManager,
            _oracle, // Pass the concrete type as used in ForkSetup
            _dynamicFeeManager,
            TEST_DEPLOYER // Use the hardcoded deployer for prediction
        );
        bytes memory hookCreationCode = type(Spot).creationCode;
        return predictDeterministicAddress(
            TEST_DEPLOYER, // Use the hardcoded deployer
            SPOT_HOOK_SALT, // Use the modified salt
            hookCreationCode,
            spotConstructorArgs
        );
    }
} 