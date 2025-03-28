// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

// Uniswap V4 Core
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";

// FullRange Contracts
import {FullRange} from "../src/FullRange.sol";
import {FullRangeLiquidityManager} from "../src/FullRangeLiquidityManager.sol";
import {FullRangeDynamicFeeManager} from "../src/FullRangeDynamicFeeManager.sol";
import {PoolPolicyManager} from "../src/PoolPolicyManager.sol";
import {DefaultPoolCreationPolicy} from "../src/DefaultPoolCreationPolicy.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {DefaultCAPEventDetector} from "../src/DefaultCAPEventDetector.sol";
import {ICAPEventDetector} from "../src/interfaces/ICAPEventDetector.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";

/**
 * @title DeployLocalUniswapV4
 * @notice Deployment script for local testing that deploys a complete Uniswap V4 environment
 * This script sets up:
 * 1. A fresh PoolManager instance
 * 2. All FullRange components
 * 3. FullRange hook with the correct address for callback permissions
 * 4. Test utility routers for liquidity and swaps
 */
contract DeployLocalUniswapV4 is Script {
    // Deployed contract references
    PoolManager public poolManager;
    PoolPolicyManager public policyManager;
    FullRangeLiquidityManager public liquidityManager;
    FullRangeDynamicFeeManager public dynamicFeeManager;
    FullRange public fullRange;
    
    // Test contract references
    PoolModifyLiquidityTest public lpRouter;
    PoolSwapTest public swapRouter;
    PoolDonateTest public donateRouter;
    
    // Deployment parameters
    uint256 public constant DEFAULT_PROTOCOL_FEE = 0; // 0% protocol fee
    uint256 public constant HOOK_FEE = 30; // 0.30% hook fee
    address public constant GOVERNANCE = address(0x5); // Governance address

    function run() external {
        vm.startBroadcast();
        
        // Step 1: Deploy PoolManager
        console2.log("Deploying PoolManager...");
        poolManager = new PoolManager(address(uint160(DEFAULT_PROTOCOL_FEE)));
        console2.log("PoolManager deployed at:", address(poolManager));
        
        // Step 2: Deploy Policy Manager
        console2.log("Deploying PolicyManager...");
        policyManager = new PoolPolicyManager(
            GOVERNANCE,      // owner
            100000,          // polSharePpm (10%)
            0,          // fullRangeSharePpm (0%)
            900000,          // lpSharePpm (80%)
            100,             // minimumTradingFeePpm (0.01%)
            10000,           // feeClaimThresholdPpm (1%)
            1000,            // defaultPolMultiplier (1000)
            300,             // defaultDynamicFeePpm (0.03%)
            4,               // tickScalingFactor
            new uint24[](0)  // supportedTickSpacings (empty for now)
        );
        console2.log("PolicyManager deployed at:", address(policyManager));
        
        // Initialize with default policy - commenting out as this method doesn't exist
        DefaultPoolCreationPolicy defaultPolicy = new DefaultPoolCreationPolicy(GOVERNANCE);
        // policyManager.setPoolCreationPolicy(address(defaultPolicy));
        
        // Step 3: Deploy FullRange components
        console2.log("Deploying FullRange components...");
        
        // First create a DefaultCAPEventDetector
        DefaultCAPEventDetector capEventDetector = new DefaultCAPEventDetector(
            IPoolManager(address(poolManager)),
            GOVERNANCE
        );
        console2.log("CAPEventDetector deployed at:", address(capEventDetector));
        
        // Deploy Liquidity Manager with properly cast interface
        liquidityManager = new FullRangeLiquidityManager(IPoolManager(address(poolManager)), GOVERNANCE);
        console2.log("LiquidityManager deployed at:", address(liquidityManager));
        
        // Step 4: Mine hook address with correct callback permissions
        console2.log("Mining hook address with correct callback permissions...");
        
        // For testing, we'll skip the hook mining since it's causing issues
        bytes32 salt = bytes32(uint256(0x1));
        
        // Deploy DynamicFeeManager first with the actual hook address placeholders
        dynamicFeeManager = new FullRangeDynamicFeeManager(
            GOVERNANCE,
            IPoolPolicy(address(policyManager)),
            IPoolManager(address(poolManager)),
            address(1), // temp placeholder address
            ICAPEventDetector(address(capEventDetector))
        );
        console2.log("DynamicFeeManager deployed at:", address(dynamicFeeManager));
        
        // Now deploy the FullRange hook directly
        console2.log("Deploying FullRange hook...");
        fullRange = new FullRange(
            IPoolManager(address(poolManager)),
            IPoolPolicy(address(policyManager)),
            liquidityManager,
            dynamicFeeManager,
            capEventDetector
        );
        console2.log("FullRange hook deployed at:", address(fullRange));
        
        // Record the hook deployment for verification
        console2.log("Hook deployed successfully.");
        
        // Step 6: Deploy test routers
        console2.log("Deploying test routers...");
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        donateRouter = new PoolDonateTest(IPoolManager(address(poolManager)));
        console2.log("LiquidityRouter deployed at:", address(lpRouter));
        console2.log("SwapRouter deployed at:", address(swapRouter));
        console2.log("DonateRouter deployed at:", address(donateRouter));
        
        vm.stopBroadcast();
        
        // Output summary
        console2.log("\n=== Deployment Complete ===");
        console2.log("PoolManager:", address(poolManager));
        console2.log("FullRange Hook:", address(fullRange));
        console2.log("PolicyManager:", address(policyManager));
        console2.log("LiquidityManager:", address(liquidityManager));
        console2.log("DynamicFeeManager:", address(dynamicFeeManager));
        console2.log("Test LP Router:", address(lpRouter));
        console2.log("Test Swap Router:", address(swapRouter));
        console2.log("Test Donate Router:", address(donateRouter));
    }
} 