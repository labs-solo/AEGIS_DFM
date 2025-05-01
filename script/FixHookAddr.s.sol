// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {Spot} from "../src/Spot.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "../src/interfaces/IFullRangeLiquidityManager.sol";
import {FullRangeLiquidityManager} from "../src/FullRangeLiquidityManager.sol";
import {PoolPolicyManager} from "../src/PoolPolicyManager.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {TruncGeoOracleMulti} from "../src/TruncGeoOracleMulti.sol";
import {IDynamicFeeManager} from "../src/interfaces/IDynamicFeeManager.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";

// Utility script to display valid hook address for debugging
contract FixHookAddr is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    function run() external {
        // Removed console log

        vm.startBroadcast();

        // Dependencies (use addresses from DeployUnichainV4.s.sol or fetch if needed)
        IPoolManager poolManager_ = IPoolManager(0x1F98400000000000000000000000000000000004);
        IPoolPolicy policyManager_ = IPoolPolicy(vm.envAddress("DEPLOYED_POLICY_MANAGER"));
        IFullRangeLiquidityManager liquidityManager_ =
            IFullRangeLiquidityManager(vm.envAddress("DEPLOYED_LIQUIDITY_MANAGER"));
        TruncGeoOracleMulti oracle_ = TruncGeoOracleMulti(vm.envAddress("DEPLOYED_ORACLE"));
        IDynamicFeeManager feeManager_ = IDynamicFeeManager(vm.envAddress("DEPLOYED_FEE_MANAGER"));
        address owner_ = vm.envAddress("DEPLOYER_ADDRESS");

        // Define required hook flags for Spot (using HookMiner constants)
        uint160 spotFlags = Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_FLAG;
        /* // Previous flags, keeping for reference
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
            */

        // Construct Spot creation code and constructor arguments
        bytes memory spotBytecode = type(Spot).creationCode;
        bytes memory spotConstructorArgs =
            abi.encode(poolManager_, policyManager_, liquidityManager_, oracle_, feeManager_, owner_);

        // Find the correct salt for Spot
        (address spotHookAddress, bytes32 spotSalt) =
            HookMiner.find(owner_, spotFlags, spotBytecode, spotConstructorArgs);

        // Removed console logs

        // Validate hook address
        bool validSpotHookAddress = Hooks.isValidHookAddress(IHooks(spotHookAddress), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        // Removed console logs
        require(validSpotHookAddress, "Predicted Spot hook address is invalid");

        // Deploy Spot with the found salt
        Spot deployedSpot =
            new Spot{salt: spotSalt}(poolManager_, policyManager_, liquidityManager_, oracle_, feeManager_, owner_);
        require(address(deployedSpot) == spotHookAddress, "Deployed Spot address mismatch");
        // Removed console log

        // Wire DynamicFeeManager to the new Spot hook by casting to implementation type
        DynamicFeeManager(address(feeManager_)).setAuthorizedHook(spotHookAddress);

        vm.stopBroadcast();
    }
}
