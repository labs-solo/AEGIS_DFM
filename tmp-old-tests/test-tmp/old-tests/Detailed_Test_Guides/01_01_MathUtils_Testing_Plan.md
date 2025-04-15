# Section 1.1: Math Utilities Testing Plan

This document outlines the testing plan for the mathematical utility functions found in `src/libraries/MathUtils.sol`, as per Section 1.1 of the Solo Hook System Testing Checklist.

## 1. Identified Math Functions

The following functions were identified in `src/libraries/MathUtils.sol`:

*   `PRECISION()`: Returns `PrecisionConstants.PRECISION`.
*   `PPM_SCALE()`: Returns `PrecisionConstants.PPM_SCALE`.
*   `clampTick(int24 tick)`: Clamps a tick within `TickMath.MIN_TICK` and `TickMath.MAX_TICK`.
*   `sqrt(uint256 x)`: Calculates square root using `FixedPointMathLib.sqrt`.
*   `absDiff(int24 a, int24 b)`: Calculates absolute difference using assembly.
*   `calculateGeometricMean(uint256 a, uint256 b)`: Calculates `sqrt(a * b)` with overflow handling.
*   `min(uint256 a, uint256 b)`: Returns the minimum of two uint256.
*   `max(uint256 a, uint256 b)`: Returns the maximum of two uint256.
*   `calculateGeometricShares(uint256 amount0, uint256 amount1, bool withMinimumLiquidity)`: Calculates shares based on geometric mean, potentially locking minimum liquidity.
*   `calculateGeometricShares(uint256 amount0, uint256 amount1)`: Overloaded version without minimum liquidity locking.
*   `calculateProportionalShares(...)`: Calculates shares for subsequent deposits based on reserves and total shares. Uses `calculateProportional`.
*   `calculatePodShares(uint256 amount, uint256 totalShares, uint256 totalValue)`: Calculates shares based on amount, total shares, and total value. Uses `calculateProportional`.
*   `calculateProportional(uint256 numerator, uint256 shares, uint256 denominator, bool roundUp)`: Core proportional calculation using `FullMath.mulDiv` or `FullMath.mulDivRoundingUp`.
*   `computeDepositAmounts(...)`: Unified function to compute actual deposit amounts and shares minted, handling first and subsequent deposits, with optional high precision. Calls `calculateGeometricShares` and `calculateProportionalShares`.
*   `computeDepositAmountsAndShares(...)`: Wrapper for standard precision deposit calculation.
*   `computeDepositAmountsAndSharesWithPrecision(...)`: Wrapper for high precision deposit calculation.
*   `computeWithdrawAmounts(...)`: Calculates token amounts to withdraw based on shares burned. Uses `calculateProportional`.
*   `computeWithdrawAmountsWithPrecision(...)`: Wrapper for high precision withdrawal calculation.
*   `calculateSurgeFee(uint256 baseFee, uint256 multiplier)`: Simple surge fee calculation.
*   `calculateSurgeFee(uint256 baseFeePpm, uint256 surgeMultiplierPpm, uint256 decayFactor)`: Calculates surge fee with optional linear decay using `FullMath.mulDiv`.
*   `calculateDecayFactor(uint256 secondsElapsed, uint256 totalDuration)`: Calculates linear decay factor using `FullMath.mulDiv`.
*   `calculateReinvestableFees(uint256 fee0, ..., uint8 options)`: Core logic for determining reinvestable fees based on reserves and fee amounts, with configurable precision and safety checks. Uses `FullMath.mulDiv`.
*   `calculateReinvestableFees(uint256 fee0, ...)`: Wrapper for default reinvestable fee calculation.
*   `calculateDynamicFee(uint256 currentFeePpm, ..., FeeBounds memory bounds)`: Core logic for dynamic fee adjustment based on market conditions (CAP events, deviation), rate limits, and bounds.
*   `calculateDynamicFee(uint256 currentFeePpm, ..., uint256 maxFeePpm)`: Simplified interface wrapper.
*   `calculateMinimumPOLTarget(...)`: Calculates minimum Protocol-Owned Liquidity target using `FullMath.mulDiv`.
*   `distributeFees(...)`: Distributes collected fees based on policy shares (POL, Full Range, LP), handling rounding errors. Uses `calculateFeePpm`.
*   `calculatePriceChangePpm(uint256 oldPrice, uint256 newPrice)`: Calculates price volatility in PPM using `FullMath.mulDiv`.
*   `calculateFeeAdjustment(...)`: Calculates fee adjustment amount based on percentage.
*   `clamp(uint256 value, uint256 minValue, uint256 maxValue)`: Clamps a uint256 value within bounds.
*   `getVersion()`: Returns library version.
*   `computeLiquidityFromAmounts(...)`: Computes liquidity from token amounts and price range using `LiquidityAmounts` library functions.
*   `computeAmountsFromLiquidity(...)`: Computes token amounts from liquidity and price range using `SqrtPriceMath` library functions.
*   `calculateFeeWithScale(...)`: Calculates fee with a custom scaling factor using `FullMath.mulDiv`.
*   `calculateFeePpm(uint256 amount, uint256 feePpm)`: Calculates fee in PPM using `calculateFeeWithScale`.

