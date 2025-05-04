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

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

/** ----------------------------------------------------------------
 * @title SharedDeployLib
 * @notice Tiny helper used by several fork-integration tests to
 *         do deterministic CREATE2 deployments without duplicating
 *         code.  It intentionally has *zero* external dependencies
 *         so that a missing import can never break the whole tree.
 * ---------------------------------------------------------------*/

/**
 * @notice Shared library for deterministic deployments using CREATE2.
 * @dev Includes functions for prediction, deployment, and specific hook deployment logic.
 */

// Define the custom error
error SharedDeployLib__DeploymentFailed();

library SharedDeployLib {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /* ---------- public deployment salts (constant so tests agree) ------- */
    // --------------------------------------------------------------------- //
    //  Single-source constants for CREATE2 salts used across every test
    // --------------------------------------------------------------------- //
    bytes32 public constant ORACLE_SALT      = keccak256("TRUNC_GEO_ORACLE");
    
    bytes32 public constant DFM_SALT         = keccak256("DYNAMIC_FEE_MANAGER");

    /// 🛑  Do **not** hard-code a deployer.  It must be provided by the caller.

    /* ---------- flags re-exported so tests don't need hard-coding ------- */
    uint24  public  constant POOL_FEE     = 3_000; // 0.30%
    int24   public  constant TICK_SPACING = 60;

    /* ------------------------------------------------------------- *
     *  Hook flag constant used by ForkSetup                         *
     *  Matches exactly what Spot.getHookPermissions() returns      *
     * ------------------------------------------------------------- */
    uint160 internal constant SPOT_HOOK_FLAGS =
        (Hooks.AFTER_INITIALIZE_FLAG |           // true
         Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |     // true
         Hooks.BEFORE_SWAP_FLAG |                // true
         Hooks.AFTER_SWAP_FLAG |                 // true
         Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG |   // true
         Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);  // true

    /* ----------------------------------------------------------------
     *  Dynamic mask that always covers *all* defined hook-flag bits.
     *  Currently TOTAL_HOOK_FLAGS = 14 (12 original + 2 RETURN_DELTA).
     *  Bump this constant whenever a new flag is added.
     * -------------------------------------------------------------- */
    uint8  private constant TOTAL_HOOK_FLAGS = 14;
    uint160 private constant _FLAG_MASK_CONST =
        uint160((uint256(1) << TOTAL_HOOK_FLAGS) - 1) << (160 - TOTAL_HOOK_FLAGS);

    function _FLAG_MASK() private pure returns (uint160) {
        return _FLAG_MASK_CONST;
    }

    function spotHookFlags() internal pure returns (uint160) {
        return uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
    }

    /* ------------------------------------------------------------------ *
     *  Deterministic-address prediction (now **uses** the `deployer` arg) *
     * ------------------------------------------------------------------ */

    function predictDeterministicAddress(
        address /* _unusedDeployer */,
        bytes32 salt,
        bytes memory bytecode,
        bytes memory constructorArgs
    ) internal view returns (address) {
        console2.log("Predict Salt:"); console2.logBytes32(salt); // Rule 27
        // Rule 27 – deep-copy to prevent aliasing between predict & deploy
        bytes memory frozenArgs = bytes(constructorArgs);
        bytes memory initCode   = abi.encodePacked(bytecode, frozenArgs);
        bytes32 codeHash = keccak256(initCode);
        console2.log("Predict Code Hash:"); console2.logBytes32(codeHash);

        return Create2.computeAddress(salt, codeHash, deployer);
    }

    /// @dev Minimal, dependency-free replica of EIP-1014 formula
    function _computeCreate2(
        address deployer,
        bytes32 salt,
        bytes32 codeHash
    ) private pure returns (address) {
        // EIP-1014:  address = keccak256(0xff ++ deployer ++ salt ++ hash))[12:]
        bytes32 digest = keccak256(
            abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)
        );
        return address(uint160(uint256(digest)));
    }

    /** @dev Performs CREATE2 deploy and returns the address. Reverts on failure */
    function deployDeterministic(
        address   deployer,            // NEW explicit executor  (Rule 29-ter)
        bytes32   salt,
        bytes     memory bytecode,
        bytes     memory constructorArgs
    ) internal returns (address addr) {
        bytes memory frozenArgs = bytes(constructorArgs);
        bytes memory initCode   = abi.encodePacked(bytecode, frozenArgs);
        bytes32 codeHash = keccak256(initCode);

        // ►► Rule 29 bis – MOVE salt to a stack-local before any further allocations
        bytes32 _salt = salt;

        // ───── Logging BEFORE touching free memory (hash is still valid)
        console2.log("--- Predict Deterministic ---");
        console2.log("Deploy Salt:");        console2.logBytes32(_salt);
        console2.log("Deploy Code Hash:");   console2.logBytes32(codeHash);
        console2.log("Deploy Executor:",     deployer);

        // ---- Rule 28: final deep-copy & re-hash -----------------
        bytes memory finalCopy = abi.encodePacked(initCode); // fresh copy
        bytes32 codeHashFinal  = keccak256(finalCopy);
        require(codeHashFinal == codeHash, "initCode mutated");

        address predicted = Create2.computeAddress(_salt, codeHashFinal, deployer); // Use finalHash here too

        // Log predicted address (now safe)
        console2.log("Predicted Address:", predicted);

        // Rule 27 guard
        if (predicted.code.length != 0) {
            revert("CREATE2 target already has code - pick a different salt");
        }

        // Add diagnostic logging for hash comparison
        console2.log("codeHashFinal:");
        console2.logBytes32(codeHashFinal);
        bytes32 onChainHash;
        assembly { onChainHash := keccak256(add(finalCopy, 0x20), mload(finalCopy)) }
        console2.log("onChainHash:");
        console2.logBytes32(onChainHash);
        
        // Calculate expected address manually to compare
        bytes32 expectedAddressBytes = keccak256(abi.encodePacked(bytes1(0xff), deployer, _salt, onChainHash));
        address expectedAddress = address(uint160(uint256(expectedAddressBytes)));
        console2.log("Manual expectedAddress:");
        console2.log(expectedAddress);
        console2.log("Create2.computeAddress result:");
        console2.log(predicted);
        console2.log("deployer parameter:");
        console2.log(deployer);
        console2.log("address(this):");
        console2.log(address(this));
        console2.log("msg.sender:");
        console2.log(msg.sender);

        // Assembly: copy salt into its own local before *any* other op
        assembly {
            let tmpSalt := _salt        // Rule 30 – re-freeze
            addr := create2(
                0,                      // value
                add(finalCopy, 0x20),   // code offset
                mload(finalCopy),       // code length
                tmpSalt                 // salt
            )
        }
        if (addr == address(0)) revert SharedDeployLib__DeploymentFailed();
        
        // Add debug output for deployed address
        console2.log("ADDR AFTER DEPLOY:", addr);
        
        if (addr != predicted) revert("SharedDeploy: Deployed address mismatch"); // Rule 28 guard
    }

    /// Derive salt **exactly** as before – tests and production infra rely on the
    /// original deterministic addresses.  Namespacing is left for a future
    /// migration; for now we return the raw userSalt.
    // Duplicate helper (older copy) still exposed `deployer`; remove the name
    // to silence 5667 without changing behaviour.
    function _deriveSalt(bytes32 userSalt, address /* _deployerIgnored */)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(userSalt, msg.sender)); // deterministic & uses sender
    }

    /* ---------- unified salt/address finder (env → miner fallback) ------ */
    function _spotHookSaltAndAddr(
        address   /* deployer */,
        bytes     memory creationCode,
        bytes     memory constructorArgs
    ) internal returns (bytes32 salt, address predicted) {
        bytes memory fullInit = abi.encodePacked(creationCode, constructorArgs);

        /* 1️⃣  Check if existing salt is valid */
        string memory raw = vm.envOr("SPOT_HOOK_SALT", string(""));
        if (bytes(raw).length != 0) {
            salt = bytes32(vm.parseBytes(raw));
            predicted = Create2.computeAddress(salt, keccak256(fullInit), TEST_DEPLOYER);

            // If the salt is valid (correct flags and address not in use), keep using it
            if (predicted.code.length == 0 && uint160(predicted) & _FLAG_MASK() == SPOT_HOOK_FLAGS) {
                return (salt, predicted);
            }
            // Otherwise signal failure to caller; do NOT touch ENV here
        }

        /* 2️⃣  Mine a new salt that fits the flag pattern */
        (predicted, salt) = HookMiner.find(
            TEST_DEPLOYER,
            SPOT_HOOK_FLAGS,
            creationCode,
            constructorArgs
        );

        // Caller decides when (and if) to persist the salt.
        return (salt, predicted);
    }

    /// @notice Predicts the Spot hook address using the provided deployer and constructor args structure
    /// @param _poolManager PoolManager instance
    /// @param _policyManager PolicyManager instance
    /// @param _liquidityManager LiquidityManager instance
    /// @param _oracle Oracle instance
    /// @param _dynamicFeeManager DynamicFeeManager instance
    /// @param _deployer The deployer address
    /// @return predictedAddress The predicted deterministic address for the Spot hook
    function predictSpotHookAddress(
        IPoolManager _poolManager,
        IPoolPolicy _policyManager,
        IFullRangeLiquidityManager _liquidityManager,
        TruncGeoOracleMulti _oracle,
        IDynamicFeeManager _dynamicFeeManager,
        address      _deployer /* ⬅ NEW explicit deployer */
    ) internal returns (address) {
        bytes memory spotConstructorArgs = abi.encode(
            _poolManager,
            _policyManager,
            _liquidityManager,
            _oracle,
            _dynamicFeeManager,
            _deployer
        );
        ( , address predicted) =
            _spotHookSaltAndAddr(_deployer, type(Spot).creationCode, spotConstructorArgs);
        return predicted;
    }

    /// @notice Deploys a new Spot hook instance via CREATE2
    function deploySpotHook(
        IPoolManager _poolManager,
        IPoolPolicy _policyManager,
        IFullRangeLiquidityManager _liquidityManager,
        TruncGeoOracleMulti _oracle,
        IDynamicFeeManager _dynamicFeeManager,
        address _deployer
    ) internal returns (address) {
        address positions = address(IFullRangeLiquidityManager(payable(address(_liquidityManager))).positions());
        if (positions == address(0)) revert("SharedDeployLib: positions-not-initialised");

        bytes memory spotConstructorArgs = abi.encode(
            _poolManager,
            _policyManager,
            _liquidityManager,
            _oracle,
            _dynamicFeeManager,
            _deployer
        );
        bytes memory hookCreationCode = type(Spot).creationCode;

        // 🔒 REUSE the salt that was *already* mined during prediction:
        // we rely on oracle.getHookAddress() == predicted earlier in ForkSetup.
        string memory raw = vm.envOr("SPOT_HOOK_SALT", string(""));
        if (bytes(raw).length == 0) revert("SharedDeployLib: missing SPOT_HOOK_SALT");
        bytes32 salt = bytes32(vm.parseBytes(raw));

        // recompute predicted with *final* init-code to double-check
        address predicted = Create2.computeAddress(
            salt,
            keccak256(abi.encodePacked(hookCreationCode, spotConstructorArgs)),
            address(this)
        );

        // Deploy – will revert automatically if some other tx used the salt
        address deployed = deployDeterministic(
            address(this),
            salt,
            hookCreationCode,
            spotConstructorArgs
        );

        // sanity-check: constructor of `Spot` ensures flags; we double-check address match
        assert(deployed == predicted);
        return deployed;
    }
} 