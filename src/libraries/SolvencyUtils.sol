// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { FullMath } from "v4-core/src/libraries/FullMath.sol";
import { MathUtils } from "./MathUtils.sol"; // Assuming MathUtils is in the same directory
import { IMargin } from "../interfaces/IMargin.sol"; // Import IMargin for Vault struct

/**
 * @title SolvencyUtils
 * @notice Utility functions for calculating vault solvency and LTV.
 */
library SolvencyUtils {
    /**
     * @notice Checks if a position is solvent based on its collateral value vs. debt value.
     * @param collateralValue The value of the collateral (e.g., in LP share equivalent).
     * @param debtValue The value of the debt (e.g., debt shares adjusted for interest).
     * @param solvencyThreshold The threshold below which the position is considered solvent (debt/collateral < threshold). Scaled by PRECISION.
     * @param precision The precision factor used for scaling (e.g., 1e18).
     * @return True if solvent (debt/collateral < threshold), False otherwise.
     */
    function isSolvent(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 solvencyThreshold,
        uint256 precision
    ) internal pure returns (bool) {
        // If there is no debt, it's always solvent.
        if (debtValue == 0) {
            return true;
        }

        // If collateral is zero but debt exists, it's insolvent.
        if (collateralValue == 0) {
            return false;
        }

        // Check solvency: debt / collateral < threshold
        // Rearranged to avoid division: debt * precision < threshold * collateral
        // Use FullMath for safe multiplication and division.
        return FullMath.mulDiv(debtValue, precision, collateralValue) < solvencyThreshold;
    }

    /**
     * @notice Calculates the Loan-to-Value (LTV) ratio.
     * @param collateralValue The value of the collateral.
     * @param debtValue The value of the debt.
     * @param precision The precision factor used for scaling (e.g., 1e18).
     * @return LTV ratio scaled by precision (debt * precision / collateralValue). Returns type(uint256).max if collateralValue is 0.
     */
    function calculateLTV(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 precision
    ) internal pure returns (uint256) {
        // If user has no debt, LTV is 0.
        if (debtValue == 0) {
            return 0;
        }

        // If collateral value is zero but debt exists, LTV is effectively infinite.
        if (collateralValue == 0) {
            return type(uint256).max;
        }

        // LTV = Debt / Value
        // Calculate LTV scaled by PRECISION (debt * precision / value)
        return FullMath.mulDiv(debtValue, precision, collateralValue);
    }

    // =========================================================================
    // New Helper Functions (Integrating Margin-specific logic)
    // =========================================================================

    /**
     * @notice Calculates the current debt value based on base debt shares and interest multiplier.
     * @param vault The user's vault data.
     * @param interestMultiplier The current interest multiplier for the pool (scaled by precision).
     * @param precision The precision factor.
     * @return currentDebtValue The debt value including accrued interest.
     */
    function calculateCurrentDebtValue(
        IMargin.Vault memory vault,
        uint256 interestMultiplier,
        uint256 precision
    ) internal pure returns (uint256 currentDebtValue) {
        uint128 baseDebtShare = vault.debtShare;
        if (baseDebtShare == 0) {
            return 0;
        }
        // If multiplier is 0 (should not happen after init) or exactly precision (no interest yet),
        // return the base debt share.
        if (interestMultiplier == 0 || interestMultiplier == precision) {
            return baseDebtShare;
        }
        return FullMath.mulDiv(baseDebtShare, interestMultiplier, precision);
    }

    /**
     * @notice Checks solvency based on full vault and pool state.
     * @param vault User's vault.
     * @param reserve0 Pool reserve0.
     * @param reserve1 Pool reserve1.
     * @param totalLiquidity Pool total liquidity.
     * @param interestMultiplier Pool's current interest multiplier.
     * @param solvencyThreshold The solvency threshold (scaled by precision).
     * @param precision The precision factor.
     * @return True if solvent, false otherwise.
     */
    function checkVaultSolvency(
        IMargin.Vault memory vault,
        uint256 reserve0,
        uint256 reserve1,
        uint128 totalLiquidity,
        uint256 interestMultiplier,
        uint256 solvencyThreshold,
        uint256 precision
    ) internal view returns (bool) {
        // 1. Calculate Collateral Value (using existing MathUtils)
        uint256 collateralValue = MathUtils.calculateProportionalShares(
            vault.token0Balance,
            vault.token1Balance,
            totalLiquidity,
            reserve0,
            reserve1,
            false // Standard precision assumed
        );

        // 2. Calculate Current Debt Value (using helper)
        uint256 currentDebtValue = calculateCurrentDebtValue(vault, interestMultiplier, precision);

        // 3. Call core solvency check
        return isSolvent(collateralValue, currentDebtValue, solvencyThreshold, precision);
    }

    /**
     * @notice Calculates LTV based on full vault and pool state.
     * @param vault User's vault.
     * @param reserve0 Pool reserve0.
     * @param reserve1 Pool reserve1.
     * @param totalLiquidity Pool total liquidity.
     * @param interestMultiplier Pool's current interest multiplier.
     * @param precision The precision factor.
     * @return ltv LTV ratio scaled by precision.
     */
    function computeVaultLTV(
        IMargin.Vault memory vault,
        uint256 reserve0,
        uint256 reserve1,
        uint128 totalLiquidity,
        uint256 interestMultiplier,
        uint256 precision
    ) internal view returns (uint256 ltv) {
        // 1. Calculate Collateral Value
         uint256 collateralValue = MathUtils.calculateProportionalShares(
            vault.token0Balance,
            vault.token1Balance,
            totalLiquidity,
            reserve0,
            reserve1,
            false // Standard precision assumed
        );

        // 2. Calculate Current Debt Value
        uint256 currentDebtValue = calculateCurrentDebtValue(vault, interestMultiplier, precision);

        // 3. Call core LTV calculation
        return calculateLTV(collateralValue, currentDebtValue, precision);
    }

    /**
     * @notice Checks solvency with specified (potentially hypothetical) balances/debt.
     * @param token0Balance Hypothetical token0 balance.
     * @param token1Balance Hypothetical token1 balance.
     * @param baseDebtShare Hypothetical base debt share (before multiplier).
     * @param reserve0 Pool reserve0.
     * @param reserve1 Pool reserve1.
     * @param totalLiquidity Pool total liquidity.
     * @param interestMultiplier Pool's current interest multiplier.
     * @param solvencyThreshold The solvency threshold (scaled by precision).
     * @param precision The precision factor.
     * @return True if solvent, false otherwise.
     */
    function checkSolvencyWithValues(
        uint128 token0Balance,
        uint128 token1Balance,
        uint128 baseDebtShare,
        uint256 reserve0,
        uint256 reserve1,
        uint128 totalLiquidity,
        uint256 interestMultiplier,
        uint256 solvencyThreshold,
        uint256 precision
    ) internal view returns (bool) {
         // 1. Calculate Collateral Value
         uint256 collateralValue = MathUtils.calculateProportionalShares(
            token0Balance,
            token1Balance,
            totalLiquidity,
            reserve0,
            reserve1,
            false // Standard precision assumed
        );

        // 2. Calculate Current Debt Value (using baseDebtShare and multiplier)
        uint256 currentDebtValue;
        if (baseDebtShare == 0) {
            currentDebtValue = 0;
        } else if (interestMultiplier == 0 || interestMultiplier == precision) {
             currentDebtValue = baseDebtShare;
        } else {
            currentDebtValue = FullMath.mulDiv(baseDebtShare, interestMultiplier, precision);
        }

        // 3. Call core solvency check
        return isSolvent(collateralValue, currentDebtValue, solvencyThreshold, precision);
    }

} 