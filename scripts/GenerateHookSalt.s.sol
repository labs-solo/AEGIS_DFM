// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Spot} from "../src/Spot.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "../src/interfaces/IFullRangeLiquidityManager.sol";
import {TruncGeoOracleMulti} from "../src/TruncGeoOracleMulti.sol";
import {IDynamicFeeManager} from "../src/interfaces/IDynamicFeeManager.sol";
import {SharedDeployLib} from "../test/utils/SharedDeployLib.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";

contract GenerateHookSalt is Script {
    // Get the flags directly from SharedDeployLib
    uint160 flags = SharedDeployLib.spotHookFlags();

    /// @notice Generate a salt for a Spot hook using env var config
    function run() external returns (bytes32 salt) {
        // Read parameters from environment variables
        address deployer            = vm.envAddress("C2_DEPLOYER");
        address poolManager         = vm.envAddress("POOL_MANAGER");
        address policyManager       = vm.envAddress("POLICY_MANAGER");
        address liquidityManager    = vm.envAddress("LIQUIDITY_MANAGER");
        address oracle              = vm.envAddress("ORACLE");
        address dynamicFeeManager   = vm.envAddress("DFM");

        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManager),
            IPoolPolicy(policyManager),
            IFullRangeLiquidityManager(liquidityManager),
            TruncGeoOracleMulti(oracle),
            IDynamicFeeManager(dynamicFeeManager),
            deployer
        );

        console2.log("Mining salt for flags:", uint256(flags));
        (address hookAddress, bytes32 minedSalt) = HookMiner.find(
            deployer,
            flags,
            type(Spot).creationCode,
            constructorArgs
        );

        salt = minedSalt;

        console2.log("Found valid salt:", vm.toString(salt));
        console2.log("Hook address:", hookAddress);
        // Compute predicted Oracle and DFM addresses using the same deployer and hook
        address gov = vm.envAddress("GOV");
        // Oracle constructor args: (poolManager, governance, policyManager, hookAddress)
        bytes memory oracleArgs = abi.encode(
            IPoolManager(poolManager),
            gov,
            IPoolPolicy(policyManager),
            TruncGeoOracleMulti(hookAddress)
        );
        address predictedOracle = SharedDeployLib.predictDeterministicAddress(
            deployer,
            SharedDeployLib.ORACLE_SALT,
            type(TruncGeoOracleMulti).creationCode,
            oracleArgs
        );
        console2.log("Predicted Oracle Address:", predictedOracle);
        // DFM constructor args: (policyManager, predictedOracle, hookAddress)
        bytes memory dfmArgs = abi.encode(
            IPoolPolicy(policyManager),
            predictedOracle,
            hookAddress
        );
        address predictedDFM = SharedDeployLib.predictDeterministicAddress(
            deployer,
            SharedDeployLib.DFM_SALT,
            type(DynamicFeeManager).creationCode,
            dfmArgs
        );
        console2.log("Predicted DFM Address:", predictedDFM);
        console2.log("");
        console2.log(string.concat("export SPOT_HOOK_SALT=", vm.toString(salt)));

        return salt;
    }
} 