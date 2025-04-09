// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

// Uniswap V4 Core
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

// Spot/Margin Contracts (Modified for MarginTestBase)
// import {Spot} from "../src/Spot.sol"; // Import Margin instead
import {Margin} from "../src/Margin.sol"; // Import Margin
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "../src/interfaces/IFullRangeLiquidityManager.sol";
import {IFullRangeDynamicFeeManager} from "../src/interfaces/IFullRangeDynamicFeeManager.sol";
import {FullRangeLiquidityManager} from "../src/FullRangeLiquidityManager.sol";
import {FullRangeDynamicFeeManager} from "../src/FullRangeDynamicFeeManager.sol";
import {PoolPolicyManager} from "../src/PoolPolicyManager.sol";
import {DefaultPoolCreationPolicy} from "../src/DefaultPoolCreationPolicy.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {MarginManager} from "../src/MarginManager.sol"; // Added
import {IMarginManager} from "../src/interfaces/IMarginManager.sol"; // Added
import {IMarginData} from "../src/interfaces/IMarginData.sol"; // Added

// Token mocks
import "../src/token/MockERC20.sol";

// New imports
import { TruncatedOracle } from "../src/libraries/TruncatedOracle.sol";
import { TruncGeoOracleMulti } from "../src/TruncGeoOracleMulti.sol";
import {DepositParams, WithdrawParams} from "../src/interfaces/ISpot.sol";

/**
 * @title MarginTestBase
 * @notice Base test contract that sets up a complete local Uniswap V4 environment with the Margin hook
 * @dev Copy of LocalUniswapV4TestBase, modified to deploy Margin instead of Spot as the hook.
 */
