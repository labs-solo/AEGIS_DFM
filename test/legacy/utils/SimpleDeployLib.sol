// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolPolicyManager} from "src/PoolPolicyManager.sol";
import {IFullRangeLiquidityManager} from "src/interfaces/IFullRangeLiquidityManager.sol";
import {TruncGeoOracleMulti} from "src/TruncGeoOracleMulti.sol";
import {DynamicFeeManager} from "src/DynamicFeeManager.sol";
import {IDynamicFeeManager} from "src/interfaces/IDynamicFeeManager.sol";
import {Spot} from "src/Spot.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {SpotFlags} from "../utils/SpotFlags.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

/* -------------------------------------------------------------------------- *
 * enable the `.isDynamicFee()` value-type extension for uint24              *
 * -------------------------------------------------------------------------- */
using LPFeeLibrary for uint24;

/// @notice **TEST-ONLY** helper that skips the CREATE2 deterministic deployment.
///         It deploys Oracle → DynamicFeeManager → Spot via simple `new` calls
///         and wires the cyclic references post-deployment via one-line setters.
///         The production code-path is left untouched – integration tests can
///         opt-in by setting the env-var `SIMPLE_DEPLOY=true` before running.
library SimpleDeployLib {
    // Get access to the Vm interface
    Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Deployed {
        TruncGeoOracleMulti oracle;
        DynamicFeeManager dfm;
        Spot hook;
    }

    /// @param manager    PoolManager instance (immutable addr on Unichain forks)
    /// @param policy      PolicyManager to be used by Oracle & DFM
    /// @param lm          LiquidityManager already deployed in the harness
    /// @param governance  Address considered the governance/owner for the deps
    function deployAll(
        IPoolManager manager,
        PoolPolicyManager policy,
        IFullRangeLiquidityManager lm,
        address governance
    ) internal returns (Deployed memory d) {
        /* ------------------------------------------------------- *
         *  Constants                                              *
         * ------------------------------------------------------- */
        address FAKE_HOOK = address(uint160(uint256(0xBEEF)));

        /* ------------------------------------------------------- *
         * 1️⃣  Oracle – deploy it with LocalSetup as *temporary*    *
         *      owner so we can wire the hook immediately, then    *
         *      (optionally) hand ownership back to `governance`.  *
         * ------------------------------------------------------- */
        d.oracle = new TruncGeoOracleMulti(
            manager,
            policy,
            address(0), // temporary hook – patched below
            address(this) // owner = LocalSetup (msg.sender here)
        );

        console2.log("Oracle.owner:");
        console2.logAddress(d.oracle.owner());

        /* 2️⃣  Dynamic Fee Manager – oracle known, give sentinel     */
        d.dfm = new DynamicFeeManager(governance, policy, address(d.oracle), FAKE_HOOK);

        /* ------------------------------------------------------- *
         * 3️⃣  Spot hook – mine flagged address *after* oracle/dfm *
         * ------------------------------------------------------- */
        bytes memory spotArgs = abi.encode(
            manager,
            policy,
            lm,
            d.oracle,
            IDynamicFeeManager(d.dfm),
            governance // Note: governance is used here for Spot's constructor arg for owner
        );

        // First, mine for an address with the correct flags
        (address minedAddr, bytes32 salt) = HookMiner.find(
            governance, // Use the actual deployer (msg.sender due to prank)
            SpotFlags.required(),
            type(Spot).creationCode,
            spotArgs
        );

        // Verify the mined address has the correct flags
        uint160 minedFlags = uint160(minedAddr) & uint160(Hooks.ALL_HOOK_MASK);
        /* ---- flag sanity-check ------------------------------------------ */
        console2.log("Expected hook flags:");
        console2.logUint(uint160(SpotFlags.required()));
        console2.log("Mined address flags:");
        console2.logUint(minedFlags);

        require(minedFlags == uint160(SpotFlags.required()), "SimpleDeployLib: mined address has unexpected flags");

        console2.log("--- DEBUG SimpleDeployLib ---");
        console2.log("Deployer (address(this)):");
        console2.logAddress(address(this));
        console2.log("Mined Address (minedAddr):");
        console2.logAddress(minedAddr);
        console2.log("Mined Addr Flags (minedAddr & MASK):");
        console2.logUint(uint160(minedAddr) & Hooks.ALL_HOOK_MASK);
        console2.log("Salt from HookMiner (bytes32):");
        console2.logBytes32(salt);

        address hookAddr = Create2.deploy(0, salt, abi.encodePacked(type(Spot).creationCode, spotArgs));
        d.hook = Spot(payable(hookAddr));

        console2.log("Deployed Hook Address (hookAddr):");
        console2.logAddress(hookAddr);
        uint160 deployedHookAddrFlags = uint160(hookAddr) & Hooks.ALL_HOOK_MASK;
        console2.log("Deployed Hook Addr Flags (hookAddr & MASK):");
        console2.logUint(deployedHookAddrFlags);

        if (hookAddr != minedAddr) {
            console2.log("[WARN] mined address != deployed address - continuing with deployed", hookAddr);
        }

        /* ------------------------------------------------------- *
         * 4️⃣  Final wiring – now that we know the real hook       *
         *     address, let the deps know and transfer ownership   *
         *     back to governance if desired.                      *
         * ------------------------------------------------------- */
        // Dynamic Fee Manager: authorise the real hook
        d.dfm.setAuthorizedHook(hookAddr);

        console2.log("LocalSetup address (this):");
        console2.logAddress(address(this));
        console2.log("Calling setHookAddress...");

        // Exit deployer prank context so LocalSetup (this) becomes msg.sender
        VM.stopPrank();

        // TODO: precompute address
        // // Oracle: store the hook address
        // d.oracle.setHookAddress(hookAddr);

        // Re-enter deployer context for any remaining deployment steps
        VM.startPrank(governance);

        // Optional but neat: make `governance` the final owner
        // of DFM and Oracle if it wasn't address(this) initially
        if (governance != address(this)) {
            // Transferring ownership of DynamicFeeManager to governance
            d.dfm.transferOwnership(governance);
            // TruncGeoOracleMulti owner is immutable; no transfer function available.
        }

        console2.log("Fee param for isValidHookAddress:");
        console2.logUint(uint24(LPFeeLibrary.DYNAMIC_FEE_FLAG));
        bool feeIsDynamic = uint24(LPFeeLibrary.DYNAMIC_FEE_FLAG).isDynamicFee();
        console2.log("fee.isDynamicFee() result:");
        console2.logBool(feeIsDynamic);

        // Log individual dependency checks from isValidHookAddress for hookAddr:
        IHooks hooksInstance = IHooks(hookAddr);
        // Get the flags directly from the hook address
        uint160 flags = uint160(hookAddr) & uint160(Hooks.ALL_HOOK_MASK);

        bool depCheck1 = !(flags & Hooks.BEFORE_SWAP_FLAG > 0) && (flags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG > 0);
        console2.log("Dependency Check 1 (NO BS_F && BS_RDF):");
        console2.logBool(depCheck1);
        bool depCheck2 = !(flags & Hooks.AFTER_SWAP_FLAG > 0) && (flags & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG > 0);
        console2.log("Dependency Check 2 (NO AS_F && AS_RDF):");
        console2.logBool(depCheck2);

        bool finalCheck_hasFlags = deployedHookAddrFlags > 0;
        console2.log("Final Check Part 1 (deployedHookAddrFlags > 0):");
        console2.logBool(finalCheck_hasFlags);
        bool finalCheck_isDynamic = feeIsDynamic;
        console2.log("Final Check Part 2 (fee.isDynamicFee()):");
        console2.logBool(finalCheck_isDynamic);

        bool isValid = Hooks.isValidHookAddress(hooksInstance, uint24(LPFeeLibrary.DYNAMIC_FEE_FLAG));
        console2.log("Hooks.isValidHookAddress returned:");
        console2.logBool(isValid);
        console2.log("--- END DEBUG SimpleDeployLib ---");

        require(isValid, "SimpleDeployLib: mined hook lacks required flags");

        return d;
    }
}
