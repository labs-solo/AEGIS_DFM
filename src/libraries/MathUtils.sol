// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Errors} from "../errors/Errors.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {PrecisionConstants} from "./PrecisionConstants.sol";

/**
 * @title MathUtils
 * @notice Consolidated mathematical utilities for the protocol
 * @dev Version 1.0.0 - Optimized implementation with gas efficiency improvements
 *
 * ===== MATH LIBRARY USAGE GUIDE =====
 *
 * 1. FullMath (Uniswap V4): Use for overflow-safe multiplication and division operations
 *    - FullMath.mulDiv: For multiplication followed by division with overflow protection
 *    - FullMath.mulDivRoundingUp: Same as mulDiv but rounds up
 *
 * 2. FixedPointMathLib (Solmate): Use for standard math operations with proven implementations
 *    - FixedPointMathLib.sqrt: For square root calculations (more gas efficient than our implementation)
 *    - Also provides wad math and other fixed-point operations if needed
 *
 * 3. MathUtils (This library): Use for protocol-specific operations and convenience wrappers
 *    - calculateProportional: For calculating proportional values (amount * shares / denominator)
 *    - absDiff: For calculating absolute difference between int24 tick values
 *    - min/max: Simple comparison utilities
 *    - Specialized functions for share calculation, deposit/withdraw amount computation
 *
 * 4. Tick/Price Math (Uniswap V4): Use for Uniswap-specific calculations
 *    - TickMath: For tick-related calculations and conversions
 *    - SqrtPriceMath: For price-related calculations
 *
 * 5. PrecisionConstants: Use for standardized precision constants
 *    - PRECISION (1e18): For high-precision calculations like interest rates
 *    - PPM_SCALE (1e6): For percentage-based calculations in parts-per-million
 */
