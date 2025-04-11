// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

// Base Test Framework
import {MarginTestBase} from "./MarginTestBase.t.sol";

// Contracts under test / Interfaces
import {Margin} from "../src/Margin.sol";
import {MarginManager} from "../src/MarginManager.sol";
import {IMarginData} from "../src/interfaces/IMarginData.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";

// Libraries & Utilities
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";

/**
 * @title GasBenchmarkTest (Refactored)
 * @notice Measures gas costs for key Margin protocol operations using shared multi-pool setup.
 * @dev Uses MarginTestBase setup. Benchmarks executeBatch on a specific pool (poolIdA).
 */
contract GasBenchmarkTest is MarginTestBase, GasSnapshot {
    // Inherits fullRange (Margin), marginManager, token0, token1, alice, bob, etc.
    using CurrencyLibrary for Currency;

    // State for the specific pool used in benchmarks
    PoolId poolIdA;
    PoolKey poolKeyA;

    uint256 constant DEPOSIT_AMOUNT = 100e18;
    uint256 constant BORROW_SHARES_AMOUNT = 50e18;
    uint256 constant REPAY_SHARES_AMOUNT = 25e18;

    function setUp() public override {
        // Call the base setup FIRST (deploys shared contracts)
        MarginTestBase.setUp();

        // --- Initialize Pool A for Benchmarks --- (T0/T1)
        uint160 initialSqrtPrice = uint160(1 << 96); // Price = 1
        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));

        // console.log("[GasBench.setUp] Creating Pool A (T0/T1)...");
        vm.startPrank(deployer);
        (poolIdA, poolKeyA) = createPoolAndRegister(
            address(fullRange), address(liquidityManager),
            currency0, currency1, DEFAULT_FEE, DEFAULT_TICK_SPACING, initialSqrtPrice
        );
        vm.stopPrank();
        // console.log("[GasBench.setUp] Pool A created, ID:", PoolId.unwrap(poolIdA));

        // --- Add Initial Liquidity & Collateral for Benchmarks to Pool A ---
        // Alice adds pool liquidity
        addFullRangeLiquidity(alice, poolIdA, 1000e18, 1000e18, 0); // Add substantial pool liquidity

        // Bob deposits initial collateral into Pool A
        vm.startPrank(bob);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory depositActionsBob = new IMarginData.BatchAction[](2);
        depositActionsBob[0] = createDepositAction(address(token0), 5000e18); // Large collateral
        depositActionsBob[1] = createDepositAction(address(token1), 5000e18);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), depositActionsBob); // Use poolIdA
        vm.stopPrank();

        // Alice also deposits collateral into Pool A
        vm.startPrank(alice);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory depositActionsAlice = new IMarginData.BatchAction[](2);
        depositActionsAlice[0] = createDepositAction(address(token0), 5000e18);
        depositActionsAlice[1] = createDepositAction(address(token1), 5000e18);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), depositActionsAlice); // Use poolIdA
        vm.stopPrank();

         // console.log("[GasBench.setUp] Completed.");
    }

    // --- Benchmark Tests for executeBatch (Targeting Pool A) --- //

    function testGas_ExecuteBatch_SingleDeposit_Token0() public {
        IMarginData.BatchAction[] memory actions = new IMarginData.BatchAction[](1);
        actions[0] = createDepositAction(address(token0), DEPOSIT_AMOUNT);

        vm.startPrank(bob);
        token0.approve(address(fullRange), DEPOSIT_AMOUNT);
        snapStart("ExecuteBatch: 1 Deposit (T0)");
        fullRange.executeBatch(PoolId.unwrap(poolIdA), actions); // Pass poolIdA
        snapEnd();
        vm.stopPrank();
    }

    function testGas_ExecuteBatch_SingleDeposit_Token1() public {
        IMarginData.BatchAction[] memory actions = new IMarginData.BatchAction[](1);
        actions[0] = createDepositAction(address(token1), DEPOSIT_AMOUNT);

        vm.startPrank(bob);
        token1.approve(address(fullRange), DEPOSIT_AMOUNT);
        snapStart("ExecuteBatch: 1 Deposit (T1)");
        fullRange.executeBatch(PoolId.unwrap(poolIdA), actions); // Pass poolIdA
        snapEnd();
        vm.stopPrank();
    }

    function testGas_ExecuteBatch_TwoDeposits() public {
        IMarginData.BatchAction[] memory actions = new IMarginData.BatchAction[](2);
        actions[0] = createDepositAction(address(token0), DEPOSIT_AMOUNT);
        actions[1] = createDepositAction(address(token1), DEPOSIT_AMOUNT);

        vm.startPrank(bob);
        token0.approve(address(fullRange), DEPOSIT_AMOUNT);
        token1.approve(address(fullRange), DEPOSIT_AMOUNT);
        snapStart("ExecuteBatch: 2 Deposits (T0, T1)");
        fullRange.executeBatch(PoolId.unwrap(poolIdA), actions); // Pass poolIdA
        snapEnd();
        vm.stopPrank();
    }

    function testGas_ExecuteBatch_FiveDeposits() public {
        IMarginData.BatchAction[] memory actions = new IMarginData.BatchAction[](5);
        uint256 amountPer = DEPOSIT_AMOUNT / 5;
        actions[0] = createDepositAction(address(token0), amountPer);
        actions[1] = createDepositAction(address(token1), amountPer);
        actions[2] = createDepositAction(address(token0), amountPer);
        actions[3] = createDepositAction(address(token1), amountPer * 2); // Mix amounts
        actions[4] = createDepositAction(address(token0), amountPer);

        vm.startPrank(bob);
        token0.approve(address(fullRange), DEPOSIT_AMOUNT);
        token1.approve(address(fullRange), DEPOSIT_AMOUNT);
        snapStart("ExecuteBatch: 5 Deposits");
        fullRange.executeBatch(PoolId.unwrap(poolIdA), actions); // Pass poolIdA
        snapEnd();
        vm.stopPrank();
    }

    function testGas_ExecuteBatch_SingleBorrow() public {
        IMarginData.BatchAction[] memory actions = new IMarginData.BatchAction[](1);
        actions[0] = createBorrowAction(BORROW_SHARES_AMOUNT, bob);

        vm.startPrank(bob);
        // No approval needed for borrow
        snapStart("ExecuteBatch: 1 Borrow");
        fullRange.executeBatch(PoolId.unwrap(poolIdA), actions); // Pass poolIdA
        snapEnd();
        vm.stopPrank();
    }

    function testGas_ExecuteBatch_SingleRepay_FromVault() public {
        // First, borrow some shares from Pool A
        vm.startPrank(bob);
        IMarginData.BatchAction[] memory borrowActions = new IMarginData.BatchAction[](1);
        borrowActions[0] = createBorrowAction(BORROW_SHARES_AMOUNT, bob);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), borrowActions); // Use poolIdA
        // Bob already deposited collateral in setUp
        vm.stopPrank();

        // Now, benchmark the repay on Pool A
        IMarginData.BatchAction[] memory repayActions = new IMarginData.BatchAction[](1);
        repayActions[0] = createRepayAction(REPAY_SHARES_AMOUNT, true); // Use vault balance

        vm.startPrank(bob);
        // No approval needed for repay from vault
        snapStart("ExecuteBatch: 1 Repay (Vault)");
        fullRange.executeBatch(PoolId.unwrap(poolIdA), repayActions); // Use poolIdA
        snapEnd();
        vm.stopPrank();
    }

     function testGas_ExecuteBatch_SingleRepay_FromExternal() public {
        // First, borrow some shares from Pool A
        vm.startPrank(bob);
        IMarginData.BatchAction[] memory borrowActions = new IMarginData.BatchAction[](1);
        borrowActions[0] = createBorrowAction(BORROW_SHARES_AMOUNT, bob);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), borrowActions); // Use poolIdA
        vm.stopPrank();

        // Estimate tokens needed for repay (crude estimation for test setup)
        (uint256 r0, uint256 r1, uint128 ts) = fullRange.getPoolReservesAndShares(poolIdA); // Don't unwrap
        uint256 approxT0Needed = (REPAY_SHARES_AMOUNT * r0) / ts + 1e10; // Add buffer
        uint256 approxT1Needed = (REPAY_SHARES_AMOUNT * r1) / ts + 1e10;

        // Now, benchmark the repay from external for Pool A
        IMarginData.BatchAction[] memory repayActions = new IMarginData.BatchAction[](1);
        repayActions[0] = createRepayAction(REPAY_SHARES_AMOUNT, false); // Do NOT use vault balance

        vm.startPrank(bob);
        token0.approve(address(fullRange), approxT0Needed);
        token1.approve(address(fullRange), approxT1Needed);
        snapStart("ExecuteBatch: 1 Repay (External)");
        fullRange.executeBatch(PoolId.unwrap(poolIdA), repayActions); // Use poolIdA
        snapEnd();
        vm.stopPrank();
    }

    function testGas_ExecuteBatch_SingleWithdraw() public {
        // Bob already has collateral from setUp

        // Benchmark the withdraw from Pool A
        IMarginData.BatchAction[] memory actions = new IMarginData.BatchAction[](1);
        actions[0] = createWithdrawAction(address(token0), DEPOSIT_AMOUNT, bob);

        vm.startPrank(bob);
        // No approval needed for withdraw
        snapStart("ExecuteBatch: 1 Withdraw");
        fullRange.executeBatch(PoolId.unwrap(poolIdA), actions); // Use poolIdA
        snapEnd();
        vm.stopPrank();
    }

    function testGas_ExecuteBatch_Complex_DepositBorrowRepayWithdraw() public {
        // Setup: Alice borrows from Pool A
        vm.startPrank(alice);
        IMarginData.BatchAction[] memory borrowActions = new IMarginData.BatchAction[](1);
        borrowActions[0] = createBorrowAction(BORROW_SHARES_AMOUNT, alice);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), borrowActions); // Use poolIdA
        vm.stopPrank();
        (uint256 r0, uint256 r1, uint128 ts) = fullRange.getPoolReservesAndShares(poolIdA); // Don't unwrap
        uint256 approxT0Needed = (REPAY_SHARES_AMOUNT * r0) / ts + 1e10;
        uint256 approxT1Needed = (REPAY_SHARES_AMOUNT * r1) / ts + 1e10;

        // Prepare complex batch for Bob on Pool A
        IMarginData.BatchAction[] memory actions = new IMarginData.BatchAction[](4);
        actions[0] = createDepositAction(address(token0), DEPOSIT_AMOUNT);
        actions[1] = createBorrowAction(BORROW_SHARES_AMOUNT, bob);
        actions[2] = createRepayAction(REPAY_SHARES_AMOUNT, false); // Repay (requires external funds)
        actions[3] = createWithdrawAction(address(token0), DEPOSIT_AMOUNT / 2, bob);

        vm.startPrank(bob);
        token0.approve(address(fullRange), DEPOSIT_AMOUNT + approxT0Needed);
        token1.approve(address(fullRange), approxT1Needed);
        snapStart("ExecuteBatch: Complex (Dep, Bor, RepExt, Wdr)");
        fullRange.executeBatch(PoolId.unwrap(poolIdA), actions); // Use poolIdA
        snapEnd();
        vm.stopPrank();
    }

    function testGas_ExecuteBatch_OptimizedVsNaiveSolvencyCheck() public {
        // This requires modifying MarginManager internally to compare gas,
        // which is difficult in a standard test setup without internal instrumentation.
        // We can infer the optimization benefit by comparing single action costs vs multi-action batch costs.
        // console.log("Gas Savings Inference: Compare single action costs vs multi-action batch costs.");
        // console.log("Lower per-action cost in batches indicates optimization effectiveness.");

        // Example: Compare (Gas(Deposit) + Gas(Borrow)) vs Gas(Deposit+Borrow Batch)
        // The batch should be significantly cheaper than the sum of individuals due to caching.
    }

} 