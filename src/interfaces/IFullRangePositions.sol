// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title IFullRangePositions
 * @notice Interface for the FullRange ERC1155 position token contract.
 */
interface IFullRangePositions is IERC1155 {
    /**
     * @notice Mints new position tokens.
     * @param to The recipient address.
     * @param id The pool ID representing the token ID.
     * @param amount The amount of shares to mint.
     */
    function mint(address to, uint256 id, uint256 amount) external;

    /**
     * @notice Burns existing position tokens.
     * @param from The address whose tokens are being burned.
     * @param id The pool ID representing the token ID.
     * @param amount The amount of shares to burn.
     */
    function burn(address from, uint256 id, uint256 amount) external;
}
