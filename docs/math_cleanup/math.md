Okay, let's consolidate the findings and identify the top areas for potential redundancy or refactoring across your `src` directory.

**Comprehensive List of Math Functions/Logic by File (within `src`)**

1.  **`src/libraries/MathUtils.sol`**: (As detailed previously)
    *   **Purpose**: Centralized library for various mathematical operations.
    *   **Functions**: `clampTick`, `sqrt`, `absDiff`, `calculateGeometricMean`, `min`, `max`, `calculateGeometricShares` (x2), `calculateInitialShares`, `calculateProportionalShares`, `calculatePodShares`, `computeDepositAmounts` (+ wrappers), `computeWithdrawAmounts` (+ wrapper), `calculateFeeWithScale` (+ wrappers), `calculateSurgeFee` (x2), `calculateDecayFactor`, `calculateReinvestableFees` (x2), `calculateDynamicFee` (x2), `calculateMinimumPOLTarget` (x2), `calculateExtraLiquidity`, `distributeFees`, `calculatePriceChangePpm`, `calculateFeeAdjustment`, `clamp`, `getVersion`, `computeLiquidityFromAmounts`, `computeAmountsFromLiquidity`.
    *   **Dependencies**: Uses `FullMath`, `TickMath`, `SqrtPriceMath`, `LiquidityAmounts`.

2.  **`src/libraries/SolvencyUtils.sol`**: (As detailed previously)
    *   **Purpose**: Calculates LTV and checks solvency for vaults.
    *   **Functions**: `isSolvent`, `calculateLTV`, `calculateCurrentDebtValue`, `checkVaultSolvency`, `computeVaultLTV`, `checkSolvencyWithValues`.
    *   **Dependencies**: Uses `FullMath`, `MathUtils`.

3.  **`src/libraries/FeeUtils.sol`**: (Discovered via `grep`)
    *   **Purpose**: Appears to focus on fee distribution.
    *   **Functions**: Contains a `distributeFees` function that calculates fee shares for POL, Full Range, and LP based on PPM inputs, including handling rounding.
    *   **Dependencies**: Uses basic arithmetic operators.

4.  **`src/LinearInterestRateModel.sol`**:
    *   **Purpose**: Calculates borrow interest rates based on utilization.
    *   **Logic**: Contains `_getCurrentRatePerSecond` which implements a kinked interest rate model using addition, subtraction, multiplication, division (`FullMath.mulDiv`), and comparisons based on utilization, base rate, slopes, and kink points. Calculates rate per year and divides by `SECONDS_PER_YEAR`.
    *   **Dependencies**: Uses `FullMath`.

5.  **`src/FeeReinvestmentManager.sol`**:
    *   **Purpose**: Manages the collection and reinvestment of fees.
    *   **Logic**: Contains arithmetic for:
        *   Calculating amounts to extract based on `polSharePpm` (similar pattern to `distributeFees`).
        *   Summing extracted and leftover amounts (`+`).
        *   Calculating net extracted amounts after swaps (`-`).
        *   Determining optimal reinvestment amounts (likely using external libraries like `MathUtils.calculateReinvestableFees`, but also involves additions/subtractions for final accounting).
    *   **Dependencies**: Likely uses `MathUtils`, basic arithmetic.

6.  **`src/FullRangeDynamicFeeManager.sol`**:
    *   **Purpose**: Manages dynamic swap fees based on market conditions (volatility, CAP events).
    *   **Logic**: Contains arithmetic for:
        *   Calculating tick changes (`-`).
        *   Capping tick changes based on `maxTickChange` (`+`, `-`).
        *   Time comparisons and differences (`>=`, `+`, `-`).
        *   Scaling fee changes based on `tickScalingFactor` (`*`, `/`).
        *   Calculating decayed surge fees based on time elapsed (`-`, `*`, `/`).
        *   Calculating total fees (`+`).
    *   **Dependencies**: Likely uses `MathUtils` (e.g., `calculateDynamicFee`), basic arithmetic.

7.  **`src/MarginManager.sol`**:
    *   **Purpose**: Core logic for user margin actions (deposit, withdraw, borrow, repay, liquidate).
    *   **Logic**: Contains arithmetic for:
        *   Calculating time elapsed (`-`).
        *   Calculating interest factor and new multiplier (`*`, `+`, `FullMath.mulDiv`).
        *   Simple vault balance updates (`+`).
        *   Updating rented shares (`+`).
    *   **Dependencies**: Uses `FullMath`, `MathUtils`, `SolvencyUtils`, basic arithmetic.

