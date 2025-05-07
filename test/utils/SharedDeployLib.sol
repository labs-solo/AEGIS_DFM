// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {ISpot} from "../../src/interfaces/ISpot.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPoolPolicy} from "../../src/interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "../../src/interfaces/IFullRangeLiquidityManager.sol";
import {TruncGeoOracleMulti} from "../../src/TruncGeoOracleMulti.sol";
import {IDynamicFeeManager} from "../../src/interfaces/IDynamicFeeManager.sol";
import {DynamicFeeManager} from "../../src/DynamicFeeManager.sol";
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

    // Define the struct for predicted contract addresses
    struct PredictedContracts {
        address oracleAddr;
        address dfmAddr;
        address hookAddr;
        bytes32 hookSalt;
    }

    // (kept for legacy scripts; **not** used by tests any more)
    address internal constant LEGACY_DEPLOYER = address(0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf);

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
    // Low-order representation (unshifted) of the flags the Spot hook must
    // embed in its address.  These correspond 1-for-1 with the symbolic
    // *_FLAG constants in `Hooks.sol` (which themselves live in the *low* 14
    // bits).  We keep the canonical unshifted form so external tooling that
    // reasons about the flag *set* can continue to reuse this constant.
    /// Only the four flags we still need
    uint160 internal constant SPOT_HOOK_FLAGS =
           Hooks.AFTER_INITIALIZE_FLAG
        |  Hooks.BEFORE_SWAP_FLAG
        |  Hooks.AFTER_SWAP_FLAG
        |  Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    /* ----------------------------------------------------------------
     *  Dynamic mask that always covers *all* defined hook-flag bits.
     *  Currently TOTAL_HOOK_FLAGS = 14 (12 original + 2 RETURN_DELTA).
     * -------------------------------------------------------------- */
    uint8  private constant TOTAL_HOOK_FLAGS = 14;
    uint160 private constant _FLAG_MASK_CONST =
          uint160((uint256(1) << TOTAL_HOOK_FLAGS) - 1)
        | uint160(0x800000);          // lock bit 23 too

    function _FLAG_MASK() private pure returns (uint160) {
        return _FLAG_MASK_CONST;
    }

    /// @notice Returns the Spot-hook flag pattern matching Hooks low-order bits.
    function spotHookFlagsShifted() public pure returns (uint160) {
        // We now keep the flag-set in the *low-order* bits as expected by
        // HookMiner (flags are encoded in the least-significant 14 bits).
        // Simply OR-in the Dynamic-Fee lock-bit (bit-23, 0x800000).
        return SPOT_HOOK_FLAGS | uint160(0x800000);
    }

    /// @notice Public helper so tests can query / reuse the mask
    function spotHookFlags() public pure returns (uint160) {
        return
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    /* ------------------------------------------------------------------ *
     *  Safe CREATE2 address computation (avoids OZ 0xff alignment bug)
     * ------------------------------------------------------------------ */
    function _safeCreate2Addr(bytes32 salt, bytes32 codeHash, address deployer) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, codeHash)))));
    }

    /* ----------------------------------------------------------------
     *  Deterministic-address prediction (now **uses** the `deployer` arg) *
     * ---------------------------------------------------------------- */

    function _computeCreate2(
        address deployer,
        bytes32 salt,
        bytes32 codeHash
    ) private pure returns (address) {
        // EIP-1014:  address = keccak256(0xff ++ deployer ++ salt ++ hash))[12:]
        bytes32 digest = keccak256(
            abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)
        );
        return address(uint160(uint256(digest))); // ← lower 20-bytes
    }

    /** @dev Predicts a CREATE2 address 
     *  @param deployer The address which will deploy the contract
     *  @param salt A 32-byte value used to create the contract address
     *  @param creationCode The creation code of the to-be-deployed contract
     *  @param constructorArgs The constructor arguments for the contract
     *  @return The predicted address of the contract
     */
    function predictDeterministicAddress(
        address deployer,
        bytes32 salt,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal view returns (address) {
        bytes memory fullInit = abi.encodePacked(creationCode, constructorArgs);
        bytes32 codeHash = keccak256(fullInit);
        // Safe Create2 computation to avoid alignment issues
        address predicted = _safeCreate2Addr(salt, codeHash, deployer);
        return predicted;
    }

    /** @dev Performs CREATE2 deploy and returns the address. Reverts on failure */
    function deployDeterministic(
        address deployer,
        bytes32 salt,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal returns (address deployed) {
        // Log the init code hash right before deployment
        bytes memory fullInit = abi.encodePacked(creationCode, constructorArgs);

        deployed = Create2.deploy(0, salt, fullInit);
        return deployed;
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

    /// @dev  The legacy pre-mined salt is no longer used – the hook's permission
    ///       bitmap changed, so we mine a fresh salt at test-time. Constant kept
    ///       for backward-compatibility only.
    bytes32 internal constant DEPRECATED_SPOT_HOOK_SALT = 0x00000000000000000000000000000000000000000000000000000000000007fb;

    /* ---------- unified salt/address finder (env → miner fallback) ------ */
    function _spotHookSaltAndAddr(
        address   deployer,
        bytes     memory creationCode,
        bytes     memory constructorArgs
    ) internal returns (bytes32 salt, address predicted) {
        // Prepare init code hash (without emitting logs)
        bytes memory fullInit = abi.encodePacked(creationCode, constructorArgs);
        // Derive salt and address by mining correct hook flags
        (address hookAddr, bytes32 hookSalt) = HookMiner.find(
            deployer,
            spotHookFlagsShifted(),
            creationCode,
            constructorArgs
        );
        predicted = _safeCreate2Addr(hookSalt, keccak256(fullInit), deployer);
        return (hookSalt, predicted);
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

        // Derive salt and predicted address via unified helper
        (bytes32 salt, address predicted) = _spotHookSaltAndAddr(
            _deployer,
            hookCreationCode,
            spotConstructorArgs
        );

        // Deploy deterministically and validate
        address deployed = deployDeterministic(
            _deployer,
            salt,
            hookCreationCode,
            spotConstructorArgs
        );

        assert(deployed == predicted);
        return deployed;
    }

    function _predictContracts(
        address c2Deployer,
        IPoolManager _pm,
        IPoolPolicy _policy,
        IFullRangeLiquidityManager _lm
    ) internal returns (PredictedContracts memory pc) {
        //------------------------------------------------------------------//
        //  Iterate until (oracle, dfm, hook) stop changing -- normally 2-3  //
        //  rounds max; guarantees a single, self-consistent triple.        //
        //------------------------------------------------------------------//

        address oracle;
        address dfm;
        address hookPred;  // Renamed to match deployment usage
        bytes32 hookSalt;
        address lastHook;

        for (uint8 i; i < 5; ++i) {               // hard bail-out guard
            // 1. mine (or re-mine) a hook that references *current* oracle/dfm
            (hookSalt, hookPred) = _spotHookSaltAndAddr(  // Store in hookPred
                c2Deployer,
                type(Spot).creationCode,
                abi.encode(_pm, _policy, _lm, oracle, dfm, c2Deployer)
            );

            // 2. predict oracle/dfm that reference that hook
            oracle = predictDeterministicAddress(
                c2Deployer,
                ORACLE_SALT,
                type(TruncGeoOracleMulti).creationCode,
                abi.encode(_pm, _policy, hookPred, c2Deployer)  // Use hookPred consistently
            );

            dfm = predictDeterministicAddress(
                c2Deployer,
                DFM_SALT,
                type(DynamicFeeManager).creationCode,
                abi.encode(_policy, oracle, hookPred)  // Use hookPred consistently
            );

            // 3. fixed-point test *after* oracle & dfm are in sync
            if (hookPred == lastHook) break;
            lastHook = hookPred;
        }

        require(hookPred == lastHook, "Hook fixed-point not reached");

        pc.oracleAddr = oracle;
        pc.dfmAddr    = dfm;
        pc.hookAddr   = hookPred;  // Return the final hookPred
        pc.hookSalt   = hookSalt;
    }
} 