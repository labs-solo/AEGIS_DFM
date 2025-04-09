// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/Console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Spot} from "../src/Spot.sol";
import {Margin} from "../src/Margin.sol";
import {MarginManager} from "../src/MarginManager.sol";
import {FullRangeLiquidityManager} from "../src/FullRangeLiquidityManager.sol";
import {FullRangeDynamicFeeManager} from "../src/FullRangeDynamicFeeManager.sol";
import {PoolPolicyManager} from "../src/PoolPolicyManager.sol";
import {DefaultPoolCreationPolicy} from "../src/DefaultPoolCreationPolicy.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {DepositParams, WithdrawParams} from "../src/interfaces/ISpot.sol";
import {IMarginData} from "../src/interfaces/IMarginData.sol";
import {TruncGeoOracleMulti} from "../src/TruncGeoOracleMulti.sol";

/**
 * @title SimpleV4Test
 * @notice A simple test suite that verifies basic Uniswap V4 operations with our hook
 * @dev This file MUST be compiled with Solidity 0.8.26 to ensure hook address validation works correctly
 */
contract SimpleV4Test is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolManager poolManager;
    Margin fullRange;
    MarginManager marginManager;
    FullRangeLiquidityManager liquidityManager;
    FullRangeDynamicFeeManager dynamicFeeManager;
    PoolPolicyManager policyManager;
    PoolSwapTest swapRouter;
    TruncGeoOracleMulti public truncGeoOracle;

    // Test tokens
    MockERC20 token0;
    MockERC20 token1;
    PoolKey poolKey;
    PoolId poolId;

    address payable alice = payable(address(0x1));
    address payable bob = payable(address(0x2));
    address payable charlie = payable(address(0x3));
    address payable deployer = payable(address(0x4));
    address payable governance = payable(address(0x5));

    function setUp() public {
        // Deploy PoolManager
        poolManager = new PoolManager(address(this));

        // Deploy test tokens
        token0 = new MockERC20("Test Token 0", "TEST0", 18);
        token1 = new MockERC20("Test Token 1", "TEST1", 18);

        // Ensure token0 address is less than token1
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Deploy Oracle (BEFORE PolicyManager)
        vm.startPrank(deployer);
        truncGeoOracle = new TruncGeoOracleMulti(poolManager, governance);
        vm.stopPrank();

        // Deploy policy manager with configuration
        uint24[] memory supportedTickSpacings = new uint24[](3);
        supportedTickSpacings[0] = 10;
        supportedTickSpacings[1] = 60;
        supportedTickSpacings[2] = 200;

        policyManager = new PoolPolicyManager(
            governance,
            500000, // POL_SHARE_PPM (50%)
            300000, // FULLRANGE_SHARE_PPM (30%)
            200000, // LP_SHARE_PPM (20%)
            100,    // MIN_TRADING_FEE_PPM (0.01%)
            1000,   // FEE_CLAIM_THRESHOLD_PPM (0.1%)
            2,      // DEFAULT_POL_MULTIPLIER
            3000,   // DEFAULT_DYNAMIC_FEE_PPM (0.3%)
            4,      // tickScalingFactor
            supportedTickSpacings,
            1e17,    // _initialProtocolInterestFeePercentage (10%)
            address(0)      // _initialFeeCollector (zero address)
        );
        console2.log("[SETUP] PolicyManager Deployed.");

        // Deploy Liquidity Manager
        liquidityManager = new FullRangeLiquidityManager(poolManager, governance);

        // Deploy Spot hook using our improved method
        (fullRange, marginManager) = _deployFullRangeAndManager();
        
        // Deploy Dynamic Fee Manager AFTER Spot, passing its address
        dynamicFeeManager = new FullRangeDynamicFeeManager(
            governance,
            IPoolPolicy(address(policyManager)),
            poolManager,
            address(fullRange) // Pass the actual Spot address now
        );
        
        // Update managers with correct Spot address & set DFM in Spot
        vm.stopPrank();
        vm.startPrank(governance);
        liquidityManager.setFullRangeAddress(address(fullRange));
        fullRange.setDynamicFeeManager(dynamicFeeManager);
        fullRange.setOracleAddress(address(truncGeoOracle));
        truncGeoOracle.setFullRangeHook(address(fullRange));
        vm.stopPrank();
        vm.startPrank(deployer);

        // Deploy swap router
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        // Initialize pool key with the deployed hook address
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(fullRange)) // Use the deployed instance address
        });

        poolId = poolKey.toId();

        // Initialize pool with sqrt price of 1
        // This should now succeed as the hook is deployed and configured
        poolManager.initialize(poolKey, 79228162514264337593543950336);

        // Mint test tokens to users
        token0.mint(alice, 1e18);
        token1.mint(alice, 1e18);
        token0.mint(bob, 1e18);
        token1.mint(bob, 1e18);
    }
    
    /**
     * @notice Tests that a user can add liquidity to a Uniswap V4 pool through the Spot hook
     * @dev This test ensures the hook correctly handles liquidity provision and updates token balances
     */
    function test_addLiquidity() public {
        // ======================= ARRANGE =======================
        // Set a small liquidity amount that's less than Alice's token balance (she has 1e18)
        uint128 liquidityAmount = 1e17;
        
        // Record Alice's initial token balances for later comparison
        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceToken1Before = token1.balanceOf(alice);
        console2.log("Alice token0 balance before:", aliceToken0Before);
        console2.log("Alice token1 balance before:", aliceToken1Before);
        
        // Approve tokens for the LiquidityManager to transfer
        vm.startPrank(alice);
        token0.approve(address(liquidityManager), type(uint256).max);
        token1.approve(address(liquidityManager), type(uint256).max);
        
        // ======================= ACT =======================
        // Use executeBatch for deposit
        IMarginData.BatchAction[] memory depositActions = new IMarginData.BatchAction[](2);
        depositActions[0] = createDepositAction(address(token0), liquidityAmount);
        depositActions[1] = createDepositAction(address(token1), liquidityAmount);
        fullRange.executeBatch(depositActions);
        vm.stopPrank();
        
        // ======================= ASSERT =======================
        // Get vault state to verify deposit
        IMarginData.Vault memory vault = fullRange.getVault(poolId, alice);

        // Verify that Alice's tokens were transferred (approximation needed due to pool math)
        uint256 aliceToken0After = token0.balanceOf(alice);
        uint256 aliceToken1After = token1.balanceOf(alice);
        assertApproxEqAbs(aliceToken0Before - aliceToken0After, uint256(vault.token0Balance), 1, "Alice's token0 balance change mismatch");
        assertApproxEqAbs(aliceToken1Before - aliceToken1After, uint256(vault.token1Balance), 1, "Alice's token1 balance change mismatch");

        // Verify vault balances reflect deposit
        assertGt(vault.token0Balance, 0, "Alice should have token0 collateral");
        assertGt(vault.token1Balance, 0, "Alice should have token1 collateral");

        // Verify the pool has reserves (implicitly tested by vault balance check)
        (uint256 reserve0, uint256 reserve1, ) = fullRange.getPoolReservesAndShares(poolId);
        assertGt(reserve0, 0, "Pool reserves should increase for token0");
        assertGt(reserve1, 0, "Pool reserves should increase for token1");
    }
    
    /**
     * @notice Tests that a user can perform a token swap in a Uniswap V4 pool with the Spot hook
     * @dev This test verifies swap execution, token transfers, and balance updates after a swap
     */
    function test_swap() public {
        // ======================= ARRANGE =======================
        // First add liquidity to enable swapping - use amount less than Alice's balance (1e18)
        uint128 liquidityAmount = 1e17;
        
        // Approve tokens for the LiquidityManager and deposit
        vm.startPrank(alice);
        token0.approve(address(liquidityManager), type(uint256).max);
        token1.approve(address(liquidityManager), type(uint256).max);
        
        // Use executeBatch for deposit
        IMarginData.BatchAction[] memory depositActions = new IMarginData.BatchAction[](2);
        depositActions[0] = createDepositAction(address(token0), liquidityAmount);
        depositActions[1] = createDepositAction(address(token1), liquidityAmount);
        fullRange.executeBatch(depositActions);
        vm.stopPrank();
        
        // Approve tokens for Bob (the swapper)
        vm.startPrank(bob);
        token0.approve(address(poolManager), type(uint256).max);
        token1.approve(address(poolManager), type(uint256).max);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        
        // Record Bob's initial token balances
        uint256 bobToken0Before = token0.balanceOf(bob);
        uint256 bobToken1Before = token1.balanceOf(bob);
        console2.log("Bob token0 balance before swap:", bobToken0Before);
        console2.log("Bob token1 balance before swap:", bobToken1Before);
        
        // ======================= ACT =======================
        // Perform swap: token0 -> token1 - amount smaller than available liquidity
        uint256 swapAmount = 1e16;
        
        vm.startPrank(bob);
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        swapRouter.swap(poolKey, swapParams, testSettings, "");
        vm.stopPrank();
        
        // ======================= ASSERT =======================
        // Record Bob's token balances after the swap
        uint256 bobToken0After = token0.balanceOf(bob);
        uint256 bobToken1After = token1.balanceOf(bob);
        console2.log("Bob token0 balance after swap:", bobToken0After);
        console2.log("Bob token1 balance after swap:", bobToken1After);
        
        // Verify the swap executed correctly
        assertTrue(bobToken0Before > bobToken0After, "Bob should have spent some token0");
        assertTrue(bobToken1After > bobToken1Before, "Bob should have received some token1");
        assertEq(bobToken1After - bobToken1Before, swapAmount, "Bob should have received exactly the swap amount of token1");
    }

    function _deployFullRangeAndManager() internal virtual returns (Margin marginContract, MarginManager managerContract) {
        // Calculate required hook flags (Inherited from Spot)
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        // Deploy MarginManager first using the *calculated* hook address
        // (We need to calculate the hook address first)

        // Need final Margin constructor args to calculate the hash for HookMiner
        // To get final args, we need the final manager address
        // To get final manager address, we need the hook address
        // => Circular dependency. Solution: Predict manager address or use updatable manager.

        // Let's use the predict & deploy pattern:

        // 1. Predict Hook Address (requires final args, including final manager address)
        //    To predict manager address, we need hook address...
        // Revert to: Calculate hook -> Deploy Manager -> Deploy Hook pattern

        address deployerAddr = address(this); // Deployer in this context

        // Args for MarginManager (needs hook address)
        uint256 initialSolvencyThreshold = 98e16; // 98%
        uint256 initialLiquidationFee = 1e16; // 1%

        // Args for Margin (needs manager address)
        bytes memory constructorArgsManagerPlaceholder = abi.encode(address(0)); // Placeholder for manager address
        bytes memory marginCreationCodeWithPlaceholder = abi.encodePacked(
            type(Margin).creationCode,
            abi.encode(address(poolManager), IPoolPolicy(address(policyManager)), address(liquidityManager), address(0)) // Placeholder manager
        );

        // Predict hook address assuming a placeholder manager address for hash calculation
        (address predictedHookAddress, ) = HookMiner.find(
            deployerAddr,
            flags,
            marginCreationCodeWithPlaceholder,
            bytes("")
        );
        console2.log("[SimpleV4] Predicted Hook Addr (using placeholder manager):", predictedHookAddress);

        // Deploy MarginManager using the predicted hook address
        MarginManager managerInstance = new MarginManager(
            predictedHookAddress,
            address(poolManager),
            address(liquidityManager),
            governance,
            initialSolvencyThreshold,
            initialLiquidationFee
        );
        console2.log("[SimpleV4] Deployed MarginManager Addr:", address(managerInstance));

        // Prepare FINAL Margin constructor arguments
        bytes memory finalConstructorArgsMargin = abi.encode(
            address(poolManager),
            IPoolPolicy(address(policyManager)),
            address(liquidityManager),
            address(managerInstance) // Use the REAL manager address
        );

        // Recalculate salt based on FINAL args
        (address finalHookAddress, bytes32 finalSalt) = HookMiner.find(
            deployerAddr,
            flags,
            abi.encodePacked(type(Margin).creationCode, finalConstructorArgsMargin), // Use FINAL args
            bytes("")
        );
        console2.log("[SimpleV4] Recalculated Final Hook Addr:", finalHookAddress);

        // Deploy Margin using the final salt and final manager address
        Margin hookContract = new Margin{salt: finalSalt}(
            poolManager,
            IPoolPolicy(address(policyManager)),
            liquidityManager,
            address(managerInstance) // Use the REAL manager address
        );

        require(address(hookContract) == finalHookAddress, "HookMiner address mismatch after manager deploy");
        console2.log("Deployed hook address:", address(hookContract));

        marginContract = hookContract;
        managerContract = managerInstance;
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
            recipient: recipient, // Use provided recipient
            flags: 0,
            data: ""
        });
    }

    function createBorrowAction(uint256 shares, address recipient) internal pure returns (IMarginData.BatchAction memory) {
        return IMarginData.BatchAction({
            actionType: IMarginData.ActionType.Borrow,
            asset: address(0), // Not used for borrow
            amount: shares,
            recipient: recipient, // Use provided recipient
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
} 