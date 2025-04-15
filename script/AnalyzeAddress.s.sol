// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

contract AnalyzeAddress is Script {
    function run() public {
        // The address we're getting now
        address hookAddress = 0xe1eC1843f1b90CdBAE8d12fac25d2630561d7CA4;
        
        // Check the flag bits
        console.log("Analyzing hook address: %s", hookAddress);
        console.log("Lower bits (mask): 0x%x", uint160(hookAddress) & Hooks.ALL_HOOK_MASK);
        
        // Check individual flags
        console.log("\nFlag breakdown:");
        uint160 flags = uint160(hookAddress) & Hooks.ALL_HOOK_MASK;
        console.log("BEFORE_INITIALIZE: %s", (flags & Hooks.BEFORE_INITIALIZE_FLAG) != 0);
        console.log("AFTER_INITIALIZE: %s", (flags & Hooks.AFTER_INITIALIZE_FLAG) != 0);
        console.log("BEFORE_ADD_LIQUIDITY: %s", (flags & Hooks.BEFORE_ADD_LIQUIDITY_FLAG) != 0);
        console.log("AFTER_ADD_LIQUIDITY: %s", (flags & Hooks.AFTER_ADD_LIQUIDITY_FLAG) != 0);
        console.log("BEFORE_REMOVE_LIQUIDITY: %s", (flags & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG) != 0);
        console.log("AFTER_REMOVE_LIQUIDITY: %s", (flags & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG) != 0);
        console.log("BEFORE_SWAP: %s", (flags & Hooks.BEFORE_SWAP_FLAG) != 0);
        console.log("AFTER_SWAP: %s", (flags & Hooks.AFTER_SWAP_FLAG) != 0);
        console.log("BEFORE_DONATE: %s", (flags & Hooks.BEFORE_DONATE_FLAG) != 0);
        console.log("AFTER_DONATE: %s", (flags & Hooks.AFTER_DONATE_FLAG) != 0);
        console.log("BEFORE_SWAP_RETURNS_DELTA: %s", (flags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) != 0);
        console.log("AFTER_SWAP_RETURNS_DELTA: %s", (flags & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) != 0);
        console.log("AFTER_ADD_LIQUIDITY_RETURNS_DELTA: %s", (flags & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG) != 0);
        console.log("AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA: %s", (flags & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG) != 0);
        
        // Generate suggested getHookPermissions()
        console.log("\nSuggested getHookPermissions for this address:");
        console.log("function getHookPermissions() public pure override returns (Hooks.Permissions memory) {");
        console.log("    return Hooks.Permissions({");
        console.log("        beforeInitialize: %s,", (flags & Hooks.BEFORE_INITIALIZE_FLAG) != 0);
        console.log("        afterInitialize: %s,", (flags & Hooks.AFTER_INITIALIZE_FLAG) != 0);
        console.log("        beforeAddLiquidity: %s,", (flags & Hooks.BEFORE_ADD_LIQUIDITY_FLAG) != 0);
        console.log("        afterAddLiquidity: %s,", (flags & Hooks.AFTER_ADD_LIQUIDITY_FLAG) != 0);
        console.log("        beforeRemoveLiquidity: %s,", (flags & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG) != 0);
        console.log("        afterRemoveLiquidity: %s,", (flags & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG) != 0);
        console.log("        beforeSwap: %s,", (flags & Hooks.BEFORE_SWAP_FLAG) != 0);
        console.log("        afterSwap: %s,", (flags & Hooks.AFTER_SWAP_FLAG) != 0);
        console.log("        beforeDonate: %s,", (flags & Hooks.BEFORE_DONATE_FLAG) != 0);
        console.log("        afterDonate: %s,", (flags & Hooks.AFTER_DONATE_FLAG) != 0);
        console.log("        beforeSwapReturnDelta: %s,", (flags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG) != 0);
        console.log("        afterSwapReturnDelta: %s,", (flags & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) != 0);
        console.log("        afterAddLiquidityReturnDelta: %s,", (flags & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG) != 0);
        console.log("        afterRemoveLiquidityReturnDelta: %s", (flags & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG) != 0);
        console.log("    });");
        console.log("}");
    }
} 