abstract contract MarginTestBase is Test { // Renamed contract
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Deployed contract references
    PoolManager public poolManager;
    PoolPolicyManager public policyManager;
    FullRangeLiquidityManager public liquidityManager;
    MarginManager public marginManager; // Added
    FullRangeDynamicFeeManager public dynamicFeeManager;
    // Spot public fullRange; // Changed type to Margin
    Margin public fullRange; // Changed type to Margin
    TruncGeoOracleMulti public truncGeoOracle;
    
    // Test contract references - these are adapter contracts for interacting with the PoolManager
    PoolModifyLiquidityTest public lpRouter;
    PoolSwapTest public swapRouter;
    PoolDonateTest public donateRouter;
    
    // Test tokens
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC20 public token2;
    
    // Test accounts
    address public deployer = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);
    address public charlie = address(0x4);
    address public governance = address(0x5);
    
    // Test constants
    uint256 public constant INITIAL_ETH_BALANCE = 1000 ether;
    uint256 public constant INITIAL_TOKEN_BALANCE = 1000000e18; // 1M tokens
    uint24 public constant DEFAULT_FEE = 0x800000; // Dynamic fee flag
    int24 public constant DEFAULT_TICK_SPACING = 200; // Wide spacing for dynamic fee pools
    
    // Policy configuration constants
    uint256 public constant POL_SHARE_PPM = 250000; // 25%
    uint256 public constant FULLRANGE_SHARE_PPM = 250000; // 25%
    uint256 public constant LP_SHARE_PPM = 500000; // 50%
    uint256 public constant MIN_TRADING_FEE_PPM = 1000; // 0.1%
    uint256 public constant FEE_CLAIM_THRESHOLD_PPM = 10000; // 1%
    uint256 public constant DEFAULT_POL_MULTIPLIER = 10; // 10x
    uint256 public constant DEFAULT_DYNAMIC_FEE_PPM = 3000; // 0.3%
    int24 public constant TICK_SCALING_FACTOR = 2;
    
    // Set up in setUp()
    PoolKey public poolKey;
    PoolId public poolId;
    
    /**
     * @notice Sets up the complete testing environment with all contracts and accounts
     * @dev This creates a fully functioning Uniswap V4 environment with the Margin hook
     */
    function setUp() public virtual {
        // Set up test accounts with ETH
        vm.deal(deployer, INITIAL_ETH_BALANCE);
        vm.deal(alice, INITIAL_ETH_BALANCE);
        vm.deal(bob, INITIAL_ETH_BALANCE);
        vm.deal(charlie, INITIAL_ETH_BALANCE);
        vm.deal(governance, INITIAL_ETH_BALANCE);
        
        // Deploy the local Uniswap V4 environment
        vm.startPrank(deployer);
        console2.log("[SETUP] Deploying PoolManager...");
        poolManager = new PoolManager(address(deployer)); 
        console2.log("[SETUP] PoolManager Deployed.");
        
        console2.log("[SETUP] Deploying PolicyManager...");
        uint24[] memory supportedTickSpacings = new uint24[](3);
        supportedTickSpacings[0] = 10;
        supportedTickSpacings[1] = 60;
        supportedTickSpacings[2] = 200;
        
        policyManager = new PoolPolicyManager(
            governance,
            POL_SHARE_PPM,
            FULLRANGE_SHARE_PPM,
            LP_SHARE_PPM,
            MIN_TRADING_FEE_PPM,
            FEE_CLAIM_THRESHOLD_PPM,
            DEFAULT_POL_MULTIPLIER,
            DEFAULT_DYNAMIC_FEE_PPM,
            TICK_SCALING_FACTOR,
            supportedTickSpacings,
            1e17,            // _initialProtocolInterestFeePercentage (10%)
            address(0)       // _initialFeeCollector (zero address)
        );
        console2.log("[SETUP] PolicyManager Deployed.");
        
        console2.log("[SETUP] Deploying LiquidityManager...");
        liquidityManager = new FullRangeLiquidityManager(poolManager, governance);
        console2.log("[SETUP] LiquidityManager Deployed.");

        console2.log("[SETUP] Deploying TruncGeoOracleMulti...");
        truncGeoOracle = new TruncGeoOracleMulti(poolManager, governance);
        console2.log("[SETUP] TruncGeoOracleMulti Deployed.");
        
        vm.stopPrank();
        vm.startPrank(governance);
        console2.log("[SETUP] Deploying Margin hook..."); // Updated log
        (fullRange, marginManager) = _deployFullRangeAndManager(); // Deploys Margin & Manager now
        console2.log("[SETUP] Margin Deployed at:", address(fullRange)); // Updated log
        console2.log("[SETUP] MarginManager Deployed at:", address(marginManager)); // Added log
        
        console2.log("[SETUP] Deploying DynamicFeeManager...");
        dynamicFeeManager = new FullRangeDynamicFeeManager(
            governance,
            IPoolPolicy(address(policyManager)),
            poolManager,
            address(fullRange) // Pass Margin address
        );
        console2.log("[SETUP] DynamicFeeManager Deployed.");
        
        console2.log("[SETUP] Setting LM.FullRangeAddress...");
        liquidityManager.setFullRangeAddress(address(fullRange)); // Sets Margin address
        console2.log("[SETUP] Setting FR.DynamicFeeManager...");
        fullRange.setDynamicFeeManager(dynamicFeeManager);
        console2.log("[SETUP] Setting FR.OracleAddress...");
        fullRange.setOracleAddress(address(truncGeoOracle));
        console2.log("[SETUP] Setting Oracle.FullRangeHook...");
        truncGeoOracle.setFullRangeHook(address(fullRange));
        console2.log("[SETUP] Setters Called.");
        vm.stopPrank();
        
        vm.startPrank(deployer);
        console2.log("[SETUP] Deploying Routers...");
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        donateRouter = new PoolDonateTest(IPoolManager(address(poolManager)));
        console2.log("[SETUP] Routers Deployed.");
        
        console2.log("[SETUP] Creating Tokens...");
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);
        token2 = new MockERC20("Token2", "TKN2", 18);
        
        // Make sure token0 has a lower address than token1 for consistency
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        
        // Mint tokens to test accounts (As deployer)
        token0.mint(alice, INITIAL_TOKEN_BALANCE);
        token0.mint(bob, INITIAL_TOKEN_BALANCE);
        token0.mint(charlie, INITIAL_TOKEN_BALANCE);
        
        token1.mint(alice, INITIAL_TOKEN_BALANCE);
        token1.mint(bob, INITIAL_TOKEN_BALANCE);
        token1.mint(charlie, INITIAL_TOKEN_BALANCE);
        
        token2.mint(alice, INITIAL_TOKEN_BALANCE);
        token2.mint(bob, INITIAL_TOKEN_BALANCE);
        token2.mint(charlie, INITIAL_TOKEN_BALANCE);
        console2.log("[SETUP] Tokens Created.");

        console2.log("[SETUP] Initializing Pool...");
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: DEFAULT_FEE,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(address(fullRange)) // Use Margin address as hook
        });
        poolManager.initialize(poolKey, uint160(1 << 96));
        poolId = poolKey.toId();
        console2.log("[SETUP] Pool Initialized.");
        
        vm.stopPrank();
        console2.log("[SETUP] Completed.");
    }

    /**
     * @notice Deploy the Margin hook and its associated MarginManager
     * @dev Uses CREATE2 with address mining to ensure the hook address has the correct permission bits
     * @return marginContract The deployed Margin hook contract
     * @return managerContract The deployed MarginManager contract
     */
    function _deployFullRangeAndManager() internal virtual returns (Margin marginContract, MarginManager managerContract) { // Changed return type
        // Calculate required hook flags (Inherited from Spot)
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        // Step 1: Prepare MarginManager constructor args (needs hook address later)
        // Placeholder for now, we'll update it after mining the hook address.
        address placeholderHookAddress = address(0);
        uint256 initialSolvencyThreshold = 980000000000000000; // 0.98 * 1e18
        uint256 initialLiquidationFee = 10000000000000000; // 0.01 * 1e18

        // Deploy MarginManager *first* with a placeholder hook address
        // We can't link it properly until Margin is deployed.
        MarginManager tempManager = new MarginManager(
            placeholderHookAddress, // Will be updated later
            address(poolManager),
            address(liquidityManager),
            governance,
            initialSolvencyThreshold,
            initialLiquidationFee
        );
        console2.log("[BaseTest] Temporarily Deployed MarginManager Addr:", address(tempManager));


        // Step 2: Prepare Margin constructor arguments including the *temporary* manager address
        bytes memory constructorArgsMargin = abi.encode(
            address(poolManager),
            IPoolPolicy(address(policyManager)),
            address(liquidityManager),
            address(tempManager) // Use the temporarily deployed manager
        );

        // Step 3: Find salt for Margin deployment using the governor
        (address hookAddress, bytes32 salt) = HookMiner.find(
            governance, // Deployer is governance as per setUp prank
            flags,
            abi.encodePacked(type(Margin).creationCode, constructorArgsMargin), // Use Margin creation code + args
            bytes("")
        );
        console2.log("[BaseTest] Calculated Hook Addr:", hookAddress);
        console2.logBytes32(salt);

        // Step 4: Deploy Margin using the mined salt and correct arguments
        Margin hookContract = new Margin{salt: salt}(
            poolManager,
            IPoolPolicy(address(policyManager)),
            liquidityManager,
            address(tempManager) // Use the temporary manager address
        );

        // Verification
        require(address(hookContract) == hookAddress, "MarginTestBase: Hook address mismatch");
        console2.log("[BaseTest] Deployed Hook Addr:", address(hookContract));

        // Step 5: Update the MarginManager with the *actual* Margin address
        // Note: This requires a setter in MarginManager (setMarginContract or similar)
        // We assume governance deploys and can call this setter.
        // IMPORTANT: MarginManager needs a `setMarginContract(address)` function callable by governance.
        // This function is NOT standard and needs to be added for this test setup pattern.
        // Alternatively, re-deploy MarginManager after Margin deployment if no such setter exists.
        // Let's assume the setter is added for this example:
        // tempManager.setMarginContract(address(hookContract)); // This would require a setter
        // If no setter, you'd need to deploy MarginManager *after* mining the hookAddress:
        MarginManager finalManager = new MarginManager(
            hookAddress, // Use the calculated hook address
            address(poolManager),
            address(liquidityManager),
            governance,
            initialSolvencyThreshold,
            initialLiquidationFee
        );
        // And update Margin to point to the final manager:
        // This requires Margin's manager address to be mutable, which contradicts non-upgradeable core.
        // WORKAROUND: The pattern where MarginManager is deployed first with placeholder
        // and then Margin is deployed referencing it, and *then* the MarginManager's
        // marginContract reference is updated requires MarginManager.marginContract to be mutable or have a setter.
        // Let's stick to the original plan assuming MarginManager can be updated.
        // IF MarginManager.marginContract IS IMMUTABLE:
        // 1. Calculate hookAddress via HookMiner.find as above.
        // 2. Deploy MarginManager *using* the calculated hookAddress.
        // 3. Deploy Margin using the same salt and referencing the now deployed MarginManager.

        // Assuming MarginManager *is* updatable via a setter for test setup convenience:
        // We need to transfer ownership or use governance prank for the setter
        // vm.prank(governance); // Assuming governance owns MarginManager
        // tempManager.setMarginContract(address(hookContract)); // Call the setter
        // vm.stopPrank();
        // managerContract = tempManager; // Return the updated manager

        // Let's proceed assuming the "calculate hook, deploy manager, deploy hook" pattern
        // as it fits better with immutability.

        // Re-calculate hook address (already done above, reusing hookAddress and salt)

        // Deploy MarginManager using the *calculated* hook address
        MarginManager managerForReal = new MarginManager(
            hookAddress, // Use the calculated hook address
            address(poolManager),
            address(liquidityManager),
            governance,
            initialSolvencyThreshold,
            initialLiquidationFee
        );
        console2.log("[BaseTest] Deployed REAL MarginManager Addr:", address(managerForReal));

        // Re-encode Margin constructor args with the REAL manager address
        constructorArgsMargin = abi.encode(
            address(poolManager),
            IPoolPolicy(address(policyManager)),
            address(liquidityManager),
            address(managerForReal) // Use the REAL manager address
        );

        // Deploy Margin using the *same salt* and the REAL manager address
        // Note: This requires the creationCode + args hash to be the same for the salt.
        // The manager address changing means the hash changes. HookMiner needs to target
        // the final creation code hash.
        // Let's recalculate salt based on final args.

        (address finalHookAddress, bytes32 finalSalt) = HookMiner.find(
            governance, // Deployer is governance as per setUp prank
            flags,
            abi.encodePacked(type(Margin).creationCode, constructorArgsMargin), // Use FINAL args
            bytes("")
        );
        console2.log("[BaseTest] Recalculated Hook Addr:", finalHookAddress);
        console2.logBytes32(finalSalt);

        // Deploy Margin using the final salt and final manager address
        hookContract = new Margin{salt: finalSalt}(
            poolManager,
            IPoolPolicy(address(policyManager)),
            liquidityManager,
            address(managerForReal) // Use the REAL manager address
        );

        require(address(hookContract) == finalHookAddress, "MarginTestBase: FINAL Hook address mismatch");
        console2.log("[BaseTest] Deployed FINAL Hook Addr:", address(hookContract));

        marginContract = hookContract;
        managerContract = managerForReal;

        // Destroy the temporary manager if created (only if using the update pattern)
        // vm.prank(governance);
        // tempManager.selfDestruct(governance); // Requires selfdestruct function
        // vm.stopPrank();
    }

    /**
     * @notice Helper function to add liquidity to the pool through the lpRouter
     * @param account The account providing liquidity
     * @param tickLower The lower tick bound
     * @param tickUpper The upper tick bound
     * @param liquidity The amount of liquidity to add
     */
    function addLiquidity(address account, int24 tickLower, int24 tickUpper, uint128 liquidity) internal {
        vm.stopPrank(); // Stop any existing prank
        vm.startPrank(account);
        
        // Approve tokens first
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        // token2.approve(address(poolManager), type(uint256).max); // Remove approval for unused token2
        
        console2.log("addLiquidity Debug: Account=", account);
        console2.log("addLiquidity Debug: token0 balance=", token0.balanceOf(account));
        console2.log("addLiquidity Debug: token1 balance=", token1.balanceOf(account));
        console2.log("addLiquidity Debug: token0 allowance for PM=", token0.allowance(account, address(poolManager)));
        console2.log("addLiquidity Debug: token1 allowance for PM=", token1.allowance(account, address(poolManager)));
        console2.log("addLiquidity Debug: Liquidity Delta=", int256(uint256(liquidity)));

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)  // Added salt parameter
        });
        
        lpRouter.modifyLiquidity(poolKey, params, "");
        vm.stopPrank();
    }
    
    /**
     * @notice Helper function to add full range liquidity to a pool
     * @dev This creates liquidity across the entire price range through the Margin hook (as fullRange)
     * @param account The address that will provide the liquidity
     * @param liquidity The amount of tokens to add as liquidity
     */
    function addFullRangeLiquidity(address account, uint128 liquidity) internal {
        // ======================= ARRANGE =======================
        vm.stopPrank(); // Stop any existing prank
        vm.startPrank(account);
        
        // Approve tokens for the Margin contract to pull (transfers go to MarginManager)
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        
        // ======================= ACT =======================
        // Use the batch execution flow for deposits
        IMarginData.BatchAction[] memory actions = new IMarginData.BatchAction[](2);
        actions[0] = createDepositAction(address(token0), liquidity);
        actions[1] = createDepositAction(address(token1), liquidity);

        // Call executeBatch
        fullRange.executeBatch(actions);
        
        // ======================= ASSERT =======================
        // Get vault state to verify deposit (optional here, primarily for setup)
        IMarginData.Vault memory vault = fullRange.getVault(poolId, account);
        // Simple check: ensure balances increased (exact amounts depend on pool state)
        assertGt(vault.token0Balance, 0, "Vault token0 should increase");
        assertGt(vault.token1Balance, 0, "Vault token1 should increase");
        console2.log("Full range liquidity added via executeBatch - T0 Balance:", vault.token0Balance);
        console2.log("Full range liquidity added via executeBatch - T1 Balance:", vault.token1Balance);

        vm.stopPrank();
    }
    
    /**
     * @notice Helper function to perform a swap through the swapRouter
     * @param account The account performing the swap
     * @param zeroForOne Whether swapping token0 for token1 (true) or token1 for token0 (false)
     * @param amountSpecified The amount to swap (negative for exact output)
     * @param sqrtPriceLimitX96 The price limit for the swap
     */
    function swap(
        address account, 
        bool zeroForOne, 
        int256 amountSpecified, 
        uint160 sqrtPriceLimitX96
    ) internal {
        vm.stopPrank(); // Stop any existing prank
        vm.startPrank(account);
        
        // Approve tokens first
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false 
        });
        
        swapRouter.swap(poolKey, params, testSettings, "");
        vm.stopPrank();
    }
    
    /**
     * @notice Helper function to perform an exact input swap
     * @dev Swaps an exact amount of input tokens for a variable amount of output tokens
     * @param account The address that will perform the swap
     * @param zeroForOne Whether to swap token0 for token1 (true) or token1 for token0 (false)
     * @param amountIn The exact amount of input tokens to swap
     */
    function swapExactInput(address account, bool zeroForOne, uint256 amountIn) internal {
        // ======================= ARRANGE =======================
        // Set the price limit based on swap direction
        uint160 sqrtPriceLimitX96 = zeroForOne ? 
            TickMath.MIN_SQRT_PRICE + 1 : 
            TickMath.MAX_SQRT_PRICE - 1;
        
        // ======================= ACT =======================
        // Execute the swap using the underlying swap function
        swap(account, zeroForOne, int256(amountIn), sqrtPriceLimitX96);
        
        // ======================= ASSERT =======================
        // The swap function handles verification and cleanup
    }
    
    /**
     * @notice Helper function to query the current tick from the pool
     * @dev Gets the current tick directly from the pool state
     * @return currentTick The current tick value
     * @return liquidity The current liquidity in the pool
     */
    function queryCurrentTick() internal view returns (int24 currentTick, uint128 liquidity) {
        (,currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        liquidity = StateLibrary.getLiquidity(poolManager, poolId);
        return (currentTick, liquidity);
    }
    
    // =========================================================================
    // Batch Action Helper Functions
    // =========================================================================

    function createDepositAction(address asset, uint256 amount) internal pure returns (IMarginData.BatchAction memory) {
        return IMarginData.BatchAction({
            actionType: IMarginData.ActionType.DepositCollateral,
            asset: asset,
            amount: amount,
            recipient: address(0), // Not used for deposit
            flags: 0,
            data: ""
        });
    }

    function createWithdrawAction(address asset, uint256 amount, address recipient) internal pure returns (IMarginData.BatchAction memory) {
        return IMarginData.BatchAction({
            actionType: IMarginData.ActionType.WithdrawCollateral,
            asset: asset,
            amount: amount,
            recipient: recipient, // Use provided recipient or defaults in Margin contract
            flags: 0,
            data: ""
        });
    }

    function createBorrowAction(uint256 shares, address recipient) internal pure returns (IMarginData.BatchAction memory) {
        return IMarginData.BatchAction({
            actionType: IMarginData.ActionType.Borrow,
            asset: address(0), // Not used for borrow
            amount: shares,
            recipient: recipient, // Use provided recipient or defaults in Margin contract
            flags: 0,
            data: ""
        });
    }

    function createRepayAction(uint256 shares, bool useVaultBalance) internal pure returns (IMarginData.BatchAction memory) {
        return IMarginData.BatchAction({
            actionType: IMarginData.ActionType.Repay,
            asset: address(0), // Not used for repay
            amount: shares,
            recipient: address(0), // Not used for repay
            flags: useVaultBalance ? IMarginData.FLAG_USE_VAULT_BALANCE_FOR_REPAY : 0,
            data: ""
        });
    }

    // --- Test Functions Removed (Keep only setup and helpers in base) ---
    // Removed test_readCurrentTick, test_oracleTracksSinglePriceChange, 
    // test_oracleValidation, test_setup as they should be in specific test files.

} 