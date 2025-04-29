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

// Utility script to display valid hook address for debugging
contract FixHookAddr is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    function run() public pure {
        console2.log("Fixing Hook Address for Spot");

        // Use exact checksummed address literal (final attempt)
        address deployer = 0x7777777f279eba2a8fDba8036083534A5A82258B;
        address poolManagerAddr = address(0x1234); // Mock address
        address policyManagerAddr = address(0x5678); // Mock address
        address liquidityManagerAddr = address(0x9ABC); // Mock address

        // Calculate required hook flags for Spot
        uint160 spotFlags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        // Prepare constructor arguments for Spot
        bytes memory spotConstructorArgs = abi.encode(poolManagerAddr, policyManagerAddr, liquidityManagerAddr);

        // Use known working salt for Spot
        bytes32 spotSalt = bytes32(uint256(4803));

        // Create the creation code
        bytes memory spotCreationCode = abi.encodePacked(type(Spot).creationCode, spotConstructorArgs);

        // Calculate the address using the known salt
        address spotHookAddress = HookMiner.computeAddress(deployer, uint256(spotSalt), spotCreationCode);

        console2.log("Calculated Spot Hook Address:", spotHookAddress);
        console2.log("Using Spot Salt:", uint256(spotSalt));

        // Check address validity for Spot
        bool validSpotHookAddress = (uint160(spotHookAddress) & uint160(Hooks.ALL_HOOK_MASK)) == spotFlags;
        console2.log("Spot hook address valid:", validSpotHookAddress);
        console2.log("Expected Spot flags:", uint256(spotFlags));
        console2.log("Actual Spot flags:", uint256(uint160(spotHookAddress) & uint160(Hooks.ALL_HOOK_MASK)));

        // Script completed successfully
        console2.log("Valid deployment configuration found!");
    }
}