8.  **`src/FullRangeLiquidityManager.sol`**:
    *   **Purpose**: Manages the protocol's full-range liquidity position (POL).
    *   **Logic**: Contains arithmetic for:
        *   Updating total shares (`+`, `-`).
        *   Calculating usable shares (`-`).
        *   Calculating amounts to pull based on swap deltas (negation `-`).
        *   Calculating token amounts based on shares, reserves, and total shares (`*`, `/`). (Similar pattern to `MathUtils.computeWithdrawAmounts`).
    *   **Dependencies**: Uses `SafeCast`, `MathUtils`, basic arithmetic.

9.  **`src/Margin.sol`**:
    *   **Purpose**: Holds user vault data and interacts with `MarginManager`.
    *   **Logic**: Contains simple arithmetic (e.g., summing required ETH `+`). Primarily relies on `MarginManager` and libraries for complex calculations.

10. **`src/Spot.sol`**:
    *   **Purpose**: Implements the Uniswap V4 hook logic for spot interactions.
    *   **Logic**: Contains negation (`-`) for setting liquidity delta during callbacks. Primarily acts as an orchestrator calling other contracts/libraries.

11. **`src/TruncGeoOracleMulti.sol`**:
    *   **Purpose**: Provides TWAP oracle functionality.
    *   **Logic**: Contains simple arithmetic for time threshold checks (`+`) and index wrapping (`+`, `%`) within its internal `TruncatedOracle` logic (likely imported or embedded).

12. **`src/utils/SettlementUtils.sol`**:
    *   **Purpose**: Utility functions for settling token balances.
    *   **Logic**: Contains negation (`-`) to determine amounts to send based on negative deltas.

**Top 10 Areas of Potential Redundancy / Consolidation**

1.  **✅ `distributeFees` Duplication**: ~~The logic in `src/libraries/FeeUtils.sol::distributeFees` appears highly redundant with `src/libraries/MathUtils.sol::distributeFees`. Choose one implementation and remove the other.~~ *Resolved by removing the unused `FeeUtils.sol` file, as it wasn't imported or used anywhere in the codebase.*
2.  **🔍 `MathUtils` Wrapper Functions**: Numerous functions in `MathUtils` exist solely to call another internal function with default arguments (e.g., `calculateInitialShares`, `calculateFee`/`FeePpm`, precision wrappers for `computeDeposit/Withdraw`, wrappers for `calculateReinvestableFees`/`DynamicFee`/`MinimumPOLTarget`). Evaluate if the convenience of these wrappers outweighs the increased function count and potential for confusion. Consider removing simple wrappers if call sites can easily provide the default arguments.
    
    **Analysis**: After reviewing the codebase, I've identified several wrapper functions that could be candidates for removal:
    
    - `calculateInitialShares`: Only used internally within `computeDepositAmounts`, never called directly from outside MathUtils.
    - `calculateFee`: No usage found in the codebase.
    - `computeDepositAmountsAndShares` and variant: Primarily used in tests, though also used via FullRangeUtils.
    - `calculateExtraLiquidity`: Simply calls `calculateGeometricMean` with no additional logic.
    - `calculateMinimumPOLTarget` overload: The simpler version could be replaced with the more configurable one.
    
    **Recommendation**: Consider removing the following wrappers as they add complexity without significant value:
    1. `calculateFee` - Unused and can be replaced with `calculateFeeWithScale` if needed.
    2. `calculateInitialShares` - Inline the call to `calculateGeometricShares(amount0, amount1, true)` in the one place it's used.
    3. `calculateExtraLiquidity` - Replace with direct calls to `calculateGeometricMean`.
    4. Keep wrapper functions that have evidence of external usage (e.g., `calculateFeePpm`, `computeDepositAmountsAndShares`).

    **Implementation Progress**:
    - ✅ Removed the unused `calculateFee` function
    - ✅ Removed `calculateExtraLiquidity` and replaced with a note to use `calculateGeometricMean` directly
    - ✅ Removed `calculateInitialShares` and replaced with a direct call to `calculateGeometricShares(amount0, amount1, true)`
    - ✅ Removed the simpler version of `calculateMinimumPOLTarget` (keeping the more configurable version)

