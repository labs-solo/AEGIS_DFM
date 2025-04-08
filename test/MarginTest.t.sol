// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {MarginTestBase} from "./MarginTestBase.t.sol";
import {Margin} from "../src/Margin.sol";
import {LinearInterestRateModel} from "../src/LinearInterestRateModel.sol";
import {IInterestRateModel} from "../src/interfaces/IInterestRateModel.sol";
import {FeeReinvestmentManager} from "../src/FeeReinvestmentManager.sol";
import {IFeeReinvestmentManager} from "../src/interfaces/IFeeReinvestmentManager.sol";
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
import {MockPoolPolicyManager} from "./mocks/MockPoolPolicyManager.sol";

contract MarginTest is MarginTestBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Contracts specific to Margin tests
    LinearInterestRateModel rateModel; // Real model for some tests
    MockLinearInterestRateModel mockRateModel; // Mock model for controlled tests
    MockPoolPolicyManager mockPolicyManager; // Re-add state variable
    FeeReinvestmentManager feeManager; // Real fee manager

    // Test parameters
    uint256 constant PRECISION = 1e18;
    uint256 constant SECONDS_PER_YEAR = 365 days;
    uint256 protocolFeePercentage = (10 * PRECISION) / 100; // 10%
    uint256 maxRateYear = 1 * PRECISION; // 100%

    // Users
    address borrower = alice;
    address lender = bob;
    address authorizedReinvestor = charlie;

    function setUp() public override {
        // Call base setup first
        MarginTestBase.setUp();

        // Deploy a mock Rate Model first
        mockRateModel = new MockLinearInterestRateModel();

        // Deploy the real Rate Model
        rateModel = new LinearInterestRateModel(
            governance,
            (2 * PRECISION) / 100,
            (10 * PRECISION) / 100,
            (80 * PRECISION) / 100,
            5 * PRECISION,
            (95 * PRECISION) / 100,
            1 * PRECISION
        );

        // Configure Margin (which is fullRange instance from base)
        vm.startPrank(governance);
        policyManager.setAuthorizedReinvestor(authorizedReinvestor, true);
        policyManager.setProtocolFeePercentage(protocolFeePercentage);
        address spotPolicyManager = address(fullRange.policyManager());
        address soloGov = address(policyManager.getSoloGovernance());
        
        console2.log("MarginTest.setUp: governance address =", governance);
        console2.log("MarginTest.setUp: fullRange.policyManager() address =", spotPolicyManager);
        console2.log("MarginTest.setUp: soloGov from test policyManager =", soloGov);
        fullRange.setInterestRateModel(address(rateModel));
        
        // Deploy FeeManager and set proper policies
        feeManager = new FeeReinvestmentManager(
            poolManager,
            address(fullRange),
            governance,
            policyManager
        );
        address reinvestPolicy = address(feeManager);
        console2.log("MarginTest.setUp: REINVESTMENT policy address =", reinvestPolicy);
        console2.log("MarginTest.setUp: feeManager address =", address(feeManager));
        
        // Set the policy so that the fee manager is authorized
        policyManager.setPolicy(poolId, IPoolPolicy.PolicyType.REINVESTMENT, reinvestPolicy);
        
        // Start prank as governance to call setters
        vm.startPrank(governance);
        // Also set the margin contract in the fee manager
        feeManager.setMarginContract(address(fullRange));
        // Log liquidityManager address before calling setter
        // console2.log("[MarginTest Setup Debug] liquidityManager address:", address(liquidityManager));
        // console2.log("[MarginTest Setup Debug] feeManager address:", address(feeManager));
        // console2.log("[MarginTest Setup Debug] governance address:", address(governance));
        feeManager.setLiquidityManager(address(liquidityManager));
        vm.stopPrank(); // Stop governance prank

        // --- Add Initial Pool Liquidity --- 
        uint128 initialPoolLiquidity = 1000 * 1e18;
        addFullRangeLiquidity(alice, initialPoolLiquidity);

        // Mint initial COLLATERAL for tests (as lender)
        uint128 initialCollateral = 1000 * 1e18;
        vm.startPrank(lender);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        fullRange.depositCollateral(poolId, initialCollateral, initialCollateral);
        vm.stopPrank();
    }

    // --- Helper --- 
    function setupMockModel() internal {
        vm.startPrank(governance);
        fullRange.setInterestRateModel(address(mockRateModel));
        vm.stopPrank();
    }

    function restoreRealModel() internal {
         vm.startPrank(governance);
        fullRange.setInterestRateModel(address(rateModel));
        vm.stopPrank();
    }

    // ===== PHASE 4 TESTS =====

    // --- Accrual & Fees Tests ---

    function test_Accrual_UpdatesMultiplier() public {
        uint256 initialMultiplier = fullRange.interestMultiplier(poolId);
        assertEq(initialMultiplier, PRECISION, "Initial multiplier should be PRECISION");

        // Deposit collateral for borrower first - INCREASED COLLATERAL
        uint256 borrowerCollateral = 2000 * 1e18; // Increased from 100e18
        vm.startPrank(borrower);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        fullRange.depositCollateral(poolId, borrowerCollateral, borrowerCollateral);
        vm.stopPrank();

        // Advance time and block to avoid reentrancy conflicts
        vm.warp(block.timestamp + 1);

        uint256 borrowShares = 100 * 1e18;
        vm.startPrank(borrower);
        fullRange.borrow(poolId, borrowShares);
        vm.stopPrank();

        uint256 timeToWarp = 30 days;
        vm.warp(block.timestamp + timeToWarp);

        vm.prank(lender);
        fullRange.depositCollateral(poolId, 1, 1);
        vm.stopPrank();

        uint256 finalMultiplier = fullRange.interestMultiplier(poolId);
        console2.log("Initial Multiplier:", initialMultiplier);
        console2.log("Final Multiplier:", finalMultiplier);

        assertTrue(finalMultiplier > initialMultiplier, "Multiplier should increase");

        (uint256 reserve0, uint256 reserve1, uint128 totalShares) = fullRange.getPoolReservesAndShares(poolId);
        uint256 rentedShares = fullRange.rentedLiquidity(poolId);
        uint256 utilization = rateModel.getUtilizationRate(poolId, rentedShares, totalShares);
        uint256 ratePerSecond = rateModel.getBorrowRate(poolId, utilization);
        uint256 expectedMultiplier = FullMath.mulDiv(
            initialMultiplier,
            PRECISION + (ratePerSecond * timeToWarp),
            PRECISION
        );

        assertApproxEqAbs(finalMultiplier, expectedMultiplier, 1, "Multiplier mismatch");
    }

    function test_Accrual_CalculatesProtocolFees() public {
        uint256 initialFees = fullRange.accumulatedFees(poolId);
        assertEq(initialFees, 0, "Initial fees should be 0");

        // INCREASED COLLATERAL for borrower first
        uint256 borrowerCollateral = 2000 * 1e18; // Increased from default/none
        vm.startPrank(borrower);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        fullRange.depositCollateral(poolId, borrowerCollateral, borrowerCollateral);
        vm.stopPrank();

        // Borrow
        uint256 borrowShares = 100 * 1e18;
        vm.startPrank(borrower);
        fullRange.borrow(poolId, borrowShares);
        vm.stopPrank();

        uint256 timeToWarp = 60 days;
        vm.warp(block.timestamp + timeToWarp);
        
        uint256 currentMultiplierBeforeAccrual = fullRange.interestMultiplier(poolId);

        vm.prank(lender);
        fullRange.depositCollateral(poolId, 1, 1);
        vm.stopPrank();

        uint256 finalFees = fullRange.accumulatedFees(poolId);
        console2.log("Final Accumulated Fees (Shares):", finalFees);
        assertTrue(finalFees > initialFees, "Fees should increase");

        (uint256 reserve0, uint256 reserve1, uint128 totalShares) = fullRange.getPoolReservesAndShares(poolId);
        uint256 rentedShares = fullRange.rentedLiquidity(poolId); // Rented shares don't change during pure accrual
        uint256 utilization = rateModel.getUtilizationRate(poolId, rentedShares, totalShares);
        uint256 ratePerSecond = rateModel.getBorrowRate(poolId, utilization);
        
        uint256 newMultiplier = fullRange.interestMultiplier(poolId); // Multiplier after accrual
        
        uint256 interestAmountShares = FullMath.mulDiv(rentedShares, newMultiplier - currentMultiplierBeforeAccrual, currentMultiplierBeforeAccrual);
        uint256 expectedFeeShares = FullMath.mulDiv(interestAmountShares, protocolFeePercentage, PRECISION);

        assertApproxEqAbs(finalFees, expectedFeeShares, 1, "Fee mismatch");
    }

    function test_GetInterestRatePerSecond() public {
         // INCREASED COLLATERAL for borrower first
        uint256 borrowerCollateral = 2000 * 1e18; // Increased from default/none
        vm.startPrank(borrower);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        fullRange.depositCollateral(poolId, borrowerCollateral, borrowerCollateral);
        vm.stopPrank();
        
         // Borrow 50% of initial liquidity
        // uint256 borrowShares = 500 * 1e18; // This needs context of total liquidity
        (,, uint128 totalLPShares) = fullRange.getPoolReservesAndShares(poolId);
        uint256 borrowShares = uint256(totalLPShares) / 2; // Borrow 50% of current total shares

        vm.startPrank(borrower);
        fullRange.borrow(poolId, borrowShares);
        vm.stopPrank();

        (,, uint128 totalShares) = fullRange.getPoolReservesAndShares(poolId);
        uint256 rentedShares = fullRange.rentedLiquidity(poolId);
        uint256 utilization = rateModel.getUtilizationRate(poolId, rentedShares, totalShares);
        uint256 expectedRate = rateModel.getBorrowRate(poolId, utilization);

        uint256 actualRate = fullRange.getInterestRatePerSecond(poolId);
        assertEq(actualRate, expectedRate, "Rate mismatch");
    }

    function test_FeeManagerInteraction_GetAndResetFees() public {
        // --- Setup: Accrue Fees Naturally ---
        // INCREASED COLLATERAL for borrower first
        uint256 borrowerCollateral = 2000 * 1e18;
        vm.startPrank(borrower);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        fullRange.depositCollateral(poolId, borrowerCollateral, borrowerCollateral);
        // Borrow some shares
        uint256 borrowShares = 100 * 1e18;
        fullRange.borrow(poolId, borrowShares);
        vm.stopPrank();
        // Warp time
        uint256 timeToWarp = 10 days;
        vm.warp(block.timestamp + timeToWarp);
        // Trigger accrual
        vm.prank(lender); // Use lender to trigger accrual
        fullRange.depositCollateral(poolId, 1, 1);
        vm.stopPrank();
        // --- End Setup ---

        uint256 accumulatedFeeSharesBefore = fullRange.accumulatedFees(poolId);
        assertTrue(accumulatedFeeSharesBefore > 0, "Fees should exist after accrual"); // Updated revert string

        // MODIFIED: Use feeManager.triggerInterestFeeProcessing instead of directly calling resetAccumulatedFees
        vm.startPrank(authorizedReinvestor);
        bool success = feeManager.triggerInterestFeeProcessing(poolId);
        vm.stopPrank();

        // MODIFIED: Check processing was successful  
        assertTrue(success, "Fee processing should succeed");
        
        // Verify fees are actually reset to zero
        assertEq(fullRange.accumulatedFees(poolId), 0, "Fees not zero after reset");

        // Verify unauthorized access is rejected
        vm.startPrank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Errors.FeeReinvestNotAuthorized.selector, address(0xBAD)));
        feeManager.triggerInterestFeeProcessing(poolId);
        vm.stopPrank();
    }

    // --- Utilization Limit Tests ---

    function test_Borrow_Revert_MaxPoolUtilizationExceeded() public {
        uint256 maxUtil = rateModel.maxUtilizationRate(); 
        (,, uint128 totalShares) = fullRange.getPoolReservesAndShares(poolId);
        uint256 targetBorrowedNearMax = maxUtil * totalShares / PRECISION - 1e10;
        uint256 collateralAmount = 5000 * 1e18;

        vm.startPrank(borrower);
        // Approve before depositing collateral
        token0.approve(address(fullRange), collateralAmount);
        token1.approve(address(fullRange), collateralAmount);
        fullRange.depositCollateral(poolId, collateralAmount, collateralAmount);
        fullRange.borrow(poolId, targetBorrowedNearMax);
        vm.stopPrank();

        uint256 currentBorrowed = fullRange.rentedLiquidity(poolId);
        uint256 currentUtil = rateModel.getUtilizationRate(poolId, currentBorrowed, totalShares);
        assertTrue(currentUtil < maxUtil, "Util below max");

        uint256 sharesToExceedLimit = (maxUtil * totalShares / PRECISION) - currentBorrowed + 1e10;
        uint256 finalBorrowed = currentBorrowed + sharesToExceedLimit;
        uint256 finalUtil = rateModel.getUtilizationRate(poolId, finalBorrowed, totalShares);

        vm.startPrank(borrower);
        vm.expectRevert(abi.encodeWithSelector(Errors.MaxPoolUtilizationExceeded.selector, finalUtil, maxUtil));
        fullRange.borrow(poolId, sharesToExceedLimit);
        vm.stopPrank();
    }

     function test_Borrow_Success_AtMaxUtilization() public {
        uint256 maxUtil = rateModel.maxUtilizationRate();
        (,, uint128 totalShares) = fullRange.getPoolReservesAndShares(poolId);
        uint256 targetBorrowedAtMax = maxUtil * totalShares / PRECISION;
        uint256 collateralAmount = 5000 * 1e18;

        vm.startPrank(borrower);
        // Approve before depositing collateral
        token0.approve(address(fullRange), collateralAmount);
        token1.approve(address(fullRange), collateralAmount);
        fullRange.depositCollateral(poolId, collateralAmount, collateralAmount);
        fullRange.borrow(poolId, targetBorrowedAtMax);
        vm.stopPrank();

        uint256 currentBorrowed = fullRange.rentedLiquidity(poolId);
        uint256 currentUtil = rateModel.getUtilizationRate(poolId, currentBorrowed, totalShares);

        assertApproxEqAbs(currentUtil, maxUtil, 1, "Util not at max");
    }

    // --- Fee Reinvestment Manager Trigger Test ---

    function test_FeeManager_TriggerInterestFeeProcessing() public {
         // INCREASED COLLATERAL for borrower first
        uint256 borrowerCollateral = 2000 * 1e18; // Increased from default/none
        vm.startPrank(borrower);
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        fullRange.depositCollateral(poolId, borrowerCollateral, borrowerCollateral);
        vm.stopPrank();

        // --- Accrue some fees first ---
        uint256 borrowShares = 100 * 1e18;
        vm.startPrank(borrower);
        fullRange.borrow(poolId, borrowShares);
        vm.stopPrank();
        uint256 timeToWarp = 10 days;
        vm.warp(block.timestamp + timeToWarp);
        vm.prank(lender);
        fullRange.depositCollateral(poolId, 1, 1);
        vm.stopPrank();

        uint256 accumulatedFeeSharesBefore = fullRange.accumulatedFees(poolId);
        assertTrue(accumulatedFeeSharesBefore > 0, "Fees should exist");

        vm.startPrank(authorizedReinvestor);
        // Call the function and check its return value
        bool success = feeManager.triggerInterestFeeProcessing(poolId);
        vm.stopPrank();

        assertTrue(success, "Trigger should succeed");

        uint256 accumulatedFeeSharesAfter = fullRange.accumulatedFees(poolId);
        assertEq(accumulatedFeeSharesAfter, 0, "Fees not zero after trigger");
    }

    function test_FeeManager_TriggerInterestFeeProcessing_NoFees() public {
         uint256 accumulatedFeeSharesBefore = fullRange.accumulatedFees(poolId);
         assertEq(accumulatedFeeSharesBefore, 0, "Fees not zero initially");

        vm.startPrank(authorizedReinvestor);
        bool success = feeManager.triggerInterestFeeProcessing(poolId);
        vm.stopPrank();

        assertTrue(success, "Trigger should succeed even if no fees");
        uint256 accumulatedFeeSharesAfter = fullRange.accumulatedFees(poolId);
        assertEq(accumulatedFeeSharesAfter, 0, "Fees not zero after trigger (no fees)");
    }

    function test_Revert_FeeManager_TriggerInterestFeeProcessing_Unauthorized() public {
         vm.startPrank(address(0xBAD));
         vm.expectRevert(abi.encodeWithSelector(Errors.FeeReinvestNotAuthorized.selector, address(0xBAD)));
         feeManager.triggerInterestFeeProcessing(poolId);
         vm.stopPrank();
    }

    function test_Revert_FeeManager_TriggerInterestFeeProcessing_MarginNotSet() public {
        // Create a new fee manager that doesn't have the margin contract set
        FeeReinvestmentManager emptyFeeManager = new FeeReinvestmentManager(
            poolManager,
            address(fullRange),
            governance,
            policyManager
        );
        
        // Don't set the margin contract - this will cause the expected revert
        
        vm.startPrank(authorizedReinvestor);
        vm.expectRevert(Errors.MarginContractNotSet.selector);
        emptyFeeManager.triggerInterestFeeProcessing(poolId);
        vm.stopPrank();
    }

} 

// --- Helper --- 