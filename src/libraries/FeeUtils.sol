// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FullMath} from "lib/v4-core/src/libraries/FullMath.sol";
import {MathUtils} from "./MathUtils.sol";

/**
 * @title FeeUtils
 * @notice Consolidated utilities for fee calculations and distribution
 */
library FeeUtils {
    // Constants from MathUtils
    uint256 private constant PRECISION = 1e18;
    uint256 private constant PPM_SCALE = 1_000_000;

    /**
     * @notice Calculate fee shares and distribution
     * @param amount0 Token0 fee amount
     * @param amount1 Token1 fee amount
     * @param totalLiquidity Total pool liquidity
     * @param polSharePpm Protocol owned liquidity share (in PPM)
     * @param fullRangeSharePpm Full range share (in PPM)
     * @return shares Total shares to mint
     * @return pol0 Protocol owned liquidity share of token0
     * @return pol1 Protocol owned liquidity share of token1
     * @return fullRange0 Full range share of token0
     * @return fullRange1 Full range share of token1
     * @return lp0 LP share of token0
     * @return lp1 LP share of token1
     */
    function calculateFeeDistribution(
        uint256 amount0,
        uint256 amount1,
        uint256 totalLiquidity,
        uint256 polSharePpm,
        uint256 fullRangeSharePpm
    ) internal pure returns (
        uint256 shares,
        uint256 pol0,
        uint256 pol1,
        uint256 fullRange0,
        uint256 fullRange1,
        uint256 lp0,
        uint256 lp1
    ) {
        // Calculate total shares based on geometric mean
        shares = MathUtils.calculateGeometricShares(amount0, amount1);
        if (totalLiquidity == 0 || shares == 0) {
            return (0, 0, 0, 0, 0, 0, 0);
        }

        // Calculate LP share (remainder)
        uint256 lpSharePpm = PPM_SCALE - polSharePpm - fullRangeSharePpm;
        
        // Calculate token distributions
        pol0 = (amount0 * polSharePpm) / PPM_SCALE;
        pol1 = (amount1 * polSharePpm) / PPM_SCALE;
        
        fullRange0 = (amount0 * fullRangeSharePpm) / PPM_SCALE;
        fullRange1 = (amount1 * fullRangeSharePpm) / PPM_SCALE;
        
        lp0 = (amount0 * lpSharePpm) / PPM_SCALE;
        lp1 = (amount1 * lpSharePpm) / PPM_SCALE;
        
        // Handle rounding errors
        uint256 totalAllocated0 = pol0 + fullRange0 + lp0;
        uint256 totalAllocated1 = pol1 + fullRange1 + lp1;
        
        if (totalAllocated0 < amount0) {
            lp0 += amount0 - totalAllocated0;
        }
        
        if (totalAllocated1 < amount1) {
            lp1 += amount1 - totalAllocated1;
        }
    }
} 