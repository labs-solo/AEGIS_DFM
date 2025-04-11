// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {MarginTestBase} from "./MarginTestBase.t.sol";
import {Margin} from "../src/Margin.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {MockLinearInterestRateModel} from "./mocks/MockLinearInterestRateModel.sol";
import {Errors} from "../src/errors/Errors.sol";
import {ISpot} from "../src/interfaces/ISpot.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {IMargin} from "../src/interfaces/IMargin.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IMarginManager} from "../src/interfaces/IMarginManager.sol";
import {MarginManager} from "../src/MarginManager.sol";
import {IMarginData} from "../src/interfaces/IMarginData.sol";
import {MockERC20} from "../src/token/MockERC20.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract MarginTest is MarginTestBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Removed RateModel and FeeManager state variables
    MockLinearInterestRateModel mockRateModel; // Keep mock for specific tests

    // Test parameters
    uint256 constant PRECISION = 1e18;
    uint256 constant SECONDS_PER_YEAR = 365 days;
    uint256 protocolFeePercentage = (10 * PRECISION) / 100; // 10%
    uint256 maxRateYear = 1 * PRECISION; // Example, actual max depends on model deployed in base

    // Users
    address borrower = alice;
    address lender = bob;
    address authorizedReinvestor = charlie; // Assuming this role is still relevant

    // Pool state variables (for two example pools A and B)
    PoolKey poolKeyA;
    PoolId poolIdA;
    PoolKey poolKeyB;
    PoolId poolIdB;
    MockERC20 tokenC; // Add another token for Pool B

    function setUp() public override {
        // Call base setup first - deploys shared contracts
        MarginTestBase.setUp();

        // Deploy a mock Rate Model if needed for specific tests (not set by default)
        mockRateModel = new MockLinearInterestRateModel();

        // --- Initialize Two Pools (A: T0/T1, B: T1/T2) ---
        uint160 initialSqrtPrice = uint160(1 << 96); // Price = 1
        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));

        // Create Pool A (T0/T1)
        console2.log("[MarginTest.setUp] Creating Pool A (T0/T1)...");
        vm.startPrank(deployer); // Assuming deployer can initialize pools
        (poolIdA, poolKeyA) = createPoolAndRegister(
            address(fullRange), // Shared hook
            address(liquidityManager), // Shared LM
            currency0,
            currency1,
            DEFAULT_FEE, // Dynamic fee
            DEFAULT_TICK_SPACING,
            initialSqrtPrice
        );
        vm.stopPrank();
        // console2.log("[MarginTest.setUp] Pool A created, ID:", PoolId.unwrap(poolIdA));

        // Create Pool B (T1/T2) - Need another token
        tokenC = new MockERC20("TokenC", "TKNC", 18);
        tokenC.mint(alice, INITIAL_TOKEN_BALANCE);
        tokenC.mint(bob, INITIAL_TOKEN_BALANCE);
        tokenC.mint(charlie, INITIAL_TOKEN_BALANCE);
        Currency currencyC = Currency.wrap(address(tokenC));

        console2.log("[MarginTest.setUp] Creating Pool B (T1/T2)...");
        vm.startPrank(deployer);
        (poolIdB, poolKeyB) = createPoolAndRegister(
            address(fullRange),
            address(liquidityManager),
            currency1, // Use T1 again
            currencyC, // Use T2 (renamed to TKN C)
            DEFAULT_FEE,
            DEFAULT_TICK_SPACING,
            initialSqrtPrice
        );
        vm.stopPrank();
        // console2.log("[MarginTest.setUp] Pool B created, ID:", PoolId.unwrap(poolIdB));

        // Configure shared PolicyManager (as governance)
        vm.startPrank(governance);
        policyManager.setAuthorizedReinvestor(authorizedReinvestor, true);
        policyManager.setProtocolFeePercentage(protocolFeePercentage); // Global setting
        // Pool-specific policies can be set if needed:
        // policyManager.setPolicy(poolIdA, IPoolPolicy.PolicyType.REINVESTMENT, address(feeManager));
        // policyManager.setPolicy(poolIdB, ...);
        vm.stopPrank();

        // Remove FeeManager deployment and setup for now
        // ... feeManager deployment ...
        // ... feeManager linking ...

        // --- Add Initial Liquidity & Collateral (Example for Pool A) ---
        // Tests should set up their own specific liquidity/collateral as needed
        // Example: Add some base liquidity to Pool A
        uint128 initialPoolLiquidityA = 1000 * 1e18;
        addFullRangeLiquidity(alice, poolIdA, initialPoolLiquidityA, initialPoolLiquidityA, 0); // Use helper with PoolId

        // Example: Lender deposits collateral into Pool A
        uint128 initialCollateralA = 1000 * 1e18;
        vm.startPrank(lender);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory depositActionsA = new IMarginData.BatchAction[](2);
        depositActionsA[0] = createDepositAction(address(token0), initialCollateralA);
        depositActionsA[1] = createDepositAction(address(token1), initialCollateralA);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), depositActionsA); // Pass poolIdA
        vm.stopPrank();

        console2.log("[MarginTest.setUp] Completed. Pools A & B initialized.");
    }

    // --- Helper to switch Rate Model --- //
    function setupMockModel() internal {
        vm.startPrank(governance);
        // Set the *single* interestRateModel in MarginManager
        marginManager.setInterestRateModel(address(mockRateModel));
        vm.stopPrank();
    }

    function restoreRealModel() internal {
         vm.startPrank(governance);
        // Set the *single* interestRateModel back to the one deployed in base
        marginManager.setInterestRateModel(address(interestRateModel));
        vm.stopPrank();
    }

    // ===== PHASE 4 TESTS (Adapted for Multi-Pool) =====

    // --- Accrual & Fees Tests (Focus on Pool A) ---

    function test_Accrual_UpdatesMultiplier_PoolA() public {
        PoolId targetPoolId = poolIdA; // Target Pool A for this test

        uint256 initialMultiplier = marginManager.interestMultiplier(targetPoolId);
        assertEq(initialMultiplier, PRECISION, "Initial multiplier should be PRECISION");

        // Deposit collateral for borrower first into Pool A
        uint256 borrowerCollateral = 2000 * 1e18;
        vm.startPrank(borrower);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory depositActions = new IMarginData.BatchAction[](2);
        depositActions[0] = createDepositAction(address(token0), borrowerCollateral);
        depositActions[1] = createDepositAction(address(token1), borrowerCollateral);
        fullRange.executeBatch(PoolId.unwrap(targetPoolId), depositActions); // Use targetPoolId
        vm.stopPrank();

        vm.warp(block.timestamp + 1); // Avoid same block timestamp issues

        // Borrow from Pool A
        uint256 borrowShares = 100 * 1e18;
        vm.startPrank(borrower);
        IMarginData.BatchAction[] memory borrowActions = new IMarginData.BatchAction[](1);
        borrowActions[0] = createBorrowAction(borrowShares, borrower);
        fullRange.executeBatch(PoolId.unwrap(targetPoolId), borrowActions); // Use targetPoolId
        vm.stopPrank();

        uint256 timeToWarp = 30 days;
        vm.warp(block.timestamp + timeToWarp);

        // Trigger accrual by interacting with Pool A
        vm.startPrank(lender);
        IMarginData.BatchAction[] memory triggerActions = new IMarginData.BatchAction[](2);
        triggerActions[0] = createDepositAction(address(token0), 1);
        triggerActions[1] = createDepositAction(address(token1), 1);
        fullRange.executeBatch(PoolId.unwrap(targetPoolId), triggerActions); // Use targetPoolId
        vm.stopPrank();

        uint256 finalMultiplier = marginManager.interestMultiplier(targetPoolId);
        console2.log("Initial Multiplier (Pool A):", initialMultiplier);
        console2.log("Final Multiplier (Pool A):", finalMultiplier);

        assertTrue(finalMultiplier > initialMultiplier, "Multiplier should increase");

        // Fetch state specifically for Pool A
        (uint256 reserve0, uint256 reserve1, uint128 totalShares) = fullRange.getPoolReservesAndShares(targetPoolId);
        uint256 rentedShares = marginManager.rentedLiquidity(targetPoolId);
        // Use the interestRateModel instance from the base class
        uint256 utilization = interestRateModel.getUtilizationRate(targetPoolId, rentedShares, totalShares);
        uint256 ratePerSecond = interestRateModel.getBorrowRate(targetPoolId, utilization);
        uint256 expectedMultiplier = FullMath.mulDiv(
            initialMultiplier,
            PRECISION + (ratePerSecond * timeToWarp),
            PRECISION
        );

        assertApproxEqAbs(finalMultiplier, expectedMultiplier, 1, "Multiplier mismatch");
    }

    function test_Accrual_CalculatesProtocolFees_PoolA() public {
        PoolId targetPoolId = poolIdA; // Target Pool A

        uint256 initialFees = marginManager.accumulatedFees(targetPoolId);
        assertEq(initialFees, 0, "Initial fees should be 0");

        // Deposit collateral into Pool A
        uint256 borrowerCollateral = 2000 * 1e18;
        vm.startPrank(borrower);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory depositActions = new IMarginData.BatchAction[](2);
        depositActions[0] = createDepositAction(address(token0), borrowerCollateral);
        depositActions[1] = createDepositAction(address(token1), borrowerCollateral);
        fullRange.executeBatch(PoolId.unwrap(targetPoolId), depositActions);
        vm.stopPrank();

        // Borrow from Pool A
        uint256 borrowShares = 100 * 1e18;
        vm.startPrank(borrower);
        IMarginData.BatchAction[] memory borrowActions = new IMarginData.BatchAction[](1);
        borrowActions[0] = createBorrowAction(borrowShares, borrower);
        fullRange.executeBatch(PoolId.unwrap(targetPoolId), borrowActions);
        vm.stopPrank();

        uint256 timeToWarp = 60 days;
        vm.warp(block.timestamp + timeToWarp);

        uint256 currentMultiplierBeforeAccrual = marginManager.interestMultiplier(targetPoolId);

        // Trigger accrual on Pool A
        vm.startPrank(lender);
        IMarginData.BatchAction[] memory triggerActions = new IMarginData.BatchAction[](2);
        triggerActions[0] = createDepositAction(address(token0), 1);
        triggerActions[1] = createDepositAction(address(token1), 1);
        fullRange.executeBatch(PoolId.unwrap(targetPoolId), triggerActions);
        vm.stopPrank();

        uint256 finalFees = marginManager.accumulatedFees(targetPoolId);
        console2.log("Final Accumulated Fees (Shares) Pool A:", finalFees);
        assertTrue(finalFees > initialFees, "Fees should increase");

        // Fetch state for Pool A
        (uint256 reserve0, uint256 reserve1, uint128 totalShares) = fullRange.getPoolReservesAndShares(targetPoolId);
        uint256 rentedShares = marginManager.rentedLiquidity(targetPoolId);
        // Use interestRateModel instance from base
        uint256 utilization = interestRateModel.getUtilizationRate(targetPoolId, rentedShares, totalShares);
        uint256 ratePerSecond = interestRateModel.getBorrowRate(targetPoolId, utilization);

        uint256 newMultiplier = marginManager.interestMultiplier(targetPoolId);

        uint256 interestAmountShares = FullMath.mulDiv(rentedShares, newMultiplier - currentMultiplierBeforeAccrual, currentMultiplierBeforeAccrual);
        // Use protocolFeePercentage state variable
        uint256 expectedFeeShares = FullMath.mulDiv(interestAmountShares, protocolFeePercentage, PRECISION);

        assertApproxEqAbs(finalFees, expectedFeeShares, 1, "Fee mismatch");
    }

    // Removed test_GetInterestRatePerSecond - implicitly tested in accrual tests

    // Removed FeeManager tests for now
    // function test_FeeManagerInteraction_GetAndResetFees() public { ... }

    // --- Utilization Limit Tests (Focus on Pool A) ---

    function test_Borrow_Revert_MaxPoolUtilizationExceeded_PoolA() public {
        PoolId targetPoolId = poolIdA;
        PoolKey memory targetKey = poolKeyA;

        uint256 maxUtil = interestRateModel.maxUtilizationRate();
        (,, uint128 totalShares) = fullRange.getPoolReservesAndShares(targetPoolId);
        uint256 targetBorrowedNearMax = maxUtil * totalShares / PRECISION - 1e10;
        uint256 collateralAmount = 5000 * 1e18;

        // Deposit collateral into Pool A
        vm.startPrank(borrower);
        token0.approve(address(fullRange), type(uint256).max); // Approve T0 for pool A
        token1.approve(address(fullRange), type(uint256).max); // Approve T1 for pool A
        IMarginData.BatchAction[] memory depositActions = new IMarginData.BatchAction[](2);
        depositActions[0] = createDepositAction(address(token0), collateralAmount);
        depositActions[1] = createDepositAction(address(token1), collateralAmount);
        fullRange.executeBatch(PoolId.unwrap(targetPoolId), depositActions);

        // Borrow near max from Pool A
        IMarginData.BatchAction[] memory borrowActions = new IMarginData.BatchAction[](1);
        borrowActions[0] = createBorrowAction(targetBorrowedNearMax, borrower);
        fullRange.executeBatch(PoolId.unwrap(targetPoolId), borrowActions);
        vm.stopPrank();

        uint256 currentBorrowed = marginManager.rentedLiquidity(targetPoolId);
        uint256 currentUtil = interestRateModel.getUtilizationRate(targetPoolId, currentBorrowed, totalShares);
        assertTrue(currentUtil < maxUtil, "Util below max");

        uint256 sharesToExceedLimit = (maxUtil * totalShares / PRECISION) - currentBorrowed + 1e10;
        uint256 finalBorrowed = currentBorrowed + sharesToExceedLimit;
        // Calculate expected final utilization based on the state *before* the failing borrow
        (,, uint128 currentTotalShares) = fullRange.getPoolReservesAndShares(targetPoolId);
        uint256 expectedFinalUtil = interestRateModel.getUtilizationRate(targetPoolId, finalBorrowed, currentTotalShares);

        // Attempt to borrow more from Pool A - expect revert
        vm.startPrank(borrower);
        // Note: The error args might be different now - check actual error if this fails
        vm.expectRevert(abi.encodeWithSelector(Errors.MaxPoolUtilizationExceeded.selector, expectedFinalUtil, maxUtil));
        IMarginData.BatchAction[] memory borrowActions2 = new IMarginData.BatchAction[](1);
        borrowActions2[0] = createBorrowAction(sharesToExceedLimit, borrower);
        fullRange.executeBatch(PoolId.unwrap(targetPoolId), borrowActions2);
        vm.stopPrank();
    }

     function test_Borrow_Success_AtMaxUtilization_PoolA() public {
        PoolId targetPoolId = poolIdA;
        PoolKey memory targetKey = poolKeyA;

        uint256 maxUtil = interestRateModel.maxUtilizationRate();
        (,, uint128 totalSharesBefore) = fullRange.getPoolReservesAndShares(targetPoolId);
        uint256 targetBorrowedAtMax = maxUtil * totalSharesBefore / PRECISION;
        uint256 collateralAmount = 5000 * 1e18;

        // Deposit collateral into Pool A
        vm.startPrank(borrower);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory depositActions = new IMarginData.BatchAction[](2);
        depositActions[0] = createDepositAction(address(token0), collateralAmount);
        depositActions[1] = createDepositAction(address(token1), collateralAmount);
        fullRange.executeBatch(PoolId.unwrap(targetPoolId), depositActions);

        // Borrow exactly max from Pool A
        IMarginData.BatchAction[] memory borrowActions = new IMarginData.BatchAction[](1);
        borrowActions[0] = createBorrowAction(targetBorrowedAtMax, borrower);
        fullRange.executeBatch(PoolId.unwrap(targetPoolId), borrowActions);
        vm.stopPrank();

        uint256 currentBorrowed = marginManager.rentedLiquidity(targetPoolId);
        (,, uint128 totalSharesAfter) = fullRange.getPoolReservesAndShares(targetPoolId);
        uint256 currentUtil = interestRateModel.getUtilizationRate(targetPoolId, currentBorrowed, totalSharesAfter);

        assertApproxEqAbs(currentUtil, maxUtil, 1, "Util not at max");
        assertApproxEqAbs(currentBorrowed, targetBorrowedAtMax, 1, "Borrowed amount mismatch");
    }

    // Removed FeeManager Trigger Tests
    // function test_FeeManager_TriggerInterestFeeProcessing() public { ... }
    // function test_FeeManager_TriggerInterestFeeProcessing_NoFees() public { ... }
    // function test_Revert_FeeManager_TriggerInterestFeeProcessing_Unauthorized() public { ... }
    // function test_Revert_FeeManager_TriggerInterestFeeProcessing_MarginNotSet() public { ... }

    // =========================================================================
    // NEW ISOLATION TESTS
    // =========================================================================

    function test_ExecuteBatch_Deposit_Isolation() public {
        uint256 depositAmount = 100 * 1e18;

        // Get initial vault states for alice in both pools
        IMarginData.Vault memory vaultA_before = fullRange.getVault(poolIdA, alice);
        IMarginData.Vault memory vaultB_before = fullRange.getVault(poolIdB, alice);

        // Alice deposits collateral into Pool A (T0/T1)
        vm.startPrank(alice);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory depositActionsA = new IMarginData.BatchAction[](2);
        depositActionsA[0] = createDepositAction(address(token0), depositAmount);
        depositActionsA[1] = createDepositAction(address(token1), depositAmount);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), depositActionsA);
        vm.stopPrank();

        // Get final vault states
        IMarginData.Vault memory vaultA_after = fullRange.getVault(poolIdA, alice);
        IMarginData.Vault memory vaultB_after = fullRange.getVault(poolIdB, alice);

        // Assert: Vault A changed
        assertTrue(vaultA_after.token0Balance > vaultA_before.token0Balance, "VaultA T0 balance should increase");
        assertTrue(vaultA_after.token1Balance > vaultA_before.token1Balance, "VaultA T1 balance should increase");
        assertEq(vaultA_after.debtShares, vaultA_before.debtShares, "VaultA debt should not change");

        // Assert: Vault B unchanged
        assertEq(vaultB_after.token0Balance, vaultB_before.token0Balance, "VaultB T0 balance should be unchanged"); // Pool B uses T1/T2
        assertEq(vaultB_after.token1Balance, vaultB_before.token1Balance, "VaultB T1 balance should be unchanged");
        assertEq(vaultB_after.debtShares, vaultB_before.debtShares, "VaultB debt should be unchanged");
    }

    function test_ExecuteBatch_Borrow_Isolation() public {
        uint256 depositAmount = 500 * 1e18;
        uint256 borrowShares = 50 * 1e18;

        // Alice deposits collateral into Pool A
        vm.startPrank(alice);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory depositActionsA = new IMarginData.BatchAction[](2);
        depositActionsA[0] = createDepositAction(address(token0), depositAmount);
        depositActionsA[1] = createDepositAction(address(token1), depositAmount);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), depositActionsA);
        vm.stopPrank();

        // Get initial states for Pool A and Pool B
        IMarginData.Vault memory vaultA_before = fullRange.getVault(poolIdA, alice);
        IMarginData.Vault memory vaultB_before = fullRange.getVault(poolIdB, alice);
        uint256 rentedA_before = marginManager.rentedLiquidity(poolIdA);
        uint256 rentedB_before = marginManager.rentedLiquidity(poolIdB);

        // Alice borrows from Pool A
        vm.startPrank(alice);
        IMarginData.BatchAction[] memory borrowActionsA = new IMarginData.BatchAction[](1);
        borrowActionsA[0] = createBorrowAction(borrowShares, alice);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), borrowActionsA);
        vm.stopPrank();

        // Get final states
        IMarginData.Vault memory vaultA_after = fullRange.getVault(poolIdA, alice);
        IMarginData.Vault memory vaultB_after = fullRange.getVault(poolIdB, alice);
        uint256 rentedA_after = marginManager.rentedLiquidity(poolIdA);
        uint256 rentedB_after = marginManager.rentedLiquidity(poolIdB);

        // Assert: Pool A state changed
        assertTrue(vaultA_after.debtShares > vaultA_before.debtShares, "VaultA debt should increase");
        assertTrue(rentedA_after > rentedA_before, "RentedA should increase");

        // Assert: Pool B state unchanged
        assertEq(vaultB_after.token0Balance, vaultB_before.token0Balance, "VaultB T0 balance unchanged");
        assertEq(vaultB_after.token1Balance, vaultB_before.token1Balance, "VaultB T1 balance unchanged");
        assertEq(vaultB_after.debtShares, vaultB_before.debtShares, "VaultB debt unchanged");
        assertEq(rentedB_after, rentedB_before, "RentedB should be unchanged");
    }

    function test_ExecuteBatch_Withdraw_Isolation() public {
        uint256 depositAmount = 200 * 1e18;
        uint256 withdrawAmount = 50 * 1e18;

        // Alice deposits collateral into Pool A
        vm.startPrank(alice);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory depositActionsA = new IMarginData.BatchAction[](2);
        depositActionsA[0] = createDepositAction(address(token0), depositAmount);
        depositActionsA[1] = createDepositAction(address(token1), depositAmount);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), depositActionsA);
        vm.stopPrank();

        // Alice deposits collateral into Pool B (T1/T2)
        vm.startPrank(alice);
        token1.approve(address(fullRange), type(uint256).max);
        tokenC.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory depositActionsB = new IMarginData.BatchAction[](2);
        depositActionsB[0] = createDepositAction(address(token1), depositAmount); // T1 is asset 0 in Pool B
        depositActionsB[1] = createDepositAction(address(tokenC), depositAmount); // T2(C) is asset 1 in Pool B
        fullRange.executeBatch(PoolId.unwrap(poolIdB), depositActionsB);
        vm.stopPrank();

        // Get initial states
        IMarginData.Vault memory vaultA_before = fullRange.getVault(poolIdA, alice);
        IMarginData.Vault memory vaultB_before = fullRange.getVault(poolIdB, alice);

        // Alice withdraws from Pool A
        vm.startPrank(alice);
        IMarginData.BatchAction[] memory withdrawActionsA = new IMarginData.BatchAction[](1);
        withdrawActionsA[0] = createWithdrawAction(address(token0), withdrawAmount, alice); // Withdraw T0
        fullRange.executeBatch(PoolId.unwrap(poolIdA), withdrawActionsA);
        vm.stopPrank();

        // Get final states
        IMarginData.Vault memory vaultA_after = fullRange.getVault(poolIdA, alice);
        IMarginData.Vault memory vaultB_after = fullRange.getVault(poolIdB, alice);

        // Assert: Vault A changed
        assertTrue(vaultA_after.token0Balance < vaultA_before.token0Balance, "VaultA T0 balance should decrease");
        assertEq(vaultA_after.token1Balance, vaultA_before.token1Balance, "VaultA T1 balance should not change");
        assertEq(vaultA_after.debtShares, vaultA_before.debtShares, "VaultA debt should not change");

        // Assert: Vault B unchanged
        assertEq(vaultB_after.token0Balance, vaultB_before.token0Balance, "VaultB T0(T1) balance unchanged");
        assertEq(vaultB_after.token1Balance, vaultB_before.token1Balance, "VaultB T1(T2) balance unchanged");
        assertEq(vaultB_after.debtShares, vaultB_before.debtShares, "VaultB debt unchanged");
    }

    function test_InterestAccrual_Isolation() public {
        uint256 depositAmount = 500 * 1e18;
        uint256 borrowShares = 50 * 1e18;

        // Alice deposits collateral and borrows from Pool A
        vm.startPrank(alice);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory setupActionsA = new IMarginData.BatchAction[](3);
        setupActionsA[0] = createDepositAction(address(token0), depositAmount);
        setupActionsA[1] = createDepositAction(address(token1), depositAmount);
        setupActionsA[2] = createBorrowAction(borrowShares, alice);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), setupActionsA);
        vm.stopPrank();

        // Get initial multipliers
        uint256 multiplierA_before = marginManager.interestMultiplier(poolIdA);
        uint256 multiplierB_before = marginManager.interestMultiplier(poolIdB);
        assertEq(multiplierB_before, PRECISION, "Pool B multiplier should start at PRECISION"); // Pool B hasn't been interacted with

        // Warp time
        uint256 timeToWarp = 7 days;
        vm.warp(block.timestamp + timeToWarp);

        // Trigger accrual ONLY in Pool A by depositing 1 wei
        vm.startPrank(lender);
        token0.approve(address(fullRange), 1);
        IMarginData.BatchAction[] memory triggerActionsA = new IMarginData.BatchAction[](1);
        triggerActionsA[0] = createDepositAction(address(token0), 1);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), triggerActionsA);
        vm.stopPrank();

        // Get final multipliers
        uint256 multiplierA_after = marginManager.interestMultiplier(poolIdA);
        uint256 multiplierB_after = marginManager.interestMultiplier(poolIdB);

        // Assert: Multiplier A increased
        assertTrue(multiplierA_after > multiplierA_before, "Multiplier A should increase");

        // Assert: Multiplier B remained unchanged
        assertEq(multiplierB_after, multiplierB_before, "Multiplier B should be unchanged");
        assertEq(multiplierB_after, PRECISION, "Multiplier B should still be PRECISION");
    }

    // =========================================================================
    // Error Handling Tests
    // =========================================================================

    function test_Revert_ExecuteBatch_InvalidPoolId() public {
        PoolId invalidPoolId = PoolId.wrap(bytes32(keccak256("invalidPool")));
        IMarginData.BatchAction[] memory actions = new IMarginData.BatchAction[](1);
        actions[0] = createDepositAction(address(token0), 1e18);

        // Expect revert when passing invalid/unrecognized poolId
        vm.expectRevert(abi.encodeWithSelector(Errors.PoolNotInitialized.selector, PoolId.unwrap(invalidPoolId)));
        fullRange.executeBatch(PoolId.unwrap(invalidPoolId), actions);
        vm.stopPrank();
    }

    function test_Revert_Getters_InvalidPoolId() public {
        PoolId invalidPoolId = PoolId.wrap(bytes32(keccak256("invalidPool")));

        vm.expectRevert(Errors.PoolNotInitialized.selector);
        fullRange.getPoolInfo(invalidPoolId);

        // MarginManager getters might revert differently (e.g., return default struct)
        // Depending on implementation, these might not revert but return zero values.
        // Adjust based on actual behavior.
        // vm.expectRevert(...);
        // fullRange.getVault(invalidPoolId, alice);

        // vm.expectRevert(...);
        // marginManager.interestMultiplier(invalidPoolId);
    }

    // =========================================================================
    // NEW ISOLATION TESTS (Margin Manager focused)
    // =========================================================================

    function test_MM_Interest_Isolation() public {
        // Same setup as test_InterestAccrual_Isolation, but check MM state directly
        address user = alice;
        uint256 depositAmount = 500 * 1e18;
        uint256 borrowShares = 50 * 1e18;

        // Alice deposits collateral and borrows from Pool A
        vm.startPrank(user);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory setupActionsA = new IMarginData.BatchAction[](3);
        setupActionsA[0] = createDepositAction(address(token0), depositAmount);
        setupActionsA[1] = createDepositAction(address(token1), depositAmount);
        setupActionsA[2] = createBorrowAction(borrowShares, user);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), setupActionsA);
        vm.stopPrank();

        // Get initial MM state
        uint256 multiplierA_before = marginManager.interestMultiplier(poolIdA);
        uint256 multiplierB_before = marginManager.interestMultiplier(poolIdB);
        uint64 lastAccrualA_before = marginManager.lastInterestAccrualTime(poolIdA);
        uint64 lastAccrualB_before = marginManager.lastInterestAccrualTime(poolIdB);

        // Warp time
        vm.warp(block.timestamp + 7 days);

        // Trigger accrual ONLY in Pool A
        vm.startPrank(lender);
        token0.approve(address(fullRange), 1);
        IMarginData.BatchAction[] memory triggerActionsA = new IMarginData.BatchAction[](1);
        triggerActionsA[0] = createDepositAction(address(token0), 1);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), triggerActionsA);
        vm.stopPrank();

        // Get final MM state
        uint256 multiplierA_after = marginManager.interestMultiplier(poolIdA);
        uint256 multiplierB_after = marginManager.interestMultiplier(poolIdB);
        uint64 lastAccrualA_after = marginManager.lastInterestAccrualTime(poolIdA);
        uint64 lastAccrualB_after = marginManager.lastInterestAccrualTime(poolIdB);

        // Assert: MM state for Pool A changed
        assertTrue(multiplierA_after > multiplierA_before, "MM Multiplier A should increase");
        assertTrue(lastAccrualA_after > lastAccrualA_before, "MM Last Accrual A should update");

        // Assert: MM state for Pool B unchanged
        assertEq(multiplierB_after, multiplierB_before, "MM Multiplier B should be unchanged");
        assertEq(lastAccrualB_after, lastAccrualB_before, "MM Last Accrual B should be unchanged");
    }

    function test_MM_Batch_Isolation() public {
        // Similar to test_ExecuteBatch_Borrow_Isolation, but check MM state
        address user = alice;
        uint256 depositAmount = 500 * 1e18;
        uint256 borrowShares = 50 * 1e18;

        // Alice deposits collateral into Pool A
        vm.startPrank(user);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory depositActionsA = new IMarginData.BatchAction[](2);
        depositActionsA[0] = createDepositAction(address(token0), depositAmount);
        depositActionsA[1] = createDepositAction(address(token1), depositAmount);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), depositActionsA);
        vm.stopPrank();

        // Get initial MM state
        IMarginData.Vault memory vaultA_before = marginManager.vaults(poolIdA, user);
        IMarginData.Vault memory vaultB_before = marginManager.vaults(poolIdB, user);
        uint256 rentedA_before = marginManager.rentedLiquidity(poolIdA);
        uint256 rentedB_before = marginManager.rentedLiquidity(poolIdB);

        // Alice borrows from Pool A
        vm.startPrank(user);
        IMarginData.BatchAction[] memory borrowActionsA = new IMarginData.BatchAction[](1);
        borrowActionsA[0] = createBorrowAction(borrowShares, user);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), borrowActionsA);
        vm.stopPrank();

        // Get final MM state
        IMarginData.Vault memory vaultA_after = marginManager.vaults(poolIdA, user);
        IMarginData.Vault memory vaultB_after = marginManager.vaults(poolIdB, user);
        uint256 rentedA_after = marginManager.rentedLiquidity(poolIdA);
        uint256 rentedB_after = marginManager.rentedLiquidity(poolIdB);

        // Assert: MM state for Pool A changed
        assertTrue(vaultA_after.debtShares > vaultA_before.debtShares, "MM VaultA debt should increase");
        assertTrue(rentedA_after > rentedA_before, "MM RentedA should increase");

        // Assert: MM state for Pool B unchanged
        assertEq(vaultB_after.token0Balance, vaultB_before.token0Balance, "MM VaultB T0 balance unchanged");
        assertEq(vaultB_after.token1Balance, vaultB_before.token1Balance, "MM VaultB T1 balance unchanged");
        assertEq(vaultB_after.debtShares, vaultB_before.debtShares, "MM VaultB debt unchanged");
        assertEq(rentedB_after, rentedB_before, "MM RentedB should be unchanged");
    }

    function test_MM_Fees_Isolation() public {
        // Same setup as test_Accrual_CalculatesProtocolFees_PoolA, check MM fees
        PoolId targetPoolIdA = poolIdA;
        PoolId targetPoolIdB = poolIdB;

        // Initial MM fees should be zero
        uint256 feesA_before = marginManager.accumulatedFees(targetPoolIdA);
        uint256 feesB_before = marginManager.accumulatedFees(targetPoolIdB);
        assertEq(feesA_before, 0, "Initial MM fees A should be 0");
        assertEq(feesB_before, 0, "Initial MM fees B should be 0");

        // Deposit collateral into Pool A
        uint256 borrowerCollateral = 2000 * 1e18;
        vm.startPrank(borrower);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory depositActions = new IMarginData.BatchAction[](2);
        depositActions[0] = createDepositAction(address(token0), borrowerCollateral);
        depositActions[1] = createDepositAction(address(token1), borrowerCollateral);
        fullRange.executeBatch(PoolId.unwrap(targetPoolIdA), depositActions);

        // Borrow from Pool A
        uint256 borrowShares = 100 * 1e18;
        IMarginData.BatchAction[] memory borrowActions = new IMarginData.BatchAction[](1);
        borrowActions[0] = createBorrowAction(borrowShares, borrower);
        fullRange.executeBatch(PoolId.unwrap(targetPoolIdA), borrowActions);
        vm.stopPrank();

        // Warp time
        vm.warp(block.timestamp + 60 days);

        // Trigger accrual on Pool A
        vm.startPrank(lender);
        IMarginData.BatchAction[] memory triggerActions = new IMarginData.BatchAction[](1);
        triggerActions[0] = createDepositAction(address(token0), 1);
        fullRange.executeBatch(PoolId.unwrap(targetPoolIdA), triggerActions);
        vm.stopPrank();

        // Get final MM fees
        uint256 feesA_after = marginManager.accumulatedFees(targetPoolIdA);
        uint256 feesB_after = marginManager.accumulatedFees(targetPoolIdB);

        // Assert: MM Fees A increased
        assertTrue(feesA_after > feesA_before, "MM Fees A should increase");

        // Assert: MM Fees B unchanged
        assertEq(feesB_after, feesB_before, "MM Fees B should be unchanged");
        assertEq(feesB_after, 0, "MM Fees B should still be 0");
    }

    // =========================================================================
    // NEW INTEGRATION TESTS
    // =========================================================================

    /**
     * @notice Test a multi-pool user journey: Deposit A, Borrow A, Swap B, Repay A, Withdraw A
     */
    function test_Integration_DepositBorrowSwapRepayWithdraw_MultiPool() public {
        address user = charlie;
        uint256 initialDeposit = 1000 * 1e18;
        uint256 borrowSharesA = 100 * 1e18;
        uint256 swapAmountB = 50 * 1e18; // Amount of T1 to swap in Pool B

        // 1. Deposit Collateral into Pool A (T0/T1)
        vm.startPrank(user);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        IMarginData.BatchAction[] memory depositActionsA = new IMarginData.BatchAction[](2);
        depositActionsA[0] = createDepositAction(address(token0), initialDeposit);
        depositActionsA[1] = createDepositAction(address(token1), initialDeposit);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), depositActionsA);
        vm.stopPrank();
        IMarginData.Vault memory vaultA_afterDeposit = marginManager.vaults(poolIdA, user);
        assertTrue(vaultA_afterDeposit.token0Balance > 0 && vaultA_afterDeposit.token1Balance > 0, "Deposit A failed");
        console2.log("Step 1: Deposit A OK");

        // 2. Borrow from Pool A
        vm.startPrank(user);
        IMarginData.BatchAction[] memory borrowActionsA = new IMarginData.BatchAction[](1);
        borrowActionsA[0] = createBorrowAction(borrowSharesA, user);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), borrowActionsA);
        vm.stopPrank();
        IMarginData.Vault memory vaultA_afterBorrow = marginManager.vaults(poolIdA, user);
        assertTrue(vaultA_afterBorrow.debtShares >= borrowSharesA, "Borrow A failed (debt)"); // gte due to potential interest
        uint256 rentedA_afterBorrow = marginManager.rentedLiquidity(poolIdA);
        assertTrue(rentedA_afterBorrow > 0, "Borrow A failed (rented)");
        uint256 userT0_afterBorrow = token0.balanceOf(user);
        uint256 userT1_afterBorrow = token1.balanceOf(user);
        console2.log("Step 2: Borrow A OK");

        // 3. Add Liquidity to Pool B (T1/TC) to enable swaps
        // Need another user (lender) to add liquidity here
        address lenderB = bob;
        uint256 liqAmountB = 500 * 1e18;
        addFullRangeLiquidity(lenderB, poolIdB, liqAmountB, liqAmountB, 0); // Bob adds T1/TC liquidity
        console2.log("Step 3a: Liquidity added to Pool B OK");

        // User (Charlie) swaps borrowed tokens (e.g., T1 from Pool A borrow) in Pool B (T1->TC)
        vm.startPrank(user);
        token1.approve(address(poolManager), type(uint256).max);
        BalanceDelta swapDeltaB = swapExactInput(user, poolKeyB, true, swapAmountB, 0); // T1->TC (zeroForOne=true for T1/TC pool)
        vm.stopPrank();
        int128 amountSwappedOutB = swapDeltaB.amount1() < 0 ? -swapDeltaB.amount1() : swapDeltaB.amount1(); // Amount of TC received
        assertTrue(amountSwappedOutB > 0, "Swap B failed");
        uint256 userTC_afterSwap = MockERC20(Currency.unwrap(poolKeyB.currency1)).balanceOf(user);
        assertTrue(userTC_afterSwap > 0, "User should have TC after swap");
        console2.log("Step 3b: Swap B OK");

        // Warp time to accrue interest on Pool A borrow
        vm.warp(block.timestamp + 1 days);

        // 4. Repay Debt in Pool A (using vault balance flag)
        IMarginData.Vault memory vaultA_beforeRepay = marginManager.vaults(poolIdA, user);
        uint256 debtToRepay = vaultA_beforeRepay.debtShares; // Repay full current debt
        vm.startPrank(user);
        IMarginData.BatchAction[] memory repayActionsA = new IMarginData.BatchAction[](1);
        // Repay using vault balance - user needs sufficient T0/T1 in vault
        repayActionsA[0] = createRepayAction(debtToRepay, true);
        fullRange.executeBatch(PoolId.unwrap(poolIdA), repayActionsA);
        vm.stopPrank();
        IMarginData.Vault memory vaultA_afterRepay = marginManager.vaults(poolIdA, user);
        assertTrue(vaultA_afterRepay.debtShares < vaultA_beforeRepay.debtShares, "Repay A failed (debt)");
        // Vault collateral should decrease
        assertTrue(vaultA_afterRepay.token0Balance < vaultA_afterBorrow.token0Balance || vaultA_afterRepay.token1Balance < vaultA_afterBorrow.token1Balance, "Repay A failed (collateral)");
        console2.log("Step 4: Repay A OK");

        // 5. Withdraw Remaining Collateral from Pool A
        vm.startPrank(user);
        uint256 withdrawT0 = vaultA_afterRepay.token0Balance;
        uint256 withdrawT1 = vaultA_afterRepay.token1Balance;
        IMarginData.BatchAction[] memory withdrawActionsA = new IMarginData.BatchAction[](2);
        uint8 actionCount = 0;
        if (withdrawT0 > 0) withdrawActionsA[actionCount++] = createWithdrawAction(address(token0), withdrawT0, user);
        if (withdrawT1 > 0) withdrawActionsA[actionCount++] = createWithdrawAction(address(token1), withdrawT1, user);
        if (actionCount < 2) assembly { mstore(withdrawActionsA, actionCount) }
        if (actionCount > 0) fullRange.executeBatch(PoolId.unwrap(poolIdA), withdrawActionsA);
        vm.stopPrank();
        IMarginData.Vault memory vaultA_final = marginManager.vaults(poolIdA, user);
        assertEq(vaultA_final.token0Balance, 0, "Withdraw A failed (T0)");
        assertEq(vaultA_final.token1Balance, 0, "Withdraw A failed (T1)");
        assertEq(vaultA_final.debtShares, 0, "Withdraw A failed (debt)");
        console2.log("Step 5: Withdraw A OK");

        // Check Pool B state remained isolated (except for Bob's liquidity add & Charlie's swap effects)
        IMarginData.Vault memory vaultB_final = marginManager.vaults(poolIdB, user);
        // Charlie's vault B should be empty as he only swapped
        assertEq(vaultB_final.token0Balance, 0, "User Vault B T0(T1) should be 0");
        assertEq(vaultB_final.token1Balance, 0, "User Vault B T1(TC) should be 0");
        assertEq(vaultB_final.debtShares, 0, "User Vault B debt should be 0");
    }
} 

// --- Helper --- 