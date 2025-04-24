// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "solmate/tokens/ERC20.sol";

/**
 * @title MockERC20
 * @notice A simple ERC20 implementation for testing purposes
 */
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint8 decimals) ERC20(name, symbol, decimals) {}

    /**
     * @notice Mint tokens to a specified address
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens from a specified address
     * @param from The address to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }
}
