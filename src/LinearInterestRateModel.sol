// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IInterestRateModel} from "./interfaces/IInterestRateModel.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
// TODO: Uncomment when Errors.sol is updated or confirm it exists
// import {Errors} from "./errors/Errors.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol"; // Assuming SafeCast exists
import {FullMath} from "v4-core/src/libraries/FullMath.sol"; // Assuming FullMath exists for calculations

/**
 * @title LinearInterestRateModel
 * @notice Implements a standard kinked interest rate model.
 * @dev Rates are calculated linearly based on utilization, with a steeper slope after a defined kink point.
 */
contract LinearInterestRateModel is IInterestRateModel, Owned {
    using SafeCast for uint256;

    // Constants for rate calculations
    uint256 public constant PRECISION = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    // Interest rate parameters (scaled by PRECISION)
    uint256 public baseRatePerYear;         // Base interest rate when utilization = 0
    uint256 public kinkRatePerYear;         // Interest rate at the kink utilization point
    uint256 public kinkUtilizationRate;     // The utilization point at which the slope increases
    uint256 public kinkMultiplier;          // Multiplier applied *to the slope* after kink point
    uint256 public _maxUtilizationRate;     // Maximum allowed utilization (internal to avoid clash)
    uint256 public maxRatePerYear;          // Upper bound on interest rate

    event ParametersUpdated(
        uint256 baseRatePerYear,
        uint256 kinkRatePerYear,
        uint256 kinkUtilizationRate,
        uint256 kinkMultiplier,
        uint256 maxUtilizationRate,
        uint256 maxRatePerYear
    );

    /**
     * @notice Constructor
     * @param _owner Address of the contract owner/governor
     * @param _baseRatePerYear Base rate at 0% utilization (e.g., 0.01e18 for 1%)
     * @param _kinkRatePerYear Rate at the kink utilization (e.g., 0.1e18 for 10%)
     * @param _kinkUtilizationRate Utilization point for the kink (e.g., 0.8e18 for 80%)
     * @param _kinkMultiplier Slope multiplier after the kink (e.g., 5e18 for 5x)
     * @param __maxUtilizationRate Maximum allowed utilization (e.g., 0.95e18 for 95%)
     * @param _maxRatePerYear Absolute maximum rate (e.g., 1e18 for 100%)
     */
    constructor(
        address _owner,
        uint256 _baseRatePerYear,
        uint256 _kinkRatePerYear,
        uint256 _kinkUtilizationRate,
        uint256 _kinkMultiplier,
        uint256 __maxUtilizationRate,
        uint256 _maxRatePerYear
    ) Owned(_owner) {
        _updateParameters(
            _baseRatePerYear,
            _kinkRatePerYear,
            _kinkUtilizationRate,
            _kinkMultiplier,
            __maxUtilizationRate,
            _maxRatePerYear
        );
    }

    /**
     * @inheritdoc IInterestRateModel
     */
    function getBorrowRate(PoolId poolId, uint256 utilization)
        external
        view
        override // from IInterestRateModel
        returns (uint256 ratePerSecond)
    {
        // Reference poolId to avoid unused variable warning; allows future extension
        poolId; // This is often considered poor practice; consider removing if truly unused.

        uint256 currentMaxUtilization = _maxUtilizationRate; // Use internal storage variable

        // Cap utilization based on the model's maximum allowed.
        if (utilization > currentMaxUtilization) {
            utilization = currentMaxUtilization;
        }

        uint256 ratePerYear;
        uint256 currentKinkUtilization = kinkUtilizationRate; // Cache storage reads
        uint256 currentBaseRate = baseRatePerYear; // Cache storage reads
        uint256 currentKinkRate = kinkRatePerYear; // Cache storage reads
        uint256 currentMaxRate = maxRatePerYear; // Cache storage reads

        if (utilization <= currentKinkUtilization) {
            // Linear interpolation before kink: baseRate + slope1 * utilization
            // Ensure kink rate >= base rate (validation done in setter, but belt-and-suspenders)
            if (currentKinkRate < currentBaseRate) {
                 ratePerYear = currentBaseRate; // Should not happen with proper validation
            } else {
                // Slope = (kinkRate - baseRate) / kinkUtil
                // Rate = baseRate + Slope * utilization
                if (currentKinkUtilization == 0) { // Avoid division by zero if kink is at 0%
                    ratePerYear = currentBaseRate; // If kink is at 0, rate is base rate up to 0 util, then kink rate applies
                                                 // But since util <= kinkUtil (0), it must be base rate.
                } else {
                    // Calculate slope carefully to maintain precision
                    uint256 slope1 = FullMath.mulDiv(
                        currentKinkRate - currentBaseRate,
                        PRECISION,
                        currentKinkUtilization
                    );
                    // ratePerYear = baseRate + (slope1 * utilization) / PRECISION
                    ratePerYear = currentBaseRate + FullMath.mulDiv(slope1, utilization, PRECISION);
                }
            }
        } else {
            // Linear interpolation after kink: kinkRate + slope2 * (utilization - kinkUtil)
            uint256 excessUtil = utilization - currentKinkUtilization; // Util is already capped, so excessUtil >= 0
            // Check if max utilization is equal to kink utilization
            // If they are equal, the rate should just be the kink rate.
            if (currentMaxUtilization <= currentKinkUtilization) {
                 ratePerYear = currentKinkRate; // Handle edge case where maxUtil = kinkUtil
            } else {
                uint256 maxExcessUtil = currentMaxUtilization - currentKinkUtilization;

                // Ensure max rate >= kink rate (validation done in setter)
                if (currentMaxRate < currentKinkRate) {
                    ratePerYear = currentKinkRate; // Should not happen with proper validation
                } else {
                    // Slope2_base = (maxRate - kinkRate) / maxExcessUtil
                    // Slope2_actual = Slope2_base * kinkMultiplier (scaled by PRECISION)
                    // Rate = kinkRate + Slope2_actual * excessUtil (scaled by PRECISION)

                    // Calculate base slope after kink
                    uint256 slope2_base = FullMath.mulDiv(
                        currentMaxRate - currentKinkRate,
                        PRECISION,
                        maxExcessUtil // Safe from div by zero due to check above
                    );

                    // Apply kink multiplier
                    // Note: kinkMultiplier itself is scaled by PRECISION (e.g., 5e18 for 5x)
                    uint256 slope2_actual = FullMath.mulDiv(
                        slope2_base,
                        kinkMultiplier, // Use the stored kinkMultiplier directly
                        PRECISION
                    );

                    // Calculate rate
                    ratePerYear = currentKinkRate + FullMath.mulDiv(slope2_actual, excessUtil, PRECISION);
                }
            }
        }

        // Final cap at absolute maximum rate
        if (ratePerYear > currentMaxRate) {
            ratePerYear = currentMaxRate;
        }

        // Ensure rate is not below base rate (shouldn't happen with logic above, but for safety)
        if (ratePerYear < currentBaseRate) {
             ratePerYear = currentBaseRate;
        }

        // Convert annual rate to per-second rate
        // Note: This introduces slight precision loss. Consider if higher precision needed.
        ratePerSecond = ratePerYear / SECONDS_PER_YEAR;
    }

    /**
     * @inheritdoc IInterestRateModel
     */
    function getUtilizationRate(
        PoolId poolId,
        uint256 totalBorrowed,
        uint256 totalSupplied
    ) external pure override returns (uint256 utilization) {
        // Reference poolId to avoid unused variable warning; allows future extension
        poolId;

        if (totalSupplied == 0) return 0; // Avoid division by zero

        // Utilization = Borrowed / Supplied
        // Use SafeMath from FullMath for safety, although SafeCast might suffice
        utilization = FullMath.mulDiv(totalBorrowed, PRECISION, totalSupplied);
    }

    /**
     * @inheritdoc IInterestRateModel
     */
    function maxUtilizationRate() external view override returns (uint256) {
        return _maxUtilizationRate; // Return internal storage variable
    }

    /**
     * @inheritdoc IInterestRateModel
     */
    function getModelParameters() external view override returns (
        uint256 baseRate,
        uint256 kinkRate,
        uint256 kinkUtilization,
        uint256 maxRate,
        uint256 _kinkMultiplier // renamed to avoid shadowing
    ) {
        return (
            baseRatePerYear,
            kinkRatePerYear,
            kinkUtilizationRate,
            maxRatePerYear,
            kinkMultiplier
        );
    }

    // --- Governance Functions ---

    /**
     * @notice Update all model parameters at once. Only callable by the owner.
     * @param _baseRatePerYear New base rate at 0% utilization
     * @param _kinkRatePerYear New rate at the kink utilization
     * @param _kinkUtilizationRate New utilization point for the kink
     * @param _kinkMultiplier New slope multiplier after the kink
     * @param __maxUtilizationRate New maximum allowed utilization
     * @param _maxRatePerYear New absolute maximum rate
     */
    function updateParameters(
        uint256 _baseRatePerYear,
        uint256 _kinkRatePerYear,
        uint256 _kinkUtilizationRate,
        uint256 _kinkMultiplier,
        uint256 __maxUtilizationRate,
        uint256 _maxRatePerYear
    ) external onlyOwner {
         _updateParameters(
            _baseRatePerYear,
            _kinkRatePerYear,
            _kinkUtilizationRate,
            _kinkMultiplier,
            __maxUtilizationRate,
            _maxRatePerYear
        );
    }

    /**
     * @notice Internal logic for parameter validation and update.
     */
    function _updateParameters(
        uint256 _baseRatePerYear,
        uint256 _kinkRatePerYear,
        uint256 _kinkUtilizationRate,
        uint256 _kinkMultiplier,
        uint256 __maxUtilizationRate,
        uint256 _maxRatePerYear
    ) internal {
        // Basic Validations
        // TODO: Use specific Errors from Errors.sol once available/updated
        require(__maxUtilizationRate <= PRECISION, "IRM: Max util <= 100%");
        require(_kinkUtilizationRate <= __maxUtilizationRate, "IRM: Kink util <= max util");
        // Multiplier represents a factor, 1x = PRECISION
        require(_kinkMultiplier >= PRECISION, "IRM: Kink mult >= 1x");
        require(_kinkRatePerYear >= _baseRatePerYear, "IRM: Kink rate >= base rate");
        require(_maxRatePerYear >= _kinkRatePerYear, "IRM: Max rate >= kink rate");
        // Add check: base rate cannot exceed max rate (implicitly covered but good to be explicit)
        require(_maxRatePerYear >= _baseRatePerYear, "IRM: Max rate >= base rate");

        baseRatePerYear = _baseRatePerYear;
        kinkRatePerYear = _kinkRatePerYear;
        kinkUtilizationRate = _kinkUtilizationRate;
        kinkMultiplier = _kinkMultiplier;
        _maxUtilizationRate = __maxUtilizationRate;
        maxRatePerYear = _maxRatePerYear;

        emit ParametersUpdated(
            baseRatePerYear,
            kinkRatePerYear,
            kinkUtilizationRate,
            kinkMultiplier,
            _maxUtilizationRate, // Use internal name
            maxRatePerYear
        );
    }
} 