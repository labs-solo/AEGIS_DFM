// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0;

import "forge-std/Test.sol";

// - - - v4 core src deps - - -

import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

// - - - v4 periphery src deps - - -

import {PositionManager} from "v4-periphery/src/PositionManager.sol";

// - - - v4-periphery - - -

import {PosmTestSetup} from "v4-periphery/test/shared/PosmTestSetup.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// Import project contracts

import {Spot} from "src/Spot.sol";
import {FullRangeLiquidityManager} from "src/FullRangeLiquidityManager.sol";
import {PoolPolicyManager} from "src/PoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "src/TruncGeoOracleMulti.sol";
import {DynamicFeeManager} from "src/DynamicFeeManager.sol";

// - - - local test helpers - - -

import {MainUtils} from "./utils/MainUtils.sol";

abstract contract Base_Test is PosmTestSetup, MainUtils {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Test accounts
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    // Contract instances
    PoolPolicyManager policyManager;
    TruncGeoOracleMulti oracle;
    DynamicFeeManager feeManager;
    FullRangeLiquidityManager liquidityManager;
    Spot spot;

    // Test variables
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public virtual {
        // Use PosmTestSetup to deploy core infrastructure
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployPosmHookSavesDelta(); // Deploy the hook that saves deltas for testing
        deployAndApprovePosm(manager); // This deploys PositionManager with proper setup

        // Create the policy manager with proper parameters
        vm.startPrank(owner);
        // Constructor(governance, dailyBudget, minTradingFee, maxTradingFee)
        policyManager = new PoolPolicyManager(owner, 1_000_000, 100, 10_000);
        vm.stopPrank();

        // Define the permissions for Spot hook
        uint160 spotFlags = permissionsToFlags(
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );

        // Mine the hook address before creating the hook
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            spotFlags,
            type(Spot).creationCode,
            abi.encodePacked(
                address(manager),
                address(0), // Placeholder for liquidityManager
                address(policyManager),
                address(0), // Placeholder for oracle
                address(0) // Placeholder for feeManager
            )
        );

        // Deploy TruncGeoOracleMulti with the precomputed hook address
        vm.startPrank(owner);
        // Constructor(poolManager, policyContract, hook, owner)
        oracle = new TruncGeoOracleMulti(manager, policyManager, hookAddress, owner);
        vm.stopPrank();

        // Deploy DynamicFeeManager with the precomputed hook address
        vm.startPrank(owner);
        // Constructor(owner, policyManager, oracleAddress, authorizedHook)
        feeManager = new DynamicFeeManager(owner, policyManager, address(oracle), hookAddress);
        vm.stopPrank();

        // Deploy FullRangeLiquidityManager with the precomputed hook address
        vm.startPrank(owner);
        // Constructor(poolManager, positionManager, policyManager, authorizedHookAddress)
        liquidityManager = new FullRangeLiquidityManager(
            manager,
            PositionManager(payable(address(lpm))), // Use the position manager from PosmTestSetup (named lpm)
            policyManager,
            hookAddress
        );
        vm.stopPrank();

        // Finally, deploy the Spot hook with all dependencies
        vm.startPrank(owner);
        // Constructor(manager, liquidityManager, policyManager, oracle, feeManager)
        spot = new Spot(manager, liquidityManager, policyManager, oracle, feeManager);
        vm.stopPrank();

        // Verify the hook address is as expected
        require(address(spot) == hookAddress, "Hook address mismatch");

        // Initialize the pool with the Spot hook
        poolKey = PoolKey(
            currency0,
            currency1,
            3000, // 0.3% fee
            60, // tick spacing
            IHooks(address(spot))
        );

        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Fund user accounts using the helper from PosmTestSetup
        seedBalance(user1);
        seedBalance(user2);
        seedBalance(owner);

        // Approve tokens for users
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Approve tokens for owner to interact with Spot
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).approve(address(spot), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(spot), type(uint256).max);

        // Use the PosmTestSetup approvePosmFor helper to approve for PositionManager
        approvePosmFor(owner);
        vm.stopPrank();
    }
}
