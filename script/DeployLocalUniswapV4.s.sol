// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Script.sol";
// import {Strings} from "@openzeppelin/contracts/utils/Strings.sol"; // Removed

// Uniswap V4 Core
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";

// FullRange Contracts
import {Spot} from "../src/Spot.sol";
import {FullRangeLiquidityManager} from "../src/FullRangeLiquidityManager.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {PoolPolicyManager} from "../src/PoolPolicyManager.sol";
// import {DefaultPoolCreationPolicy} from "../src/DefaultPoolCreationPolicy.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TruncGeoOracleMulti} from "../src/TruncGeoOracleMulti.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

// Test Tokens
import {MockERC20} from "../src/token/MockERC20.sol";

// New imports
import {IFullRangeLiquidityManager} from "../src/interfaces/IFullRangeLiquidityManager.sol";
import {IDynamicFeeManager} from "../src/interfaces/IDynamicFeeManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {HookMiner as HMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {DummyFullRangeHook} from "utils/DummyFullRangeHook.sol";
import {ExtendedPositionManager} from "../src/ExtendedPositionManager.sol";

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
    uint24 constant EXPECTED_MIN_DYNAMIC_FEE     =  100; // 0.01 %
    uint24 constant EXPECTED_MAX_DYNAMIC_FEE     = 50000; // 5 %
    uint24 constant EXPECTED_DEFAULT_DYNAMIC_FEE =  5000; // 0.5 %

    // ADD using directive HERE
    using PoolIdLibrary for PoolId;

    // Deployed contract references
    PoolManager public poolManager;
    PoolPolicyManager public policyManager;
    FullRangeLiquidityManager public liquidityManager;
    DynamicFeeManager public dynamicFeeManager;
    Spot public fullRange;
    TruncGeoOracleMulti public truncGeoOracle;

    // Test contract references
    PoolModifyLiquidityTest public lpRouter;
    PoolSwapTest public swapRouter;
    PoolDonateTest public donateRouter;

    // Deployment parameters
    uint256 public constant DEFAULT_PROTOCOL_FEE = 0; // 0% protocol fee
    uint256 public constant HOOK_FEE = 30; // 0.30% hook fee
    uint24 public constant FEE = 3000; // Added FEE constant (0.3%)
    int24 public constant TICK_SPACING = 60; // Added TICK_SPACING constant
    uint160 public constant INITIAL_SQRT_PRICE_X96 = 79228162514264337593543950336; // Added INITIAL_SQRT_PRICE_X96 (1:1 price)

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        /* governance is the deployer in local test-nets */
        address governance = deployer;

        vm.startBroadcast(deployerKey);

        // Step 1: Deploy PoolManager
        console.log("Deploying PoolManager...");
        poolManager = new PoolManager(address(uint160(DEFAULT_PROTOCOL_FEE)));
        console.log("PoolManager deployed at:", address(poolManager));

        // Deploy Test Tokens Here
        console.log("Deploying Test Tokens...");
        MockERC20 localToken0 = new MockERC20("Token0", "TKN0", 18);
        MockERC20 localToken1 = new MockERC20("Token1", "TKN1", 18);
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

        // Step 2: Deploy Policy Manager
        console.log("Deploying PoolPolicyManager...");
        uint24[] memory supportedTickSpacings = new uint24[](3);
        supportedTickSpacings[0] = 10;
        supportedTickSpacings[1] = 60;
        supportedTickSpacings[2] = 200;
        policyManager = new PoolPolicyManager(
            msg.sender,
            EXPECTED_DEFAULT_DYNAMIC_FEE,
            supportedTickSpacings,
            0,
            msg.sender,
            EXPECTED_MIN_DYNAMIC_FEE,     // NEW: min base fee
            EXPECTED_MAX_DYNAMIC_FEE      // NEW: max base fee
        );
        console.log("[DEPLOY] PoolPolicyManager Deployed at:", address(policyManager));

        // Step 2.5: Deploy Oracle now that we have the policyManager
        console.log("Deploying TruncGeoOracleMulti...");
        DummyFullRangeHook fullRangeHook = new DummyFullRangeHook(address(0));
        truncGeoOracle = new TruncGeoOracleMulti(
            poolManager, 
            policyManager, 
            address(fullRangeHook),
            msg.sender // Use deployer as owner
        );
        // Assuming DummyFullRangeHook now has setOracle
        // fullRangeHook.setOracle(address(truncGeoOracle));
        console.log("TruncGeoOracleMulti deployed at:", address(truncGeoOracle));

        // Step 3: Deploy FullRange components
        console.log("Deploying FullRange components...");

        // Deploy Liquidity Manager
        liquidityManager =
            new FullRangeLiquidityManager(
                IPoolManager(address(poolManager)),
                ExtendedPositionManager(payable(address(0))), // placeholder, to be wired later (cast via payable to satisfy compiler)
                IPoolPolicy(address(0)),
                governance
            );
        console.log("LiquidityManager deployed at:", address(liquidityManager));

        // Deploy Spot hook (which is MarginHarness in this script)
        // Use _deployFullRange which now needs poolId
        fullRange = _deployFullRange(deployer, poolId, key, governance);
        console.log("FullRange hook deployed at:", address(fullRange));

        // Deploy DynamicFeeManager AFTER FullRange
        dynamicFeeManager = new DynamicFeeManager(
            governance, // ADDED owner
            policyManager, // policy
            address(truncGeoOracle), // oracle
            address(fullRange) // authorizedHook
        );
        console.log("DynamicFeeManager deployed at:", address(dynamicFeeManager));

        // Step 4: Configure deployed contracts
        console.log("Configuring contracts...");
        liquidityManager.setAuthorizedHookAddress(address(fullRange));

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

    // Update _deployFullRange to accept and use PoolId and governance
    function _deployFullRange(
        address _deployer,
        PoolId /* _poolId */,
        PoolKey memory /* _key */,
        address _governance
    )
        internal
        returns (Spot)
    {
        // Calculate required hook flags
        uint160 flags = uint160(
            // Hooks.BEFORE_INITIALIZE_FLAG | // Removed if not used
            Hooks.AFTER_INITIALIZE_FLAG
            // Hooks.BEFORE_ADD_LIQUIDITY_FLAG | // Removed if not used
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            // Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | // Removed if not used
            | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        // Predict hook address first to deploy MarginManager
        bytes memory spotCreationCodePlaceholder = abi.encodePacked(
            type(Spot).creationCode, // Use Spot instead of MarginHarness
            abi.encode(
                IPoolManager(address(poolManager)),
                policyManager,
                liquidityManager,
                TruncGeoOracleMulti(address(0)), // Oracle placeholder (will be set later)
                IDynamicFeeManager(address(0)), // DynamicFeeManager placeholder (will be set later)
                _deployer // Add _deployer as owner
            )
        );
        (address predictedHookAddress,) = HMiner.find(
            _deployer,
            flags,
            spotCreationCodePlaceholder, // Use Spot creation code
            bytes("")
        );
        console.log("Predicted hook address:", predictedHookAddress);

        // Prepare final Spot constructor args
        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(poolManager)),
            policyManager,
            liquidityManager,
            TruncGeoOracleMulti(address(0)), // Oracle placeholder (will be set later)
            IDynamicFeeManager(address(0)), // DynamicFeeManager placeholder (will be set later)
            _governance // <-- use parameter
        );

        // Recalculate salt with final args
        (address finalHookAddress, bytes32 salt) = HMiner.find(
            _deployer,
            flags,
            abi.encodePacked(type(Spot).creationCode, constructorArgs), // Use Spot creation code
            bytes("")
        );
        console.log("Calculated final hook address:", finalHookAddress);
        console.logBytes32(salt);

        // Deploy Spot
        Spot hook = new Spot{salt: salt}(
            poolManager,
            IPoolPolicy(address(policyManager)),
            liquidityManager,
            TruncGeoOracleMulti(address(0)), // Will be set later via setOracleAddress
            IDynamicFeeManager(address(0)), // Will be set later via setDynamicFeeManager
            _governance // governance injected here
        );

        // Verify the deployed address matches the calculated address
        require(address(hook) == finalHookAddress, "HookMiner address mismatch");
        console.log("Deployed hook address:", address(hook));

        return hook;
    }

    function _onPoolCreated(
        IPoolManager /* manager */,
        uint160      /* sqrtPriceX96 */,
        int24        /* tick */
    ) internal pure {
        // logging stripped; nothing else to do
    }
}
