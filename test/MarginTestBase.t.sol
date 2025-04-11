// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";

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
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

// Spot/Margin Contracts
import {Margin} from "../src/Margin.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "../src/interfaces/IFullRangeLiquidityManager.sol";
import {IFullRangeDynamicFeeManager} from "../src/interfaces/IFullRangeDynamicFeeManager.sol";
import {FullRangeLiquidityManager} from "../src/FullRangeLiquidityManager.sol";
import {FullRangeDynamicFeeManager} from "../src/FullRangeDynamicFeeManager.sol";
import {PoolPolicyManager} from "../src/PoolPolicyManager.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {MarginManager} from "../src/MarginManager.sol";
import {IMarginManager} from "../src/interfaces/IMarginManager.sol";
import {IMarginData} from "../src/interfaces/IMarginData.sol";

// Token mocks
import "../src/token/MockERC20.sol";

// New imports
import { TruncatedOracle } from "../src/libraries/TruncatedOracle.sol";
import { TruncGeoOracleMulti } from "../src/TruncGeoOracleMulti.sol";
import {DepositParams, WithdrawParams} from "../src/interfaces/ISpot.sol";
import {LinearInterestRateModel} from "../src/LinearInterestRateModel.sol";
import {IInterestRateModel} from "../src/interfaces/IInterestRateModel.sol";
import {Errors} from "../src/errors/Errors.sol";
import {IFullRangePositions} from "../src/interfaces/IFullRangePositions.sol";

/**
 * @title MarginTestBase
 * @notice Base test contract setting up shared instances for multi-pool Margin testing.
 * @dev Deploys single instances of core contracts (PoolManager, Margin, MM, LM, etc.)
 *      and provides helpers for pool initialization and interaction.
 */
