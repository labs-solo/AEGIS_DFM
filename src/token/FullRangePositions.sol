// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC6909Claims} from "@uniswap/v4-core/src/ERC6909Claims.sol";
import {Errors} from "../errors/Errors.sol";
import {IFullRangePositions} from "../interfaces/IFullRangePositions.sol";

/**
 * @title FullRangePositions
 * @notice ERC6909Claims implementation for FullRange position tokens
 * @dev Each pool gets a unique tokenId derived from its poolId
 */
/// @notice ERC-6909 share token that also tracks V4 liquidity.
contract FullRangePositions is ERC6909Claims, IFullRangePositions {
    // The address that can mint/burn tokens (LiquidityManager contract)
    address public immutable minter;

    // Token metadata
    string public name;
    string public symbol;

    // Keep internal struct definition for storage
    struct PositionInfo {
        mapping(address => uint256) balanceOf;
        uint128 liquidity;
    }

    mapping(bytes32 => PositionInfo) internal _positions; // pool-id → info
    mapping(bytes32 => uint256) internal _totalSupply; // total ERC-6909 shares per pool

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

    function _mint(bytes32 id, address to, uint256 amount) internal {
        PositionInfo storage p = _positions[id];
        p.balanceOf[to] += amount;
        _totalSupply[id] += amount;
    }

    function _burn(bytes32 id, address from, uint256 amount) internal {
        PositionInfo storage p = _positions[id];
        p.balanceOf[from] -= amount;
        _totalSupply[id] -= amount;
    }

    /* ───────────────────────── PUBLIC GETTERS ───────────────────────── */
    /// @inheritdoc IFullRangePositions
    function totalSupply(bytes32 id) public view override returns (uint256) {
        return _totalSupply[id];
    }

    /// @inheritdoc IFullRangePositions
    function positionLiquidity(bytes32 id) external view override returns (uint128) {
        return _positions[id].liquidity;
    }

    /// @inheritdoc IFullRangePositions
    function shareBalance(bytes32 id, address owner) external view override returns (uint256) {
        return _positions[id].balanceOf[owner];
    }
}