3.  **✅ `calculateExtraLiquidity` vs. `calculateGeometricMean`**: ~~`MathUtils.calculateExtraLiquidity` currently just calls `MathUtils.calculateGeometricMean`. Unless it's intended to evolve, it's redundant and could be removed or renamed for clarity.~~ *Resolved by removing the redundant `calculateExtraLiquidity` function.*
4.  **Proportional Share / Amount Calculation**: Multiple places calculate proportional amounts based on shares, reserves, and totals (e.g., `MathUtils.calculateProportionalShares`, `MathUtils.calculatePodShares`, `MathUtils.computeWithdrawAmounts`, `FullRangeLiquidityManager` internal calculation `(reserve * shares) / totalShares`). While often using `FullMath.mulDiv`, review if these calculations are fundamentally the same pattern and could be consolidated into a single, more generic utility function in `MathUtils`.

    **Implementation Progress**:
    - ✅ Added a new general-purpose `calculateProportional` function in `MathUtils` that handles the core pattern: `(numerator * shares) / denominator`
    - ✅ Refactored `calculatePodShares` to use the general-purpose function
    - ✅ Refactored `computeWithdrawAmounts` to use the general-purpose function
    - ✅ Refactored `calculateProportionalShares` to use the general-purpose function internally
    - ✅ Updated token amount calculations in `computeDepositAmounts` to use the general-purpose function
    - ✅ Updated `FullRangeLiquidityManager` to use `MathUtils.calculateProportional` instead of its own calculations in `_calculateWithdrawAmounts`, `borrowImpl`, `getShareValue`, `_calculateDepositShares`, and `reinvestFees`

5.  **✅ Tick Capping/Clamping**: ~~`MathUtils.clampTick` clamps to the absolute Uniswap V3/V4 min/max ticks. `FullRangeDynamicFeeManager` implements logic to cap a *change* in ticks (`cappedTick = lastTick + (tickChange > 0 ? maxTickChange : -maxTickChange)`). These serve different purposes (absolute bounds vs. relative change limit) and are likely *not* redundant, but it's worth double-checking the exact requirements.~~ *Investigated and determined that these functions serve distinct purposes: one for absolute range validation (static) and the other for limiting tick movement between updates (dynamic). No consolidation needed.*

6.  **✅ Fee Calculation Variations**: ~~`MathUtils` provides `calculateFeeWithScale` and wrappers. `LinearInterestRateModel` uses `FullMath.mulDiv` for rate calculations. `FeeReinvestmentManager` uses simple `*` and `/` for `polSharePpm` distribution. `FullRangeDynamicFeeManager` scales `maxChangeScaled` using `*` and `/`. Review if a single, consistent utility (like `calculateFeeWithScale` or `FullMath.mulDiv`) could be used for all percentage/PPM/scaled calculations for consistency.~~ *Updated non-standard fee calculations to use the MathUtils library for better consistency, improved overflow protection, and more maintainable code. Specifically:*
    - *Replaced direct calculation in FeeReinvestmentManager with MathUtils.calculateFeePpm*
    - *Updated FullRangeDynamicFeeManager._calculateMaxTickChange to use MathUtils.calculateFeeWithScale*

7.  **✅ Solvency/LTV Wrappers**: ~~`SolvencyUtils` contains core `isSolvent`/`calculateLTV` and compositional wrappers (`checkVaultSolvency`, `computeVaultLTV`, `checkSolvencyWithValues`). While composition is good, evaluate if the wrappers add significant value or if call sites could perform the composition directly using the core functions and `MathUtils.calculateProportionalShares`/`calculateCurrentDebtValue`.~~ *Removed unused wrapper functions from SolvencyUtils, integrated core functions with MarginManager, and added a simplified calculateCurrentDebtValue function that takes direct debt share values.*

8.  **✅ Basic Math Utilities (`MathUtils` vs. `StdMath`)**: ~~`MathUtils` defines `min`, `max`, `absDiff`, `sqrt`. Check if you are also importing and using similar functions from libraries like `forge-std/StdMath.sol` (`abs`, `delta`). Ensure you're using one consistent source for basic utilities where possible (preferring established libraries like Solmate or Forge Std if they suffice, or consistently using your custom ones if they offer specific advantages like `absDiff` for `int24`).~~ *Completed the following optimizations:*
    - *Replaced `MathUtils.sqrt()` with a wrapper for `FixedPointMathLib.sqrt()` from Solmate*
    - *Added comprehensive documentation to MathUtils.sol explaining when to use each math library*
    - *Kept `min`, `max`, and `absDiff` in MathUtils as they are simple, gas-efficient implementations with specialized purposes*

9.  **Fee Distribution in `FeeReinvestmentManager`**: This contract calculates `extract0`/`extract1` using `(fee * share) / denominator`. This is the same pattern as `MathUtils.calculateFeePpm` (or `calculateFeeWithScale`). Consider replacing this direct calculation with a call to the library function for consistency.

10. **Precision/Scaling Constants (`PRECISION`, `PPM_SCALE`)**: Consistent use of `FullMath.mulDiv` is good. Ensure that the correct scaling factor (`PRECISION` or `PPM_SCALE`) is always used where appropriate and that functions clearly document expected input/output scaling. This is more about consistency than code duplication.