// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Spot} from "../src/Spot.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "../src/interfaces/IFullRangeLiquidityManager.sol";
import {PoolPolicyManager} from "../src/PoolPolicyManager.sol";
import {FullRangeLiquidityManager} from "../src/FullRangeLiquidityManager.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {TruncGeoOracleMulti} from "../src/TruncGeoOracleMulti.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {IDynamicFeeManager} from "../src/interfaces/IDynamicFeeManager.sol";

/**
 * Script to directly deploy the hook with an explicit constructor and salt.
 */
contract DirectDeploy is Script {
    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    // Unichain Mainnet-specific addresses
    address constant UNICHAIN_POOL_MANAGER = 0x1F98400000000000000000000000000000000004;

    // Constants
    uint256 constant LIQUIDITY_ACCUMULATOR_REACTIVATION_DELAY = 3600; // 1 hour in seconds

    // Pre-deployed contract addresses from previous steps
    TruncGeoOracleMulti public truncGeoOracle;
    PoolPolicyManager public policyManager;
    FullRangeLiquidityManager public liquidityManager;
    DynamicFeeManager public dynamicFeeManager;

    function run() public {
        // Read private key from environment
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("========== Direct Deploy Script ==========");
        console.log("Deployer address: %s", deployer);

        // Configure hook permissions
        Hooks.Permissions memory permissions;
        permissions.beforeInitialize = false;
        permissions.afterInitialize = true;
        permissions.beforeAddLiquidity = false;
        permissions.afterAddLiquidity = false;
        permissions.beforeRemoveLiquidity = false;
        permissions.afterRemoveLiquidity = false;
        permissions.beforeSwap = true;
        permissions.afterSwap = false;
        permissions.beforeDonate = false;
        permissions.afterDonate = false;
        permissions.beforeSwapReturnDelta = false;
        permissions.afterSwapReturnDelta = true;
        permissions.afterAddLiquidityReturnDelta = false;
        permissions.afterRemoveLiquidityReturnDelta = true;

        uint160 expectedFlags = 0;
        if (permissions.afterInitialize) expectedFlags |= Hooks.AFTER_INITIALIZE_FLAG;
        if (permissions.beforeSwap) expectedFlags |= Hooks.BEFORE_SWAP_FLAG;
        if (permissions.afterSwapReturnDelta) expectedFlags |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (permissions.afterRemoveLiquidityReturnDelta) {
            expectedFlags |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
        }

        console.log("Expected hook flags: 0x%x", uint256(expectedFlags));

        // We'll read the existing contracts we've deployed
        vm.startBroadcast(pk);

        // Deploy the helper contracts
        if (address(truncGeoOracle) == address(0)) {
            console.log("Deploying TruncGeoOracleMulti...");
            truncGeoOracle = new TruncGeoOracleMulti(
                IPoolManager(UNICHAIN_POOL_MANAGER),
                deployer, // governance parameter
                policyManager // policy manager parameter
            );
            console.log("TruncGeoOracleMulti deployed at: %s", address(truncGeoOracle));
        }

        if (address(policyManager) == address(0)) {
            console.log("Deploying PolicyManager...");
            // Simplified parameters for this test deployment
            address owner = deployer;
            uint256 polSharePpm = 800000; // 80%
            uint256 fullRangeSharePpm = 0; // 0%
            uint256 lpSharePpm = 200000; // 20%
            uint256 minimumTradingFeePpm = 1000; // 0.1%
            uint256 feeClaimThresholdPpm = 1000; // 0.1%
            uint256 defaultPolMultiplier = 2;
            uint256 defaultDynamicFeePpm = 5000; // 0.5%
            int24 tickScalingFactor = 10;
            uint24[] memory supportedTickSpacings = new uint24[](3);
            supportedTickSpacings[0] = 1;
            supportedTickSpacings[1] = 10;
            supportedTickSpacings[2] = 100;
            uint256 initialProtocolFeePercentage = 0; // 0%
            address initialFeeCollector = deployer;

            policyManager = new PoolPolicyManager(
                owner, defaultDynamicFeePpm, supportedTickSpacings, initialProtocolFeePercentage, initialFeeCollector
            );
            console.log("PolicyManager deployed at: %s", address(policyManager));
        }

        if (address(liquidityManager) == address(0)) {
            console.log("Deploying LiquidityManager...");
            liquidityManager = new FullRangeLiquidityManager(IPoolManager(UNICHAIN_POOL_MANAGER), IPoolPolicy(address(0)), deployer);
            console.log("LiquidityManager deployed at: %s", address(liquidityManager));
        }

        // Now find the right hook address with expected flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            expectedFlags,
            type(Spot).creationCode,
            abi.encode(IPoolManager(UNICHAIN_POOL_MANAGER), policyManager, liquidityManager, deployer)
        );

        console.log("Found valid hook address: %s", hookAddress);
        console.log("Salt: 0x%x", uint256(salt));
        console.log("Flags: 0x%x", uint160(hookAddress) & Hooks.ALL_HOOK_MASK);

        // Now deploy the hook
        console.log("Deploying hook directly with CREATE2...");
        Spot hook = new Spot{salt: salt}(
            IPoolManager(UNICHAIN_POOL_MANAGER),
            policyManager,
            liquidityManager,
            truncGeoOracle,
            IDynamicFeeManager(address(0)), // Will be set later
            deployer
        );
        console.log("Hook deployed at: %s", address(hook));

        // Verify it has the right address
        require(address(hook) == hookAddress, "Hook address mismatch");

        // Verify it has the correct flags
        uint160 actualFlags = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        require(actualFlags == expectedFlags, "Hook flags mismatch");

        console.log("Hook address validation passed!");

        // Now we can continue with the rest of the initialization
        console.log("Initializing dynamic fee manager...");
        dynamicFeeManager = new DynamicFeeManager(
            IPoolPolicy(address(policyManager)), // policy
            address(truncGeoOracle), // oracle
            address(hook) // authorizedHook
        );
        console.log("DynamicFeeManager deployed: %s", address(dynamicFeeManager));

        // Authorize hook in LiquidityManager
        liquidityManager.setAuthorizedHookAddress(address(hook));
        console.log("Hook authorized in LiquidityManager");

        vm.stopBroadcast();

        console.log("\n======= Deployment Summary =======");
        console.log("TruncGeoOracle: %s", address(truncGeoOracle));
        console.log("PolicyManager: %s", address(policyManager));
        console.log("LiquidityManager: %s", address(liquidityManager));
        console.log("DynamicFeeManager: %s", address(dynamicFeeManager));
        console.log("Spot Hook: %s", address(hook));
        console.log("==================================");
    }
}
