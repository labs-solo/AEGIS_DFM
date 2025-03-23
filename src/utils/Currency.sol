// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title Currency
 * @notice Utility functions for handling native ETH and ERC20 tokens
 */
library Currency {
    /// @dev Constant representing ETH (address(0))
    address constant ETH = address(0);
    
    /**
     * @notice Unwraps a currency address (useful for compatibility with v4-core Currency)
     * @param token The token address (ETH is address(0))
     * @return The unwrapped token address
     */
    function unwrap(address token) internal pure returns (address) {
        return token; // For ETH, token == ETH; for ERC20, returns token address
    }
    
    /**
     * @notice Checks if a token address represents ETH
     * @param token The token address to check
     * @return True if token is ETH, false otherwise
     */
    function isETH(address token) internal pure returns (bool) {
        return token == ETH;
    }
} 