## 2. Risk Assessment

Functions are categorized based on complexity, potential for errors (overflow, rounding), use of external libraries/assembly, and impact on core protocol finances.

### Low Risk

*   `PRECISION`, `PPM_SCALE`: Constant getters.
*   `min`, `max`: Simple comparisons.
*   `clamp`: Simple bounds checking.
*   `getVersion`: Constant getter.
*   `clampTick`: Simple bounds check using `TickMath` constants.
*   `calculateFeeAdjustment`: Simple percentage calculation.
*   `calculateSurgeFee(baseFee, multiplier)`: Simple multiplication/division.
*   Wrappers (`computeDepositAmountsAndShares`, `computeDepositAmountsAndSharesWithPrecision`, `computeWithdrawAmountsWithPrecision`, `calculateReinvestableFees` wrapper, `calculateDynamicFee` wrapper, `calculateFeePpm`): Risk primarily inherited from the functions they call.

### High Risk

*   `sqrt`: Uses external `FixedPointMathLib`. Precision and edge cases.
*   `absDiff`: Uses assembly. Potential for subtle errors.
*   `calculateGeometricMean`: Overflow handling, calls `sqrt`.
*   `calculateGeometricShares` (both versions): Complex logic, `calculateGeometricMean`, minimum liquidity.
*   `calculateProportional`: Core arithmetic (`FullMath`), rounding, division by zero potential.
*   `calculateProportionalShares`: Complex logic, uses `calculateProportional`.
*   `calculatePodShares`: Uses `calculateProportional`.
*   `computeDepositAmounts`: Complex branching (first/subsequent deposit), uses multiple math functions, precision handling. Critical for LPing.
*   `computeWithdrawAmounts`: Uses `calculateProportional`. Critical for LP withdrawals.
*   `calculateSurgeFee` (with decay): Uses `FullMath`, decay logic.
*   `calculateDecayFactor`: Uses `FullMath`, time logic.
*   `calculateReinvestableFees` (core): Complex ratios (`FullMath`), branching, options. Critical for fee handling.
*   `calculateDynamicFee` (core): Complex state-dependent logic, rate limiting, bounds. Critical for pool fees.
*   `calculateMinimumPOLTarget`: Uses `FullMath`. Protocol liquidity management.
*   `distributeFees`: Uses `calculateFeePpm`, rounding error handling. Critical for fee distribution.
*   `calculatePriceChangePpm`: Uses `FullMath`, division by zero edge case. Volatility measures.
*   `computeLiquidityFromAmounts`: Relies on external `LiquidityAmounts`. Test interactions.
*   `computeAmountsFromLiquidity`: Relies on external `SqrtPriceMath`. Test interactions.
*   `calculateFeeWithScale`: Core fee calculation (`FullMath`).

## 3. Unit Test Plan (Low Risk Functions)

*   **Target File:** `test/01_01_MathUtils_Unit_LowRisk.t.sol` (Create this file)
*   **Framework:** Foundry (`forge test`)
*   **Approach:** Focus on direct input/output validation and standard edge cases (zero, boundaries).
*   **Tests:**
    *   Verify constant getters return correct values.
    *   Test `min`, `max`, `clamp`, `clampTick` with values inside, outside, and at boundaries.
    *   Test `calculateFeeAdjustment` and simple `calculateSurgeFee` with zero/typical inputs.
    *   Test wrapper functions primarily ensure correct parameter passing to underlying implementations.

## 4. Unit & Fuzz Test Plan (High Risk Functions)

*   **Target File:** `test/01_01_MathUtils_UnitFuzz_HighRisk.t.sol` (Create this file)
*   **Framework:** Foundry (`forge test` with fuzzing enabled)
*   **Approach:** Combine specific scenario unit tests with broad fuzz testing.

### 4.1 Best Practices

*   **Isolate Logic:** Unit test functions individually where possible.
*   **Mock Dependencies:** For unit tests involving external libraries (`FullMath`, `TickMath`, etc.), consider if mocking specific return values is beneficial, though direct testing with the actual libraries is often preferred for integration behavior.
*   **Invariant Definition:** Define strong, specific invariants for fuzz tests (see examples below).
*   **Input Ranges:** Use `vm.assume` or the `bound` cheatcode judiciously in fuzz tests to focus on relevant input spaces and avoid excessive reverts from unrealistic inputs (e.g., price ordering, non-zero denominators where required).
*   **Code Coverage:** Monitor coverage (`forge coverage`) and add tests to cover unreached code paths, especially complex conditional logic.
*   **Gas Analysis:** Be mindful of gas costs, especially in assembly (`absDiff`) or complex loops if they existed.

