// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

import {PosmTestSetup} from "v4-periphery/test/shared/PosmTestSetup.sol";

import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PositionDescriptor} from "v4-periphery/src/PositionDescriptor.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {INITIAL_LP_USDC, INITIAL_LP_WETH} from "../utils/TestConstants.sol";

// Core Contract Interfaces & Libraries
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
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
import {IPoolPolicyManager} from "src/interfaces/IPoolPolicyManager.sol";
import {IFullRangeLiquidityManager} from "src/interfaces/IFullRangeLiquidityManager.sol"; // Use Interface
import {FullRangeLiquidityManager} from "src/FullRangeLiquidityManager.sol";
import {Spot} from "src/Spot.sol";
import {PriceHelper} from "./utils/PriceHelper.sol";
import {PoolPolicyManager} from "src/PoolPolicyManager.sol";
import {DynamicFeeManager} from "src/DynamicFeeManager.sol";
import {IDynamicFeeManager} from "src/interfaces/IDynamicFeeManager.sol";
import {TruncGeoOracleMulti} from "src/TruncGeoOracleMulti.sol";
import {ITruncGeoOracleMulti} from "src/interfaces/ITruncGeoOracleMulti.sol";
import {SimpleDeployLib} from "test/legacy/utils/SimpleDeployLib.sol";
import {SpotFlags} from "test/legacy/utils/SpotFlags.sol";

// Test Routers
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";

import "forge-std/console.sol";

uint24 constant EXPECTED_MIN_DYNAMIC_FEE = 100; // 0.01 %
uint24 constant EXPECTED_MAX_DYNAMIC_FEE = 100000; // 10 %
uint24 constant EXPECTED_DEFAULT_DYNAMIC_FEE = 3000; // 0.3 %
uint256 constant EXPECTED_DAILY_BUDGET = 50000; // 50 000 units

// --- Local Constants for Integration Tests ---
int24 constant DEFAULT_TICK_SPACING = 60; // matches original library value

/**
 * @title LocalSetup
 * @notice Establishes a consistent baseline state for local testing without forking
 * @dev Deploys all necessary contracts from scratch for a fully local testing environment
 */
