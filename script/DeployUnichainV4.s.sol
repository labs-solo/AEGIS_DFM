// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

// Uniswap V4 Core
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/test/PoolDonateTest.sol";

// Deployed Contracts (Dependencies Only)
import {FullRangeLiquidityManager} from "../src/FullRangeLiquidityManager.sol";
import {PoolPolicyManager} from "../src/PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "../src/TruncGeoOracleMulti.sol";

// Interfaces and Libraries (Needed for Types)
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";

// Unused imports removed: Spot, FullRangeDynamicFeeManager, DefaultPoolCreationPolicy, HookMiner, Hooks, IERC20

/**
 * @title DeployUnichainV4 Dependencies Only
 * @notice Deployment script for Unichain Mainnet - DEPLOYS DEPENDENCIES ONLY.
 *         Hook, DynamicFeeManager deployment, configuration, and pool initialization
 *         are expected to happen externally (e.g., in test setup).
 * This script sets up:
 * 1. Uses the existing PoolManager on Unichain mainnet
 * 2. Deploys TruncGeoOracleMulti, PoolPolicyManager, FullRangeLiquidityManager
 * 3. Deploys test utility routers for liquidity, swaps, and donations
 */
contract DeployUnichainV4 is Script {
    // Deployed contract references
    IPoolManager public poolManager; // Reference to existing manager
    PoolPolicyManager public policyManager; // Deployed
    FullRangeLiquidityManager public liquidityManager; // Deployed
    TruncGeoOracleMulti public truncGeoOracle; // Deployed
    // Removed: dynamicFeeManager, fullRange

    // Test contract references
    PoolModifyLiquidityTest public lpRouter; // Deployed
    PoolSwapTest public swapRouter; // Deployed
    PoolDonateTest public donateRouter; // Deployed

    // Deployment parameters (Constants remain, used by external setup)
    uint24 public constant FEE = 3000; // Pool fee (0.3%)
    int24 public constant TICK_SPACING = 60; // Tick spacing
    uint160 public constant INITIAL_SQRT_PRICE_X96 = 79228162514264337593543950336; // 1:1 price

    // Unichain Mainnet-specific addresses
    address public constant UNICHAIN_POOL_MANAGER = 0x1F98400000000000000000000000000000000004; // Official Unichain PoolManager

    // Official tokens (Constants remain, used by external setup)
    address public constant WETH = 0x4200000000000000000000000000000000000006; // WETH9 on Unichain
    address public constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6; // Circle USDC on Unichain

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        address governance = deployerAddress; // Use deployer as governance for this deployment

        console2.log("=== Dependency Deployment Script Starting ===");
        console2.log("Running on chain ID:", block.chainid);
        console2.log("Deployer address:", deployerAddress);
        console2.log("==========================================");

        // Step 1: Use existing PoolManager
        console2.log("Using Unichain PoolManager at:", UNICHAIN_POOL_MANAGER);
        poolManager = IPoolManager(UNICHAIN_POOL_MANAGER);

        // --- Broadcast: Deploy Dependencies & Test Routers ---
        console2.log("\n--- Starting Broadcast: Dependencies & Test Routers ---");
        vm.startBroadcast(deployerPrivateKey);

        // Step 2: Deploy Policy Manager
        console2.log("Deploying PoolPolicyManager...");
        uint24[] memory supportedTickSpacings = new uint24[](3);
        supportedTickSpacings[0] = 10;
        supportedTickSpacings[1] = 60;
        supportedTickSpacings[2] = 200;

        policyManager = new PoolPolicyManager(
            governance,
            FEE,
            supportedTickSpacings,
            1e17, // Interest Fee
            address(0) // Fee Collector
        );
        console2.log("PoolPolicyManager Deployed at:", address(policyManager));

        // Step 2.5: Deploy Oracle (needs policyManager)
        console2.log("Deploying TruncGeoOracleMulti...");
        truncGeoOracle = new TruncGeoOracleMulti(poolManager, governance, policyManager);
        console2.log("TruncGeoOracleMulti deployed at:", address(truncGeoOracle));

        // Step 3: Deploy Liquidity Manager
        console2.log("Deploying Liquidity Manager...");
        liquidityManager = new FullRangeLiquidityManager(poolManager, governance);
        console2.log("LiquidityManager deployed at:", address(liquidityManager));

        // Step 4: Deploy test routers
        console2.log("Deploying test routers...");
        lpRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);
        donateRouter = new PoolDonateTest(poolManager);
        console2.log("Test LiquidityRouter deployed at:", address(lpRouter));
        console2.log("Test SwapRouter deployed at:", address(swapRouter));
        console2.log("Test Donate Router deployed at:", address(donateRouter));

        // Removed: Hook deployment, Dynamic Fee Manager deployment, configurations, pool initialization

        vm.stopBroadcast();
        console2.log("--- Broadcast Complete ---");

        // Output summary
        console2.log("\n=== Dependency Deployment Complete ===");
        console2.log("Using Unichain PoolManager:", address(poolManager));
        console2.log("Deployed PolicyManager:", address(policyManager));
        console2.log("Deployed LiquidityManager:", address(liquidityManager));
        console2.log("Deployed TruncGeoOracleMulti:", address(truncGeoOracle));
        console2.log("Deployed Test LP Router:", address(lpRouter));
        console2.log("Deployed Test Swap Router:", address(swapRouter));
        console2.log("Deployed Test Donate Router:", address(donateRouter));
    }

    // Removed: _getHookSaltConfig function (no longer needed here)
}
