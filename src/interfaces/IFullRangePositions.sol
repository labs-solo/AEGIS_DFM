// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC1155} from "v4-core/lib/openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title IFullRangePositions
 * @notice Interface for the FullRangePositions ERC1155 token contract
 */
interface IFullRangePositions is IERC1155 {
    /**
     * @notice Mints tokens to an address
     * @param to The address to mint to
     * @param id The token ID to mint
     * @param amount The amount to mint
     */
    function mint(address to, uint256 id, uint256 amount) external;

    /**
     * @notice Burns tokens from an address
     * @param from The address to burn from
     * @param id The token ID to burn
     * @param amount The amount to burn
     */
    function burn(address from, uint256 id, uint256 amount) external;
}
