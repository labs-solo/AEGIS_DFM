// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {INITIAL_LP_USDC, INITIAL_LP_WETH} from "../utils/TestConstants.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol"; // Corrected path

// Core Contract Interfaces & Libraries
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol"; // Needed for Permissions & Flags
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol"; // Added for getSlot0

// Project Interfaces & Implementations
import {IPoolPolicy} from "src/interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "src/interfaces/IFullRangeLiquidityManager.sol"; // Use Interface
import {FullRangeLiquidityManager} from "src/FullRangeLiquidityManager.sol";
import {Spot} from "src/Spot.sol";
import {HookMiner} from "src/utils/HookMiner.sol";
import {PriceHelper} from "./utils/PriceHelper.sol";
import {PoolPolicyManager} from "src/PoolPolicyManager.sol";
import {DefaultPoolCreationPolicy} from "src/DefaultPoolCreationPolicy.sol";
import {DynamicFeeManager} from "src/DynamicFeeManager.sol";
import {IDynamicFeeManager} from "src/interfaces/IDynamicFeeManager.sol";
import {TruncGeoOracleMulti} from "src/TruncGeoOracleMulti.sol";
import {ITruncGeoOracleMulti} from "src/interfaces/ITruncGeoOracleMulti.sol";

// Use the new shared library
import {SharedDeployLib} from "test/utils/SharedDeployLib.sol";

// Test Routers
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";

