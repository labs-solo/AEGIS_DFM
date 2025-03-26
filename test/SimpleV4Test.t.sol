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

import {FullRange} from "../src/FullRange.sol";
import {FullRangeLiquidityManager} from "../src/FullRangeLiquidityManager.sol";
import {FullRangeDynamicFeeManager} from "../src/FullRangeDynamicFeeManager.sol";
import {PoolPolicyManager} from "../src/PoolPolicyManager.sol";
import {DefaultCAPEventDetector} from "../src/DefaultCAPEventDetector.sol";
import {ICAPEventDetector} from "../src/interfaces/ICAPEventDetector.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {DepositParams, WithdrawParams} from "../src/interfaces/IFullRange.sol";

/**
 * @title SimpleV4Test
 * @notice A simple test suite that verifies basic Uniswap V4 operations with our hook
 * @dev This file MUST be compiled with Solidity 0.8.26 to ensure hook address validation works correctly
 */
contract SimpleV4Test is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolManager poolManager;
    FullRange fullRange;
    FullRangeLiquidityManager liquidityManager;
    FullRangeDynamicFeeManager dynamicFeeManager;
    PoolPolicyManager policyManager;
    DefaultCAPEventDetector capEventDetector;
    PoolSwapTest swapRouter;

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
            10,     // TICK_SCALING_FACTOR
            supportedTickSpacings
        );

        // Deploy CAP Event Detector
        capEventDetector = new DefaultCAPEventDetector(poolManager, governance);

        // Deploy Liquidity Manager
        liquidityManager = new FullRangeLiquidityManager(poolManager, governance);

        // We need to create a temporary address for FullRange since the constructor requires a non-zero address
        address tempFullRangeAddress = address(1);
        
        // Deploy Dynamic Fee Manager with temporary FullRange address
        dynamicFeeManager = new FullRangeDynamicFeeManager(
            governance,
            IPoolPolicy(address(policyManager)),
            poolManager,
            tempFullRangeAddress, // temporary address - will be updated after FullRange deployment
            ICAPEventDetector(address(capEventDetector))
        );

        // Calculate required hook flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | 
            Hooks.AFTER_INITIALIZE_FLAG | 
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | 
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_SWAP_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        // Prepare constructor arguments
        bytes memory constructorArgs = abi.encode(
            address(poolManager),
            IPoolPolicy(address(policyManager)),
            address(liquidityManager),
            address(dynamicFeeManager)
        );

        // Mine for a hook address with the correct permission bits
        (address hookAddress, bytes32 salt) = HookMiner.find(
            governance,
            flags,
            type(FullRange).creationCode,
            constructorArgs
        );

        console2.log("Mined hook address:", hookAddress);
        console2.log("Permission bits in address:", uint160(hookAddress) & Hooks.ALL_HOOK_MASK);

        // Deploy from governance account
        vm.startPrank(governance);

        // Deploy the hook with the mined salt
        fullRange = new FullRange{salt: salt}(
            poolManager,
            IPoolPolicy(address(policyManager)),
            liquidityManager,
            dynamicFeeManager
        );

        // Verify the deployment
        require(address(fullRange) == hookAddress, "Hook address mismatch");
        require((uint160(address(fullRange)) & Hooks.ALL_HOOK_MASK) == flags, "Hook permission bits mismatch");

        // Update managers with correct FullRange address
        liquidityManager.setFullRangeAddress(address(fullRange));
        
        // Redeploy the dynamic fee manager with the correct FullRange address
        dynamicFeeManager = new FullRangeDynamicFeeManager(
            governance,
            IPoolPolicy(address(policyManager)),
            poolManager,
            address(fullRange),  // Now using the actual FullRange address
            ICAPEventDetector(address(capEventDetector))
        );

        vm.stopPrank();

        // Deploy swap router
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        // Initialize pool
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(fullRange))
        });

        poolId = poolKey.toId();

        // Initialize pool with sqrt price of 1
        poolManager.initialize(poolKey, 79228162514264337593543950336);

        // Mint test tokens to users
        token0.mint(alice, 1e18);
        token1.mint(alice, 1e18);
        token0.mint(bob, 1e18);
        token1.mint(bob, 1e18);
    }
    
    /**
     * @notice Tests that a user can add liquidity to a Uniswap V4 pool through the FullRange hook
     * @dev This test ensures the hook correctly handles liquidity provision and updates token balances
     */
    function test_addLiquidity() public {
        // ======================= ARRANGE =======================
        // Set a small liquidity amount to avoid arithmetic overflow in token transfers
        uint128 liquidityAmount = 1e9;
        
        // Record Alice's initial token balances for later comparison
        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 aliceToken1Before = token1.balanceOf(alice);
        console2.log("Alice token0 balance before:", aliceToken0Before);
        console2.log("Alice token1 balance before:", aliceToken1Before);
        
        // Approve tokens for the FullRange hook to transfer
        vm.startPrank(alice);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        
        // ======================= ACT =======================
        // Use the proper deposit flow to add liquidity
        DepositParams memory params = DepositParams({
            poolId: poolId,
            amount0Desired: liquidityAmount,
            amount1Desired: liquidityAmount,
            minShares: 0,  // No slippage protection for this test
            deadline: block.timestamp + 1 hours
        });
        
        // Call deposit which will pull tokens and add liquidity
        (uint256 shares, uint256 amount0, uint256 amount1) = fullRange.deposit(params);
        vm.stopPrank();
        
        console2.log("Deposit successful - shares:", shares);
        console2.log("Amount0 used:", amount0);
        console2.log("Amount1 used:", amount1);
        
        // ======================= ASSERT =======================
        // Record Alice's token balances after adding liquidity
        uint256 aliceToken0After = token0.balanceOf(alice);
        uint256 aliceToken1After = token1.balanceOf(alice);
        console2.log("Alice token0 balance after:", aliceToken0After);
        console2.log("Alice token1 balance after:", aliceToken1After);
        
        // Verify that Alice's tokens were transferred
        assertEq(aliceToken0Before - aliceToken0After, amount0, "Alice's token0 balance should decrease by the exact deposit amount");
        assertEq(aliceToken1Before - aliceToken1After, amount1, "Alice's token1 balance should decrease by the exact deposit amount");
        
        // Verify shares were created
        assertGt(shares, 0, "Alice should have received shares");
        
        // Verify the hook has reserves
        (uint256 reserve0, uint256 reserve1, ) = fullRange.getPoolReservesAndShares(poolId);
        assertEq(reserve0, amount0, "Hook reserves should match deposit amount for token0");
        assertEq(reserve1, amount1, "Hook reserves should match deposit amount for token1");
    }
    
    /**
     * @notice Tests that a user can perform a token swap in a Uniswap V4 pool with the FullRange hook
     * @dev This test verifies swap execution, token transfers, and balance updates after a swap
     */
    function test_swap() public {
        // ======================= ARRANGE =======================
        // First add liquidity to enable swapping
        uint128 liquidityAmount = 1e9;
        
        // Approve tokens for the FullRange hook and deposit
        vm.startPrank(alice);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        
        // Use proper deposit flow
        DepositParams memory params = DepositParams({
            poolId: poolId,
            amount0Desired: liquidityAmount,
            amount1Desired: liquidityAmount,
            minShares: 0,  // No slippage protection for this test
            deadline: block.timestamp + 1 hours
        });
        
        // Deposit tokens to add liquidity
        (uint256 shares, , ) = fullRange.deposit(params);
        console2.log("Liquidity added, shares minted:", shares);
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
        // Perform swap: token0 -> token1
        uint256 swapAmount = 1e8;
        
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
} 