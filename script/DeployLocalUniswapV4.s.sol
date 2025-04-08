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
import {Spot} from "../src/Spot.sol";
import {FullRangeLiquidityManager} from "../src/FullRangeLiquidityManager.sol";
import {FullRangeDynamicFeeManager} from "../src/FullRangeDynamicFeeManager.sol";
import {PoolPolicyManager} from "../src/PoolPolicyManager.sol";
import {DefaultPoolCreationPolicy} from "../src/DefaultPoolCreationPolicy.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TruncGeoOracleMulti} from "../src/TruncGeoOracleMulti.sol";

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
    Spot public fullRange;
    TruncGeoOracleMulti public truncGeoOracle;
    
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
        
        // Step 1.5: Deploy Oracle (BEFORE PolicyManager)
        console2.log("Deploying TruncGeoOracleMulti...");
        truncGeoOracle = new TruncGeoOracleMulti(poolManager, governance);
        console2.log("TruncGeoOracleMulti deployed at:", address(truncGeoOracle));
        
        // Step 2: Deploy Policy Manager
        console2.log("Deploying PolicyManager...");
        uint24[] memory supportedTickSpacings = new uint24[](3);
        supportedTickSpacings[0] = 10;
        supportedTickSpacings[1] = 60;
        supportedTickSpacings[2] = 200;

        policyManager = new PoolPolicyManager(
            governance,
            250000, // POL_SHARE_PPM (25%)
            250000, // FULLRANGE_SHARE_PPM (25%)
            500000, // LP_SHARE_PPM (50%)
            1000,   // MIN_TRADING_FEE_PPM (0.1%)
            10000,  // FEE_CLAIM_THRESHOLD_PPM (1%)
            10,     // DEFAULT_POL_MULTIPLIER
            3000,   // DEFAULT_DYNAMIC_FEE_PPM (0.3%)
            2,      // TICK_SCALING_FACTOR
            supportedTickSpacings,
            1e17,   // Protocol Interest Fee Percentage (10%)
            address(0) // Fee Collector
        );
        console2.log("[DEPLOY] PoolPolicyManager Deployed at:", address(policyManager));
                
        // Step 3: Deploy FullRange components
        console2.log("Deploying FullRange components...");
        
        // Deploy Liquidity Manager
        liquidityManager = new FullRangeLiquidityManager(IPoolManager(address(poolManager)), governance);
        console2.log("LiquidityManager deployed at:", address(liquidityManager));
        
        // Deploy Spot hook
        fullRange = _deployFullRange(deployerAddress);
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
        console2.log("Test Donate Router:", address(donateRouter));
        
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

    function _deployFullRange(address _deployer) internal returns (Spot) {
        // Calculate required hook flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        // Prepare constructor arguments for Spot (WITHOUT dynamicFeeManager)
        bytes memory constructorArgs = abi.encode(
            address(poolManager),
            IPoolPolicy(address(policyManager)),
            address(liquidityManager)
        );

        // Find salt using the correct deployer
        (address hookAddress, bytes32 salt) = HookMiner.find(
            _deployer, // Use the passed deployer address
            flags,
            abi.encodePacked(type(Spot).creationCode, constructorArgs),
            bytes("") // Constructor args already packed into creation code
        );

        console.log("Calculated hook address:", hookAddress);
        console.logBytes32(salt);

        // Deploy the hook using the mined salt and CORRECT constructor args
        Spot fullRangeInstance = new Spot{salt: salt}(
            poolManager,
            IPoolPolicy(address(policyManager)),
            liquidityManager
        );

        // Verify the deployed address matches the calculated address
        require(address(fullRangeInstance) == hookAddress, "HookMiner address mismatch");
        console.log("Deployed hook address:", address(fullRangeInstance));

        return fullRangeInstance;
    }
} 