### 4.2 Unit Tests (High Risk)

*   **Edge Cases:** Test with 0, 1, `type(uint/int).max/min`, large values that might cause overflow/underflow *before* `FullMath` handling.
*   **Division by Zero:** Explicitly test scenarios where denominators could be zero (e.g., `calculateProportional` with `denominator = 0`, `calculatePriceChangePpm` with `oldPrice = 0`) and verify expected revert or safe handling.
*   **Rounding:** Test `calculateProportional`, `computeAmountsFromLiquidity`, `distributeFees` for expected rounding behavior (up/down).
*   **Precision:** Test functions with `highPrecision` flags (e.g., `computeDepositAmounts`) toggled and compare results.
*   **Assembly:** Test `absDiff` with positive/negative inputs, zero, min/max int24 values.
*   **External Libraries:** Test behavior when underlying libraries (`FullMath`, `TickMath`, `SqrtPriceMath`, etc.) might revert or return edge values (e.g., `getLiquidityForAmount0` when price is out of bounds).
*   **Scenario-Specific:**
    *   `computeDepositAmounts`: Test first deposit vs. subsequent deposit logic. Test cases where `amount0Desired` or `amount1Desired` is zero.
    *   `calculateReinvestableFees`: Test all combinations of `options`, different `feeRatio` vs `targetRatio` scenarios, cases where one fee is zero.
    *   `calculateDynamicFee`: Test `capEventOccurred = true/false`, different `eventDeviation` values (positive, negative, zero, significant), hitting min/max bounds.
    *   `distributeFees`: Test scenarios where rounding error occurs and is correctly assigned.

### 4.3 Fuzz Tests (Stateless)

*   **Targets:** All high-risk functions.
*   **Invariants:**
    *   **General:** No arithmetic overflows/underflows (should be caught by Foundry). Functions should not revert unexpectedly for valid (even if extreme) inputs within defined preconditions.
    *   **`calculateProportional(num, shares, den)`:** Result should generally scale linearly with `num` and `shares`, inversely with `den`. `calculateProportional(a, b, c) * c / b ≈ a` (within rounding).
    *   **`computeDepositAmounts / computeWithdrawAmounts`:** For a given state (`reserves`, `totalShares`), depositing amounts `a0, a1` yielding `s` shares, then immediately withdrawing `s` shares should return amounts close to `a0, a1`. `fuzz_depositWithdrawSymmetry(uint128 totalShares, uint256 r0, uint256 r1, uint256 a0, uint256 a1)`
    *   **`calculateReinvestableFees`:** `investable0 <= fee0`, `investable1 <= fee1`. `investable0 * reserve1 ≈ investable1 * reserve0` if not limited by original fees. `limitingToken` should be consistent with ratios.
    *   **`distributeFees`:** `pol0 + fullRange0 + lp0 == amount0`, `pol1 + fullRange1 + lp1 == amount1`. Each component should be `amount * share / PPM_SCALE` within rounding.
    *   **`computeLiquidityFromAmounts / computeAmountsFromLiquidity`:** These should be roughly inverse operations within the same price range and rounding mode.
    *   **`sqrt(x*x)`:** Should be approximately `x`.
    *   **`calculateGeometricMean(a, b)`:** Should be symmetric (`mean(a,b) == mean(b,a)`), result squared should be approx `a*b`.
*   **Input Ranges:**
    *   Use `vm.assume(denominator > 0)` for relevant functions.
    *   Use `bound` for ticks (`TickMath.MIN_TICK` to `MAX_TICK`), prices (`TickMath.MIN_SQRT_RATIO` to `MAX_SQRT_RATIO`), shares/amounts (e.g., 0 to `type(uint128).max` or `type(uint256).max / 1e18` depending on context).
    *   Assume valid price ordering (`sqrtPriceA <= sqrtPriceB`) for relevant functions.

### 4.4 Fuzz Tests (Stateful - Optional but Recommended)

*   **Approach:** Define a state machine test (using Foundry's Handler pattern) that simulates interactions with a hypothetical pool using `MathUtils`.
*   **State:** Track `reserve0`, `reserve1`, `totalShares`.
*   **Actions:** Call `computeDepositAmounts`, `computeWithdrawAmounts`, potentially `calculateReinvestableFees` and `distributeFees` based on fuzzed inputs.
*   **Invariants:**
    *   `totalShares` should only increase on deposit, decrease on withdrawal.
    *   Reserves should change consistent with deposit/withdrawal amounts.
    *   Invariant checks from stateless fuzzing can be adapted (e.g., check deposit/withdraw symmetry after a sequence of actions).
    *   No token loss beyond expected rounding/fees over multiple operations. 