contract LocalSetup is Test, PosmTestSetup {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    // --- Deployed/Referenced Contract Instances --- (Interfaces preferred)
    IPoolManager public poolManager;
    /// @dev keep the concrete type; it still implements IPoolPolicyManager
    PoolPolicyManager public policyManager;
    IFullRangeLiquidityManager public liquidityManager;
    ITruncGeoOracleMulti public oracle;
    TruncGeoOracleMulti public truncGeoOracle;
    IDynamicFeeManager public dynamicFeeManager;
    Spot public fullRange;

    // --- Test Routers --- (Deployed in setup)
    PoolModifyLiquidityTest public lpRouter;

    // --- Core V4 & Pool Identifiers ---
    PoolKey internal poolKey;
    PoolId internal poolId;

    // --- Token Addresses & Instances ---
    address internal USDC_ADDRESS;
    IERC20Minimal internal weth;
    IERC20Minimal internal usdc;

    // --- Test User & Deployer EOA ---
    address internal testUser;
    address public deployerEOA;
    uint256 internal deployerPrivateKey;

    // --- Funding Constants ---
    uint256 internal constant FUND_ETH_AMOUNT = 1000 ether;

    // --- Deployment Constants ---

    // Variable to track the actual hook address used (set during deployment)
    address internal actualHookAddress;

    // --- Constants ---
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

    function setUp() public virtual {
        // 1. Basic Env Setup
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

        // 2. Deploy Mock Tokens
        emit log_string("Deploying Mock Tokens...");
        vm.startPrank(deployerEOA);

        // Deploy USDC with 6 decimals
        MockERC20 mockUSDC = new MockERC20("USD Coin", "USDC", 6);
        USDC_ADDRESS = address(mockUSDC);
        usdc = IERC20Minimal(USDC_ADDRESS);

        vm.stopPrank();

        // emit log_named_address("WETH deployed at", WETH_ADDRESS);
        emit log_named_address("USDC deployed at", USDC_ADDRESS);
        emit log_named_address("Permit2 deployed at", PERMIT2_ADDRESS);

        // 3. Deploy PoolManager
        emit log_string("Deploying PoolManager...");
        vm.startPrank(deployerEOA);
        poolManager = new PoolManager(address(this));
        emit log_named_address("PoolManager deployed at", address(poolManager));

        deployPosm(poolManager);

        vm.stopPrank();

        // 4. Deploy All Other Contracts, Configure, Initialize
        emit log_string("\n--- Starting Full Deployment & Configuration ---");
        vm.startPrank(deployerEOA);

        // Deploy PolicyManager (standard new)
        emit log_string("Deploying PolicyManager...");
        PoolPolicyManager policyManagerImpl = new PoolPolicyManager(deployerEOA, EXPECTED_DAILY_BUDGET);
        policyManager = policyManagerImpl; // Use concrete type
        emit log_named_address("[DEPLOY] PoolPolicyManager Deployed at:", address(policyManager));

        // Deploy LiquidityManager (standard new)
        emit log_string("Deploying Extended PositionManager...");
        PositionManager posm = new PositionManager(
            poolManager, IAllowanceTransfer(PERMIT2_ADDRESS), uint256(300_000), IPositionDescriptor(address(0)), _WETH9
        );

        emit log_string("Deploying LiquidityManager...");
        FullRangeLiquidityManager liquidityManagerImpl =
            new FullRangeLiquidityManager(poolManager, posm, truncGeoOracle, deployerEOA);
        liquidityManager = IFullRangeLiquidityManager(address(liquidityManagerImpl));
        emit log_named_address("LiquidityManager deployed at", address(liquidityManager));
        require(address(liquidityManager) != address(0), "LiquidityManager deployment failed");

        // Deploy all other contracts using SimpleDeployLib
        emit log_string("Deploying remaining contracts via SimpleDeployLib...");

        SimpleDeployLib.Deployed memory sd =
            SimpleDeployLib.deployAll(poolManager, policyManager, liquidityManager, deployerEOA);

        truncGeoOracle = sd.oracle;
        oracle = ITruncGeoOracleMulti(address(sd.oracle));
        dynamicFeeManager = sd.dfm;
        fullRange = sd.hook;
        actualHookAddress = address(sd.hook);

        // --- Configure Contracts ---
        emit log_string("Configuring contracts...");

        // --- Set PoolKey & PoolId ---
        address token0;
        address token1;
        (token0, token1) =
            address(_WETH9) < USDC_ADDRESS ? (address(_WETH9), USDC_ADDRESS) : (USDC_ADDRESS, address(_WETH9));

        weth = IERC20Minimal(address(_WETH9));

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            hooks: IHooks(actualHookAddress),
            tickSpacing: DEFAULT_TICK_SPACING
        });
        poolId = poolKey.toId();
        emit log_named_bytes32("Pool ID created", PoolId.unwrap(poolId));
        emit log_named_address("Pool Key Hook Address", address(poolKey.hooks));

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
            address(_WETH9), USDC_ADDRESS, priceUSDCperWETH_scaled, wethDecimals, usdcDecimals
        );
        emit log_named_uint("Calculated SqrtPriceX96 for Pool Init", calculatedSqrtPriceX96);

        // Initialize the pool
        try poolManager.initialize(poolKey, calculatedSqrtPriceX96) {
            emit log_string("Pool initialized successfully in PoolManager.");
        } catch Error(string memory reason) {
            emit log_string(string.concat("Pool initialization failed with string: ", reason));
            revert(string.concat("Pool initialization failed: ", reason));
        } catch (bytes memory rawError) {
            emit log_named_bytes("Pool initialization failed raw data", rawError);
            revert("Pool initialization failed with raw error");
        }

        // Now check slot0 after initialization
        (uint160 sqrtPriceX96_check, int24 tick_check,,) = StateLibrary.getSlot0(poolManager, poolId);
        require(sqrtPriceX96_check != 0 || tick_check == 0, "slot0 zero - pool not init after initialize call");

        // --- Initialize DFM ---
        vm.startPrank(deployerEOA); // Re-prank as owner/deployer for DFM init
        (, int24 initialTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        emit log_named_int("Initializing DFM with tick", initialTick);
        DynamicFeeManager(address(dynamicFeeManager)).initialize(poolId, initialTick);
        emit log_string("DFM Initialized for pool.");
        vm.stopPrank();

        // --- Bootstrap Allowances & Fund Accounts ---
        _bootstrapPoolManagerAllowances();
        _fundTestAccounts();

        // regression-guard: hook MUST be deployed and initialised
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
        assertTrue(sqrtPriceX96 != 0, "Pool not initialized");

        emit log_string("--- LocalSetup Complete ---");
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

        // TODO: remove? no need for hook to approve the PoolManager!?
        // Prank Spot Hook to approve Pool Manager
        vm.startPrank(hookAddr);
        for (uint256 i = 0; i < tokens.length; ++i) {
            IERC20Minimal(tokens[i]).approve(poolManagerAddr, type(uint256).max);
        }
        vm.stopPrank();
    }

    // Helper to fund test accounts
    function _fundTestAccounts() internal {
        seedWeth(deployerEOA);

        vm.startPrank(deployerEOA);

        MockERC20(USDC_ADDRESS).mint(deployerEOA, 30000000 * 10 ** 6); // 30M USDC

        // Transfer tokens to test accounts
        IERC20Minimal(address(_WETH9)).transfer(user1, INITIAL_WETH_BALANCE);
        IERC20Minimal(USDC_ADDRESS).transfer(user1, INITIAL_USDC_BALANCE);
        IERC20Minimal(address(_WETH9)).transfer(user2, INITIAL_WETH_BALANCE);
        IERC20Minimal(USDC_ADDRESS).transfer(user2, INITIAL_USDC_BALANCE);
        IERC20Minimal(address(_WETH9)).transfer(lpProvider, EXTRA_WETH_FOR_ISOLATED + INITIAL_LP_WETH);
        IERC20Minimal(USDC_ADDRESS).transfer(lpProvider, EXTRA_USDC_FOR_ISOLATED + INITIAL_LP_USDC);

        vm.stopPrank();

        // Set up approvals for all test accounts for PoolManager & Routers
        address pmAddr = address(poolManager);
        address lrAddr = address(lpRouter);
        address srAddr = address(swapRouter);

        address[] memory users = new address[](3);
        users[0] = user1;
        users[1] = user2;
        users[2] = lpProvider;

        for (uint256 i = 0; i < users.length; i++) {
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
    function testLocalSetupComplete() public {
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
        (uint160 sqrtPriceX96_check,,,) = StateLibrary.getSlot0(poolManager, poolId);
        require(sqrtPriceX96_check != 0, "slot0 zero - pool not initialized in testLocalSetupComplete");
        emit log_string("PoolManager getSlot0 check passed via require.");

        // Check DFM is initialized for the pool
        try dynamicFeeManager.getFeeState(poolId) returns (uint256, /* baseFee */ uint256 /* surgeFee */ ) {
            emit log_string("DFM getFeeState check passed.");
        } catch {
            assertTrue(false, "Failed to get fee state from DFM");
        }

        // Check Oracle is enabled for the pool
        assertTrue(oracle.isOracleEnabled(poolId), "Oracle not enabled for pool");

        emit log_string("testLocalSetupComplete basic checks passed!");
    }

    // Helper to debug hook flags
    function debugHookFlags() public {
        uint160 requiredFlags = SpotFlags.required();

        emit log_named_uint("Required flags (SpotFlags)", uint256(requiredFlags));
        emit log_named_uint("DYNAMIC_FEE_FLAG", uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG));

        if (actualHookAddress != address(0)) {
            emit log_named_address("Actual Hook Address", actualHookAddress);
            emit log_named_uint("Hook address (as uint)", uint256(uint160(actualHookAddress)));
            uint160 hookFlags = uint160(actualHookAddress) & uint160(Hooks.ALL_HOOK_MASK);
            emit log_named_uint("Actual Hook flags", uint256(hookFlags));

            bool isValidDynamic = Hooks.isValidHookAddress(IHooks(actualHookAddress), LPFeeLibrary.DYNAMIC_FEE_FLAG);
            emit log_named_string("Valid with dynamic fee flag?", isValidDynamic ? "true" : "false");

            // Detailed flag checks if invalid
            if (!isValidDynamic) {
                bool dependency1 = !((hookFlags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG > 0) && (hookFlags & Hooks.BEFORE_SWAP_FLAG == 0));
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

                emit log_named_string(
                    "Flag dependency check 1 (BEFORE_SWAP_DELTA requires BEFORE_SWAP)", dependency1 ? "pass" : "fail"
                );
                emit log_named_string(
                    "Flag dependency check 2 (AFTER_SWAP_DELTA requires AFTER_SWAP)", dependency2 ? "pass" : "fail"
                );
                emit log_named_string(
                    "Flag dependency check 3 (ADD_LIQ_DELTA requires ADD_LIQ)", dependency3 ? "pass" : "fail"
                );
                emit log_named_string(
                    "Flag dependency check 4 (REMOVE_LIQ_DELTA requires REMOVE_LIQ)", dependency4 ? "pass" : "fail"
                );

                bool hasAtLeastOneFlag = uint160(actualHookAddress) & uint160(Hooks.ALL_HOOK_MASK) > 0;
                emit log_named_string("Has at least one flag?", hasAtLeastOneFlag ? "true" : "false");
            }
        } else {
            emit log_string("Cannot debug hook flags: actualHookAddress is zero.");
        }
    }

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
        if (amt0 > 0) {
            vm.startPrank(deployerEOA);
            MockERC20(t0).mint(deployerEOA, amt0);
            vm.stopPrank();
        }
        if (amt1 > 0) {
            vm.startPrank(deployerEOA);
            MockERC20(t1).mint(deployerEOA, amt1);
            vm.stopPrank();
        }

        vm.startPrank(deployerEOA);
        IERC20Minimal(t0).approve(lmAddress, type(uint256).max);
        IERC20Minimal(t1).approve(lmAddress, type(uint256).max);

        // Use the Spot proxy to deposit – FRLM.deposit is restricted to the hook
        (shares, used0, used1) = fullRange.depositToFRLM(k, amt0, amt1, min0, min1, recipient);
        vm.stopPrank();

        return (shares, used0, used1);
    }

    /// @notice Helper function to withdraw liquidity through governance
    /// @dev Pranks as deployerEOA to call withdraw on LM.
    function _withdrawLiquidityAsGovernance(
        PoolKey memory _poolKey,
        uint256 sharesToBurn,
        uint256 min0,
        uint256 min1,
        address recipient
    ) internal returns (uint256 amt0, uint256 amt1) {
        vm.startPrank(deployerEOA); // deployerEOA is governance
        // Cast lmAddress to the concrete type for the call
        (amt0, amt1) = FullRangeLiquidityManager(payable(address(liquidityManager))).withdraw(
            _poolKey, sharesToBurn, min0, min1, recipient, msg.sender
        );
        vm.stopPrank();
        return (amt0, amt1);
    }

    function testDebugHookFlags() public {
        debugHookFlags(); // just prints the required vs. actual flag-bits
    }
}
