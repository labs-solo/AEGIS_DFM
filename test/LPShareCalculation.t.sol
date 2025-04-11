// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {MarginTestBase} from "./MarginTestBase.t.sol"; // Import the refactored base
import {Strings} from "v4-core/lib/openzeppelin-contracts/contracts/utils/Strings.sol";
import "src/Margin.sol"; // Inherited
import "src/MarginManager.sol"; // Inherited
import "src/FullRangeLiquidityManager.sol"; // Inherited
import "src/interfaces/ISpot.sol"; // Inherited
import "src/interfaces/IPoolPolicy.sol"; // Inherited
import "src/interfaces/IMarginData.sol"; // Inherited
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol"; // Inherited
import {PoolKey} from "v4-core/src/types/PoolKey.sol"; // Inherited
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol"; // Inherited
import {TickMath} from "v4-core/src/libraries/TickMath.sol"; // Inherited
import {MockERC20} from "../src/token/MockERC20.sol";
import {MathUtils} from "src/libraries/MathUtils.sol";
import {FullRangePositions} from "src/token/FullRangePositions.sol"; // Already in base?

// Removed direct V4 imports, they are handled by the base or inherited types
// Removed MockPoolPolicy, use real one from base
// Removed Harness contract, use MathUtils directly

using SafeCast for uint256;
using SafeCast for int256;
using MathUtils for uint256; // Use MathUtils for uint256
using PoolIdLibrary for PoolKey;
using CurrencyLibrary for Currency;
using CurrencyLibrary for address; // Added for convenience
using Strings for uint256;

