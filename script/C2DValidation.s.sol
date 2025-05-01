// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Spot} from "../src/Spot.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "../src/interfaces/IFullRangeLiquidityManager.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

/**
 * @notice A script to debug Create2Deployer validation issues by emulating how Uniswap V4 validates hook addresses
 */
contract C2DValidation is Script {
    // The official CREATE2 Deployer used by forge scripts
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    // Unichain Mainnet-specific addresses
    address constant UNICHAIN_POOL_MANAGER = 0x1F98400000000000000000000000000000000004;

    // Fixed addresses from the deployment attempt
    address constant POLICY_MANAGER = 0xC7aC2675006260688a521A798dB7f27319691E10;
    address constant LIQUIDITY_MANAGER = 0x8Db039972348c6df2C1a9cf362d52D6fE04CA8E0;

    // Hook validation errors
    error HookAddressNotValid(address hooks);

    /**
     * @notice Check if a hook address is valid using the same logic as Uniswap V4
     * @param hookAddress The address of the hook to validate
     * @param requiredFlags The flags that the hook address should have
     */
    function isValidHookAddress(address hookAddress, uint160 requiredFlags, uint24 fee) internal pure returns (bool) {
        // The hook address must have the right bits set for the flags it implements
        // See how this is done in the Hooks.sol library

        // Check if flag dependencies are correct
        IHooks hook = IHooks(hookAddress);

        // The hook can only have a flag to return a hook delta on an action if it also has the corresponding action flag
        if (!hasPermission(hook, Hooks.BEFORE_SWAP_FLAG) && hasPermission(hook, Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)) {
            return false;
        }
        if (!hasPermission(hook, Hooks.AFTER_SWAP_FLAG) && hasPermission(hook, Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)) {
            return false;
        }
        if (
            !hasPermission(hook, Hooks.AFTER_ADD_LIQUIDITY_FLAG)
                && hasPermission(hook, Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)
        ) {
            return false;
        }
        if (
            !hasPermission(hook, Hooks.AFTER_REMOVE_LIQUIDITY_FLAG)
                && hasPermission(hook, Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        ) {
            return false;
        }

        // Check if required flags are present
        for (uint256 i = 0; i < 14; i++) {
            uint160 flag = uint160(1 << i);
            if ((requiredFlags & flag) != 0 && !hasPermission(hook, flag)) {
                return false;
            }
        }

        // If there is no hook contract set, then fee cannot be dynamic
        bool isDynamicFee = fee > type(uint16).max; // simplified check
        // If a hook contract is set, it must have at least 1 flag set, or have a dynamic fee
        return address(hook) == address(0)
            ? !isDynamicFee
            : (uint160(address(hook)) & Hooks.ALL_HOOK_MASK > 0 || isDynamicFee);
    }

    /**
     * @notice Check if a hook has a specific permission flag
     */
    function hasPermission(IHooks hook, uint160 flag) internal pure returns (bool) {
        return uint160(address(hook)) & flag != 0;
    }

    /**
     * @notice Main script to test hook validation
     */
    function run() public view {
        console.log("Testing Create2Deployer validation for hooks");

        // Create the same hook flags as in our deployment
        uint160 targetFlags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        // Our test pool uses this fee
        uint24 poolFee = 3000;

        // Salt that we've been trying to use
        bytes32 salt = bytes32(uint256(0x48bd));

        // Prepare constructor arguments for Spot
        bytes memory constructorArgs = abi.encode(
            IPoolManager(UNICHAIN_POOL_MANAGER),
            IPoolPolicy(POLICY_MANAGER),
            IFullRangeLiquidityManager(LIQUIDITY_MANAGER)
        );

        // Calculate the hook address with our salt
        address hookAddress = HookMiner.computeAddress(
            CREATE2_DEPLOYER, uint256(salt), abi.encodePacked(type(Spot).creationCode, constructorArgs)
        );

        console.log("Hook address: %s", hookAddress);
        console.log("Hook address (lower 20 bytes): 0x%x", uint160(hookAddress));
        console.log("Hook flags in address: 0x%x", uint256(uint160(hookAddress) & Hooks.ALL_HOOK_MASK));
        console.log("Target flags: 0x%x", uint256(targetFlags));

        // Check validation using our function that replicates Uniswap's logic
        bool isValid = isValidHookAddress(hookAddress, targetFlags, poolFee);
        console.log("Hook address is valid according to our validation? %s", isValid);

        // Try to identify why it might be invalid
        console.log("\nChecking specific validation rules...");

        // Check flag dependencies
        if (
            !hasPermission(IHooks(hookAddress), Hooks.BEFORE_SWAP_FLAG)
                && hasPermission(IHooks(hookAddress), Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
        ) {
            console.log("Invalid: Has BEFORE_SWAP_RETURNS_DELTA but not BEFORE_SWAP");
        }

        if (
            !hasPermission(IHooks(hookAddress), Hooks.AFTER_SWAP_FLAG)
                && hasPermission(IHooks(hookAddress), Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
        ) {
            console.log("Invalid: Has AFTER_SWAP_RETURNS_DELTA but not AFTER_SWAP");
        }

        if (
            !hasPermission(IHooks(hookAddress), Hooks.AFTER_ADD_LIQUIDITY_FLAG)
                && hasPermission(IHooks(hookAddress), Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)
        ) {
            console.log("Invalid: Has AFTER_ADD_LIQUIDITY_RETURNS_DELTA but not AFTER_ADD_LIQUIDITY");
        }

        if (
            !hasPermission(IHooks(hookAddress), Hooks.AFTER_REMOVE_LIQUIDITY_FLAG)
                && hasPermission(IHooks(hookAddress), Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        ) {
            console.log("Invalid: Has AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA but not AFTER_REMOVE_LIQUIDITY");
        }

        // Check individual required flags
        console.log("\nVerifying individual required flags...");
        console.log("AFTER_INITIALIZE: %s", hasPermission(IHooks(hookAddress), Hooks.AFTER_INITIALIZE_FLAG));
        console.log("AFTER_ADD_LIQUIDITY: %s", hasPermission(IHooks(hookAddress), Hooks.AFTER_ADD_LIQUIDITY_FLAG));
        console.log("AFTER_REMOVE_LIQUIDITY: %s", hasPermission(IHooks(hookAddress), Hooks.AFTER_REMOVE_LIQUIDITY_FLAG));
        console.log("BEFORE_SWAP: %s", hasPermission(IHooks(hookAddress), Hooks.BEFORE_SWAP_FLAG));
        console.log("AFTER_SWAP: %s", hasPermission(IHooks(hookAddress), Hooks.AFTER_SWAP_FLAG));
        console.log(
            "AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA: %s",
            hasPermission(IHooks(hookAddress), Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        );

        // Check if we need to change our claimed flags
        console.log("\nChecking what flags the address actually has...");
        Hooks.Permissions memory actualPermissions = Hooks.Permissions({
            beforeInitialize: hasPermission(IHooks(hookAddress), Hooks.BEFORE_INITIALIZE_FLAG),
            afterInitialize: hasPermission(IHooks(hookAddress), Hooks.AFTER_INITIALIZE_FLAG),
            beforeAddLiquidity: hasPermission(IHooks(hookAddress), Hooks.BEFORE_ADD_LIQUIDITY_FLAG),
            afterAddLiquidity: hasPermission(IHooks(hookAddress), Hooks.AFTER_ADD_LIQUIDITY_FLAG),
            beforeRemoveLiquidity: hasPermission(IHooks(hookAddress), Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG),
            afterRemoveLiquidity: hasPermission(IHooks(hookAddress), Hooks.AFTER_REMOVE_LIQUIDITY_FLAG),
            beforeSwap: hasPermission(IHooks(hookAddress), Hooks.BEFORE_SWAP_FLAG),
            afterSwap: hasPermission(IHooks(hookAddress), Hooks.AFTER_SWAP_FLAG),
            beforeDonate: hasPermission(IHooks(hookAddress), Hooks.BEFORE_DONATE_FLAG),
            afterDonate: hasPermission(IHooks(hookAddress), Hooks.AFTER_DONATE_FLAG),
            beforeSwapReturnDelta: hasPermission(IHooks(hookAddress), Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG),
            afterSwapReturnDelta: hasPermission(IHooks(hookAddress), Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG),
            afterAddLiquidityReturnDelta: hasPermission(IHooks(hookAddress), Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG),
            afterRemoveLiquidityReturnDelta: hasPermission(
                IHooks(hookAddress), Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            )
        });

        // Suggest a modified getHookPermissions function to match the actual address
        console.log("\nSuggested getHookPermissions() for this hook address:");
        console.log("function getHookPermissions() public pure override returns (Hooks.Permissions memory) {");
        console.log("    return Hooks.Permissions({");
        console.log("        beforeInitialize: %s,", actualPermissions.beforeInitialize);
        console.log("        afterInitialize: %s,", actualPermissions.afterInitialize);
        console.log("        beforeAddLiquidity: %s,", actualPermissions.beforeAddLiquidity);
        console.log("        afterAddLiquidity: %s,", actualPermissions.afterAddLiquidity);
        console.log("        beforeRemoveLiquidity: %s,", actualPermissions.beforeRemoveLiquidity);
        console.log("        afterRemoveLiquidity: %s,", actualPermissions.afterRemoveLiquidity);
        console.log("        beforeSwap: %s,", actualPermissions.beforeSwap);
        console.log("        afterSwap: %s,", actualPermissions.afterSwap);
        console.log("        beforeDonate: %s,", actualPermissions.beforeDonate);
        console.log("        afterDonate: %s,", actualPermissions.afterDonate);
        console.log("        beforeSwapReturnDelta: %s,", actualPermissions.beforeSwapReturnDelta);
        console.log("        afterSwapReturnDelta: %s,", actualPermissions.afterSwapReturnDelta);
        console.log("        afterAddLiquidityReturnDelta: %s,", actualPermissions.afterAddLiquidityReturnDelta);
        console.log("        afterRemoveLiquidityReturnDelta: %s", actualPermissions.afterRemoveLiquidityReturnDelta);
        console.log("    });");
        console.log("}");
    }
}
