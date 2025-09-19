// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Uniswap V4 imports
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

// local scripts contracts

import {UniswapV4Config} from "./base/UniswapV4Config.sol";

// local src contracts
import {Spot} from "src/Spot.sol";
import {FullRangeLiquidityManager} from "src/FullRangeLiquidityManager.sol";
import {PoolPolicyManager} from "src/PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "src/TruncGeoOracleMulti.sol";
import {DynamicFeeManager} from "src/DynamicFeeManager.sol";

contract DeployScript is Script, UniswapV4Config {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Deployed contracts struct for easy reference
    struct DeployedContracts {
        address policyManager;
        address oracle;
        address feeManager;
        address liquidityManager;
        address spot;
    }

    // Configuration variables
    UniswapV4 private uniswapV4;
    address private deployer;
    uint256 private dailyBudget; // NOTE: if we use default(i.e. 0) then 1e6 will be used in PPM.constructor

    function run() external {
        // Load Uniswap V4 addresses
        uniswapV4 = getChainConfig();

        string memory activeProfile = vm.envString("FOUNDRY_PROFILE");

        console.log("=== Deployment Configuration ===");
        console.log("Active profile:", activeProfile);
        console.log("Chain ID:", block.chainid);

        console.log("=== Uniswap V4 Info ===");
        console.log("Pool Manager:", address(uniswapV4.poolManager));
        console.log("Position Manager:", address(uniswapV4.positionManager));
        console.log("Daily Budget:", dailyBudget);
        console.log("===========================");

        // Deploy contracts
        DeployedContracts memory deployed = deployAllContracts();

        // Log deployment results
        logDeploymentResults(deployed);

        console.log("Deployment completed successfully!");
    }

    function deployAllContracts() internal returns (DeployedContracts memory deployed) {
        vm.startBroadcast();

        deployer = msg.sender;
        console.log("Deployer:", deployer);
        console.log("Starting deployment...");

        // Step 1: Precompute ALL deployment addresses first (before any deployments)
        uint256 currentNonce = vm.getNonce(deployer);
        console.log("Current nonce:", currentNonce);

        address policyManagerAddress = computeCreateAddress(deployer, currentNonce);
        address oracleAddress = computeCreateAddress(deployer, currentNonce + 1);
        address feeManagerAddress = computeCreateAddress(deployer, currentNonce + 2);
        address liquidityManagerAddress = computeCreateAddress(deployer, currentNonce + 3);

        console.log("Precomputed addresses:");
        console.log("PolicyManager:", policyManagerAddress);
        console.log("Oracle:", oracleAddress);
        console.log("FeeManager:", feeManagerAddress);
        console.log("LiquidityManager:", liquidityManagerAddress);

        // Step 2: Mine hook address with precomputed addresses
        uint160 hookFlags = getSpotHookFlags();
        console.log("Mining hook address with flags:", hookFlags);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            hookFlags,
            type(Spot).creationCode,
            abi.encode(
                address(uniswapV4.poolManager),
                liquidityManagerAddress,
                policyManagerAddress,
                oracleAddress,
                feeManagerAddress
            )
        );

        console.log("Hook address found:", hookAddress);
        console.log("Salt:", vm.toString(salt));

        // Step 3: Deploy PoolPolicyManager
        console.log("Deploying PoolPolicyManager...");
        PoolPolicyManager policyManager = new PoolPolicyManager(
            deployer, // governance
            dailyBudget
        );
        deployed.policyManager = address(policyManager);
        require(deployed.policyManager == policyManagerAddress, "PolicyManager address mismatch");
        console.log("PoolPolicyManager deployed at:", deployed.policyManager);

        // Step 4: Deploy TruncGeoOracleMulti
        console.log("Deploying TruncGeoOracleMulti...");
        TruncGeoOracleMulti oracle =
            new TruncGeoOracleMulti(uniswapV4.poolManager, policyManager, hookAddress, deployer);
        deployed.oracle = address(oracle);
        require(deployed.oracle == oracleAddress, "Oracle address mismatch");
        console.log("TruncGeoOracleMulti deployed at:", deployed.oracle);

        // Step 5: Deploy DynamicFeeManager
        console.log("Deploying DynamicFeeManager...");
        DynamicFeeManager feeManager = new DynamicFeeManager(deployer, policyManager, deployed.oracle, hookAddress);
        deployed.feeManager = address(feeManager);
        require(deployed.feeManager == feeManagerAddress, "FeeManager address mismatch");
        console.log("DynamicFeeManager deployed at:", deployed.feeManager);

        // Step 6: Deploy FullRangeLiquidityManager
        console.log("Deploying FullRangeLiquidityManager...");
        FullRangeLiquidityManager liquidityManager =
            new FullRangeLiquidityManager(uniswapV4.poolManager, uniswapV4.positionManager, oracle, hookAddress);
        deployed.liquidityManager = address(liquidityManager);
        require(deployed.liquidityManager == liquidityManagerAddress, "LiquidityManager address mismatch");
        console.log("FullRangeLiquidityManager deployed at:", deployed.liquidityManager);

        // Step 7: Deploy Spot hook using precomputed addresses
        console.log("Deploying Spot hook...");
        Spot spot = new Spot{salt: salt}(uniswapV4.poolManager, liquidityManager, policyManager, oracle, feeManager);
        deployed.spot = address(spot);
        require(deployed.spot == hookAddress, "Hook address mismatch");
        console.log("Spot hook deployed at:", deployed.spot);

        // Step 8: Post-deployment configuration - authorize Spot hook in PoolPolicyManager
        console.log("Configuring post-deployment authorizations...");
        policyManager.setAuthorizedHook(deployed.spot);
        console.log("Spot hook authorized in PoolPolicyManager");

        vm.stopBroadcast();

        return deployed;
    }

    function getSpotHookFlags() internal pure returns (uint160) {
        return Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG
            | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    }

    function logDeploymentResults(DeployedContracts memory deployed) internal view {
        console.log("\n=== Deployment Results ===");
        console.log("PoolPolicyManager:", deployed.policyManager);
        console.log("TruncGeoOracleMulti:", deployed.oracle);
        console.log("DynamicFeeManager:", deployed.feeManager);
        console.log("FullRangeLiquidityManager:", deployed.liquidityManager);
        console.log("Spot Hook:", deployed.spot);
        console.log("=========================\n");
    }
}
