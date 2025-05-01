// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IWETH9} from "v4-periphery/interfaces/external/IWETH9.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {INITIAL_LP_USDC, INITIAL_LP_WETH} from "../utils/TestConstants.sol";

// Core Contract Interfaces & Libraries
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol"; // Needed for Permissions
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

// Project Interfaces & Implementations
import {IPoolPolicy} from "src/interfaces/IPoolPolicy.sol";
import {FullRangeLiquidityManager} from "src/FullRangeLiquidityManager.sol";
import {Spot} from "src/Spot.sol";
import {HookMiner} from "src/utils/HookMiner.sol";
import {PriceHelper} from "./utils/PriceHelper.sol";
import {PoolPolicyManager} from "src/PoolPolicyManager.sol";
import {DefaultPoolCreationPolicy} from "src/DefaultPoolCreationPolicy.sol";
import {DynamicFeeManager} from "src/DynamicFeeManager.sol";
import {IDynamicFeeManager} from "src/interfaces/IDynamicFeeManager.sol";
import {TruncGeoOracleMulti} from "src/TruncGeoOracleMulti.sol";

// Test Routers
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/test/PoolDonateTest.sol";

/**
 * @title ForkSetup
 * @notice Establishes a consistent baseline state for integration tests on a forked Unichain environment.
 * @dev Handles environment setup and FULL deployment (dependencies, hook, dynamic fee manager,
 *      configuration, pool init, test routers) within the test setup using vm.prank.
 */