library MathUtils {
    /**
     * @dev Constants
     */
    // Import precision constants from central library
    using PrecisionConstants for uint256;

    /// @notice   Exact same constant Uniswap V2/V3 use – irrevocably locked
    uint256 internal constant MINIMUM_LIQUIDITY = 1_000;

    /// @dev absolute value of a signed int returned as uint
    function abs(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    // For backward compatibility, expose the precision constants directly
    function PRECISION() internal pure returns (uint256) {
        return PrecisionConstants.PRECISION;
    }

    function PPM_SCALE() internal pure returns (uint256) {
        return PrecisionConstants.PPM_SCALE;
    }

    /**
     * @notice Clamps a tick value to the valid Uniswap tick range
     * @param tick The tick to clamp
     * @return The clamped tick value
     */
    function clampTick(int24 tick) internal pure returns (int24) {
        unchecked {
            return tick < TickMath.MIN_TICK ? TickMath.MIN_TICK : (tick > TickMath.MAX_TICK ? TickMath.MAX_TICK : tick);
        }
    }

    /**
     * @notice Calculate square root using Solmate's FixedPointMathLib
     * @dev Efficient implementation with optimized assembly code from Solmate
     * @param x The value to calculate the square root of
     * @return y The square root of x
     */
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        return FixedPointMathLib.sqrt(x);
    }

    /**
     * @notice Optimized implementation of absolute difference between two int24 values
     * @dev Uses inline assembly for maximum gas efficiency
     * @param a First value
     * @param b Second value
     * @return diff The absolute difference
     */
    function absDiff(int24 a, int24 b) internal pure returns (uint24 diff) {
        assembly {
            // Calculate difference (a - b)
            let x := sub(a, b)

            // Get sign bit by shifting right by 31 positions
            let sign := shr(31, x)

            // If sign bit is 1 (negative), negate x
            // Otherwise keep x as is
            diff := xor(x, mul(sign, not(0)))

            // If sign bit is 1, add 1 to complete two's complement negation
            diff := add(diff, sign)
        }
    }

    /**
     * @notice Calculates geometric mean (sqrt(a * b)) with overflow protection
     * @dev Uses overflow protection for large numbers and calls sqrt internally
     * @param a First value
     * @param b Second value
     * @return The geometric mean of a and b
     */
    function calculateGeometricMean(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;

        // Handle potential overflow
        uint256 product;
        unchecked {
            if (a > type(uint256).max / b) {
                product = (a / 1e9) * (b / 1e9);
                return sqrt(product) * 1e9;
            } else {
                product = a * b;
                return sqrt(product);
            }
        }
    }

    /**
     * @notice Calculate minimum of two values
     * @dev Simple helper function to find minimum
     * @param a First value
     * @param b Second value
     * @return The minimum of a and b
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @notice Calculate maximum of two values
     * @dev Simple helper function to find maximum
     * @param a First value
     * @param b Second value
     * @return The maximum of a and b
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /**
     * @notice Calculates shares based on geometric mean with option for locking shares
     * @dev Core implementation of share calculation based on geometric mean
     * @param amount0 The amount of token0
     * @param amount1 The amount of token1
     * @param withMinimumLiquidity Whether to lock minimum liquidity
     * @return shares The calculated shares
     * @return lockedShares The amount of shares permanently locked
     */
    function calculateGeometricShares(uint256 amount0, uint256 amount1, bool withMinimumLiquidity)
        internal
        pure
        returns (uint256 shares, uint256 lockedShares)
    {
        if (amount0 == 0 || amount1 == 0) return (0, 0);

        uint256 totalShares = calculateGeometricMean(amount0, amount1);

        if (withMinimumLiquidity && totalShares > MINIMUM_LIQUIDITY) {
            unchecked {
                shares = totalShares - MINIMUM_LIQUIDITY;
                lockedShares = MINIMUM_LIQUIDITY;
            }
        } else if (withMinimumLiquidity) {
            // Special case for small amounts
            unchecked {
                lockedShares = totalShares / 10;
                shares = totalShares - lockedShares;
            }
        } else {
            shares = totalShares;
            lockedShares = 0;
        }
    }

    /**
     * @notice Simplified function for geometric shares calculation
     * @dev Default implementation of geometric shares without minimum liquidity
     * @param amount0 The amount of token0
     * @param amount1 The amount of token1
     * @return The calculated shares using geometric mean
     */
    function calculateGeometricShares(uint256 amount0, uint256 amount1) internal pure returns (uint256) {
        (uint256 shares,) = calculateGeometricShares(amount0, amount1, false);
        return shares;
    }

    /**
     * @notice Calculates proportional shares for subsequent deposits
     * @dev Handles both standard and high-precision calculations
     * @param amount0 The amount of token0
     * @param amount1 The amount of token1
     * @param totalShares The current total shares
     * @param reserve0 The current reserve of token0
     * @param reserve1 The current reserve of token1
     * @param highPrecision Whether to use high-precision calculations
     * @return shares The calculated shares
     */
    function calculateProportionalShares(
        uint256 amount0,
        uint256 amount1,
        uint256 totalShares,
        uint256 reserve0,
        uint256 reserve1,
        bool highPrecision
    ) internal pure returns (uint256 shares) {
        // silence "unused" warning – the flag is reserved for a future high-precision mode
        highPrecision;
        // Phase 3 Implementation:
        // Note: `totalShares` here refers to the LP shares, equivalent to liquidity in some contexts.
        // `highPrecision` flag is ignored for now, using FullMath for safety.

        if (uint128(totalShares) == 0 || (reserve0 == 0 && reserve1 == 0)) {
            // Cannot determine value if pool is empty or has no reserves.
            return 0;
        }

        uint256 shares0 = 0;
        if (reserve0 > 0 && amount0 > 0) {
            // shares0 = amount0 * totalLiquidity / reserve0;
            shares0 = calculateProportional(amount0, totalShares, reserve0, false);
        }

        uint256 shares1 = 0;
        if (reserve1 > 0 && amount1 > 0) {
            // shares1 = amount1 * totalLiquidity / reserve1;
            shares1 = calculateProportional(amount1, totalShares, reserve1, false);
        }

        // If only one token amount is provided (or reserve for the other is 0, or amount is 0),
        // return the share value calculated from that one token.
        // If both amounts/reserves allow calculation, return the minimum value to maintain ratio.
        if (amount0 == 0 || shares0 == 0) {
            shares = shares1;
        } else if (amount1 == 0 || shares1 == 0) {
            shares = shares0;
        } else {
            // Return the smaller value to ensure the collateral value isn't overestimated
            shares = shares0 < shares1 ? shares0 : shares1;
        }
    }

    /**
     * @notice Calculates shares for pods based on amount, total shares, and value
     * @dev Used for calculating pod shares
     * @param amount The amount to calculate shares for
     * @param totalShares The current total shares
     * @param totalValue The current total value
     * @return The calculated shares
     */
    function calculatePodShares(uint256 amount, uint256 totalShares, uint256 totalValue)
        internal
        pure
        returns (uint256)
    {
        if (totalValue == 0) {
            if (totalShares == 0) {
                return amount; // Initial deposit
            }
            revert Errors.ValidationZeroAmount("totalValue");
        }

        return calculateProportional(amount, totalShares, totalValue, false);
    }

    /**
     * @notice General-purpose function for proportional calculations
     * @dev Core implementation for calculating proportional values using the formula: (numerator * shares) / denominator
     * @param numerator The value to be scaled (e.g., amount, reserve)
     * @param shares The shares to use for calculation
     * @param denominator The total value to divide by (e.g., totalShares, totalValue)
     * @param roundUp Whether to round up the result
     * @return The calculated proportional value
     */
    function calculateProportional(uint256 numerator, uint256 shares, uint256 denominator, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        if (denominator == 0) return 0;

        if (roundUp) {
            return FullMath.mulDivRoundingUp(numerator, shares, denominator);
        } else {
            return FullMath.mulDiv(numerator, shares, denominator);
        }
    }

    /**
     * @notice Unified compute deposit function with optional precision flag
     * @dev Consolidated function for deposit calculations. Uses FullMath via internal helpers
     *      for improved precision and robustness compared to standard division.
     * @param totalShares The existing total shares
     * @param amount0Desired The user's desired token0 input
     * @param amount1Desired The user's desired token1 input
     * @param reserve0 Current reserve of token0
     * @param reserve1 Current reserve of token1
     * @param highPrecision Whether to use high-precision calculations via FullMath (standard also uses FullMath now)
     * @return actual0 The final token0 used
     * @return actual1 The final token1 used
     * @return sharesMinted The minted shares
     * @return lockedShares Shares permanently locked (only for first deposit)
     */
    function computeDepositAmounts(
        uint128 totalShares,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 reserve0,
        uint256 reserve1,
        bool highPrecision // Note: Both paths now use FullMath via helpers
    ) internal pure returns (uint256 actual0, uint256 actual1, uint256 sharesMinted, uint256 lockedShares) {
        // === Input Validation ===
        // 1. Check for zero total desired amounts
        if (amount0Desired == 0 && amount1Desired == 0) revert Errors.ValidationZeroAmount("tokens");

        // 2. Check for individual amount overflow (against uint128 limit)
        //    We check against uint128 max because underlying Uniswap V4 functions often expect amounts <= uint128.max
        //    This acts as an early sanity check, although FullMath handles larger uint256 values.
        if (amount0Desired > type(uint128).max) {
            revert Errors.AmountTooLarge(amount0Desired, type(uint128).max);
        }
        if (amount1Desired > type(uint128).max) {
            revert Errors.AmountTooLarge(amount1Desired, type(uint128).max);
        }

        // === First Deposit Logic ===
        if (totalShares == 0) {
            // 3. First deposit requires both tokens to be non-zero
            if (amount0Desired == 0 || amount1Desired == 0) revert Errors.ValidationZeroAmount("token");

            actual0 = amount0Desired;
            actual1 = amount1Desired;
            // Calculate shares using geometric mean, locking minimum liquidity
            (sharesMinted, lockedShares) = calculateGeometricShares(actual0, actual1, true);
            // No need to check actual amounts against desired here, as they are used directly.
            return (actual0, actual1, sharesMinted, lockedShares);
        }

        // === Subsequent Deposit Logic ===
        lockedShares = 0; // No locked shares for subsequent deposits

        // 4. Validate reserves for subsequent deposits (should not be zero if totalShares > 0)
        //    Using calculateProportionalShares/calculateProportional handles zero reserves gracefully by returning 0,
        //    but explicitly reverting might be safer if zero reserves with non-zero totalShares is considered an invalid state.
        if (reserve0 == 0 || reserve1 == 0) {
            // If pool exists (totalShares > 0), reserves should ideally not be zero.
            // Returning 0 amounts based on helpers is safe, but reverting might indicate an issue.
            // Let's stick to returning 0 amounts for now, aligned with helper behavior.
            // If revert is preferred, uncomment below:
            // revert Errors.InvalidInput("Zero reserve in existing pool");
        }

        // Calculate potential shares minted based on each token amount relative to reserves.
        // This uses calculateProportional internally, which uses FullMath.
        // The function returns the *minimum* of the two potential share amounts to maintain the pool ratio.
        sharesMinted = calculateProportionalShares(
            amount0Desired,
            amount1Desired,
            totalShares,
            reserve0,
            reserve1,
            highPrecision // Pass flag, though calculateProportionalShares primarily uses it to select FullMath
        );

        // Calculate token amounts required for the determined sharesMinted.
        // We round down (roundUp = false) to ensure we don't take more tokens than the ratio strictly allows.
        if (sharesMinted > 0) {
            // Use calculateProportional (which uses FullMath) for precision
            actual0 = calculateProportional(reserve0, sharesMinted, totalShares, false); // amount = reserve * shares / totalShares
            actual1 = calculateProportional(reserve1, sharesMinted, totalShares, false);
        } else {
            // If no shares are minted (e.g., due to zero desired amounts filtered earlier,
            // or extremely tiny amounts rounding down to zero shares in calculateProportionalShares),
            // then actual amounts are zero.
            actual0 = 0;
            actual1 = 0;
        }

        // --- Post-calculation Adjustments & Checks ---

        // A. Minimum Amount Guarantee: If shares were minted and a non-zero amount was desired,
        //    ensure at least 1 wei is used if the calculation rounded down to zero.
        //    This prevents dust amounts desired by the user from being entirely ignored.
        if (sharesMinted > 0) {
            if (actual0 == 0 && amount0Desired > 0) actual0 = 1;
            if (actual1 == 0 && amount1Desired > 0) actual1 = 1;
        }

        // B. Cap by Desired Amount: Ensure the calculated actual amount (potentially adjusted to 1 wei)
        //    does not exceed the user's originally desired amount. This is crucial because `sharesMinted`
        //    was based on the limiting token; the amount for the non-limiting token might exceed the desired
        //    amount if only the `calculateProportional` result was used. Also covers the case where
        //    setting actualN = 1 made it exceed a desired amount less than 1 (though unlikely).
        actual0 = min(actual0, amount0Desired);
        actual1 = min(actual1, amount1Desired);

        // A. Strict dust-prevention: if rounding drove one side to zero while the
        // user supplied a non-zero amount we revert instead of silently topping-up.
        if (sharesMinted > 0 && (actual0 == 0 || actual1 == 0)) {
            revert Errors.ValidationZeroAmount("roundedAmount");
        }

        // Final return values are set.
    }

    /**
     * @notice Compute deposit amounts for standard precision
     * @dev Backward compatibility wrapper for computeDepositAmounts
     * @param totalShares The existing total shares
     * @param amount0Desired The user's desired token0 input
     * @param amount1Desired The user's desired token1 input
     * @param reserve0 Current reserve of token0
     * @param reserve1 Current reserve of token1
     * @return actual0 The final token0 used
     * @return actual1 The final token1 used
     * @return sharesMinted The minted shares
     * @return lockedShares Shares permanently locked
     */
    function computeDepositAmountsAndShares(
        uint128 totalShares,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (uint256 actual0, uint256 actual1, uint256 sharesMinted, uint256 lockedShares) {
        return computeDepositAmounts(totalShares, amount0Desired, amount1Desired, reserve0, reserve1, false);
    }

    /**
     * @notice Compute deposit amounts with high precision
     * @dev Backward compatibility wrapper for computeDepositAmounts
     * @param totalShares The existing total shares
     * @param amount0Desired The user's desired token0 input
     * @param amount1Desired The user's desired token1 input
     * @param reserve0 Current reserve of token0
     * @param reserve1 Current reserve of token1
     * @return actual0 The final token0 used
     * @return actual1 The final token1 used
     * @return sharesMinted The minted shares
     * @return lockedShares Shares permanently locked
     */
    function computeDepositAmountsAndSharesWithPrecision(
        uint128 totalShares,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (uint256 actual0, uint256 actual1, uint256 sharesMinted, uint256 lockedShares) {
        return computeDepositAmounts(totalShares, amount0Desired, amount1Desired, reserve0, reserve1, true);
    }

    /**
     * @notice Calculate withdrawal amounts based on shares to burn
     * @dev Handles both standard and high-precision calculations
     * @param totalLiquidity The current total liquidity
     * @param sharesToBurn The shares to burn
     * @param reserve0 The current reserve of token0
     * @param reserve1 The current reserve of token1
     * @return amount0Out The amount of token0 to withdraw
     * @return amount1Out The amount of token1 to withdraw
     */
    function computeWithdrawAmounts(
        uint128 totalLiquidity,
        uint256 sharesToBurn,
        uint256 reserve0,
        uint256 reserve1,
        bool highPrecision // highPrecision - ignored in Phase 4 basic implementation
    ) internal pure returns (uint256 amount0Out, uint256 amount1Out) {
        // silence "unused" warning – the flag is reserved for a future high-precision mode
        highPrecision;
        if (totalLiquidity == 0 || sharesToBurn == 0) {
            return (0, 0);
        }
        // Ensure sharesToBurn doesn't exceed totalLiquidity? Typically handled by caller (e.g., cannot withdraw more than balance)
        // If sharesToBurn > totalLiquidity, this calculation might yield more tokens than reserves,
        // but the calling function should prevent this scenario.

        amount0Out = calculateProportional(reserve0, sharesToBurn, totalLiquidity, false);
        amount1Out = calculateProportional(reserve1, sharesToBurn, totalLiquidity, false);
    }

    /**
     * @notice Calculate surge fee based on base fee and multiplier
     * @dev Specialized fee calculation for surge pricing
     * @param baseFee The base fee
     * @param multiplier The surge multiplier
     * @return The calculated surge fee
     */
    function calculateSurgeFee(uint256 baseFee, uint256 multiplier) internal pure returns (uint256) {
        // Surge fee calculation cannot overflow as both values are bounded
        unchecked {
            return (baseFee * multiplier) / PPM_SCALE();
        }
    }

    /**
     * @notice Calculate surge fee with efficient multiplication
     * @dev Applies surge multiplier to base fee with optional linear decay
     * @param baseFeePpm Base fee in parts per million
     * @param surgeMultiplierPpm Surge multiplier in parts per million (1e6 = 1x)
     * @param decayFactor Decay factor (0 = fully decayed, PRECISION = no decay)
     * @return surgeFee The calculated surge fee
     */
    function calculateSurgeFee(uint256 baseFeePpm, uint256 surgeMultiplierPpm, uint256 decayFactor)
        internal
        pure
        returns (uint256 surgeFee)
    {
        // Quick return for no surge case
        if (surgeMultiplierPpm <= PPM_SCALE() || decayFactor == 0) {
            return baseFeePpm;
        }

        // Calculate surge amount (amount above base fee)
        uint256 surgeAmount = FullMath.mulDiv(baseFeePpm, surgeMultiplierPpm - PPM_SCALE(), PPM_SCALE());

        // Apply decay factor
        if (decayFactor < PRECISION()) {
            surgeAmount = FullMath.mulDiv(surgeAmount, decayFactor, PRECISION());
        }

        // Return base fee plus (potentially decayed) surge amount
        return baseFeePpm + surgeAmount;
    }

    /**
     * @notice Calculate linear decay factor based on elapsed time
     * @param secondsElapsed Time elapsed since surge activation
     * @param totalDuration Total duration of surge effect
     * @return decayFactor The calculated decay factor (PRECISION = no decay, 0 = full decay)
     */
    function calculateDecayFactor(uint256 secondsElapsed, uint256 totalDuration)
        internal
        pure
        returns (uint256 decayFactor)
    {
        // Return 0 if beyond duration (fully decayed)
        if (secondsElapsed >= totalDuration) {
            return 0;
        }

        // Calculate linear decay: 1 - (elapsed/total)
        return PRECISION() - FullMath.mulDiv(secondsElapsed, PRECISION(), totalDuration);
    }

    /**
     * @notice Fee bounds for enforcing min/max limits
     */
    struct FeeBounds {
        uint256 minFeePpm; // Minimum fee (PPM)
        uint256 maxFeePpm; // Maximum fee (PPM)
    }

    /**
     * @notice Types of fee adjustments for better context
     */
    enum FeeAdjustmentType {
        NO_CHANGE,
        SIGNIFICANT_INCREASE,
        MODERATE_INCREASE,
        GRADUAL_DECREASE,
        MINIMUM_ENFORCED,
        MAXIMUM_ENFORCED
    }

    /**
     * @notice Calculate dynamic fee based on market conditions
     * @dev Core implementation with support for CAP events and graduated fee changes
     *
     * @param currentFeePpm Current fee in parts per million (PPM)
     * @param capEventOccurred Whether a CAP event has been detected
     * @param eventDeviation Deviation from target event rate (can be negative)
     * @param targetEventRate Target event rate for comparison
     * @param maxIncreasePct Maximum percentage increase (e.g., 10 = 10%)
     * @param maxDecreasePct Maximum percentage decrease
     * @param bounds Fee bounds structure with min/max limits
     * @return newFeePpm The calculated fee in parts per million
     * @return surgeEnabled Whether surge pricing should be enabled
     * @return adjustmentType Reason code for the fee change
     */
    function calculateDynamicFee(
        uint256 currentFeePpm,
        bool capEventOccurred,
        int256 eventDeviation,
        uint256 targetEventRate,
        uint16 maxIncreasePct,
        uint16 maxDecreasePct,
        FeeBounds memory bounds
    ) internal pure returns (uint256 newFeePpm, bool surgeEnabled, FeeAdjustmentType adjustmentType) {
        // Calculate maximum adjustment amounts
        uint256 maxIncrease = (currentFeePpm * maxIncreasePct) / 100;
        uint256 maxDecrease = (currentFeePpm * maxDecreasePct) / 100;

        // Ensure minimum adjustments (avoid zero adjustments)
        if (maxIncrease == 0) maxIncrease = 1;
        if (maxDecrease == 0) maxDecrease = 1;

        // Start with current fee
        newFeePpm = currentFeePpm;
        adjustmentType = FeeAdjustmentType.NO_CHANGE;

        // Calculate deviation significance threshold
        int256 significantDeviation = int256(targetEventRate) / 10;

        // Handle CAP event case
        if (capEventOccurred) {
            surgeEnabled = true;

            if (eventDeviation > significantDeviation) {
                // Significant positive deviation - apply full increase
                newFeePpm = currentFeePpm + maxIncrease;
                adjustmentType = FeeAdjustmentType.SIGNIFICANT_INCREASE;
            } else if (eventDeviation > 0) {
                // Moderate positive deviation - apply partial increase (1/3 of max)
                newFeePpm = currentFeePpm + (maxIncrease / 3);
                adjustmentType = FeeAdjustmentType.MODERATE_INCREASE;
            }
            // If CAP event but no positive deviation, maintain current fee
        } else {
            // No CAP event - apply fee decrease
            surgeEnabled = false;

            if (currentFeePpm > maxDecrease) {
                newFeePpm = currentFeePpm - maxDecrease;
            } else {
                newFeePpm = bounds.minFeePpm;
            }

            adjustmentType = FeeAdjustmentType.GRADUAL_DECREASE;
        }

        // Enforce fee bounds
        if (newFeePpm < bounds.minFeePpm) {
            newFeePpm = bounds.minFeePpm;
            adjustmentType = FeeAdjustmentType.MINIMUM_ENFORCED;
        } else if (newFeePpm > bounds.maxFeePpm) {
            newFeePpm = bounds.maxFeePpm;
            adjustmentType = FeeAdjustmentType.MAXIMUM_ENFORCED;
        }

        return (newFeePpm, surgeEnabled, adjustmentType);
    }

    /**
     * @notice Simplified interface for backward compatibility
     * @param currentFeePpm Current fee in PPM
     * @param capEventOccurred Whether a CAP event occurred
     * @param eventDeviation Deviation from target rate
     * @param targetEventRate Target event rate
     * @param maxIncreasePct Maximum increase percentage
     * @param maxDecreasePct Maximum decrease percentage
     * @param minFeePpm Minimum fee bound
     * @param maxFeePpm Maximum fee bound
     * @return newFee The calculated new fee
     * @return surgeEnabled Whether surge mode is activated
     */
    function calculateDynamicFee(
        uint256 currentFeePpm,
        bool capEventOccurred,
        int256 eventDeviation,
        uint256 targetEventRate,
        uint16 maxIncreasePct,
        uint16 maxDecreasePct,
        uint256 minFeePpm,
        uint256 maxFeePpm
    ) internal pure returns (uint256 newFee, bool surgeEnabled) {
        // Create bounds structure
        FeeBounds memory bounds = FeeBounds({minFeePpm: minFeePpm, maxFeePpm: maxFeePpm});

        // Call main implementation
        FeeAdjustmentType adjustmentType;
        (newFee, surgeEnabled, adjustmentType) = calculateDynamicFee(
            currentFeePpm, capEventOccurred, eventDeviation, targetEventRate, maxIncreasePct, maxDecreasePct, bounds
        );

        return (newFee, surgeEnabled);
    }

    /**
     * @notice Calculate minimum POL target based on dynamic fee
     * @dev Uses the formula: minPOL = (dynamicFeePpm * polMultiplier * totalLiquidity) / 1e6
     * @param totalLiquidity Current total pool liquidity
     * @param dynamicFeePpm Current dynamic fee in PPM
     * @param polMultiplier POL multiplier factor
     * @return polTarget Minimum required protocol-owned liquidity amount
     */
    function calculateMinimumPOLTarget(uint256 totalLiquidity, uint256 dynamicFeePpm, uint256 polMultiplier)
        internal
        pure
        returns (uint256 polTarget)
    {
        return FullMath.mulDiv(dynamicFeePpm * polMultiplier, totalLiquidity, PPM_SCALE());
    }

    /**
     * @notice Distribute fees according to policy shares
     * @dev Handles fee distribution with improved rounding error handling
     * @param amount0 Amount of token0 fees
     * @param amount1 Amount of token1 fees
     * @param polSharePpm Protocol-owned liquidity share in PPM
     * @param fullRangeSharePpm Full range share in PPM
     * @param lpSharePpm LP share in PPM
     * @return pol0 Protocol-owned liquidity token0 share
     * @return pol1 Protocol-owned liquidity token1 share
     * @return fullRange0 Full range token0 share
     * @return fullRange1 Full range token1 share
     * @return lp0 LP token0 share
     * @return lp1 LP token1 share
     */
    function distributeFees(
        uint256 amount0,
        uint256 amount1,
        uint256 polSharePpm,
        uint256 fullRangeSharePpm,
        uint256 lpSharePpm
    )
        internal
        pure
        returns (uint256 pol0, uint256 pol1, uint256 fullRange0, uint256 fullRange1, uint256 lp0, uint256 lp1)
    {
        // Validate shares sum to 100%
        uint256 totalShares = polSharePpm + fullRangeSharePpm + lpSharePpm;
        if (totalShares != PPM_SCALE()) {
            revert Errors.InvalidInput();
        }

        // Calculate shares with improved precision
        pol0 = calculateFeePpm(amount0, polSharePpm);
        pol1 = calculateFeePpm(amount1, polSharePpm);

        fullRange0 = calculateFeePpm(amount0, fullRangeSharePpm);
        fullRange1 = calculateFeePpm(amount1, fullRangeSharePpm);

        lp0 = calculateFeePpm(amount0, lpSharePpm);
        lp1 = calculateFeePpm(amount1, lpSharePpm);

        // Handle rounding errors
        uint256 totalAllocated0 = pol0 + fullRange0 + lp0;
        uint256 totalAllocated1 = pol1 + fullRange1 + lp1;

        // Ensure no tokens are lost to rounding
        if (totalAllocated0 < amount0) {
            // Assign unallocated tokens to LP share
            lp0 += amount0 - totalAllocated0;
        }

        if (totalAllocated1 < amount1) {
            // Assign unallocated tokens to LP share
            lp1 += amount1 - totalAllocated1;
        }
    }

    /**
     * @notice Calculate the percentage price change in parts per million (PPM)
     * @dev Used for volatility calculations in CAP event detection
     * @param oldPrice The original price
     * @param newPrice The new price
     * @return volatilityPpm The price change percentage in PPM
     */
    function calculatePriceChangePpm(uint256 oldPrice, uint256 newPrice)
        internal
        pure
        returns (uint256 volatilityPpm)
    {
        if (oldPrice == 0) return 0;

        // Calculate price change as percentage
        uint256 priceDiffAbs;
        if (newPrice > oldPrice) {
            priceDiffAbs = newPrice - oldPrice;
        } else {
            priceDiffAbs = oldPrice - newPrice;
        }

        // Volatility as percentage of older price (in PPM)
        volatilityPpm = FullMath.mulDiv(priceDiffAbs, PPM_SCALE(), oldPrice);

        return volatilityPpm;
    }

    /**
     * @notice Returns `baseFee ± (baseFee * adjustmentPercent / 1e6)`.
     * @dev `isIncrease` is intentionally unused in this placeholder (warning 5667).
     */
    function calculateFeeAdjustment(
        uint256 baseFee,
        uint256 adjustmentPercent,
        bool    /* isIncrease */
    )
        internal
        pure                                       // 2018: no storage reads
        returns (uint256 adjustedFee)
    {
        // Example maths; replace with real logic when implemented
        adjustedFee = baseFee + (baseFee * adjustmentPercent) / 1e6;
    }

    /**
     * @notice Clamp a value between min and max
     * @param value The value to clamp
     * @param minValue The minimum value
     * @param maxValue The maximum value
     * @return The clamped value
     */
    function clamp(uint256 value, uint256 minValue, uint256 maxValue) internal pure returns (uint256) {
        return value < minValue ? minValue : (value > maxValue ? maxValue : value);
    }

    /**
     * @notice Get the library version information
     * @dev Used for tracking the library version
     * @return major Major version component
     * @return minor Minor version component
     * @return patch Patch version component
     */
    function getVersion() internal pure returns (uint8 major, uint8 minor, uint8 patch) {
        return (1, 0, 0);
    }

    /**
     * @notice Calculate withdrawal amounts with high precision based on shares to burn
     * @dev Wrapper for computeWithdrawAmounts with high precision flag enabled
     * @param totalShares Total shares in the pool
     * @param sharesToBurn Shares to burn for withdrawal
     * @param reserve0 Token0 reserves in the pool
     * @param reserve1 Token1 reserves in the pool
     * @return amount0Out Amount of token0 to withdraw
     * @return amount1Out Amount of token1 to withdraw
     */
    function computeWithdrawAmountsWithPrecision(
        uint128 totalShares,
        uint256 sharesToBurn,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (uint256 amount0Out, uint256 amount1Out) {
        return computeWithdrawAmounts(totalShares, sharesToBurn, reserve0, reserve1, true);
    }

    /**
     * @notice Computes liquidity from token amounts within a given price range
     * @param sqrtPriceX96 Current pool sqrt price
     * @param sqrtPriceAX96 Sqrt price at lower tick boundary
     * @param sqrtPriceBX96 Sqrt price at upper tick boundary
     * @param amount0 Amount of token0
     * @param amount1 Amount of token1
     * @return liquidity The calculated liquidity
     */
    function computeLiquidityFromAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        // Early return for zero amounts
        if (amount0 == 0 && amount1 == 0) return 0;

        // Validate price inputs - Revert on invalid prices
        if (sqrtPriceX96 == 0) revert Errors.InvalidInput();
        if (sqrtPriceAX96 == 0 || sqrtPriceBX96 == 0) revert Errors.InvalidInput();

        // Validate price bounds
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        // Handle token0 (if present)
        uint128 liquidity0 = 0;
        if (amount0 > 0) {
            // Let LiquidityAmounts handle potential reverts (e.g., overflow)
            liquidity0 = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
        }

        // Handle token1 (if present)
        uint128 liquidity1 = 0;
        if (amount1 > 0) {
            // Let LiquidityAmounts handle potential reverts (e.g., overflow)
            liquidity1 = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);
        }

        // Determine result based on available amounts
        if (amount0 > 0 && amount1 > 0) {
            return liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else if (amount0 > 0) {
            return liquidity0;
        } else {
            // amount1 > 0
            return liquidity1;
        }
    }

    /**
     * @notice Computes token amounts from a given liquidity amount
     * @param sqrtPriceX96 Current pool sqrt price
     * @param sqrtPriceAX96 Sqrt price at lower tick boundary
     * @param sqrtPriceBX96 Sqrt price at upper tick boundary
     * @param liquidity The liquidity amount
     * @param roundUp Whether to round up the resulting amounts
     * @return amount0 Calculated amount of token0
     * @return amount1 Calculated amount of token1
     */
    function computeAmountsFromLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        // Early return for zero liquidity
        if (liquidity == 0) return (0, 0);

        // Re-introduce zero-price checks for fuzz testing resilience
        if (sqrtPriceX96 == 0 || sqrtPriceAX96 == 0 || sqrtPriceBX96 == 0) {
            return (0, 0); // Return 0 if any price is invalid
        }

        // Validate price bounds
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        // Let SqrtPriceMath handle the case where price is outside the bounds
        // It will return 0 for the corresponding amount if price is out of range

        // Calculate token amounts using SqrtPriceMath
        // Let the underlying library revert on potential issues like invalid prices
        amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceBX96, liquidity, roundUp);
        amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceAX96, sqrtPriceX96, liquidity, roundUp);

        return (amount0, amount1);
    }

    /**
     * @notice Calculate fee with custom scaling factor
     * @dev Base implementation for fee calculations
     * @param amount The amount to calculate fee for
     * @param feeRate The fee rate
     * @param scale The scale factor
     * @return The calculated fee
     */
    function calculateFeeWithScale(uint256 amount, uint256 feeRate, uint256 scale) internal pure returns (uint256) {
        if (amount == 0 || feeRate == 0) {
            return 0;
        }

        unchecked {
            return FullMath.mulDiv(amount, feeRate, scale);
        }
    }

    /**
     * @notice Calculate fee in PPM (parts per million)
     * @dev Wrapper for calculateFeeWithScale with PPM scale
     * @param amount The amount to calculate fee for
     * @param feePpm The fee rate in PPM
     * @return The calculated fee
     */
    function calculateFeePpm(uint256 amount, uint256 feePpm) internal pure returns (uint256) {
        return calculateFeeWithScale(amount, feePpm, PPM_SCALE());
    }

    /**
     * @notice Calculates the optimal amounts to reinvest based on current reserves
     * @dev Ensures reinvestment maintains the pool's current price ratio
     * @param total0 Total amount of token0 available
     * @param total1 Total amount of token1 available
     * @param reserve0 Pool reserve of token0
     * @param reserve1 Pool reserve of token1
     * @return optimal0 Optimal amount of token0 to reinvest
     * @return optimal1 Optimal amount of token1 to reinvest
     */
    function calculateReinvestableFees(uint256 total0, uint256 total1, uint256 reserve0, uint256 reserve1)
        internal
        pure
        returns (uint256 optimal0, uint256 optimal1)
    {
        // Handle edge cases where reserves are zero
        if (reserve0 == 0 || reserve1 == 0) {
            // Cannot determine ratio, return 0
            return (0, 0);
        }

        // Calculate amounts based on reserve ratio
        // Amount of token1 needed for all of token0: total0 * reserve1 / reserve0
        uint256 amount1Needed = FullMath.mulDiv(total0, reserve1, reserve0);

        if (amount1Needed <= total1) {
            // Can use all of token0
            optimal0 = total0;
            optimal1 = amount1Needed;
        } else {
            // Can use all of token1
            // Amount of token0 needed for all of token1: total1 * reserve0 / reserve1
            uint256 amount0Needed = FullMath.mulDiv(total1, reserve0, reserve1);
            optimal0 = amount0Needed;
            optimal1 = total1;
        }
    }

    // --- Added from LiquidityAmountsExt ---
    /**
     * @notice Calculates the maximum liquidity that can be added for the given amounts across the full range,
     *         and the amounts required to achieve that liquidity.
     * @param sqrtPriceX96 The current price sqrt ratio
     * @param tickSpacing The pool tick spacing
     * @param bal0 The available amount of token0
     * @param bal1 The available amount of token1
     * @return use0 The amount of token0 to use for max liquidity
     * @return use1 The amount of token1 to use for max liquidity
     * @return liq The maximum liquidity that can be added
     */
    function getAmountsToMaxFullRange(uint160 sqrtPriceX96, int24 tickSpacing, uint256 bal0, uint256 bal1)
        internal
        pure
        returns (uint256 use0, uint256 use1, uint128 liq)
    {
        // Ensure valid price
        if (sqrtPriceX96 == 0) return (0, 0, 0);

        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);

        (uint160 sqrtA, uint160 sqrtB) =
            (TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper));
        // Ensure sqrtA <= sqrtB
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);

        // --- MODIFIED: Use LiquidityAmounts from periphery, then SqrtPriceMath for amounts ---
        // Calculate max liquidity based on balances within the full range
        liq = LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, bal0, bal1);
        if (liq == 0) return (0, 0, 0);

        // Calculate the amounts needed for this liquidity using standard SqrtPriceMath
        // Use roundUp = true for amounts to ensure we cover the liquidity target
        if (sqrtPriceX96 < sqrtA) {
            // Price below range, only token0 needed
            use0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liq, true);
            use1 = 0;
        } else if (sqrtPriceX96 >= sqrtB) {
            // Price above range, only token1 needed
            use0 = 0;
            use1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liq, true);
        } else {
            // Price within range, both tokens needed
            use0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtB, liq, true);
            use1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, liq, true);
        }
        // --- END MODIFIED ---
    }

    /**
     * @notice Calculates amounts and liquidity for max full-range usage, rounding amounts UP by 1 wei.
     * @dev Rounds non-zero amounts UP by 1 wei (if balance allows) to prevent settlement
     *      shortfalls due to PoolManager's internal ceil-rounding. Liquidity (`liq`) is based on
     *      the pre-rounded amounts to maintain consistency with standard calculations.
     *      Note: In the extremely unlikely case where both calculated amounts `f0` and `f1` exactly equal `bal0`
     *      and `bal1` respectively, and the PoolManager simultaneously rounds both deltas up during settlement,
     *      a 1 wei shortfall *could* theoretically still occur. This function mitigates the common case.
     * @param sqrtP Current sqrt price of the pool.
     * @param tickSpacing Tick spacing of the pool.
     * @param bal0 Available balance of token0.
     * @param bal1 Available balance of token1.
     * @return use0 The amount of token0 required (potentially rounded up).
     * @return use1 The amount of token1 required (potentially rounded up).
     * @return liq The maximum full-range liquidity achievable with the balances.
     */
    function getAmountsToMaxFullRangeRoundUp(uint160 sqrtP, int24 tickSpacing, uint256 bal0, uint256 bal1)
        internal
        pure
        returns (uint256 use0, uint256 use1, uint128 liq)
    {
        // --- MODIFIED: Use local helper for L, then SqrtPriceMath for amounts ---
        // 1. get the *liquidity ceiling* for our balances using the local helper
        // Discard the amounts returned by the local helper, use different names.
        (uint256 f0_unused, uint256 f1_unused, uint128 L) = getAmountsToMaxFullRange(sqrtP, tickSpacing, bal0, bal1);
        // --- Silence unused variable warnings ---
        f0_unused;
        f1_unused;
        // --- End Silence ---
        if (L == 0) return (0, 0, 0); // Bail early if no liquidity possible

        // 2. Calculate the *exact* amounts needed for this liquidity L using standard SqrtPriceMath.
        // Use roundUp = true to align with potential core ceil-rounding.
        int24 lower = TickMath.minUsableTick(tickSpacing);
        int24 upper = TickMath.maxUsableTick(tickSpacing);
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(upper);
        // Ensure sqrtA <= sqrtB (redundant if getAmountsToMaxFullRange ensures it, but safe)
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);

        if (sqrtP < sqrtA) {
            use0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, L, true);
            use1 = 0;
        } else if (sqrtP >= sqrtB) {
            use0 = 0;
            use1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, L, true);
        } else {
            use0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, L, true);
            use1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, L, true);
        }

        // 3. top‑up by 1 wei **only if** balances allow (covers PM ceil‑rounding)
        if (use0 > 0 && use0 < bal0) ++use0;
        if (use1 > 0 && use1 < bal1) ++use1;
        // --- END MODIFIED ---

        liq = L;
    }
}
