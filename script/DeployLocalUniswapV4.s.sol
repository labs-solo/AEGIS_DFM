// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Script.sol";

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
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {MarginManager} from "../src/MarginManager.sol";

// Test Tokens
import { MockERC20 as TestERC20 } from "forge-std/mocks/MockERC20.sol";

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
    MarginManager public marginManager;
    
    // Test contract references
    PoolModifyLiquidityTest public lpRouter;
    PoolSwapTest public swapRouter;
    PoolDonateTest public donateRouter;
    
    // Deployment parameters
    uint256 public constant DEFAULT_PROTOCOL_FEE = 0; // 0% protocol fee
    uint256 public constant HOOK_FEE = 30; // 0.30% hook fee
    address public constant GOVERNANCE = address(0x5); // Governance address
    uint24 public constant FEE = 3000; // Added FEE constant (0.3%)
    int24 public constant TICK_SPACING = 60; // Added TICK_SPACING constant
    uint160 public constant INITIAL_SQRT_PRICE_X96 = 79228162514264337593543950336; // Added INITIAL_SQRT_PRICE_X96 (1:1 price)

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        address governance = deployerAddress; // Use deployer as governance for local test

        vm.startBroadcast(deployerPrivateKey);
        
        // Step 1: Deploy PoolManager
        console.log("Deploying PoolManager...");
        poolManager = new PoolManager(address(uint160(DEFAULT_PROTOCOL_FEE)));
        console.log("PoolManager deployed at:", address(poolManager));

        // Deploy Test Tokens Here
        console.log("Deploying Test Tokens...");
        TestERC20 localToken0 = new TestERC20();
        TestERC20 localToken1 = new TestERC20();
        if (address(localToken0) > address(localToken1)) {
            (localToken0, localToken1) = (localToken1, localToken0);
        }
        console.log("Token0 deployed at:", address(localToken0));
        console.log("Token1 deployed at:", address(localToken1));

        // Create Pool Key using deployed tokens
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(localToken0)), // Use deployed token0
            currency1: Currency.wrap(address(localToken1)), // Use deployed token1
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0)) // Placeholder hook address initially
        });
        PoolId poolId = PoolIdLibrary.toId(key); // Use library for PoolId calculation
        
        // Step 1.5: Deploy Oracle (BEFORE PolicyManager)
        console.log("Deploying TruncGeoOracleMulti...");
        truncGeoOracle = new TruncGeoOracleMulti(poolManager, governance);
        console.log("TruncGeoOracleMulti deployed at:", address(truncGeoOracle));
        
        // Step 2: Deploy Policy Manager
        console.log("Deploying PolicyManager...");
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
        console.log("[DEPLOY] PoolPolicyManager Deployed at:", address(policyManager));
                
        // Step 3: Deploy FullRange components
        console.log("Deploying FullRange components...");
        
        // Deploy Liquidity Manager
        liquidityManager = new FullRangeLiquidityManager(IPoolManager(address(poolManager)), governance);
        console.log("LiquidityManager deployed at:", address(liquidityManager));
        
        // Deploy Spot hook (which is MarginHarness in this script)
        // Use _deployFullRange which now needs poolId
        fullRange = _deployFullRange(deployerAddress, poolId, key); // Pass poolId and key
        console.log("FullRange hook deployed at:", address(fullRange));
        
        // Deploy DynamicFeeManager AFTER FullRange
        dynamicFeeManager = new FullRangeDynamicFeeManager(
            governance,
            IPoolPolicy(address(policyManager)),
            IPoolManager(address(poolManager)),
            address(fullRange) // Pass actual FullRange address
        );
        console.log("DynamicFeeManager deployed at:", address(dynamicFeeManager));
        
        // Step 4: Configure deployed contracts
        console.log("Configuring contracts...");
        liquidityManager.setAuthorizedHookAddress(address(fullRange));
        fullRange.setDynamicFeeManager(address(dynamicFeeManager)); // Set DFM on FullRange

        // Initialize Pool (requires hook address in key now)
        key.hooks = IHooks(address(fullRange)); // Update key with actual hook address
        poolManager.initialize(key, INITIAL_SQRT_PRICE_X96);

        // Step 5: Deploy test routers
        console.log("Deploying test routers...");
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        donateRouter = new PoolDonateTest(IPoolManager(address(poolManager)));
        console.log("LiquidityRouter deployed at:", address(lpRouter));
        console.log("SwapRouter deployed at:", address(swapRouter));
        console.log("Test Donate Router:", address(donateRouter));
        
        vm.stopBroadcast();
        
        // Output summary
        console.log("\n=== Deployment Complete ===");
        console.log("PoolManager:", address(poolManager));
        console.log("FullRange Hook:", address(fullRange));
        console.log("PolicyManager:", address(policyManager));
        console.log("LiquidityManager:", address(liquidityManager));
        console.log("DynamicFeeManager:", address(dynamicFeeManager));
        console.log("Test LP Router:", address(lpRouter));
        console.log("Test Swap Router:", address(swapRouter));
        console.log("Test Donate Router:", address(donateRouter));
    }

    // Update _deployFullRange to accept and use PoolId
    function _deployFullRange(address _deployer, PoolId _poolId, PoolKey memory _key) internal returns (Spot) {
        // Calculate required hook flags
        uint160 flags = uint160(
            // Hooks.BEFORE_INITIALIZE_FLAG | // Removed if not used
            Hooks.AFTER_INITIALIZE_FLAG |
            // Hooks.BEFORE_ADD_LIQUIDITY_FLAG | // Removed if not used
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            // Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | // Removed if not used
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        // Predict hook address first to deploy MarginManager
        bytes memory spotCreationCodePlaceholder = abi.encodePacked(
            type(Spot).creationCode, // Use Spot instead of MarginHarness
            abi.encode(IPoolManager(address(poolManager)), policyManager, liquidityManager) // Remove _poolId
        );
        (address predictedHookAddress, ) = HookMiner.find(
            _deployer,
            flags,
            spotCreationCodePlaceholder, // Use Spot creation code
            bytes("")
        );
        console.log("Predicted hook address:", predictedHookAddress);

        // Deploy MarginManager using predicted hook address
        uint256 initialSolvencyThreshold = 98e16; // 98%
        uint256 initialLiquidationFee = 1e16; // 1%
        marginManager = new MarginManager(
            predictedHookAddress,
            address(poolManager),
            address(liquidityManager),
            _deployer, // governance = deployer
            initialSolvencyThreshold,
            initialLiquidationFee
        );
        console.log("MarginManager deployed at:", address(marginManager));

        // Prepare final Spot constructor args
        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(poolManager)),
            policyManager,
            liquidityManager
        );

        // Recalculate salt with final args
        (address finalHookAddress, bytes32 salt) = HookMiner.find(
            _deployer,
            flags,
            abi.encodePacked(type(Spot).creationCode, constructorArgs), // Use Spot creation code
            bytes("")
        );
        console.log("Calculated final hook address:", finalHookAddress);
        console.logBytes32(salt);

        // Deploy Spot
        Spot fullRangeInstance = new Spot{salt: salt}( // Use Spot instead of MarginHarness
            poolManager,
            IPoolPolicy(address(policyManager)),
            liquidityManager
        );

        // Verify the deployed address matches the calculated address
        require(address(fullRangeInstance) == finalHookAddress, "HookMiner address mismatch");
        console.log("Deployed hook address:", address(fullRangeInstance));

        return fullRangeInstance; // Return the Spot instance directly
    }
} 