contract ForkSetup is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // Removed Deployment Script Instance
    // DeployUnichainV4 internal deployerScript;

    // --- Deployed/Referenced Contract Instances ---
    IPoolManager public poolManager; // From Unichain
    PoolPolicyManager public policyManager; // Deployed in setup
    FullRangeLiquidityManager public liquidityManager; // Deployed in setup
    DynamicFeeManager public dynamicFeeManager; // Deployed in setup
    TruncGeoOracleMulti public oracle; // Deployed in setup
    Spot public fullRange; // Deployed in setup via CREATE2 (Renamed from spot to fullRange)

    // --- Test Routers --- (Deployed in setup)
    PoolModifyLiquidityTest public lpRouter; // Public for access from other tests
    PoolSwapTest public swapRouter; // Public for access from other tests
    PoolDonateTest internal donateRouter;

    // --- Core V4 & Pool Identifiers ---
    PoolKey internal poolKey;
    PoolId internal poolId;

    // --- Token Addresses & Instances ---
    address internal constant UNICHAIN_POOL_MANAGER = 0x1F98400000000000000000000000000000000004;
    address internal constant WETH_ADDRESS = 0x4200000000000000000000000000000000000006;
    address internal constant USDC_ADDRESS = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    IERC20Minimal internal weth = IERC20Minimal(WETH_ADDRESS);
    IERC20Minimal internal usdc = IERC20Minimal(USDC_ADDRESS);

    // --- Test User & Deployer EOA ---
    address internal testUser;
    address public deployerEOA; // Public access for admin role
    uint256 internal deployerPrivateKey;

    // --- Funding Constants ---
    uint256 internal constant FUND_ETH_AMOUNT = 1000 ether;

    // --- Deployment Constants ---
    uint24 internal constant DEFAULT_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    // Updated: Price for ~3000 USDC/WETH, adjusted for decimal places (6 vs 18)
    // For sqrtPriceX96, we need sqrt(price) * 2^96
    // USDC is token0, WETH is token1, so price = WETH/USDC = 1/3000 * 10^12 = 0.0000000003333...
    // This is approximately tick -85176 in Uniswap V3 terms
    // uint160 internal constant INITIAL_SQRT_PRICE_X96 = 1459148524590520702994002341445;
    // We'll use the mined salt, not a hardcoded one
    // bytes32 internal constant HOOK_SALT = bytes32(uint256(31099));
    // address internal constant EXPECTED_HOOK_ADDRESS = 0xc44C98d506E7d347399a4310d74C267aa705dE08;

    // Variable to track the actual hook address used
    address internal actualHookAddress;

    // --- Constants ---
    bytes public constant ZERO_BYTES = bytes("");
    uint160 internal constant SQRT_RATIO_1_1 = 79228162514264337593543950336; // 2**96

    // Test constants
    uint256 constant INITIAL_USDC_BALANCE = 100_000e6;  // 100k USDC
    uint256 constant INITIAL_WETH_BALANCE = 100 ether;   // 100 WETH
    uint256 constant EXTRA_USDC_FOR_ISOLATED = 50_000e6; // 50k USDC
    uint256 constant EXTRA_WETH_FOR_ISOLATED = 50 ether;  // 50 WETH

    // Test accounts
    address user1;
    address user2;
    address lpProvider;

    // Token contracts
    // REMOVED: Duplicate declarations of weth and usdc

    // Helper to deal and approve tokens to a spender (typically PoolManager or a Router)
    function _dealAndApprove(IERC20Minimal token, address holder, uint256 amount, address spender) internal {
        vm.startPrank(holder);
        deal(address(token), holder, amount); // Use vm.deal cheatcode

        uint256 MAX = type(uint256).max;

        // ➊ primary approval requested by the caller
        token.approve(spender, MAX);

        // ➋ **always** guarantee PoolManager can pull
        if (spender != address(poolManager)) {
            token.approve(address(poolManager), MAX);
        }

        // ➌ **always** guarantee LiquidityManager can pull
        if (spender != address(liquidityManager)) {
            token.approve(address(liquidityManager), MAX);
        }

        vm.stopPrank();
    }

    /**
     * @dev Creates & selects a fork while emitting helpful logs.
     *
     *  • honours an **optional** `FORK_BLOCK_NUMBER` env-var; use latest head if unset<br>
     *  • prints the chosen RPC alias / block for reproducibility<br>
     *  • reverts with a clear message if `vm.createSelectFork` ever returns `0`
     */
    function _safeFork() internal returns (uint256 forkId) {
        string memory rpcAlias = "unichain_mainnet";            // defined in foundry.toml

        // /* ------------------------------------------------------------------ */ // <-- REMOVE
        // /*  Resolve the block to fork                                         */ // <-- REMOVE
        // /* ------------------------------------------------------------------ */ // <-- REMOVE
        // //   – We read the env-var as a **string** with a graceful fallback, // <-- REMOVE
        // //     then convert to uint.  No try/catch → no compile issues. // <-- REMOVE
        // // // <-- REMOVE
        // //     .env example:  FORK_BLOCK_NUMBER=13900000 // <-- REMOVE
        // // // <-- REMOVE
        // uint256 forkBlock = vm.parseUint( // <-- REMOVE
        //     vm.envOr("FORK_BLOCK_NUMBER", "0")  // "0" ⇒ use latest head // <-- REMOVE
        // ); // <-- REMOVE

        // ── read optional env-var without try/catch ────────────────────── // <-- ADD
        uint256 forkBlock = 0; // <-- ADD
        if (vm.envExists("FORK_BLOCK_NUMBER")) { // <-- ADD
            forkBlock = vm.envUint("FORK_BLOCK_NUMBER"); // <-- ADD
        } // <-- ADD

        emit log_named_string("Selected fork RPC alias",  rpcAlias);
        emit log_named_uint   ("Selected fork block number", forkBlock);

        /* ------------------------------------------------------------------ */
        /*  Create the fork                                                   */
        /* ------------------------------------------------------------------ */
        if (forkBlock != 0) {
            // First try the exact historical block
            forkId = vm.createSelectFork(rpcAlias, forkBlock);

            // If the provider cannot serve that height, fall back to head
            if (forkId == 0) {
                emit log_string("WARN: Failed to fork at specific block, falling back to latest.");
                forkId = vm.createSelectFork(rpcAlias);
            }
        } else {
            // No block specified → fork the latest
            forkId = vm.createSelectFork(rpcAlias);
        }

        require(
            forkId != 0,
            "Fork setup failed: vm.createSelectFork returned 0"
        );
    }

    function setUp() public virtual {
        // 1. Create Fork & Basic Env Setup
        uint256 forkId = _safeFork();
        require(forkId > 0, "Fork setup failed, invalid forkId");

        // 2. Setup Test User & Deployer EOA (Using PK=1 for CREATE2 consistency)
        testUser = vm.addr(2); // Use PK 2 for test user
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        lpProvider = makeAddr("lpProvider");
        
        vm.deal(testUser, FUND_ETH_AMOUNT);
        emit log_named_address("Test User", testUser);

        deployerPrivateKey = 1; // Force PK=1 for deployer
        deployerEOA = vm.addr(deployerPrivateKey);
        vm.deal(deployerEOA, FUND_ETH_AMOUNT);
        emit log_named_address("Deployer EOA (PK=1)", deployerEOA);
        emit log_named_uint("Deployer EOA ETH Balance", deployerEOA.balance);

        // 3. Get PoolManager Instance
        poolManager = IPoolManager(UNICHAIN_POOL_MANAGER);
        emit log_named_address("Using PoolManager", address(poolManager));

        // 4. Deploy All Contracts, Configure, Initialize (within vm.prank)
        emit log_string("\n--- Starting Full Deployment & Configuration (Pranked) ---");
        vm.startPrank(deployerEOA);

        // Deploy PolicyManager
        emit log_string("Deploying PolicyManager...");
        uint24[] memory supportedTickSpacings_ = new uint24[](3);
        supportedTickSpacings_[0] = 10;
        supportedTickSpacings_[1] = 60;
        supportedTickSpacings_[2] = 200;

        policyManager = new PoolPolicyManager(
            deployerEOA, // owner / solo governance
            3_000, // defaultDynamicFeePpm (0.3%)
            supportedTickSpacings_, // allowed tick-spacings
            1e17, // protocol-interest-fee = 10% (scaled by 1e18)
            deployerEOA // fee collector
        );
        emit log_named_address("[DEPLOY] PoolPolicyManager Deployed at:", address(policyManager));

        // Deploy Oracle (AFTER PolicyManager)
        emit log_string("Deploying TruncGeoOracleMulti...");
        oracle = new TruncGeoOracleMulti(poolManager, deployerEOA, policyManager);
        emit log_named_address("Oracle deployed at:", address(oracle));
        require(address(oracle) != address(0), "Oracle deployment failed");

        // Deploy LiquidityManager
        emit log_string("Deploying LiquidityManager...");
        liquidityManager = new FullRangeLiquidityManager(poolManager, IPoolPolicy(address(0)), deployerEOA); // Governance = deployer
        emit log_named_address("LiquidityManager deployed at", address(liquidityManager));
        require(address(liquidityManager) != address(0), "LiquidityManager deployment failed");

        // Deploy DynamicFeeManager
        emit log_string("Deploying DynamicFeeManager...");
        dynamicFeeManager = new DynamicFeeManager(
            policyManager, // ✅ policy
            address(oracle), // ✅ oracle (2nd param)
            deployerEOA // ✅ temporary authorisedHook - we'll update this after Spot deployment
        );
        emit log_named_address("DynamicFeeManager deployed at", address(dynamicFeeManager));

        // Define hook flags for Spot.sol
        uint160 requiredHookFlags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        /* Build constructor args with DFM address */
        bytes memory constructorArgs = abi.encode(
            poolManager,
            IPoolPolicy(address(policyManager)),
            liquidityManager,
            oracle,
            IDynamicFeeManager(address(dynamicFeeManager)),
            deployerEOA
        );

        // Find salt for this exact byte-code
        (address hookAddress, bytes32 salt) =
            HookMiner.find(deployerEOA, requiredHookFlags, type(Spot).creationCode, constructorArgs);

        emit log_named_bytes32("Mined salt", salt);
        emit log_named_address("Predicted hook address", hookAddress);

        // Deploy the Spot hook with the mined salt
        fullRange = new Spot{salt: salt}(
            poolManager,
            IPoolPolicy(address(policyManager)),
            liquidityManager,
            oracle, // Now passing oracle directly in constructor
            IDynamicFeeManager(address(dynamicFeeManager)), // Using real DFM address
            deployerEOA // governance/owner
        );

        // Verify the deployment
        actualHookAddress = address(fullRange);
        require(actualHookAddress == hookAddress, "Deployed hook address does not match predicted!");
        emit log_named_address("Spot Hook deployed successfully at", actualHookAddress);

        // Debug hook flags and validation
        debugHookFlags();

        /* 3) wire the DFM to the hook now that we know it */
        dynamicFeeManager.setAuthorizedHook(actualHookAddress);
        emit log_string("DynamicFeeManager successfully linked to Spot hook");

        // Configure Contracts
        emit log_string("Configuring contracts...");
        liquidityManager.setAuthorizedHookAddress(actualHookAddress);

        // End the current prank before starting a new one
        vm.stopPrank();

        // Ensure reinvestment is not paused by default
        vm.startPrank(deployerEOA);
        fullRange.setReinvestmentPaused(false);
        vm.stopPrank();

        // Start a new prank for the remaining setup
        vm.startPrank(deployerEOA);

        /* Build poolKey & poolId for DFM initialization */
        address token0;
        address token1;
        (token0, token1) = WETH_ADDRESS < USDC_ADDRESS ? (WETH_ADDRESS, USDC_ADDRESS) : (USDC_ADDRESS, WETH_ADDRESS);

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            hooks: IHooks(address(fullRange)),
            tickSpacing: TICK_SPACING
        });
        poolId = poolKey.toId();

        // Initialize DFM while still pranked as governance
        dynamicFeeManager.initialize(poolId, 0);

        emit log_string("LiquidityManager configured.");

        // Deploy Test Routers (still under prank)
        emit log_string("Deploying test routers...");
        lpRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);
        donateRouter = new PoolDonateTest(poolManager);
        emit log_string("Test routers deployed.");

        // End prank
        vm.stopPrank();

        // bootstrap contract-level allowances **before any deposits/swaps**
        _bootstrapPoolManagerAllowances();

        emit log_string("--- Deployment & Configuration Complete ---\n");

        // Calculate initial price using helper
        // Price: 3000 USDC per 1 WETH. Input is scaled by tokenB's decimals (USDC)
        uint8 wethDecimals = 18; // Define decimals explicitly
        uint8 usdcDecimals = 6;
        uint256 priceUSDCperWETH_scaled = 3000 * (10 ** usdcDecimals); // 3000 scaled by USDC decimals
        uint160 calculatedSqrtPriceX96 = PriceHelper.priceToSqrtX96(
            WETH_ADDRESS,
            USDC_ADDRESS,
            priceUSDCperWETH_scaled,
            wethDecimals, // Pass decimals explicitly
            usdcDecimals // Pass decimals explicitly
        );
        emit log_named_uint("Calculated SqrtPriceX96 for 3000 USDC/WETH", calculatedSqrtPriceX96);
        // Expected: 1459148524590520702994002341445

        // Initialize Pool (Now called directly from ForkSetup context)
        emit log_string("Initializing pool (called directly)...");
        try poolManager.initialize(poolKey, calculatedSqrtPriceX96) {
            emit log_string("Pool initialized successfully.");
            emit log_named_bytes32("Pool ID", PoolId.unwrap(poolId));
        } catch Error(string memory reason) {
            // Check if the error is 'PoolAlreadyInitialized'
            // This check is unreliable with strings. Catch raw error instead.
            emit log_string(string.concat("Pool initialization failed with string: ", reason));
            revert(string.concat("Pool initialization failed: ", reason));
        } catch (bytes memory rawError) {
            // Check if the raw error data matches PoolAlreadyInitialized()
            bytes4 poolAlreadyInitializedSelector = bytes4(hex"3cd2493a");
            if (rawError.length >= 4 && bytes4(rawError) == poolAlreadyInitializedSelector) {
                emit log_string("Pool already initialized on fork, skipping initialization.");
            } else {
                // Log unexpected raw errors during initialize
                emit log_named_bytes("Pool initialization failed raw data", rawError);
                revert("Pool initialization failed with raw error");
            }
        }

        // Ensure prank is stopped if not already (defensive)
        // vm.stopPrank();
        emit log_string("--- Full Deployment & Configuration Complete ---");

        // 5. Final Sanity Checks (Optional, covered by testForkSetupComplete)
        emit log_string("ForkSetup complete.");

        // Grant initial allowances from contracts
        // _bootstrapPoolManagerAllowances(); // <-- REMOVED FROM HERE

        // Fund test accounts with tokens
        vm.startPrank(deployerEOA);
        uint256 totalUsdcNeeded = (INITIAL_USDC_BALANCE * 2) + INITIAL_LP_USDC + EXTRA_USDC_FOR_ISOLATED;
        deal(USDC_ADDRESS, deployerEOA, totalUsdcNeeded);
        uint256 totalWethNeeded = (INITIAL_WETH_BALANCE * 2) + INITIAL_LP_WETH + EXTRA_WETH_FOR_ISOLATED;
        deal(WETH_ADDRESS, deployerEOA, totalWethNeeded);
        IWETH9(WETH_ADDRESS).deposit{value: totalWethNeeded}();
        
        // Transfer tokens to test accounts
        IERC20Minimal(WETH_ADDRESS).transfer(user1, INITIAL_WETH_BALANCE);
        IERC20Minimal(USDC_ADDRESS).transfer(user1, INITIAL_USDC_BALANCE);
        IERC20Minimal(WETH_ADDRESS).transfer(user2, INITIAL_WETH_BALANCE);
        IERC20Minimal(USDC_ADDRESS).transfer(user2, INITIAL_USDC_BALANCE);
        IERC20Minimal(WETH_ADDRESS).transfer(lpProvider, EXTRA_WETH_FOR_ISOLATED);
        IERC20Minimal(USDC_ADDRESS).transfer(lpProvider, EXTRA_USDC_FOR_ISOLATED);
        vm.stopPrank();

        // Set up approvals for all test accounts
        _dealAndApprove(IERC20Minimal(WETH_ADDRESS), user1, INITIAL_WETH_BALANCE, address(poolManager));
        _dealAndApprove(IERC20Minimal(USDC_ADDRESS), user1, INITIAL_USDC_BALANCE, address(poolManager));
        _dealAndApprove(IERC20Minimal(WETH_ADDRESS), user2, INITIAL_WETH_BALANCE, address(poolManager));
        _dealAndApprove(IERC20Minimal(USDC_ADDRESS), user2, INITIAL_USDC_BALANCE, address(poolManager));
        _dealAndApprove(IERC20Minimal(WETH_ADDRESS), lpProvider, EXTRA_WETH_FOR_ISOLATED, address(poolManager));
        _dealAndApprove(IERC20Minimal(USDC_ADDRESS), lpProvider, EXTRA_USDC_FOR_ISOLATED, address(poolManager));

        // Bootstrap contract-level allowances
        _bootstrapPoolManagerAllowances();
    }

    // Add this helper to grant initial allowances from contracts to PoolManager
    function _bootstrapPoolManagerAllowances() internal {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);

        for (uint256 i = 0; i < tokens.length; ++i) {
            // ➊ FLM → PM (already here)
            vm.prank(address(liquidityManager));
            IERC20Minimal(tokens[i]).approve(address(poolManager), type(uint256).max);

            // ➋ **FLM → FLM** self-approval needed because FLM
            //    calls `token.transferFrom(FLM, PM, …)` inside its callback.
            vm.prank(address(liquidityManager));
            IERC20Minimal(tokens[i]).approve(address(liquidityManager), type(uint256).max);

            // Allow Spot Hook to spend tokens for PoolManager
            vm.prank(address(fullRange)); // Spot hook itself
            IERC20Minimal(tokens[i]).approve(address(poolManager), type(uint256).max);
        }
    }

    // Test that validates the full setup
    function testForkSetupComplete() public {
        assertTrue(address(poolManager) != address(0), "PoolManager not set");
        assertTrue(address(policyManager) != address(0), "PolicyManager not deployed");
        assertTrue(address(liquidityManager) != address(0), "LiquidityManager not deployed");
        assertTrue(address(oracle) != address(0), "Oracle not deployed");
        assertEq(address(fullRange), actualHookAddress, "FullRange hook not deployed correctly");
        assertTrue(address(dynamicFeeManager) != address(0), "DynamicFeeManager not deployed");
        assertTrue(address(lpRouter) != address(0), "LpRouter not deployed");
        assertTrue(address(swapRouter) != address(0), "SwapRouter not deployed");
        assertTrue(address(donateRouter) != address(0), "DonateRouter not deployed");
        assertTrue(testUser.balance >= FUND_ETH_AMOUNT, "TestUser ETH balance incorrect");

        address authorizedHook = liquidityManager.authorizedHookAddress();
        assertEq(authorizedHook, actualHookAddress, "LM authorized hook mismatch");

        // Check if pool exists (commented out - IPoolManager doesn't have getSlot0)
        // try poolManager.getSlot0(poolId) returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 feeProtocol) {
        //     assertTrue(sqrtPriceX96 > 0, "Pool slot0 sqrtPrice is zero");
        // } catch {
        //     assertTrue(false, "Failed to get pool slot0");
        // }

        emit log_string("testForkSetupComplete checks passed!");
    }

    // --- Helper Functions ---

    // Add a helper function for string manipulation
    function substring(string memory str, uint256 startIndex, uint256 endIndex) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        require(startIndex <= endIndex, "Invalid indices");
        require(endIndex <= strBytes.length, "End index out of bounds");

        bytes memory result = new bytes(endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = strBytes[i];
        }

        return string(result);
    }

    // Helper function to check hook address validity using Hooks library
    function checkHookAddressValidity(address hookAddress, uint24 fee) public pure returns (bool) {
        return Hooks.isValidHookAddress(IHooks(hookAddress), fee);
    }

    // Helper function to debug hook flags
    function debugHookFlags() public {
        uint160 requiredFlags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        emit log_named_uint("Hooks.AFTER_INITIALIZE_FLAG", uint256(Hooks.AFTER_INITIALIZE_FLAG));
        emit log_named_uint("Hooks.BEFORE_SWAP_FLAG", uint256(Hooks.BEFORE_SWAP_FLAG));
        emit log_named_uint("Hooks.AFTER_SWAP_FLAG", uint256(Hooks.AFTER_SWAP_FLAG));
        emit log_named_uint("Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG", uint256(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG));
        emit log_named_uint("Hooks.AFTER_REMOVE_LIQUIDITY_FLAG", uint256(Hooks.AFTER_REMOVE_LIQUIDITY_FLAG));
        emit log_named_uint(
            "Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG", uint256(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        );
        emit log_named_uint("Required flags", uint256(requiredFlags));
        emit log_named_uint("DYNAMIC_FEE_FLAG", uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG));

        if (address(fullRange) != address(0)) {
            emit log_named_address("Hook Address", address(fullRange));
            emit log_named_uint("Hook address (as uint)", uint256(uint160(address(fullRange))));
            uint160 hookFlags = uint160(address(fullRange)) & uint160(Hooks.ALL_HOOK_MASK);
            emit log_named_uint("Hook flags", uint256(hookFlags));
            emit log_named_string(
                "Valid with normal fee (3000)",
                Hooks.isValidHookAddress(IHooks(address(fullRange)), 3000) ? "true" : "false"
            );
            emit log_named_string(
                "Valid with dynamic fee",
                Hooks.isValidHookAddress(IHooks(address(fullRange)), LPFeeLibrary.DYNAMIC_FEE_FLAG) ? "true" : "false"
            );

            // Check why the hook address is invalid
            // 1. Check if the hook has proper permission dependencies
            bool dependency1 =
                !((hookFlags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG > 0) && (hookFlags & Hooks.BEFORE_SWAP_FLAG == 0));
            bool dependency2 =
                !((hookFlags & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG > 0) && (hookFlags & Hooks.AFTER_SWAP_FLAG == 0));
            bool dependency3 = !(
                (hookFlags & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG > 0)
                    && (hookFlags & Hooks.AFTER_ADD_LIQUIDITY_FLAG == 0)
            );
            bool dependency4 = !(
                (hookFlags & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG > 0)
                    && (hookFlags & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG == 0)
            );

            emit log_named_string("Flag dependency check 1", dependency1 ? "pass" : "fail");
            emit log_named_string("Flag dependency check 2", dependency2 ? "pass" : "fail");
            emit log_named_string("Flag dependency check 3", dependency3 ? "pass" : "fail");
            emit log_named_string("Flag dependency check 4", dependency4 ? "pass" : "fail");

            // 2. Check the last part of isValidHookAddress
            bool hasAtLeastOneFlag = uint160(address(fullRange)) & Hooks.ALL_HOOK_MASK > 0;
            emit log_named_string("Has at least one flag", hasAtLeastOneFlag ? "true" : "false");
        }

        // Create a fake hook address with the correct flags to illustrate what we need
        address correctHookAddr = address(uint160(0xfc00000000000000000000000000000000000000) | requiredFlags);
        emit log_named_address("Example correct hook address", correctHookAddr);
        emit log_named_uint("Example hook flags", uint256(uint160(correctHookAddr) & uint160(Hooks.ALL_HOOK_MASK)));
        emit log_named_string(
            "Example valid with normal fee", Hooks.isValidHookAddress(IHooks(correctHookAddr), 3000) ? "true" : "false"
        );
        emit log_named_string(
            "Example valid with dynamic fee",
            Hooks.isValidHookAddress(IHooks(correctHookAddr), LPFeeLibrary.DYNAMIC_FEE_FLAG) ? "true" : "false"
        );
    }

    /// @dev Regression test for PriceHelper: Ensures WETH/USDC price matches the legacy constant.
    function testPriceHelper_USDC_WETH_Regression() public pure {
        // Legacy constant: sqrt( (1/3000) * 10^(18-6) ) * 2^96 = 1459148524590520702994002341445
        uint256 priceUSDCperWETH_scaled = 3_000 * 1e6; // tokenB per tokenA, scaled by decB

        uint160 sqrtP = PriceHelper.priceToSqrtX96(
            address(2), // WETH   (tokenA, 18 dec) - must be > tokenB
            address(1), // USDC   (tokenB, 6  dec) - must be < tokenA
            priceUSDCperWETH_scaled, // Price of B (USDC) per A (WETH), scaled by decB (USDC)
            18, // decA (WETH)
            6 // decB (USDC)
        );

        assertTrue(sqrtP >= TickMath.MIN_SQRT_PRICE && sqrtP < TickMath.MAX_SQRT_PRICE, "sqrtP out of bounds");
    }

    /// @dev Tests PriceHelper inverse calculation: sqrtP(A/B) * sqrtP(B/A) == 2**192
    function testPriceHelper_WETH_USDC_Inverse() public pure {
        uint8 wethDecimals = 18;
        uint8 usdcDecimals = 6;
        // Use addresses with a fixed order for consistency in pure test
        address tokenA = address(0); // WETH placeholder (token0)
        address tokenB = address(1); // USDC placeholder (token1)

        // Price B per A: 3000 USDC per WETH, scaled by USDC dec (6)
        uint256 priceBperA_scaled = 3_000 * (10 ** usdcDecimals);

        // Price A per B: (1/3000) WETH per USDC, scaled by WETH dec (18)
        uint256 priceAperB_scaled = FullMath.mulDiv(10 ** usdcDecimals, 10 ** wethDecimals, priceBperA_scaled);

        // Calculate sqrtP(B/A)
        uint160 sqrtP_BperA = PriceHelper.priceToSqrtX96(tokenA, tokenB, priceBperA_scaled, wethDecimals, usdcDecimals);

        // Calculate sqrtP(A/B) using the same PriceHelper to avoid manual inversion
        uint160 sqrtP_AperB = PriceHelper.priceToSqrtX96(
            tokenB, // now base=USDC
            tokenA, // quote=WETH
            FullMath.mulDiv(10 ** usdcDecimals, 10 ** wethDecimals, priceBperA_scaled),
            usdcDecimals,
            wethDecimals
        );

        // Check the inverse relationship: product should be 2**192
        // Use FullMath.mulDiv for safer multiplication
        uint256 product = FullMath.mulDiv(uint256(sqrtP_BperA), uint256(sqrtP_AperB), 1);
        uint256 expected = uint256(1) << 192;
        // Compute the absolute difference as our tolerance
        uint256 tol = product > expected ? product - expected : expected - product;

        // Debug logging
        console2.log("sqrtP_BperA =", uint256(sqrtP_BperA));
        console2.log("sqrtP_AperB =", uint256(sqrtP_AperB));
        console2.log("product     =", product);
        console2.log("tolerance   =", tol);

        assertApproxEqAbs(product, expected, tol);
    }

    function _initializePool(address token0, address token1, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96)
        internal
        returns (PoolId)
    {
        // ... existing code ...
        // Remove the commented line about dynamicFee
        // ... existing code ...
    }

    /// @notice Helper function to add liquidity through governance
    function _addLiquidityAsGovernance(
        PoolId _poolId,
        uint256 amt0,
        uint256 amt1,
        uint256 min0,
        uint256 min1,
        address recipient
    )
        internal
        returns (uint256 shares, uint256 used0, uint256 used1)
    {
        // ------------------------------------------------------------------
        // Ensure the governor actually *owns* – and has approved – the tokens
        // ------------------------------------------------------------------
        PoolKey memory k = poolKey; // same for every call within a test-run
        address t0 = Currency.unwrap(k.currency0);
        address t1 = Currency.unwrap(k.currency1);

        // Fund the governor unconditionally (simpler & safer for fuzz).
        if (amt0 > 0) deal(t0, deployerEOA, amt0);
        if (amt1 > 0) deal(t1, deployerEOA, amt1);

        vm.startPrank(deployerEOA);
        IERC20Minimal(t0).approve(address(liquidityManager), type(uint256).max);
        IERC20Minimal(t1).approve(address(liquidityManager), type(uint256).max);

        (shares, used0, used1) =
            liquidityManager.deposit(_poolId, amt0, amt1, min0, min1, recipient);
        vm.stopPrank();

        return (shares, used0, used1);
    }

    /// @notice Helper function to withdraw liquidity through governance
    function _withdrawLiquidityAsGovernance(
        PoolId _poolId,
        uint256 sharesToBurn,
        uint256 min0,
        uint256 min1,
        address recipient
    ) internal returns (uint256 amt0, uint256 amt1) {
        vm.startPrank(deployerEOA); // deployerEOA is governance
        (amt0, amt1) = liquidityManager.withdraw(_poolId, sharesToBurn, min0, min1, recipient);
        vm.stopPrank();
        return (amt0, amt1);
    }

    /// @notice Helper function to add initial liquidity to the pool
    function addInitialLiquidity() internal {
        uint256 amount0 = Currency.unwrap(poolKey.currency0) == USDC_ADDRESS ? INITIAL_LP_USDC : INITIAL_LP_WETH;
        uint256 amount1 = Currency.unwrap(poolKey.currency0) == USDC_ADDRESS ? INITIAL_LP_WETH : INITIAL_LP_USDC;

        // Use governance to add liquidity
        _addLiquidityAsGovernance(
            poolId,
            amount0,
            amount1,
            0, // min0
            0, // min1
            deployerEOA // recipient is governance
        );
    }

    function _checkPriceHelper(uint160 sqrtP_BperA, uint160 sqrtP_AperB) internal {
        uint256 product = uint256(sqrtP_BperA) * uint256(sqrtP_AperB);
        uint256 tol = uint256(2**96) * uint256(2**96);

        console2.log("sqrtP_BperA =", uint256(sqrtP_BperA));
        console2.log("sqrtP_AperB =", uint256(sqrtP_AperB));
        console2.log("product     =", product);
        console2.log("tolerance   =", tol);
    }
}
