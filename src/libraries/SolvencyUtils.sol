// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { FullMath } from "v4-core/src/libraries/FullMath.sol";
import { MathUtils } from "./MathUtils.sol"; // Assuming MathUtils is in the same directory
import { PrecisionConstants } from "./PrecisionConstants.sol"; // Import for standardized precision constants
import { IMarginData } from "../interfaces/IMarginData.sol"; // Import IMarginData directly for Vault struct

/**
 * @title SolvencyUtils
 * @notice Utility functions for calculating vault solvency and LTV.
 * @dev Core utility functions for solvency checks and LTV calculations.
 */
library SolvencyUtils {
    /**
     * @notice Checks if a position is solvent based on its collateral value vs. debt value.
     * @param collateralValue The value of the collateral (e.g., in LP share equivalent).
     * @param debtValue The value of the debt (e.g., debt shares adjusted for interest).
     * @param solvencyThreshold The threshold below which the position is considered solvent (debt/collateral < threshold). Scaled by PrecisionConstants.PRECISION.
     * @param precision The precision factor used for scaling (defaults to PrecisionConstants.PRECISION).
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
     * @notice Checks if a position is solvent based on its collateral value vs. debt value.
     * @param collateralValue The value of the collateral (e.g., in LP share equivalent).
     * @param debtValue The value of the debt (e.g., debt shares adjusted for interest).
     * @param solvencyThreshold The threshold below which the position is considered solvent (debt/collateral < threshold). Scaled by PrecisionConstants.PRECISION.
     * @return True if solvent (debt/collateral < threshold), False otherwise.
     */
    function isSolvent(
        uint256 collateralValue,
        uint256 debtValue,
        uint256 solvencyThreshold
    ) internal pure returns (bool) {
        return isSolvent(collateralValue, debtValue, solvencyThreshold, PrecisionConstants.PRECISION);
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
        // Calculate LTV scaled by PrecisionConstants.PRECISION (debt * precision / value)
        return FullMath.mulDiv(debtValue, precision, collateralValue);
    }

    /**
     * @notice Calculates the Loan-to-Value (LTV) ratio using default precision.
     * @param collateralValue The value of the collateral.
     * @param debtValue The value of the debt.
     * @return LTV ratio scaled by PrecisionConstants.PRECISION.
     */
    function calculateLTV(
        uint256 collateralValue,
        uint256 debtValue
    ) internal pure returns (uint256) {
        return calculateLTV(collateralValue, debtValue, PrecisionConstants.PRECISION);
    }

    /**
     * @notice Calculates the current debt value based on base debt shares and interest multiplier.
     * @param vault The user's vault data.
     * @param interestMultiplier The current interest multiplier for the pool (scaled by PrecisionConstants.PRECISION).
     * @param precision The precision factor.
     * @return currentDebtValue The debt value including accrued interest.
     */
    function calculateCurrentDebtValue(
        IMarginData.Vault memory vault,
        uint256 interestMultiplier,
        uint256 precision
    ) internal pure returns (uint256 currentDebtValue) {
        uint128 baseDebtShare = uint128(vault.debtShares);
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
     * @notice Calculates the current debt value based on base debt shares and interest multiplier using default precision.
     * @param vault The user's vault data.
     * @param interestMultiplier The current interest multiplier for the pool (scaled by PrecisionConstants.PRECISION).
     * @return currentDebtValue The debt value including accrued interest.
     */
    function calculateCurrentDebtValue(
        IMarginData.Vault memory vault,
        uint256 interestMultiplier
    ) internal pure returns (uint256 currentDebtValue) {
        return calculateCurrentDebtValue(vault, interestMultiplier, PrecisionConstants.PRECISION);
    }

    /**
     * @notice Calculates the current debt value from a base debt share and interest multiplier.
     * @param baseDebtShare The base debt share amount.
     * @param interestMultiplier The current interest multiplier for the pool (scaled by PrecisionConstants.PRECISION).
     * @param precision The precision factor.
     * @return currentDebtValue The debt value including accrued interest.
     */
    function calculateCurrentDebtValue(
        uint256 baseDebtShare,
        uint256 interestMultiplier,
        uint256 precision
    ) internal pure returns (uint256 currentDebtValue) {
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
     * @notice Calculates the current debt value from a base debt share and interest multiplier using default precision.
     * @param baseDebtShare The base debt share amount.
     * @param interestMultiplier The current interest multiplier for the pool (scaled by PrecisionConstants.PRECISION).
     * @return currentDebtValue The debt value including accrued interest.
     */
    function calculateCurrentDebtValue(
        uint256 baseDebtShare,
        uint256 interestMultiplier
    ) internal pure returns (uint256 currentDebtValue) {
        return calculateCurrentDebtValue(baseDebtShare, interestMultiplier, PrecisionConstants.PRECISION);
    }
} 