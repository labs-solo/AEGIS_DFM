// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC6909Claims} from "v4-core/src/ERC6909Claims.sol";
import {Errors} from "../errors/Errors.sol";

/**
 * @title FullRangePositions
 * @notice ERC6909Claims implementation for FullRange position tokens
 * @dev Each pool gets a unique tokenId derived from its poolId
 */
contract FullRangePositions is ERC6909Claims {
    // The address that can mint/burn tokens (LiquidityManager contract)
    address public immutable minter;

    // Token metadata
    string public name;
    string public symbol;

    constructor(string memory _name, string memory _symbol, address _minter) {
        name = _name;
        symbol = _symbol;
        minter = _minter;
    }

    // Only LiquidityManager contract can mint/burn
    modifier onlyMinter() {
        if (msg.sender != minter) revert Errors.AccessNotAuthorized(msg.sender);
        _;
    }

    /**
     * @notice Mint position tokens to a recipient
     * @param to Recipient address
     * @param id Token ID (derived from poolId)
     * @param amount Amount to mint
     */
    function mint(address to, uint256 id, uint256 amount) external onlyMinter {
        _mint(to, id, amount);
    }

    /**
     * @notice Burn position tokens from a holder
     * @param from Token holder
     * @param id Token ID (derived from poolId)
     * @param amount Amount to burn
     */
    function burn(address from, uint256 id, uint256 amount) external onlyMinter {
        _burn(from, id, amount);
    }

    /**
     * @notice Burn tokens from a holder, respecting allowances
     * @param from Token holder
     * @param id Token ID (derived from poolId)
     * @param amount Amount to burn
     */
    function burnFrom(address from, uint256 id, uint256 amount) external onlyMinter {
        _burnFrom(from, id, amount);
    }
}