uint24 constant EXPECTED_DEFAULT_DYNAMIC_FEE = 3000; // 0.3%

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

    // --- Deployed/Referenced Contract Instances --- (Interfaces preferred)
    IPoolManager public poolManager; // From Unichain
    IPoolPolicy public policyManager; // Deployed in setup (using interface)
    IFullRangeLiquidityManager public liquidityManager; // Deployed in setup (using interface)
    IDynamicFeeManager public dynamicFeeManager; // Deployed in setup (using interface)
    ITruncGeoOracleMulti public oracle; // Deployed in setup (using interface)
    Spot public fullRange; // Deployed in setup via CREATE2

    // --- Test Routers --- (Deployed in setup)
    PoolModifyLiquidityTest public lpRouter;
    PoolSwapTest public swapRouter;
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
    address public deployerEOA;
    uint256 internal deployerPrivateKey;

    // --- Funding Constants ---
    uint256 internal constant FUND_ETH_AMOUNT = 1000 ether;

    // --- Deployment Constants from SharedDeployLib ---
    // uint24 internal constant DEFAULT_FEE = SharedDeployLib.POOL_FEE; // Already dynamic
    int24 internal constant TICK_SPACING = int24(SharedDeployLib.TICK_SPACING);

    // Variable to track the actual hook address used (set during deployment)
    address internal actualHookAddress;

    // --- Constants ---
    bytes public constant ZERO_BYTES = bytes("");
    uint160 internal constant SQRT_RATIO_1_1 = 79228162514264337593543950336; // 2**96

    // Test constants
    uint256 constant INITIAL_USDC_BALANCE = 100_000e6; // 100k USDC
    uint256 constant INITIAL_WETH_BALANCE = 100 ether; // 100 WETH
    uint256 constant EXTRA_USDC_FOR_ISOLATED = 50_000e6; // 50k USDC
    uint256 constant EXTRA_WETH_FOR_ISOLATED = 50 ether; // 50 WETH

    // Test accounts
    address user1;
    address user2;
    address lpProvider;

    // Helper to deal and approve tokens
    function _dealAndApprove(IERC20Minimal token, address holder, uint256 amount, address spender) internal {
        vm.startPrank(holder);
        deal(address(token), holder, amount);
        uint256 MAX = type(uint256).max;
        token.approve(spender, MAX);
        if (spender != address(poolManager)) {
            token.approve(address(poolManager), MAX);
        }
        if (spender != address(liquidityManager)) {
            token.approve(address(liquidityManager), MAX);
        }
        vm.stopPrank();
    }

    // Helper to safely create/select fork
    function _safeFork() internal returns (uint256 forkId) {
        string memory rpcAlias = "unichain_mainnet";
        uint256 forkBlock = 0;
        if (vm.envExists("FORK_BLOCK_NUMBER")) {
            forkBlock = vm.envUint("FORK_BLOCK_NUMBER");
        }
        emit log_named_string("Selected fork RPC alias", rpcAlias);
        emit log_named_uint("Selected fork block number", forkBlock);

        if (forkBlock != 0) {
            forkId = vm.createSelectFork(rpcAlias, forkBlock);
            if (forkId == 0) {
                emit log_string("WARN: Failed to fork at specific block, falling back to latest.");
                forkId = vm.createSelectFork(rpcAlias);
            }
        } else {
            forkId = vm.createSelectFork(rpcAlias);
        }
        require(forkId != 0, "Fork setup failed: vm.createSelectFork returned 0");
    }

    function setUp() public virtual {
        // 1. Create Fork & Basic Env Setup
        uint256 forkId = _safeFork();
        require(forkId > 0, "Fork setup failed, invalid forkId");

        // 2. Setup Test User & Deployer EOA
        testUser = vm.addr(2);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        lpProvider = makeAddr("lpProvider");
        vm.deal(testUser, FUND_ETH_AMOUNT);
        emit log_named_address("Test User", testUser);

        deployerPrivateKey = 1;
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

        // Deploy PolicyManager (standard new)
        emit log_string("Deploying PolicyManager...");
        uint24[] memory supportedTickSpacings = new uint24[](3);
        supportedTickSpacings[0] = 10;
        supportedTickSpacings[1] = 60;
        supportedTickSpacings[2] = 200;
        PoolPolicyManager policyManagerImpl = new PoolPolicyManager(
            deployerEOA, // owner / solo governance
            uint32(EXPECTED_DEFAULT_DYNAMIC_FEE), // Default dynamic fee
            supportedTickSpacings,
            0, // Initial protocol interest fee (0 for test)
            deployerEOA // Fee collector (use deployer for test)
        );
        policyManager = IPoolPolicy(address(policyManagerImpl));
        emit log_named_address("[DEPLOY] PoolPolicyManager Deployed at:", address(policyManager));

        // Deploy LiquidityManager (standard new)
        emit log_string("Deploying LiquidityManager...");
        FullRangeLiquidityManager liquidityManagerImpl = new FullRangeLiquidityManager(poolManager, policyManager, deployerEOA); // Use interface, Governance = deployer
        liquidityManager = IFullRangeLiquidityManager(address(liquidityManagerImpl));
        emit log_named_address("LiquidityManager deployed at", address(liquidityManager));
        require(address(liquidityManager) != address(0), "LiquidityManager deployment failed");

        /* ------------------------------------------------------------------ *
         * PREDICT & DEPLOY ORACLE, DFM, SPOT HOOK VIA CREATE2
         * ------------------------------------------------------------------ */

        // --- Arguments for DynamicFeeManager Prediction/Deployment ---
        bytes memory dfmConstructorArgs = abi.encode(
            policyManager,
            address(0), // Oracle address placeholder, needed for prediction
            address(0)  // Hook address placeholder, needed for prediction
        );
        address predictedDfmAddress = SharedDeployLib.predictDeterministicAddress(
            deployerEOA, SharedDeployLib.DFM_SALT, type(DynamicFeeManager).creationCode, dfmConstructorArgs
        );
        emit log_named_address("Predicted DFM Address", predictedDfmAddress);

        // --- Arguments for Oracle Prediction (Needs Predicted Hook) ---
        // Oracle depends on Hook, Hook depends on Oracle & DFM. Predict DFM first.
        // Predict Spot Hook Address FIRST (needs predicted Oracle & DFM)
        bytes memory spotConstructorArgs = abi.encode(
            poolManager,
            policyManager, // Use interface
            liquidityManager, // Use interface
            address(0), // Oracle address placeholder
            IDynamicFeeManager(predictedDfmAddress), // Use predicted DFM address
            deployerEOA // Initial Owner
        );
        address predictedHookAddress = SharedDeployLib.predictDeterministicAddress(
            deployerEOA, SharedDeployLib.SPOT_SALT, type(Spot).creationCode, spotConstructorArgs
        );
        emit log_named_address("Predicted Spot Hook Address", predictedHookAddress);

        // --- Predict Oracle Address (using predicted Hook) ---
        bytes memory oracleConstructorArgs = abi.encode(
            poolManager,
            deployerEOA,
            policyManager,
            predictedHookAddress // Use predicted hook address
        );
        address predictedOracleAddress = SharedDeployLib.predictDeterministicAddress(
            deployerEOA, SharedDeployLib.ORACLE_SALT, type(TruncGeoOracleMulti).creationCode, oracleConstructorArgs
        );
        emit log_named_address("Predicted Oracle Address", predictedOracleAddress);

        // --- DEPLOY Oracle with CREATE2 ---
        // NOTE: predictedHookAddress is determined *after* oracle deployment below,
        // because the oracle constructor now enforces the hook address.

        emit log_string("Deploying Oracle via CREATE2...");
        oracle = ITruncGeoOracleMulti(SharedDeployLib.deployDeterministic(
            SharedDeployLib.ORACLE_SALT, type(TruncGeoOracleMulti).creationCode, oracleConstructorArgs
        ));
        emit log_named_address("Oracle deployed at:", address(oracle));
        require(address(oracle) == predictedOracleAddress, "Oracle address mismatch");

        // --- Get required hook address from deployed Oracle ---
        address requiredHook = oracle.getHookAddress();
        require(requiredHook == predictedHookAddress, "Oracle hook address mismatch vs prediction");

        // --- Prepare FINAL DFM Constructor Args (with actual Oracle) ---
        bytes memory finalDfmConstructorArgs = abi.encode(
            policyManager,
            address(oracle), // Use deployed oracle address
            requiredHook // Use hook address required by oracle
        );

        // --- DEPLOY DFM with CREATE2 (using final args) ---
        emit log_string("Deploying DFM via CREATE2...");
        dynamicFeeManager = IDynamicFeeManager(SharedDeployLib.deployDeterministic(
            SharedDeployLib.DFM_SALT, type(DynamicFeeManager).creationCode, finalDfmConstructorArgs
        ));
        emit log_named_address("DynamicFeeManager deployed at:", address(dynamicFeeManager));
        // We cannot easily predict the address with the *final* oracle address easily beforehand,
        // but we deploy with the same salt, so it *should* land at predictedDfmAddress if bytecode matches.
        // Let's check against the initially predicted address based on placeholders.
        // If this fails, it implies bytecode changed due to oracle address, which is possible.
        // assertEq(address(dynamicFeeManager), predictedDfmAddress, "DFM address mismatch");
        // A safer check might be to re-predict with final args, or accept the deployed address.


        // --- Prepare FINAL Spot Hook Constructor Args (with actual Oracle & DFM) ---
        bytes memory finalSpotConstructorArgs = abi.encode(
            poolManager,
            policyManager, // Use interface
            liquidityManager, // Use interface
            TruncGeoOracleMulti(address(oracle)), // Use deployed Oracle address
            dynamicFeeManager, // Use deployed DFM address
            deployerEOA // Initial Owner
        );

        // --- DEPLOY Spot Hook with CREATE2 (using final args, MUST match oracle's required address) ---
        emit log_string("Deploying Spot hook via CREATE2...");
        bytes memory hookCreationCode = type(Spot).creationCode;
        address deployedHookAddress = SharedDeployLib.deployDeterministic(
            SharedDeployLib.SPOT_SALT, hookCreationCode, finalSpotConstructorArgs
        );
        require(deployedHookAddress == requiredHook, "Deployed hook != required hook");
        fullRange = Spot(payable(deployedHookAddress));
        emit log_named_address("Spot hook deployed at:", deployedHookAddress);
        actualHookAddress = deployedHookAddress;

        // --- Configure Contracts ---
        emit log_string("Configuring contracts...");
        FullRangeLiquidityManager(payable(address(liquidityManager))).setAuthorizedHookAddress(actualHookAddress);
        emit log_string("LiquidityManager configured.");

        // --- Set PoolKey & PoolId ---
        address token0;
        address token1;
        (token0, token1) = WETH_ADDRESS < USDC_ADDRESS ? (WETH_ADDRESS, USDC_ADDRESS) : (USDC_ADDRESS, WETH_ADDRESS);

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: SharedDeployLib.POOL_FEE, // Use dynamic fee flag from library
            hooks: IHooks(actualHookAddress), // Use the deployed hook address
            tickSpacing: TICK_SPACING
        });
        poolId = poolKey.toId();
        emit log_named_bytes32("Pool ID created", PoolId.unwrap(poolId));
        emit log_named_address("Pool Key Hook Address", address(poolKey.hooks));

        // --- Initialize DFM --- (Already deployed, now initialize pool within it)
        emit log_string("Initializing DFM for pool...");
        // Get initial tick *after* pool is potentially initialized below
        // (Tick is needed for DFM init, but pool might not exist yet on fork)
        // We will initialize DFM *after* poolManager.initialize

        // --- Deploy Test Routers ---
        emit log_string("Deploying test routers...");
        lpRouter = new PoolModifyLiquidityTest(poolManager);
        swapRouter = new PoolSwapTest(poolManager);
        donateRouter = new PoolDonateTest(poolManager);
        emit log_string("Test routers deployed.");

        // End prank for deployments & config
        vm.stopPrank();

        // --- Initialize Pool in PoolManager ---
        emit log_string("Initializing pool in PoolManager...");
        uint8 wethDecimals = 18;
        uint8 usdcDecimals = 6;
        uint256 priceUSDCperWETH_scaled = 3000 * (10 ** usdcDecimals);
        uint160 calculatedSqrtPriceX96 = PriceHelper.priceToSqrtX96(
            WETH_ADDRESS, USDC_ADDRESS, priceUSDCperWETH_scaled, wethDecimals, usdcDecimals
        );
        emit log_named_uint("Calculated SqrtPriceX96 for Pool Init", calculatedSqrtPriceX96);

        // Library call is internal – no try/catch allowed.
        // It SHOULD NOT revert if pool is properly initialized; we assert.
        // The PoolManager.initialize call might revert if already initialized or hook is invalid.
        try poolManager.initialize(poolKey, calculatedSqrtPriceX96) {
            emit log_string("Pool initialized successfully in PoolManager.");
        } catch Error(string memory reason) {
            // Handle specific known errors gracefully if needed, otherwise let it revert
            bytes4 poolAlreadyInitializedSelector = bytes4(keccak256("PoolAlreadyInitialized(bytes32)"));
            bytes4 hookAddressNotValidSelector = bytes4(keccak256("HookAddressNotValid(address)"));
            if (bytes(reason).length >= 4) {
                bytes4 selector = bytes4(bytes(reason));
                 if (selector == poolAlreadyInitializedSelector) {
                    emit log_string("Pool already initialized on fork, skipping PoolManager.initialize.");
                 } else if (selector == hookAddressNotValidSelector) {
                    // This revert should not happen now, but keep check for debugging
                    address invalidHookAddress; // Need to decode from reason if possible, complex
                    emit log_named_string("Pool initialization failed", "HookAddressNotValid");
                    // emit log_named_address("Invalid Hook Address provided to PoolManager", invalidHookAddress);
                    debugHookFlags();
                    revert("HookAddressNotValid during pool initialization");
                 } else {
                    // Unknown error string
                     emit log_string(string.concat("Pool initialization failed with string: ", reason));
                     revert(string.concat("Pool initialization failed: ", reason));
                 }
            } else {
                 emit log_string(string.concat("Pool initialization failed with short string: ", reason));
                 revert(string.concat("Pool initialization failed: ", reason));
            }
        } catch (bytes memory rawError) {
            // Catch generic byte errors if string decoding fails
            emit log_named_bytes("Pool initialization failed raw data", rawError);
            revert("Pool initialization failed with raw error");
        }

        // Now check slot0 *after* potential initialization or handled error
        (uint160 sqrtPriceX96_check, int24 tick_check,,) = StateLibrary.getSlot0(poolManager, poolId);
        require(sqrtPriceX96_check != 0 || tick_check == 0, "slot0 zero - pool not init after initialize call");

        // --- Initialize DFM (Now that pool definitely exists or is initialized) ---
        vm.startPrank(deployerEOA); // Re-prank as owner/deployer for DFM init
        (, int24 initialTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        emit log_named_int("Initializing DFM with tick", initialTick);
        DynamicFeeManager(address(dynamicFeeManager)).initialize(poolId, initialTick);
        emit log_string("DFM Initialized for pool.");
        vm.stopPrank();

        // --- Bootstrap Allowances & Fund Accounts ---
        _bootstrapPoolManagerAllowances();
        _fundTestAccounts();

        emit log_string("--- ForkSetup Complete ---");
    }

    // Helper to grant initial allowances from contracts to PoolManager & Self
    function _bootstrapPoolManagerAllowances() internal {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        address liqManagerAddr = address(liquidityManager);
        address poolManagerAddr = address(poolManager);
        address hookAddr = address(fullRange);

        // Prank Liquidity Manager to approve Pool Manager and Self
        vm.startPrank(liqManagerAddr);
        for (uint256 i = 0; i < tokens.length; ++i) {
            IERC20Minimal(tokens[i]).approve(poolManagerAddr, type(uint256).max);
            IERC20Minimal(tokens[i]).approve(liqManagerAddr, type(uint256).max); // Self-approval
        }
        vm.stopPrank();

        // Prank Spot Hook to approve Pool Manager
        vm.startPrank(hookAddr);
        for (uint256 i = 0; i < tokens.length; ++i) {
            IERC20Minimal(tokens[i]).approve(poolManagerAddr, type(uint256).max);
        }
        vm.stopPrank();
    }

    // Helper to fund test accounts
    function _fundTestAccounts() internal {
        vm.startPrank(deployerEOA);
        uint256 totalUsdcNeeded = (INITIAL_USDC_BALANCE * 2) + INITIAL_LP_USDC + EXTRA_USDC_FOR_ISOLATED;
        deal(USDC_ADDRESS, deployerEOA, totalUsdcNeeded);
        uint256 totalWethNeeded = (INITIAL_WETH_BALANCE * 2) + INITIAL_LP_WETH + EXTRA_WETH_FOR_ISOLATED;
        deal(WETH_ADDRESS, deployerEOA, totalWethNeeded);
        if (weth.balanceOf(deployerEOA) < totalWethNeeded) {
             // Wrap ETH only if needed
             uint256 ethNeeded = totalWethNeeded - weth.balanceOf(deployerEOA);
             if (deployerEOA.balance >= ethNeeded) { // Check ETH balance
                IWETH9(WETH_ADDRESS).deposit{value: ethNeeded}();
             } else {
                 revert("Deployer has insufficient ETH to wrap for WETH");
             }
        }

        // Transfer tokens to test accounts
        IERC20Minimal(WETH_ADDRESS).transfer(user1, INITIAL_WETH_BALANCE);
        IERC20Minimal(USDC_ADDRESS).transfer(user1, INITIAL_USDC_BALANCE);
        IERC20Minimal(WETH_ADDRESS).transfer(user2, INITIAL_WETH_BALANCE);
        IERC20Minimal(USDC_ADDRESS).transfer(user2, INITIAL_USDC_BALANCE);
        IERC20Minimal(WETH_ADDRESS).transfer(lpProvider, EXTRA_WETH_FOR_ISOLATED + INITIAL_LP_WETH); // Fund for initial LP too
        IERC20Minimal(USDC_ADDRESS).transfer(lpProvider, EXTRA_USDC_FOR_ISOLATED + INITIAL_LP_USDC); // Fund for initial LP too
        vm.stopPrank();

        // Set up approvals for all test accounts for PoolManager & Routers
        address pmAddr = address(poolManager);
        address lrAddr = address(lpRouter);
        address srAddr = address(swapRouter);

        address[] memory users = new address[](3);
        users[0] = user1; users[1] = user2; users[2] = lpProvider;
        uint256[] memory wethDeals = new uint256[](3);
        wethDeals[0] = INITIAL_WETH_BALANCE; wethDeals[1] = INITIAL_WETH_BALANCE; wethDeals[2] = EXTRA_WETH_FOR_ISOLATED + INITIAL_LP_WETH;
        uint256[] memory usdcDeals = new uint256[](3);
        usdcDeals[0] = INITIAL_USDC_BALANCE; usdcDeals[1] = INITIAL_USDC_BALANCE; usdcDeals[2] = EXTRA_USDC_FOR_ISOLATED + INITIAL_LP_USDC;

        for(uint i = 0; i < users.length; i++) {
             vm.startPrank(users[i]);
             weth.approve(pmAddr, type(uint256).max);
             usdc.approve(pmAddr, type(uint256).max);
             weth.approve(lrAddr, type(uint256).max);
             usdc.approve(lrAddr, type(uint256).max);
             weth.approve(srAddr, type(uint256).max);
             usdc.approve(srAddr, type(uint256).max);
             vm.stopPrank();
        }
    }

    // Test that validates the full setup
    function testForkSetupComplete() public {
        assertTrue(address(poolManager) != address(0), "PoolManager not set");
        assertTrue(address(policyManager) != address(0), "PolicyManager not deployed");
        assertTrue(address(liquidityManager) != address(0), "LiquidityManager not deployed");
        assertTrue(address(oracle) != address(0), "Oracle not deployed");
        assertEq(address(fullRange), actualHookAddress, "FullRange hook address mismatch");
        assertTrue(address(dynamicFeeManager) != address(0), "DynamicFeeManager not deployed");
        assertTrue(address(lpRouter) != address(0), "LpRouter not deployed");
        assertTrue(address(swapRouter) != address(0), "SwapRouter not deployed");
        assertTrue(address(donateRouter) != address(0), "DonateRouter not deployed");
        assertTrue(testUser.balance >= FUND_ETH_AMOUNT, "TestUser ETH balance incorrect");

        // Check LM authorized hook
        address authorizedHook = FullRangeLiquidityManager(payable(address(liquidityManager))).authorizedHookAddress();
        assertEq(authorizedHook, actualHookAddress, "LM authorized hook mismatch");

        // Check Oracle hook address
        address oracleHook = oracle.getHookAddress();
        assertEq(oracleHook, actualHookAddress, "Oracle hook address mismatch");

        // Check DFM hook address
        address dfmHook = DynamicFeeManager(address(dynamicFeeManager)).authorizedHook();
        assertEq(dfmHook, actualHookAddress, "DFM hook address mismatch");

        // Check if pool is initialized in PoolManager
        // Library call is internal (not external), so we can't use try/catch.
        // It SHOULD succeed if the pool was initialized – assert minimal sanity.
        (uint160 sqrtPriceX96_check,,,) = StateLibrary.getSlot0(poolManager, poolId);
        require(sqrtPriceX96_check != 0, "slot0 zero - pool not initialized in testForkSetupComplete");
        emit log_string("PoolManager getSlot0 check passed via require.");

        // Check DFM is initialized for the pool
        try dynamicFeeManager.getFeeState(poolId) returns (uint256 baseFee, uint256 surgeFee) {
             emit log_string("DFM getFeeState check passed.");
        } catch {
             assertTrue(false, "Failed to get fee state from DFM");
        }

        // Check Oracle is enabled for the pool
        assertTrue(oracle.isOracleEnabled(poolId), "Oracle not enabled for pool");

        emit log_string("testForkSetupComplete basic checks passed!");
    }

    // Helper function to debug hook flags (Now uses actualHookAddress)
    function debugHookFlags() public {
        uint160 requiredFlags = SharedDeployLib.spotHookFlags();

        emit log_named_uint("Required flags (SharedDeployLib)", uint256(requiredFlags));
        emit log_named_uint("DYNAMIC_FEE_FLAG", uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG));

        if (actualHookAddress != address(0)) {
            emit log_named_address("Actual Hook Address", actualHookAddress);
            emit log_named_uint("Hook address (as uint)", uint256(uint160(actualHookAddress)));
            uint160 hookFlags = uint160(actualHookAddress) & uint160(Hooks.ALL_HOOK_MASK);
            emit log_named_uint("Actual Hook flags", uint256(hookFlags));

            bool isValidDynamic = Hooks.isValidHookAddress(IHooks(actualHookAddress), LPFeeLibrary.DYNAMIC_FEE_FLAG);
            emit log_named_string(
                "Valid with dynamic fee flag?",
                isValidDynamic ? "true" : "false"
            );

            // Detailed flag checks if invalid
            if (!isValidDynamic) {
                bool dependency1 = !((hookFlags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG > 0) && (hookFlags & Hooks.BEFORE_SWAP_FLAG == 0));
                bool dependency2 = !((hookFlags & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG > 0) && (hookFlags & Hooks.AFTER_SWAP_FLAG == 0));
                bool dependency3 = !((hookFlags & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG > 0) && (hookFlags & Hooks.AFTER_ADD_LIQUIDITY_FLAG == 0));
                bool dependency4 = !((hookFlags & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG > 0) && (hookFlags & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG == 0));

                emit log_named_string("Flag dependency check 1 (BEFORE_SWAP_DELTA requires BEFORE_SWAP)", dependency1 ? "pass" : "fail");
                emit log_named_string("Flag dependency check 2 (AFTER_SWAP_DELTA requires AFTER_SWAP)", dependency2 ? "pass" : "fail");
                emit log_named_string("Flag dependency check 3 (ADD_LIQ_DELTA requires ADD_LIQ)", dependency3 ? "pass" : "fail");
                emit log_named_string("Flag dependency check 4 (REMOVE_LIQ_DELTA requires REMOVE_LIQ)", dependency4 ? "pass" : "fail");

                bool hasAtLeastOneFlag = uint160(actualHookAddress) & Hooks.ALL_HOOK_MASK > 0;
                emit log_named_string("Has at least one flag or is dynamic fee?", (hasAtLeastOneFlag || LPFeeLibrary.DYNAMIC_FEE_FLAG == SharedDeployLib.POOL_FEE) ? "true" : "false");
            }
        } else {
             emit log_string("Cannot debug hook flags: actualHookAddress is zero.");
        }
    }

    // --- Other Helpers (Price, Liquidity) ---

    /// @notice Helper function to add liquidity through governance
    /// @dev Ensures the governor (deployerEOA) has funds and approves LM.
    function _addLiquidityAsGovernance(
        PoolId _poolId,
        uint256 amt0,
        uint256 amt1,
        uint256 min0,
        uint256 min1,
        address recipient
    ) internal returns (uint256 shares, uint256 used0, uint256 used1) {
        PoolKey memory k = poolKey; // Use the class-level poolKey
        address t0 = Currency.unwrap(k.currency0);
        address t1 = Currency.unwrap(k.currency1);
        address lmAddress = address(liquidityManager);

        // Fund the governor unconditionally.
        if (amt0 > 0) deal(t0, deployerEOA, amt0);
        if (amt1 > 0) deal(t1, deployerEOA, amt1);

        vm.startPrank(deployerEOA);
        IERC20Minimal(t0).approve(lmAddress, type(uint256).max);
        IERC20Minimal(t1).approve(lmAddress, type(uint256).max);

        // Cast lmAddress to the concrete type for the call
        (shares, used0, used1) = FullRangeLiquidityManager(payable(lmAddress)).deposit(_poolId, amt0, amt1, min0, min1, recipient);
        vm.stopPrank();

        return (shares, used0, used1);
    }

    /// @notice Helper function to withdraw liquidity through governance
    /// @dev Pranks as deployerEOA to call withdraw on LM.
    function _withdrawLiquidityAsGovernance(
        PoolId _poolId,
        uint256 sharesToBurn,
        uint256 min0,
        uint256 min1,
        address recipient
    ) internal returns (uint256 amt0, uint256 amt1) {
        vm.startPrank(deployerEOA); // deployerEOA is governance
        // Cast lmAddress to the concrete type for the call
        (amt0, amt1) = FullRangeLiquidityManager(payable(address(liquidityManager))).withdraw(_poolId, sharesToBurn, min0, min1, recipient);
        vm.stopPrank();
        return (amt0, amt1);
    }

    // Removed testPriceHelper_USDC_WETH_Regression, testPriceHelper_WETH_USDC_Inverse
    // Removed substring
    // Removed checkHookAddressValidity (replaced by debugHookFlags and direct check)
    // Removed _initializePool
    // Removed addInitialLiquidity
    // Removed _checkPriceHelper
}
