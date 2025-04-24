// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Spot} from "../src/Spot.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "../src/interfaces/IFullRangeLiquidityManager.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

// Script to fix the hook address mining for Unichain deployment
contract FixUnichain is Script {
    // The official CREATE2 Deployer used by forge scripts
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    // Unichain Mainnet-specific addresses
    address constant UNICHAIN_POOL_MANAGER = 0x1F98400000000000000000000000000000000004; // Official Unichain PoolManager

    function run() public view {
        console.log("Finding valid hook address for Unichain deployment");

        // Get dynamic deployment parameters from DeployUnichainV4.s.sol
        address policyManager = 0xC7aC2675006260688a521A798dB7f27319691E10; // Adjust as needed
        address liquidityManager = 0x8Db039972348c6df2C1a9cf362d52D6fE04CA8E0; // Adjust as needed

        // Calculate required hook flags for Spot
        uint160 spotFlags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        // Prepare constructor arguments for Spot
        bytes memory constructorArgs = abi.encode(
            IPoolManager(UNICHAIN_POOL_MANAGER),
            IPoolPolicy(policyManager),
            IFullRangeLiquidityManager(liquidityManager)
        );

        // IMPORTANT FIX: The original code incorrectly passed empty bytes as constructorArgs
        // We need to use type(Spot).creationCode for creationCode and constructorArgs for constructorArgs
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, spotFlags, type(Spot).creationCode, constructorArgs);

        console.log("Found valid hook address:", hookAddress);
        console.log("Using salt (decimal):", uint256(salt));
        console.log("Using salt (hex):", vm.toString(salt));

        // Check if address is valid
        bool isValid = HookMiner.verifyHookAddress(hookAddress, spotFlags);
        console.log("Hook address is valid:", isValid);

        console.log("\nTo fix the DeployUnichainV4.s.sol script:");
        console.log("1. Update the HookMiner.find() call to pass the following:");
        console.log("   - creationCode: type(Spot).creationCode");
        console.log("   - constructorArgs: the abi.encode() of constructor arguments");
        console.log("2. Or, use this hardcoded salt with the salt value above");
    }
}