contract LPShareCalculationTest is MarginTestBase { // Inherit from MarginTestBase
    // --- Inherited State Variables ---
    // poolManager, liquidityManager, policyManager, marginManager, margin (fullRange),
    // token0, token1, token2, positions, interestRateModel, etc.
    // alice, bob, charlie

    // --- Pool Data for Tests ---
    PoolKey poolKeyA; // Main pool for tests
    PoolId poolIdA;
    PoolKey emptyPoolKey; // Zero liquidity pool
    PoolId emptyPoolId;

    // Constants (inherited DEFAULT_FEE, TICK_SPACING, etc.)
    uint160 public constant INITIAL_SQRT_PRICE_X96 = 79228162514264337593543950336; // sqrt(1) << 96
    uint256 public constant CONVERSION_TOLERANCE = 1e15; // 0.1% tolerance for approx checks
    uint256 public constant SLIPPAGE_TOLERANCE = 1e16; // 1% tolerance for round trip

    uint256 internal aliceInitialShares; // Store Alice's shares from setup

    // --- Setup ---
    function setUp() public override {
        // Call base setup first (deploys shared contracts, tokens T0, T1, T2)
        MarginTestBase.setUp();

        // --- Initialize Main Test Pool (Pool A: T0/T1) ---
        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));

        // console.log("[LPShareCalc.setUp] Creating Pool A (T0/T1)...");
        vm.startPrank(deployer);
        (poolIdA, poolKeyA) = createPoolAndRegister(
            address(fullRange), address(liquidityManager),
            currency0, currency1, DEFAULT_FEE, DEFAULT_TICK_SPACING, INITIAL_SQRT_PRICE_X96
        );
        vm.stopPrank();
        // console.log("[LPShareCalc.setUp] Pool A created, ID:", PoolId.unwrap(poolIdA));

        // --- Initialize Empty Pool (T1/T2) ---
        // Use T1 and T2 already deployed in base
        Currency currency2 = Currency.wrap(address(token2));
        // console.log("[LPShareCalc.setUp] Creating Empty Pool (T1/T2)...");
        vm.startPrank(deployer);
        (emptyPoolId, emptyPoolKey) = createPoolAndRegister(
            address(fullRange), address(liquidityManager),
            currency1, currency2, DEFAULT_FEE, DEFAULT_TICK_SPACING, INITIAL_SQRT_PRICE_X96
        );
        vm.stopPrank();
        // console.log("[LPShareCalc.setUp] Empty Pool created, ID:", PoolId.unwrap(emptyPoolId));

        // --- Add Initial Liquidity to Pool A ---
        vm.startPrank(alice);
        uint256 initialDepositAmount = 10_000e18;
        token0.approve(address(fullRange), type(uint256).max);
        token1.approve(address(fullRange), type(uint256).max);
        addFullRangeLiquidity(alice, poolIdA, initialDepositAmount, initialDepositAmount, 0);

        // Store Alice's shares (approximation)
        aliceInitialShares = liquidityManager.poolTotalShares(poolIdA);
        assertTrue(aliceInitialShares > 0, "SETUP: Alice shares > 0");
        vm.stopPrank();

        // console.log("[LPShareCalc.setUp] Completed.");
    }

    // --- Helper to get current pool state for MathUtils --- 
    function _getPoolState(PoolId _poolId) internal view returns (uint256 reserve0, uint256 reserve1, uint128 totalShares) {
        totalShares = liquidityManager.poolTotalShares(_poolId);
        (reserve0, reserve1) = liquidityManager.getPoolReserves(_poolId);
    }

    // =========================================================================
    // Test #1: LP-Share Calculation (Refactored)
    // =========================================================================

    function testLpEquivalentStandardConversion() public {
        (uint256 reserve0, uint256 reserve1, uint128 totalShares) = _getPoolState(poolIdA);
        assertTrue(totalShares > 0, "PRE-TEST: Total shares > 0");

        uint256 amount0_1pct = reserve0 / 100;
        uint256 amount1_1pct = reserve1 / 100;
        uint256 expectedShares_1pct = uint256(totalShares) / 100;
        uint256 calculatedShares = MathUtils.calculateProportionalShares(amount0_1pct, amount1_1pct, totalShares, reserve0, reserve1, false);
        assertApproxEqRel(calculatedShares, expectedShares_1pct, CONVERSION_TOLERANCE, "TEST 1: Balanced 1% input");

        uint256 amount0_2pct = reserve0 / 50;
        calculatedShares = MathUtils.calculateProportionalShares(amount0_2pct, amount1_1pct, totalShares, reserve0, reserve1, false);
        assertApproxEqRel(calculatedShares, expectedShares_1pct, CONVERSION_TOLERANCE, "TEST 2: Imbalanced (more token0)");

        uint256 amount1_2pct = reserve1 / 50;
        calculatedShares = MathUtils.calculateProportionalShares(amount0_1pct, amount1_2pct, totalShares, reserve0, reserve1, false);
        assertApproxEqRel(calculatedShares, expectedShares_1pct, CONVERSION_TOLERANCE, "TEST 3: Imbalanced (more token1)");
    }

    function testLpEquivalentZeroInputs() public {
        (uint256 reserve0, uint256 reserve1, uint128 totalShares) = _getPoolState(poolIdA);
        assertTrue(totalShares > 0, "PRE-TEST: Total shares > 0");
        uint256 amount1_1pct = reserve1 / 100; // Use reserve1 for non-zero amount

        assertEq(MathUtils.calculateProportionalShares(0, 0, totalShares, reserve0, reserve1, false), 0, "TEST 4.1: Both zero inputs");
        assertEq(MathUtils.calculateProportionalShares(0, amount1_1pct, totalShares, reserve0, reserve1, false), 0, "TEST 4.2: Zero token0 input");
        assertEq(MathUtils.calculateProportionalShares(reserve0 / 100, 0, totalShares, reserve0, reserve1, false), 0, "TEST 4.3: Zero token1 input");
    }

    function testLpEquivalentExtremeValues() public {
        (uint256 reserve0, uint256 reserve1, uint128 totalShares) = _getPoolState(poolIdA);
        assertTrue(totalShares > 0, "PRE-TEST: Total shares > 0");

        // Small Amounts (relative)
        uint256 amount0_tiny_rel = reserve0 / 100000;
        uint256 amount1_tiny_rel = reserve1 / 100000;
        uint256 expectedShares_tiny_rel = uint256(totalShares) / 100000;
        uint256 calculatedShares_tiny_rel = MathUtils.calculateProportionalShares(amount0_tiny_rel, amount1_tiny_rel, totalShares, reserve0, reserve1, false);
        if (expectedShares_tiny_rel > 0) {
            assertApproxEqRel(calculatedShares_tiny_rel, expectedShares_tiny_rel, 1e16, "TEST 5: Small (0.001%)"); // Higher tolerance ok
        } else {
            assertEq(calculatedShares_tiny_rel, 0, "TEST 5: Small (0.001%) expected zero");
        }

        // Very Tiny Amounts (absolute)
        uint256 calculatedShares_wei = MathUtils.calculateProportionalShares(1, 1, totalShares, reserve0, reserve1, false);
        assertTrue(calculatedShares_wei <= 1, "TEST 6: Tiny (1 wei) amounts");

        // Large Amounts (relative)
        uint256 amount0_large = reserve0 * 10;
        uint256 amount1_large = reserve1 * 10;
        uint256 expectedShares_large = uint256(totalShares) * 10;
        uint256 calculatedShares_large = MathUtils.calculateProportionalShares(amount0_large, amount1_large, totalShares, reserve0, reserve1, false);
        assertApproxEqRel(calculatedShares_large, expectedShares_large, CONVERSION_TOLERANCE, "TEST 7: Large (10x pool)");
    }

    function testLpEquivalentZeroLiquidityPool() public {
        (uint256 reserve0, uint256 reserve1, uint128 totalShares) = _getPoolState(emptyPoolId);
        assertEq(totalShares, 0, "PRE-TEST: Zero liquidity pool has zero shares");
        assertEq(MathUtils.calculateProportionalShares(1e18, 1e18, totalShares, reserve0, reserve1, false), 0, "TEST 8: Zero liquidity pool");
    }

    function testLpEquivalentStateChange() public {
        (uint256 reserve0_before, uint256 reserve1_before, uint128 totalShares_before) = _getPoolState(poolIdA);
        assertTrue(totalShares_before > 0, "PRE-TEST: Total shares > 0");

        // Bob deposits
        uint256 bobDepositAmount0 = reserve0_before / 2;
        uint256 bobDepositAmount1 = reserve1_before / 2;

        uint256 expectedBobShares = MathUtils.calculateProportionalShares(bobDepositAmount0, bobDepositAmount1, totalShares_before, reserve0_before, reserve1_before, false);

        // Use executeBatch for Bob's deposit via base helper
        addFullRangeLiquidity(bob, poolIdA, bobDepositAmount0, bobDepositAmount1, 0);

        // Verify shares approximately match prediction
        (,, uint128 totalShares_after_bob) = _getPoolState(poolIdA);
        uint256 actualBobShares = totalShares_after_bob - totalShares_before;
        assertApproxEqRel(actualBobShares, expectedBobShares, CONVERSION_TOLERANCE, "BOB-DEPOSIT: Actual vs Predicted mismatch");

        // Test share calculation after state change
        (uint256 reserve0_after, uint256 reserve1_after, uint128 totalShares_after) = _getPoolState(poolIdA);
        assertTrue(totalShares_after > totalShares_before, "POST-DEPOSIT: Shares increased");
        uint256 amount0_new_2pct = reserve0_after / 50;
        uint256 amount1_new_2pct = reserve1_after / 50;
        uint256 expectedShares_new_2pct = uint256(totalShares_after) / 50;
        uint256 calculatedShares_new = MathUtils.calculateProportionalShares(amount0_new_2pct, amount1_new_2pct, totalShares_after, reserve0_after, reserve1_after, false);
        assertApproxEqRel(calculatedShares_new, expectedShares_new_2pct, CONVERSION_TOLERANCE, "TEST 10: Post-state-change");
    }

    // =========================================================================
    // Test #2: Shares-to-Token Calculation & Round Trip (Refactored)
    // =========================================================================

    // --- Helper Functions (Moved to contract level) ---

    /** @notice Helper to verify round-trip conversion quality and economic properties */
    function verifyRoundTrip(uint256 startToken0, uint256 startToken1, PoolId _poolId, string memory testName) internal returns (uint256 slippage0, uint256 slippage1) {
        // console.log(string(abi.encodePacked("--- Verifying Round Trip for: ", testName, " ---")));
        (uint256 reserve0, uint256 reserve1, uint128 totalShares) = _getPoolState(_poolId);
        // console.log(string(abi.encodePacked("  Pool State - R0: ", reserve0.toString(), " R1: ", reserve1.toString(), " TotalShares: ", uint256(totalShares).toString())));
        if (totalShares == 0) {
             // console.log("  Skipping round trip on empty pool.");
             return (0,0);
        }

        // console.log(string(abi.encodePacked("  Inputs - startT0: ", startToken0.toString(), " startT1: ", startToken1.toString())));

        // Token -> Shares
        uint256 shares = MathUtils.calculateProportionalShares(startToken0, startToken1, totalShares, reserve0, reserve1, false);
        // console.log(string(abi.encodePacked("  Calculated Shares: ", shares.toString())));

        // Shares -> Token
        (uint256 endToken0, uint256 endToken1) = MathUtils.computeWithdrawAmounts(totalShares, shares, reserve0, reserve1, false);
        // console.log(string(abi.encodePacked("  Outputs - endT0: ", endToken0.toString(), " endT1: ", endToken1.toString())));

        // Calculate slippage relative to input amounts
        slippage0 = startToken0 > 0 ? ((startToken0 - endToken0) * 1e18) / startToken0 : 0;
        slippage1 = startToken1 > 0 ? ((startToken1 - endToken1) * 1e18) / startToken1 : 0;
        // console.log(string(abi.encodePacked("  Slippage - slipT0: ", slippage0.toString(), " slipT1: ", slippage1.toString(), " (Tolerance: ", SLIPPAGE_TOLERANCE.toString(), ")")));

        // Assert economic properties
        assertTrue(endToken0 <= startToken0, string(abi.encodePacked(testName, ": End T0 <= Start T0")));
        assertTrue(endToken1 <= startToken1, string(abi.encodePacked(testName, ": End T1 <= Start T1")));

        // Check slippage tolerance, especially for balanced inputs
        if (startToken0 > 1e6 && startToken1 > 1e6 && startToken0 == startToken1) {
            assertTrue(slippage0 <= SLIPPAGE_TOLERANCE, "T0 Slippage too high for balanced input");
            assertTrue(slippage1 <= SLIPPAGE_TOLERANCE, "T1 Slippage too high for balanced input");
        }
        // console.log("--- Verification Complete ---");
        return (slippage0, slippage1);
    }

    /** @notice Create an imbalanced pool with the specified token ratio */
    function createImbalancedPool(
        uint256 ratio0,
        uint256 ratio1
    ) internal returns (PoolId _poolId, PoolKey memory _key) {
        // Use existing T0 and T2 (from base) for the imbalanced pool
        MockERC20 t0 = token0;
        MockERC20 t1 = token2;
        address user = deployer; // Use deployer to create and fund

        deal(address(t0), user, ratio0);
        deal(address(t1), user, ratio1);

        // Create Pool (T0/T2)
        Currency currencyT0 = Currency.wrap(address(t0));
        Currency currencyT1 = Currency.wrap(address(t1));
        vm.startPrank(user);
        (_poolId, _key) = createPoolAndRegister(
            address(fullRange), address(liquidityManager),
            currencyT0, currencyT1, DEFAULT_FEE, DEFAULT_TICK_SPACING, INITIAL_SQRT_PRICE_X96
        );

        // Deposit initial amounts
        addFullRangeLiquidity(user, _poolId, ratio0, ratio1, 0);
        vm.stopPrank();

        // Verify deposit worked (optional check)
        (,,uint128 ts) = _getPoolState(_poolId);
        assertTrue(ts > 0, "IMBALANCED SETUP: Deposit failed, zero shares");

        return (_poolId, _key);
    }

    // --- Round Trip Tests ---

    function testRoundTripBalanced() public {
        (uint256 reserve0, uint256 reserve1,) = _getPoolState(poolIdA);
        verifyRoundTrip(reserve0 / 10, reserve1 / 10, poolIdA, "Balanced 10%");
        verifyRoundTrip(reserve0, reserve1, poolIdA, "Balanced 100%");
        verifyRoundTrip(reserve0 * 2, reserve1 * 2, poolIdA, "Balanced 200%");
    }

    function testRoundTripImbalanced() public {
        (uint256 reserve0, uint256 reserve1,) = _getPoolState(poolIdA);
        verifyRoundTrip(reserve0 / 10, reserve1 / 5, poolIdA, "Imbalanced T1 Heavy");
        verifyRoundTrip(reserve0 / 5, reserve1 / 10, poolIdA, "Imbalanced T0 Heavy");
    }

    function testRoundTripSingleToken() public {
        (uint256 reserve0, uint256 reserve1,) = _getPoolState(poolIdA);
        verifyRoundTrip(reserve0 / 10, 0, poolIdA, "Single Token T0");
        verifyRoundTrip(0, reserve1 / 10, poolIdA, "Single Token T1");
    }

    function testRoundTripExtremeReserves() public {
        // Create a pool with highly skewed reserves
        (PoolId imbalancedPoolId,) = createImbalancedPool(1e24, 1e18); // 1M : 1 ratio
        (uint256 r0, uint256 r1,) = _getPoolState(imbalancedPoolId);

        // Test with amounts proportional to the new, skewed reserves
        verifyRoundTrip(r0 / 10, r1 / 10, imbalancedPoolId, "Imbalanced Pool (10%)");
        verifyRoundTrip(r0, r1, imbalancedPoolId, "Imbalanced Pool (100%)");
        // Test with amounts *not* proportional
        verifyRoundTrip(r0 / 100, r1, imbalancedPoolId, "Imbalanced Pool (Mixed Ratio 1)");
        verifyRoundTrip(r0, r1 / 100, imbalancedPoolId, "Imbalanced Pool (Mixed Ratio 2)");
    }

    function testRoundTripZeroLiquidity() public {
        verifyRoundTrip(1e18, 1e18, emptyPoolId, "Zero Liquidity Pool");
    }

     function testRoundTripVerySmallAmounts() public {
        // Test with 1 wei inputs
        verifyRoundTrip(1, 1, poolIdA, "Very Small (1 wei)");
        verifyRoundTrip(100, 100, poolIdA, "Very Small (100 wei)");
    }

    // Removed batch helper functions - inherit from base if needed

} // Close contract definition 