abstract contract MarginTestBase is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Deployed contract references (SINGLE SHARED INSTANCES)
    PoolManager public poolManager;
    PoolPolicyManager public policyManager;
    FullRangeLiquidityManager public liquidityManager;
    MarginManager public marginManager;
    FullRangeDynamicFeeManager public dynamicFeeManager;
    Margin public fullRange;
    TruncGeoOracleMulti public truncGeoOracle;
    LinearInterestRateModel public interestRateModel;

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

    // Constants
    uint256 constant FLAG_USE_VAULT_BALANCE_FOR_REPAY = 1; // Direct value from IMarginData.sol

    /**
     * @notice Sets up the single shared instances of all core contracts.
     * @dev Deploys PoolManager, LM, MM, Margin (via CREATE2), Oracle, RateModel, etc.
     *      Does NOT initialize any specific pool.
     */
    function setUp() public virtual {
        // Set up test accounts with ETH
        vm.deal(deployer, INITIAL_ETH_BALANCE);
        vm.deal(alice, INITIAL_ETH_BALANCE);
        vm.deal(bob, INITIAL_ETH_BALANCE);
        vm.deal(charlie, INITIAL_ETH_BALANCE);
        vm.deal(governance, INITIAL_ETH_BALANCE);

        // --- Deploy Shared Infrastructure ---
        vm.startPrank(deployer);
        // console.log("[SETUP] Deploying PoolManager...");
        poolManager = new PoolManager(address(deployer));
        // console.log("[SETUP] PoolManager Deployed.");

        // console.log("[SETUP] Deploying PolicyManager...");
        uint24[] memory supportedTickSpacings = new uint24[](3);
        supportedTickSpacings[0] = 10;
        supportedTickSpacings[1] = 60;
        supportedTickSpacings[2] = 200;
        policyManager = new PoolPolicyManager(
            governance, POL_SHARE_PPM, FULLRANGE_SHARE_PPM, LP_SHARE_PPM, MIN_TRADING_FEE_PPM,
            FEE_CLAIM_THRESHOLD_PPM, DEFAULT_POL_MULTIPLIER, DEFAULT_DYNAMIC_FEE_PPM,
            TICK_SCALING_FACTOR, supportedTickSpacings, 1e17, address(0)
        );
        // console.log("[SETUP] PolicyManager Deployed.");

        // console.log("[SETUP] Deploying LiquidityManager...");
        liquidityManager = new FullRangeLiquidityManager(poolManager, governance);
        // console.log("[SETUP] LiquidityManager Deployed.");

        // console.log("[SETUP] Deploying TruncGeoOracleMulti...");
        truncGeoOracle = new TruncGeoOracleMulti(poolManager, governance);
        // console.log("[SETUP] TruncGeoOracleMulti Deployed.");

        // console.log("[SETUP] Deploying InterestRateModel...");
        interestRateModel = new LinearInterestRateModel(
            governance, 2 * 1e16, 10 * 1e16, 80 * 1e16, 5 * 1e18, 95 * 1e16, 1 * 1e18
        );
        // console.log("[SETUP] InterestRateModel Deployed.");
        vm.stopPrank();

        // --- Deploy MarginManager and Margin (via CREATE2) ---
        vm.startPrank(governance);
        // console.log("[SETUP] Deploying Margin hook and MarginManager via CREATE2...");

        // 1. Define correct flags based on Margin.getHookPermissions()
        // Matching the original Margin hook permissions
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        
        console2.log("DEBUG - Hook flags:", flags);
        console2.log("DEBUG - Hook all flags mask:", Hooks.ALL_HOOK_MASK);

        // 2. Encode constructor args with the MarginManager placeholder (address(0))
        bytes memory marginConstructorArgs = abi.encode(
            address(poolManager), IPoolPolicy(address(policyManager)), address(liquidityManager), address(0) // Placeholder MM
        );
        
        // 3. Create the final creation code by combining code and args
        bytes memory marginCreationCode = abi.encodePacked(type(Margin).creationCode, marginConstructorArgs);
        bytes32 creationCodeHash = keccak256(marginCreationCode);
        console2.log("DEBUG - Creation code size:", marginCreationCode.length);
        console2.logBytes32(creationCodeHash);

        // 4. Get predicted hook address using our known salt
        bytes32 salt = bytes32(uint256(4803)); // Known working salt for original hook permissions
        address predictedHookAddress = HookMiner.computeAddress(
            governance, 
            uint256(salt),
            marginCreationCode
        );
        console2.log("DEBUG - Using hardcoded salt for hook deployment:", uint256(salt));
        console2.log("DEBUG - Computed hook address:", predictedHookAddress);
        console2.log("DEBUG - Hook address permissions:", uint160(predictedHookAddress) & Hooks.ALL_HOOK_MASK);
        require(predictedHookAddress != address(0), "Hook address prediction failed");

        // 5. Deploy MarginManager, passing the PREDICTED hook address
        uint256 initialSolvencyThreshold = 98 * 1e16;
        uint256 initialLiquidationFee = 1 * 1e16;
        marginManager = new MarginManager(
            predictedHookAddress, // Pass the predicted address
            address(poolManager),
            address(liquidityManager),
            governance,
            initialSolvencyThreshold,
            initialLiquidationFee
        );
        console2.log("DEBUG - MarginManager deployed at:", address(marginManager));

        // Add extra debug information about flags and addresses
        console2.log("DEBUG - Margin Flags Value:", flags);
        console2.log("DEBUG - Hook ALL_HOOK_MASK:", Hooks.ALL_HOOK_MASK);
        
        // Debug addresses
        console2.log("DEBUG - Governance:", governance);
        console2.log("DEBUG - Pool Manager:", address(poolManager));
        console2.log("DEBUG - Policy Manager:", address(policyManager));
        console2.log("DEBUG - Liquidity Manager:", address(liquidityManager));
        console2.log("DEBUG - Margin Manager:", address(marginManager));
        
        // 6. Prepare FINAL constructor args with real MarginManager address
        bytes memory finalMarginConstructorArgs = abi.encode(
            address(poolManager), 
            IPoolPolicy(address(policyManager)), 
            address(liquidityManager), 
            address(marginManager) // Real MM address
        );

        // Debug bytecode
        console2.logBytes32(keccak256(finalMarginConstructorArgs));

        // 7. Verify the creation code with FINAL arguments doesn't change the bytecode hash significantly
        bytes memory finalMarginCreationCode = abi.encodePacked(type(Margin).creationCode, finalMarginConstructorArgs);
        bytes32 finalCreationCodeHash = keccak256(finalMarginCreationCode);
        console2.log("DEBUG - Final creation code size:", finalMarginCreationCode.length);
        console2.logBytes32(finalCreationCodeHash);

        // 8. Deploy Margin using the same hardcoded salt and FINAL constructor args
        console2.log("DEBUG - Using hardcoded salt for hook deployment:", uint256(salt));
        
        fullRange = new Margin{salt: salt}(
            poolManager,
            IPoolPolicy(address(policyManager)),
            liquidityManager,
            address(marginManager)
        );
        console2.log("DEBUG - Margin deployed at:", address(fullRange));

        // 9. VERIFY the deployed address matches the prediction passed to MM
        console2.log("DEBUG - Expected address:", predictedHookAddress);
        console2.log("DEBUG - Actual address:", address(fullRange));
        
        // Try to compute the address directly for debugging
        address computedAddress = HookMiner.computeAddress(
            governance, uint256(salt), finalMarginCreationCode
        );
        console2.log("DEBUG - Computed address:", computedAddress);
        
        require(address(fullRange) == predictedHookAddress, "CREATE2 Hook address deployment mismatch");

        // console.log("[SETUP] Deploying DynamicFeeManager...");
        dynamicFeeManager = new FullRangeDynamicFeeManager(
            governance, IPoolPolicy(address(policyManager)), poolManager, address(fullRange)
        );
        // console.log("[SETUP] DynamicFeeManager Deployed.");

        // console.log("[SETUP] Linking contracts...");
        liquidityManager.setAuthorizedHookAddress(address(fullRange));
        fullRange.setDynamicFeeManager(address(dynamicFeeManager));
        fullRange.setOracleAddress(address(truncGeoOracle));
        truncGeoOracle.setFullRangeHook(address(fullRange));
        marginManager.setInterestRateModel(address(interestRateModel));
        // console.log("[SETUP] Contracts Linked.");
        vm.stopPrank();

        vm.startPrank(deployer);
        // console.log("[SETUP] Deploying Routers...");
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        donateRouter = new PoolDonateTest(IPoolManager(address(poolManager)));
        // console.log("[SETUP] Routers Deployed.");

        // console.log("[SETUP] Creating Tokens...");
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);
        token2 = new MockERC20("Token2", "TKN2", 18);

        if (address(token0) > address(token1)) { (token0, token1) = (token1, token0); }

        token0.mint(alice, INITIAL_TOKEN_BALANCE); token1.mint(alice, INITIAL_TOKEN_BALANCE); token2.mint(alice, INITIAL_TOKEN_BALANCE);
        token0.mint(bob, INITIAL_TOKEN_BALANCE); token1.mint(bob, INITIAL_TOKEN_BALANCE); token2.mint(bob, INITIAL_TOKEN_BALANCE);
        token0.mint(charlie, INITIAL_TOKEN_BALANCE); token1.mint(charlie, INITIAL_TOKEN_BALANCE); token2.mint(charlie, INITIAL_TOKEN_BALANCE);
        // console.log("[SETUP] Tokens Created.");

        vm.stopPrank();
        // console.log("[SETUP] Completed. Shared instances ready. No pools initialized yet.");
    }

    /**
     * @notice Helper function to initialize a new pool and register its key with the Liquidity Manager.
     * @dev This should be called within individual tests or specific test setups.
     * @param _hookAddress The address of the hook to use (should be the shared `fullRange` instance).
     * @param _lmAddress The address of the liquidity manager (should be the shared `liquidityManager` instance).
     * @param _currency0 Currency 0 for the pool.
     * @param _currency1 Currency 1 for the pool.
     * @param _fee Pool fee tier. Use `DEFAULT_FEE` (0x800000) for dynamic fee.
     * @param _tickSpacing Pool tick spacing.
     * @param _sqrtPriceX96 Initial price for the pool.
     * @return poolId_ The ID of the newly created pool.
     * @return key_ The PoolKey of the newly created pool.
     */
    function createPoolAndRegister(
        address _hookAddress,
        address _lmAddress,
        Currency _currency0,
        Currency _currency1,
        uint24 _fee,
        int24 _tickSpacing,
        uint160 _sqrtPriceX96
    ) internal returns (PoolId poolId_, PoolKey memory key_) {
        if (Currency.unwrap(_currency0) > Currency.unwrap(_currency1)) {
            (_currency0, _currency1) = (_currency1, _currency0);
        }

        key_ = PoolKey({
            currency0: _currency0,
            currency1: _currency1,
            fee: _fee,
            tickSpacing: _tickSpacing,
            hooks: IHooks(_hookAddress)
        });

        poolId_ = key_.toId();
        // console.log("[Helper] Attempting to initialize pool:", PoolId.unwrap(poolId_));

        try poolManager.initialize(key_, _sqrtPriceX96) {
             // console.log("[Helper] Pool initialized successfully.");
             PoolKey memory storedKey = liquidityManager.poolKeys(poolId_);
            require(
                keccak256(abi.encode(storedKey)) == keccak256(abi.encode(key_)),
                 "LM did not store correct key"
            );
            // console.log("[Helper] PoolKey confirmed stored in LM.");
        } catch Error(string memory reason) {
            // console.log("[Helper] Pool initialization failed:", reason);
            revert(reason);
        } catch (bytes memory lowLevelData) {
            // console.logBytes(lowLevelData);
            revert("Pool initialization failed with low-level data");
        }

        return (poolId_, key_);
    }

    /**
     * @notice Helper function to add traditional concentrated liquidity via lpRouter.
     * @param account The account providing liquidity.
     * @param poolKey_ The key of the target pool.
     * @param tickLower The lower tick bound.
     * @param tickUpper The upper tick bound.
     * @param liquidity The amount of liquidity to add.
     */
    function addLiquidity(address account, PoolKey memory poolKey_, int24 tickLower, int24 tickUpper, uint128 liquidity) internal {
        vm.stopPrank();
        vm.startPrank(account);

        address tokenAddr0 = Currency.unwrap(poolKey_.currency0);
        address tokenAddr1 = Currency.unwrap(poolKey_.currency1);
        if (tokenAddr0 != address(0)) {
            IERC20Minimal(tokenAddr0).approve(address(poolManager), type(uint256).max);
        }
        if (tokenAddr1 != address(0)) {
            IERC20Minimal(tokenAddr1).approve(address(poolManager), type(uint256).max);
        }

        // console.log("addLiquidity Debug: Account=", account);
        // console.log("addLiquidity Debug: PoolId=", PoolId.unwrap(poolKey_.toId()));

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });

        uint256 valueToSend = 0;

        lpRouter.modifyLiquidity{value: valueToSend}(poolKey_, params, "");
        vm.stopPrank();
    }

    /**
     * @notice Helper function to add full range liquidity via Margin hook's executeBatch.
     * @param account The address providing liquidity.
     * @param poolId_ The ID of the target pool.
     * @param amount0 The amount of token0 to deposit.
     * @param amount1 The amount of token1 to deposit.
     * @param value ETH value to send (if token0 or token1 is NATIVE).
     */
    function addFullRangeLiquidity(address account, PoolId poolId_, uint256 amount0, uint256 amount1, uint256 value) internal {
        vm.stopPrank();
        vm.startPrank(account);

        PoolKey memory key_ = liquidityManager.poolKeys(poolId_);
        address tokenAddr0 = Currency.unwrap(key_.currency0);
        address tokenAddr1 = Currency.unwrap(key_.currency1);

        if (tokenAddr0 != address(0)) {
            IERC20Minimal(tokenAddr0).approve(address(fullRange), type(uint256).max);
        }
        if (tokenAddr1 != address(0)) {
            IERC20Minimal(tokenAddr1).approve(address(fullRange), type(uint256).max);
        }

        IMarginData.BatchAction[] memory actions = new IMarginData.BatchAction[](2);
        uint8 actionCount = 0;
        if (amount0 > 0) {
            actions[actionCount++] = createDepositAction(tokenAddr0, amount0);
        }
        if (amount1 > 0) {
             actions[actionCount++] = createDepositAction(tokenAddr1, amount1);
        }

        if (actionCount < 2) {
            assembly {
                mstore(actions, actionCount)
            }
        }

        fullRange.executeBatch{value: value}(PoolId.unwrap(poolId_), actions);

        vm.stopPrank();
    }

    /**
     * @notice Helper function to perform a swap through the swapRouter.
     * @param account The account performing the swap.
     * @param poolKey_ The key of the target pool.
     * @param zeroForOne Whether swapping currency0 for currency1.
     * @param amountSpecified The amount to swap (negative for exact output).
     * @param sqrtPriceLimitX96 The price limit for the swap.
     * @param value ETH value to send (if input currency is NATIVE).
     */
    function swap(
        address account,
        PoolKey memory poolKey_,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        uint256 value
    ) internal returns (BalanceDelta delta) {
        vm.stopPrank();
        vm.startPrank(account);

        address inputTokenAddr = zeroForOne ? Currency.unwrap(poolKey_.currency0) : Currency.unwrap(poolKey_.currency1);

        if (inputTokenAddr != address(0)) {
             IERC20Minimal(inputTokenAddr).approve(address(poolManager), type(uint256).max);
        }

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        delta = swapRouter.swap{value: value}(poolKey_, params, testSettings, "");
        vm.stopPrank();
    }

    /**
     * @notice Helper function to perform an exact input swap.
     * @param account The address performing the swap.
     * @param poolKey_ The key of the target pool.
     * @param zeroForOne Whether swapping currency0 for currency1.
     * @param amountIn The exact amount of input currency to swap.
     * @param value ETH value to send (if input currency is NATIVE).
     */
    function swapExactInput(address account, PoolKey memory poolKey_, bool zeroForOne, uint256 amountIn, uint256 value) internal returns (BalanceDelta) {
        uint160 sqrtPriceLimitX96 = zeroForOne ?
            TickMath.MIN_SQRT_PRICE + 1 :
            TickMath.MAX_SQRT_PRICE - 1;

        return swap(account, poolKey_, zeroForOne, int256(amountIn), sqrtPriceLimitX96, value);
    }

    /**
     * @notice Helper function to query the current tick and liquidity from a pool.
     * @param poolId_ The ID of the target pool.
     * @return currentTick The current tick value.
     * @return liquidity_ The current liquidity in the pool.
     */
    function queryCurrentTickAndLiquidity(PoolId poolId_) internal view returns (int24 currentTick, uint128 liquidity_) {
        (,currentTick,,) = StateLibrary.getSlot0(poolManager, poolId_);
        liquidity_ = StateLibrary.getLiquidity(poolManager, poolId_);
        return (currentTick, liquidity_);
    }

    // =========================================================================
    // Batch Action Helper Functions (Remain largely the same, ensure consistency)
    // =========================================================================

    function createDepositAction(address asset, uint256 amount) internal pure virtual returns (IMarginData.BatchAction memory) {
        return IMarginData.BatchAction({
            actionType: IMarginData.ActionType.DepositCollateral,
            asset: asset,
            amount: amount,
            recipient: address(0),
            flags: 0,
            data: ""
        });
    }

    function createWithdrawAction(address asset, uint256 amount, address recipient) internal pure returns (IMarginData.BatchAction memory) {
        return IMarginData.BatchAction({
            actionType: IMarginData.ActionType.WithdrawCollateral,
            asset: asset,
            amount: amount,
            recipient: recipient,
            flags: 0,
            data: ""
        });
    }

    function createBorrowAction(uint256 shares, address recipient) internal pure returns (IMarginData.BatchAction memory) {
        return IMarginData.BatchAction({
            actionType: IMarginData.ActionType.Borrow,
            asset: address(0),
            amount: shares,
            recipient: recipient,
            flags: 0,
            data: ""
        });
    }

    function createRepayAction(uint256 shares, bool useVaultBalance) internal pure returns (IMarginData.BatchAction memory) {
        return IMarginData.BatchAction({
            actionType: IMarginData.ActionType.Repay,
            asset: address(0),
            amount: shares,
            recipient: address(0),
            flags: useVaultBalance ? FLAG_USE_VAULT_BALANCE_FOR_REPAY : 0,
            data: ""
        });
    }

    function createSwapAction(
        Currency currencyIn,
        Currency currencyOut,
        uint256 amountIn,
        uint256 amountOutMin
    ) internal pure returns (IMarginData.BatchAction memory) {
         IMarginData.SwapRequest memory swapReq = IMarginData.SwapRequest({
            currencyIn: currencyIn,
            currencyOut: currencyOut,
            amountIn: amountIn,
            amountOutMin: amountOutMin
        });
        return IMarginData.BatchAction({
            actionType: IMarginData.ActionType.Swap,
            asset: address(0),
            amount: 0,
            recipient: address(0),
            flags: 0,
            data: abi.encode(swapReq)
        });
    }
} 