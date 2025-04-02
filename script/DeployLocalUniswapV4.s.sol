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
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        address governance = deployerAddress; // Use deployer as governance for local test

        vm.startBroadcast(deployerPrivateKey);
        
        // Step 1: Deploy PoolManager
        console2.log("Deploying PoolManager...");
        poolManager = new PoolManager(address(uint160(DEFAULT_PROTOCOL_FEE)));
        console2.log("PoolManager deployed at:", address(poolManager));
        
        // Step 2: Deploy Policy Manager
        console2.log("Deploying PolicyManager...");
        policyManager = new PoolPolicyManager(
            governance,      // owner
            100000,          // polSharePpm (10%)
            0,               // fullRangeSharePpm (0%)
            900000,          // lpSharePpm (90% - corrected from 80)
            100,             // minimumTradingFeePpm (0.01%)
            10000,           // feeClaimThresholdPpm (1%)
            1000,            // defaultPolMultiplier (1000)
            300,             // defaultDynamicFeePpm (0.03%)
            4,               // tickScalingFactor
            new uint24[](0)  // supportedTickSpacings (empty for now)
        );
        console2.log("PolicyManager deployed at:", address(policyManager));
                
        // Step 3: Deploy FullRange components
        console2.log("Deploying FullRange components...");
        
        // Deploy Liquidity Manager
        liquidityManager = new FullRangeLiquidityManager(IPoolManager(address(poolManager)), governance);
        console2.log("LiquidityManager deployed at:", address(liquidityManager));
        
        // Deploy FullRange (using new 3-arg constructor)
        console2.log("Deploying FullRange hook...");
        fullRange = new FullRange(
            IPoolManager(address(poolManager)),
            IPoolPolicy(address(policyManager)),
            liquidityManager
        );
        console2.log("FullRange hook deployed at:", address(fullRange));
        
        // Deploy DynamicFeeManager AFTER FullRange
        dynamicFeeManager = new FullRangeDynamicFeeManager(
            governance,
            IPoolPolicy(address(policyManager)),
            IPoolManager(address(poolManager)),
            address(fullRange) // Pass actual FullRange address
        );
        console2.log("DynamicFeeManager deployed at:", address(dynamicFeeManager));
        
        // Step 4: Configure deployed contracts
        console2.log("Configuring contracts...");
        liquidityManager.setFullRangeAddress(address(fullRange));
        fullRange.setDynamicFeeManager(dynamicFeeManager); // Set DFM on FullRange

        // Step 5: Deploy test routers
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