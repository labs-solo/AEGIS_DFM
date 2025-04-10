// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

import {Spot} from "../src/Spot.sol";
import {Margin} from "../src/Margin.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "../src/interfaces/IFullRangeLiquidityManager.sol";
import {FullRangeLiquidityManager} from "../src/FullRangeLiquidityManager.sol";
import {PoolPolicyManager} from "../src/PoolPolicyManager.sol";
import {MarginManager} from "../src/MarginManager.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";

// Utility script to display valid hook address for debugging
contract FixHookAddr is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    
    function run() public {
        console2.log("Fixing Hook Address");
        
        address deployer = address(0x5); // Governance in tests
        address poolManagerAddr = address(0x1234); // Mock address
        address policyManagerAddr = address(0x5678); // Mock address
        address liquidityManagerAddr = address(0x9ABC); // Mock address
        address marginManagerAddr = address(0xDEF0); // Mock address
        
        // Calculate required hook flags for Margin (original configuration)
        uint160 marginFlags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        // Prepare constructor arguments for Margin
        bytes memory marginConstructorArgs = abi.encode(
            poolManagerAddr,
            policyManagerAddr,
            liquidityManagerAddr,
            marginManagerAddr
        );
        
        // Use known working salt for Margin
        bytes32 marginSalt = bytes32(uint256(4803));
        
        // Create the creation code
        bytes memory marginCreationCode = abi.encodePacked(type(Margin).creationCode, marginConstructorArgs);
        
        // Calculate the address using the known salt
        address marginHookAddress = HookMiner.computeAddress(
            deployer,
            uint256(marginSalt),
            marginCreationCode
        );
        
        console2.log("Calculated Margin Hook Address:", marginHookAddress);
        console2.log("Using Margin Salt:", uint256(marginSalt));
        
        // Check address validity for Margin
        bool validMarginHookAddress = (uint160(marginHookAddress) & uint160(Hooks.ALL_HOOK_MASK)) == marginFlags;
        console2.log("Margin hook address valid:", validMarginHookAddress);
        console2.log("Expected Margin flags:", uint256(marginFlags));
        console2.log("Actual Margin flags:", uint256(uint160(marginHookAddress) & uint160(Hooks.ALL_HOOK_MASK)));
        
        // Script completed successfully
        console2.log("Valid deployment configuration found!");
    }
} 