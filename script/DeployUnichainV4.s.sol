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

// For IERC20 interface
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title DeployUnichainV4
 * @notice Deployment script for Unichain Mainnet that integrates with the existing PoolManager
 * This script sets up:
 * 1. Uses the existing PoolManager on Unichain mainnet
 * 2. All FullRange components
 * 3. FullRange hook with the correct address for callback permissions
 * 4. Test utility routers for liquidity and swaps
 * 5. Creates a pool with existing tokens on Unichain
 */
contract DeployUnichainV4 is Script {
    // Deployed contract references
    IPoolManager public poolManager;
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
    uint256 public constant HOOK_FEE = 30; // 0.30% hook fee
    uint24 public constant FEE = 3000; // Pool fee (0.3%)
    int24 public constant TICK_SPACING = 60; // Tick spacing
    uint160 public constant INITIAL_SQRT_PRICE_X96 = 79228162514264337593543950336; // 1:1 price
    
    // Unichain Mainnet-specific addresses
    address public constant UNICHAIN_POOL_MANAGER = 0x1F98400000000000000000000000000000000004; // Official Unichain PoolManager
    
    // Official tokens on Unichain Mainnet
    address public constant WETH = 0x4200000000000000000000000000000000000006; // WETH9 on Unichain
    address public constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6; // Circle USDC on Unichain

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        address governance = deployerAddress; // Use deployer as governance for this deployment

        vm.startBroadcast(deployerPrivateKey);
        
        // Step 1: Use existing PoolManager on Unichain
        console.log("Using Unichain PoolManager at:", UNICHAIN_POOL_MANAGER);
        poolManager = IPoolManager(UNICHAIN_POOL_MANAGER);
        
        // Create Pool Key using existing tokens - make sure to order them correctly
        address token0;
        address token1;
        if (uint160(WETH) < uint160(USDC)) {
            token0 = WETH;
            token1 = USDC;
        } else {
            token0 = USDC;
            token1 = WETH;
        }
        console.log("Using token0:", token0);
        console.log("Using token1:", token1);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0)) // Placeholder hook address initially
        });
        PoolId poolId = PoolIdLibrary.toId(key);
        
        // Step 1.5: Deploy Oracle
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
        console.log("PoolPolicyManager Deployed at:", address(policyManager));
                
        // Step 3: Deploy FullRange components
        console.log("Deploying FullRange components...");
        
        // Deploy Liquidity Manager
        liquidityManager = new FullRangeLiquidityManager(poolManager, governance);
        console.log("LiquidityManager deployed at:", address(liquidityManager));
        
        // Deploy Spot hook
        fullRange = _deployFullRange(deployerAddress, poolId, key);
        console.log("FullRange hook deployed at:", address(fullRange));
        
        // Deploy DynamicFeeManager AFTER FullRange
        dynamicFeeManager = new FullRangeDynamicFeeManager(
            governance,
            IPoolPolicy(address(policyManager)),
            poolManager,
            address(fullRange)
        );
        console.log("DynamicFeeManager deployed at:", address(dynamicFeeManager));
        
        // Step 4: Configure deployed contracts
        console.log("Configuring contracts...");
        liquidityManager.setAuthorizedHookAddress(address(fullRange));
        fullRange.setDynamicFeeManager(address(dynamicFeeManager));

        // Initialize Pool (requires hook address in key now)
        key.hooks = IHooks(address(fullRange));
        poolManager.initialize(key, INITIAL_SQRT_PRICE_X96);

        // Step 5: Deploy test routers
        console.log("Deploying test routers...");
        lpRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);
        donateRouter = new PoolDonateTest(poolManager);
        console.log("LiquidityRouter deployed at:", address(lpRouter));
        console.log("SwapRouter deployed at:", address(swapRouter));
        console.log("DonateRouter deployed at:", address(donateRouter));
        
        vm.stopBroadcast();
        
        // Output summary
        console.log("\n=== Deployment Complete ===");
        console.log("Unichain PoolManager:", address(poolManager));
        console.log("FullRange Hook:", address(fullRange));
        console.log("PolicyManager:", address(policyManager));
        console.log("LiquidityManager:", address(liquidityManager));
        console.log("DynamicFeeManager:", address(dynamicFeeManager));
        console.log("Test LP Router:", address(lpRouter));
        console.log("Test Swap Router:", address(swapRouter));
        console.log("Test Donate Router:", address(donateRouter));
    }

    function _deployFullRange(address _deployer, PoolId _poolId, PoolKey memory _key) internal returns (Spot) {
        // Calculate required hook flags
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        // Prepare constructor arguments for Spot
        bytes memory constructorArgs = abi.encode(
            poolManager,
            IPoolPolicy(address(policyManager)),
            liquidityManager
        );
        
        // Use a fixed, known-working salt to ensure deterministic deployment
        bytes32 salt = 0x00000000000000000000000000000000000000000000000000000000000048bd;
        
        // Calculate the expected hook address
        address hookAddress = HookMiner.computeAddress(
            _deployer,
            uint256(salt),
            abi.encodePacked(type(Spot).creationCode, constructorArgs)
        );
        
        console.log("Calculated hook address:", hookAddress);
        console.logBytes32(salt);

        // Deploy Spot with the salt
        Spot spot = new Spot{salt: salt}(
            poolManager,
            IPoolPolicy(address(policyManager)),
            liquidityManager
        );

        // Verify the deployed address matches the calculated address
        require(address(spot) == hookAddress, "Hook address mismatch");
        
        return spot;
    }
} 