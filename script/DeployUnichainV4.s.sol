// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

// Uniswap V4 Core
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";

// Deployed Contracts (Dependencies Only)
import {FullRangeLiquidityManager} from "../src/FullRangeLiquidityManager.sol";
import {PoolPolicyManager} from "../src/PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "../src/TruncGeoOracleMulti.sol";

// Interfaces and Libraries (Needed for Types)
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {DummyFullRangeHook} from "utils/DummyFullRangeHook.sol";
import {ExtendedPositionManager} from "../src/ExtendedPositionManager.sol";

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

    uint24 constant EXPECTED_MIN_DYNAMIC_FEE     =  100; // 0.01 %
    uint24 constant EXPECTED_MAX_DYNAMIC_FEE     = 50000; // 5 %
    uint24 constant EXPECTED_DEFAULT_DYNAMIC_FEE =  5000; // 0.5 %

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        address governance = deployerAddress; // Use deployer as governance for this deployment

        vm.startBroadcast(deployerPrivateKey);

        poolManager = IPoolManager(UNICHAIN_POOL_MANAGER);

        // --- Deploy Dependencies ---

        // Deploy PoolPolicyManager
        uint24[] memory supportedTickSpacings_ = new uint24[](3);
        supportedTickSpacings_[0] = 10;
        supportedTickSpacings_[1] = 60;
        supportedTickSpacings_[2] = 200;
        policyManager = new PoolPolicyManager(
            deployerAddress, // owner
            EXPECTED_DEFAULT_DYNAMIC_FEE, // defaultDynamicFee. Removed uint32 cast
            supportedTickSpacings_, // supportedTickSpacings
            0,
            msg.sender,
            EXPECTED_MIN_DYNAMIC_FEE,     // NEW: min base fee
            EXPECTED_MAX_DYNAMIC_FEE      // NEW: max base fee
        );

        // ─── NEW flow: deploy hook first, then pass address to oracle ───
        DummyFullRangeHook fullRangeHook = new DummyFullRangeHook(address(0));

        truncGeoOracle = new TruncGeoOracleMulti(
            poolManager,
            policyManager,
            address(fullRangeHook),
            msg.sender // Deployer as owner
        );

        // Optional: if hook needs to know oracle addr, redeploy / init
        // Assuming DummyFullRangeHook now has a setOracle method
        // fullRangeHook.setOracle(address(truncGeoOracle));

        // Deploy LiquidityManager
        liquidityManager = new FullRangeLiquidityManager(
            poolManager,
            ExtendedPositionManager(payable(address(0))),
            IPoolPolicy(address(0)),
            deployerAddress
        );

        // --- Deploy Test Routers ---
        lpRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);
        donateRouter = new PoolDonateTest(poolManager);

        vm.stopBroadcast();

        // --- Log Deployed Addresses ---
    }

    // Removed: _getHookSaltConfig function (no longer needed here)
}
