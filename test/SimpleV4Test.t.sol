// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {MarginTestBase} from "./MarginTestBase.t.sol"; // Import the refactored base
import {console2} from "forge-std/Console2.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol"; // Already in base, maybe remove?

import {Margin} from "../src/Margin.sol"; // Already in base
import {MarginManager} from "../src/MarginManager.sol"; // Already in base
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol"; // Already in base
import {DepositParams, WithdrawParams} from "../src/interfaces/ISpot.sol"; // Already in base
import {IMarginData} from "../src/interfaces/IMarginData.sol"; // Already in base
import {Errors} from "../src/errors/Errors.sol"; // Already in base
import {TruncGeoOracleMulti} from "../src/TruncGeoOracleMulti.sol"; // Already in base

/**
 * @title SimpleV4Test (Refactored)
 * @notice Basic tests for pool interactions using the shared Margin hook setup.
 * @dev Inherits shared contracts from MarginTestBase. Focuses on swap and basic Spot interactions.
 */
contract SimpleV4Test is MarginTestBase { // Inherit from MarginTestBase
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // Constants - FLAG_USE_VAULT_BALANCE_FOR_REPAY already in base
    // uint256 constant FLAG_USE_VAULT_BALANCE_FOR_REPAY = 1;

    // Contract instances inherited from MarginTestBase:
    // poolManager, fullRange (Margin), marginManager, liquidityManager,
    // dynamicFeeManager, policyManager, swapRouter, truncGeoOracle,
    // token0, token1, token2, interestRateModel

    // Pool state variables (inherited poolKey/poolId removed from base)
    PoolKey poolKeyA;
    PoolId poolIdA;
    PoolKey poolKeyB;
    PoolId poolIdB;
    // Additional tokens (tokenC) can be deployed if needed

    // Test accounts inherited: alice, bob, charlie, deployer, governance

    function setUp() public override {
        // Call base setup first (deploys shared contracts)
        MarginTestBase.setUp();

        // --- Initialize Pools for Simple Tests --- (Example: T0/T1)
        uint160 initialSqrtPrice = uint160(1 << 96); // Price = 1
        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));

        console2.log("[SimpleV4Test.setUp] Creating Pool A (T0/T1)...");
        vm.startPrank(deployer); // Use deployer or authorized address
        (poolIdA, poolKeyA) = createPoolAndRegister(
            address(fullRange), address(liquidityManager),
            currency0, currency1, DEFAULT_FEE, DEFAULT_TICK_SPACING, initialSqrtPrice
        );
        vm.stopPrank();
        // console2.log("[SimpleV4Test.setUp] Pool A created, ID:", PoolId.unwrap(poolIdA));

        // Add initial liquidity to Pool A for swaps (using base helper)
        uint128 initialLiquidityA = 100 * 1e18;
        addFullRangeLiquidity(alice, poolIdA, initialLiquidityA, initialLiquidityA, 0);
        console2.log("[SimpleV4Test.setUp] Initial liquidity added to Pool A.");

        // Setup for Pool B if needed for isolation tests
        MockERC20 tokenC = new MockERC20("TokenC", "TKNC", 18);
        tokenC.mint(alice, INITIAL_TOKEN_BALANCE);
        tokenC.mint(bob, INITIAL_TOKEN_BALANCE);
        Currency currencyC = Currency.wrap(address(tokenC));

        console2.log("[SimpleV4Test.setUp] Creating Pool B (T1/TC)...");
        vm.startPrank(deployer);
        (poolIdB, poolKeyB) = createPoolAndRegister(
            address(fullRange), address(liquidityManager),
            currency1, currencyC, DEFAULT_FEE, DEFAULT_TICK_SPACING, initialSqrtPrice
        );
        vm.stopPrank();
        // console2.log("[SimpleV4Test.setUp] Pool B created, ID:", PoolId.unwrap(poolIdB));

        console2.log("[SimpleV4Test.setUp] Completed.");
    }

    /**
     * @notice Tests that a user can perform a basic token swap (T0->T1) in Pool A.
     */
    function test_Swap_PoolA() public {
        // Target Pool A for this test
        PoolId targetPoolId = poolIdA;
        PoolKey memory targetKey = poolKeyA;

        // --- ARRANGE --- //
        // Bob will swap
        address swapper = bob;
        uint256 swapAmount = 1e16; // Amount of token0 to swap

        // Approve tokens for Bob
        vm.startPrank(swapper);
        token0.approve(address(poolManager), type(uint256).max); // Approve PM for swap
        // token1 approval not needed for 0->1 swap input
        vm.stopPrank();

        // Record Bob's initial balances
        uint256 bobToken0Before = token0.balanceOf(swapper);
        uint256 bobToken1Before = token1.balanceOf(swapper);
        console2.log("Bob T0 Before:", bobToken0Before); console2.log("Bob T1 Before:", bobToken1Before);

        // --- ACT --- //
        // Perform swap: T0 -> T1 using the base helper
        BalanceDelta delta = swapExactInput(swapper, targetKey, true, swapAmount, 0);

        // --- ASSERT --- //
        // Record Bob's final balances
        uint256 bobToken0After = token0.balanceOf(swapper);
        uint256 bobToken1After = token1.balanceOf(swapper);
        console2.log("Bob T0 After:", bobToken0After); console2.log("Bob T1 After:", bobToken1After);

        // Verify the swap occurred
        assertEq(bobToken0Before - bobToken0After, swapAmount, "Bob did not spend correct T0");
        assertTrue(bobToken1After > bobToken1Before, "Bob should have received T1");

        // Verify delta matches balance changes
        // console2.log("[test_swap_uniV4Only] Swapped:", delta.amount0(), delta.amount1());
        int128 absAmount0 = delta.amount0() < 0 ? -delta.amount0() : delta.amount0();
        int128 absAmount1 = delta.amount1() < 0 ? -delta.amount1() : delta.amount1();
        assertTrue(uint128(absAmount0) == swapAmount, "Delta T0 mismatch");
        assertTrue(absAmount1 > 0, "Delta T1 should be positive");
    }

    /**
     * @notice Tests basic vault deposit via executeBatch (Spot-like behavior).
     */
    function test_DepositCollateral_PoolA() public {
        PoolId targetPoolId = poolIdA;
        address depositor = charlie;
        uint256 depositAmount = 50 * 1e18;

        // --- ARRANGE --- //
        IMarginData.Vault memory vaultBefore = fullRange.getVault(targetPoolId, depositor);
        uint256 token0BalanceBefore = token0.balanceOf(depositor);
        uint256 token1BalanceBefore = token1.balanceOf(depositor);

        // Approve Margin contract
        vm.startPrank(depositor);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);

        // --- ACT --- //
        IMarginData.BatchAction[] memory actions = new IMarginData.BatchAction[](2);
        actions[0] = createDepositAction(address(token0), depositAmount);
        actions[1] = createDepositAction(address(token1), depositAmount);
        fullRange.executeBatch(PoolId.unwrap(targetPoolId), actions);
        vm.stopPrank();

        // --- ASSERT --- //
        IMarginData.Vault memory vaultAfter = fullRange.getVault(targetPoolId, depositor);
        uint256 token0BalanceAfter = token0.balanceOf(depositor);
        uint256 token1BalanceAfter = token1.balanceOf(depositor);

        // Vault balances increased
        assertTrue(vaultAfter.token0Balance > vaultBefore.token0Balance, "Vault T0 did not increase");
        assertTrue(vaultAfter.token1Balance > vaultBefore.token1Balance, "Vault T1 did not increase");
        assertApproxEqAbs(vaultAfter.token0Balance - vaultBefore.token0Balance, depositAmount, 1, "Vault T0 increase mismatch");
        assertApproxEqAbs(vaultAfter.token1Balance - vaultBefore.token1Balance, depositAmount, 1, "Vault T1 increase mismatch");
        assertEq(vaultAfter.debtShares, vaultBefore.debtShares, "Debt should not change");

        // Depositor balances decreased
        assertEq(token0BalanceBefore - token0BalanceAfter, vaultAfter.token0Balance - vaultBefore.token0Balance, "Depositor T0 decrease mismatch");
        assertEq(token1BalanceBefore - token1BalanceAfter, vaultAfter.token1Balance - vaultBefore.token1Balance, "Depositor T1 decrease mismatch");
    }

    // =========================================================================
    // ISOLATION TESTS (Spot focused)
    // =========================================================================

    function test_Deposit_Isolation() public {
        address depositor = charlie;
        uint256 depositAmount = 50 * 1e18;

        // Get initial states for both pools
        IMarginData.Vault memory vaultA_before = fullRange.getVault(poolIdA, depositor);
        IMarginData.Vault memory vaultB_before = fullRange.getVault(poolIdB, depositor);
        (uint256 reservesA0_before, uint256 reservesA1_before,) = fullRange.getPoolReservesAndShares(poolIdA);
        (uint256 reservesB0_before, uint256 reservesB1_before,) = fullRange.getPoolReservesAndShares(poolIdB);

        // Deposit into Pool A
        vm.startPrank(depositor);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory actionsA = new IMarginData.BatchAction[](1);
        actionsA[0] = createDepositAction(address(token0), depositAmount); // Deposit only T0 for simplicity
        fullRange.executeBatch(PoolId.unwrap(poolIdA), actionsA);
        vm.stopPrank();

        // Get final states
        IMarginData.Vault memory vaultA_after = fullRange.getVault(poolIdA, depositor);
        IMarginData.Vault memory vaultB_after = fullRange.getVault(poolIdB, depositor);
        (uint256 reservesA0_after, uint256 reservesA1_after,) = fullRange.getPoolReservesAndShares(poolIdA);
        (uint256 reservesB0_after, uint256 reservesB1_after,) = fullRange.getPoolReservesAndShares(poolIdB);

        // Assert: Pool A state changed
        assertTrue(vaultA_after.token0Balance > vaultA_before.token0Balance, "VaultA T0 should increase");
        assertTrue(reservesA0_after > reservesA0_before, "ReservesA T0 should increase");
        assertEq(vaultA_after.token1Balance, vaultA_before.token1Balance, "VaultA T1 unchanged");
        assertEq(reservesA1_after, reservesA1_before, "ReservesA T1 unchanged");

        // Assert: Pool B state unchanged
        assertEq(vaultB_after.token0Balance, vaultB_before.token0Balance, "VaultB T0 unchanged");
        assertEq(vaultB_after.token1Balance, vaultB_before.token1Balance, "VaultB T1 unchanged");
        assertEq(reservesB0_after, reservesB0_before, "ReservesB T0 unchanged");
        assertEq(reservesB1_after, reservesB1_before, "ReservesB T1 unchanged");
    }

    function test_Withdraw_Isolation() public {
        address user = alice; // Alice deposited initial liquidity
        uint256 withdrawAmount = 10 * 1e18;

        // Get initial states for both pools
        IMarginData.Vault memory vaultA_before = fullRange.getVault(poolIdA, user);
        IMarginData.Vault memory vaultB_before = fullRange.getVault(poolIdB, user);
        (uint256 reservesA0_before, uint256 reservesA1_before,) = fullRange.getPoolReservesAndShares(poolIdA);
        (uint256 reservesB0_before, uint256 reservesB1_before,) = fullRange.getPoolReservesAndShares(poolIdB);

        // Ensure Alice has something to withdraw from A
        assertTrue(vaultA_before.token0Balance > withdrawAmount, "Insufficient T0 in Vault A to withdraw");

        // Withdraw from Pool A
        vm.startPrank(user);
        IMarginData.BatchAction[] memory actionsA = new IMarginData.BatchAction[](1);
        actionsA[0] = createWithdrawAction(address(token0), withdrawAmount, user); // Withdraw T0
        fullRange.executeBatch(PoolId.unwrap(poolIdA), actionsA);
        vm.stopPrank();

        // Get final states
        IMarginData.Vault memory vaultA_after = fullRange.getVault(poolIdA, user);
        IMarginData.Vault memory vaultB_after = fullRange.getVault(poolIdB, user);
        (uint256 reservesA0_after, uint256 reservesA1_after,) = fullRange.getPoolReservesAndShares(poolIdA);
        (uint256 reservesB0_after, uint256 reservesB1_after,) = fullRange.getPoolReservesAndShares(poolIdB);

        // Assert: Pool A state changed
        assertTrue(vaultA_after.token0Balance < vaultA_before.token0Balance, "VaultA T0 should decrease");
        assertTrue(reservesA0_after < reservesA0_before, "ReservesA T0 should decrease");
        assertEq(vaultA_after.token1Balance, vaultA_before.token1Balance, "VaultA T1 unchanged");
        assertEq(reservesA1_after, reservesA1_before, "ReservesA T1 unchanged");

        // Assert: Pool B state unchanged
        assertEq(vaultB_after.token0Balance, vaultB_before.token0Balance, "VaultB T0 unchanged");
        assertEq(vaultB_after.token1Balance, vaultB_before.token1Balance, "VaultB T1 unchanged");
        assertEq(reservesB0_after, reservesB0_before, "ReservesB T0 unchanged");
        assertEq(reservesB1_after, reservesB1_before, "ReservesB T1 unchanged");
    }

    function test_EmergencyState_Isolation() public {
        // Check initial emergency state for Pool A and B
        (bool isInitializedA, , , ) = fullRange.getPoolInfo(poolIdA);
        (bool isInitializedB, , , ) = fullRange.getPoolInfo(poolIdB);
        assertTrue(isInitializedA, "Pool A should be initialized");
        assertTrue(isInitializedB, "Pool B should be initialized");

        // Set emergency state for Pool A only
        vm.startPrank(governance);
        fullRange.setPoolEmergencyState(poolIdA, true);
        vm.stopPrank();

        // Try deposit to Pool A (should revert due to emergency)
        vm.startPrank(alice);
        IMarginData.BatchAction[] memory actionsFail = new IMarginData.BatchAction[](1);
        actionsFail[0] = createDepositAction(address(token0), 1e18);
        vm.expectRevert(abi.encodeWithSelector(Errors.PoolInEmergencyState.selector, PoolId.unwrap(poolIdA)));
        fullRange.executeBatch(PoolId.unwrap(poolIdA), actionsFail);
        vm.stopPrank();

        // Try depositing into Pool B (expect success)
        vm.startPrank(charlie);
        token1.approve(address(fullRange), 1e18);
        address tokenCAddr = Currency.unwrap(poolKeyB.currency1);
        MockERC20(tokenCAddr).approve(address(fullRange), 1e18);
        IMarginData.BatchAction[] memory actionsSuccess = new IMarginData.BatchAction[](1);
        actionsSuccess[0] = createDepositAction(address(token1), 1e18); // Deposit T1 into Pool B
        // No revert expected
        fullRange.executeBatch(PoolId.unwrap(poolIdB), actionsSuccess);
        vm.stopPrank();

        // Verify Pool B vault updated
        IMarginData.Vault memory vaultB = fullRange.getVault(poolIdB, charlie);
        assertTrue(vaultB.token0Balance > 0, "Pool B vault T0(T1) should have increased");
    }

    function test_Oracle_Isolation() public {
        // Check initial oracle state
        (int24 tickA_before, uint32 blockA_before) = fullRange.getOracleData(poolIdA);
        (int24 tickB_before, uint32 blockB_before) = fullRange.getOracleData(poolIdB);
        
        // Swap in Pool A to update oracle
        vm.startPrank(alice);
        token0.approve(address(poolManager), type(uint256).max);
        swapExactInput(alice, poolKeyA, true, 1e18, 0);  // Swap T0->T1
        vm.stopPrank();
        
        // Check oracle state after swap
        (int24 tickA_after, uint32 blockA_after) = fullRange.getOracleData(poolIdA);
        (int24 tickB_after, uint32 blockB_after) = fullRange.getOracleData(poolIdB);
        
        // Assert: Pool A oracle updated, Pool B oracle unchanged
        assertTrue(tickA_after != tickA_before, "Pool A tick should change");
        assertEq(tickB_after, tickB_before, "Pool B tick should not change");
        assertTrue(blockA_after >= blockA_before, "Pool A block number should increase");
        // console2.log("Oracle A Tick Before/After:", tickA_before, tickA_after);
        // console2.log("Oracle B Tick Before/After:", tickB_before, tickB_after);
    }

    // =========================================================================
    // ISOLATION TESTS (Liquidity Manager focused)
    // =========================================================================

    function test_LM_Deposit_Isolation() public {
        address user = charlie;
        uint256 depositAmount = 30 * 1e18;

        // Get initial LM state
        uint128 totalSharesA_before = liquidityManager.poolTotalShares(poolIdA);
        uint128 totalSharesB_before = liquidityManager.poolTotalShares(poolIdB);
        uint256 tokenIdA = fullRange.getPoolTokenId(poolIdA);
        uint256 tokenIdB = fullRange.getPoolTokenId(poolIdB);
        uint256 balanceA_before = liquidityManager.positions().balanceOf(user, tokenIdA);
        uint256 balanceB_before = liquidityManager.positions().balanceOf(user, tokenIdB);

        // Deposit into Pool A (via hook)
        // Use the base helper `addFullRangeLiquidity` which calls executeBatch
        addFullRangeLiquidity(user, poolIdA, depositAmount, depositAmount, 0);

        // Get final LM state
        uint128 totalSharesA_after = liquidityManager.poolTotalShares(poolIdA);
        uint128 totalSharesB_after = liquidityManager.poolTotalShares(poolIdB);
        uint256 balanceA_after = liquidityManager.positions().balanceOf(user, tokenIdA);
        uint256 balanceB_after = liquidityManager.positions().balanceOf(user, tokenIdB);

        // Assert: LM state for Pool A changed
        assertTrue(totalSharesA_after > totalSharesA_before, "LM totalSharesA should increase");
        assertTrue(balanceA_after > balanceA_before, "LM balanceA should increase");

        // Assert: LM state for Pool B unchanged
        assertEq(totalSharesB_after, totalSharesB_before, "LM totalSharesB should be unchanged");
        assertEq(balanceB_after, balanceB_before, "LM balanceB should be unchanged");
    }

    function test_LM_Withdraw_Isolation() public {
        address user = alice; // Alice has initial liquidity
        uint256 withdrawAmountShares = 10 * 1e18; // Withdraw based on shares

        // Get initial LM state for Alice
        uint128 totalSharesA_before = liquidityManager.poolTotalShares(poolIdA);
        uint128 totalSharesB_before = liquidityManager.poolTotalShares(poolIdB);
        uint256 tokenIdA = fullRange.getPoolTokenId(poolIdA);
        uint256 tokenIdB = fullRange.getPoolTokenId(poolIdB);
        uint256 balanceA_before = liquidityManager.positions().balanceOf(user, tokenIdA);
        uint256 balanceB_before = liquidityManager.positions().balanceOf(user, tokenIdB);

        assertTrue(balanceA_before >= withdrawAmountShares, "Insufficient shares A to withdraw");

        // Withdraw from Pool A (need equivalent token amounts, tricky)
        // For simplicity, let's deposit to B first, then withdraw A
        addFullRangeLiquidity(user, poolIdB, 50e18, 50e18, 0);
        uint128 totalSharesB_mid = liquidityManager.poolTotalShares(poolIdB);
        uint256 balanceB_mid = liquidityManager.positions().balanceOf(user, tokenIdB);
        assertTrue(totalSharesB_mid > totalSharesB_before, "Pool B shares did not increase after deposit");
        assertTrue(balanceB_mid > balanceB_before, "Pool B balance did not increase after deposit");

        // Withdraw shares from Pool A via executeBatch
        vm.startPrank(user);
        IMarginData.BatchAction[] memory actionsA = new IMarginData.BatchAction[](1);
        // We need to withdraw based on *shares* using Vault balance if possible, or provide tokens
        // Using WithdrawCollateral withdraws tokens, not shares directly. Let's withdraw tokens.
        // Calculate rough token amount for shares (this is approximate!)
        uint256 approxTokenAmount = withdrawAmountShares; // Simplification: assume 1 share ~ 1 token
        actionsA[0] = createWithdrawAction(address(token0), approxTokenAmount, user);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), actionsA);
        vm.stopPrank();

        // Get final LM state
        uint128 totalSharesA_after = liquidityManager.poolTotalShares(poolIdA);
        uint128 totalSharesB_after = liquidityManager.poolTotalShares(poolIdB);
        uint256 balanceA_after = liquidityManager.positions().balanceOf(user, tokenIdA);
        uint256 balanceB_after = liquidityManager.positions().balanceOf(user, tokenIdB);

        // Assert: LM state for Pool A changed (shares decreased)
        assertTrue(totalSharesA_after < totalSharesA_before, "LM totalSharesA should decrease");
        assertTrue(balanceA_after < balanceA_before, "LM balanceA should decrease");

        // Assert: LM state for Pool B unchanged from its mid-state
        assertEq(totalSharesB_after, totalSharesB_mid, "LM totalSharesB should be unchanged after A withdraw");
        assertEq(balanceB_after, balanceB_mid, "LM balanceB should be unchanged after A withdraw");
    }

    function test_LM_Borrow_Isolation() public {
        address user = charlie;
        uint256 depositAmount = 100 * 1e18;
        uint256 borrowShares = 10 * 1e18;

        // Deposit into Pool A and B first
        addFullRangeLiquidity(user, poolIdA, depositAmount, depositAmount, 0);
        addFullRangeLiquidity(user, poolIdB, depositAmount, depositAmount, 0); // Pool B uses T1/TC

        // Get initial LM state (Reserves and Total Shares)
        (uint256 reservesA0_before, uint256 reservesA1_before) = liquidityManager.getPoolReserves(poolIdA);
        (uint256 reservesB0_before, uint256 reservesB1_before) = liquidityManager.getPoolReserves(poolIdB);
        uint128 totalSharesA_before = liquidityManager.poolTotalShares(poolIdA);
        uint128 totalSharesB_before = liquidityManager.poolTotalShares(poolIdB);

        // Borrow shares from Pool A via executeBatch
        vm.startPrank(user);
        IMarginData.BatchAction[] memory actionsA = new IMarginData.BatchAction[](1);
        actionsA[0] = createBorrowAction(borrowShares, user);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), actionsA);
        vm.stopPrank();

        // Get final LM state
        (uint256 reservesA0_after, uint256 reservesA1_after) = liquidityManager.getPoolReserves(poolIdA);
        (uint256 reservesB0_after, uint256 reservesB1_after) = liquidityManager.getPoolReserves(poolIdB);
        uint128 totalSharesA_after = liquidityManager.poolTotalShares(poolIdA);
        uint128 totalSharesB_after = liquidityManager.poolTotalShares(poolIdB);

        // Assert: LM Pool A reserves decreased (tokens were removed)
        assertTrue(reservesA0_after < reservesA0_before, "LM reservesA0 should decrease");
        assertTrue(reservesA1_after < reservesA1_before, "LM reservesA1 should decrease");
        // Assert: LM Pool A Total Shares *unchanged* by borrow itself (rented liquidity increased in MM)
        assertEq(totalSharesA_after, totalSharesA_before, "LM totalSharesA should be unchanged by borrow");

        // Assert: LM Pool B state unchanged
        assertEq(reservesB0_after, reservesB0_before, "LM reservesB0 should be unchanged");
        assertEq(reservesB1_after, reservesB1_before, "LM reservesB1 should be unchanged");
        assertEq(totalSharesB_after, totalSharesB_before, "LM totalSharesB should be unchanged");
    }

    function test_LM_TotalShares_Isolation() public {
        address user = charlie;
        uint256 amount = 30 * 1e18;

        // Initial State
        uint128 totalSharesA_0 = liquidityManager.poolTotalShares(poolIdA);
        uint128 totalSharesB_0 = liquidityManager.poolTotalShares(poolIdB);

        // 1. Deposit Pool A
        addFullRangeLiquidity(user, poolIdA, amount, amount, 0);
        uint128 totalSharesA_1 = liquidityManager.poolTotalShares(poolIdA);
        uint128 totalSharesB_1 = liquidityManager.poolTotalShares(poolIdB);
        assertTrue(totalSharesA_1 > totalSharesA_0, "A shares should increase after deposit A");
        assertEq(totalSharesB_1, totalSharesB_0, "B shares should not change after deposit A");

        // 2. Deposit Pool B
        addFullRangeLiquidity(user, poolIdB, amount, amount, 0);
        uint128 totalSharesA_2 = liquidityManager.poolTotalShares(poolIdA);
        uint128 totalSharesB_2 = liquidityManager.poolTotalShares(poolIdB);
        assertEq(totalSharesA_2, totalSharesA_1, "A shares should not change after deposit B");
        assertTrue(totalSharesB_2 > totalSharesB_1, "B shares should increase after deposit B");

        // 3. Withdraw Pool A (approx token amount)
        vm.startPrank(user);
        IMarginData.BatchAction[] memory actionsA = new IMarginData.BatchAction[](1);
        actionsA[0] = createWithdrawAction(address(token0), amount / 2, user);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), actionsA);
        vm.stopPrank();
        uint128 totalSharesA_3 = liquidityManager.poolTotalShares(poolIdA);
        uint128 totalSharesB_3 = liquidityManager.poolTotalShares(poolIdB);
        assertTrue(totalSharesA_3 < totalSharesA_2, "A shares should decrease after withdraw A");
        assertEq(totalSharesB_3, totalSharesB_2, "B shares should not change after withdraw A");
    }

    // Removed old _deployFullRangeAndManager - logic moved to base

    // Helper functions createDepositAction, etc. are inherited from base
} 