// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// - - - V4 Core Deps - - -

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {ERC6909Claims} from "v4-core/src/ERC6909Claims.sol";

// - - - V4 Periphery Deps - - -

import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

// - - - Project Interfaces - - -

import {Errors} from "./errors/Errors.sol";
import {IFullRangeLiquidityManager} from "./interfaces/IFullRangeLiquidityManager.sol";

// - - - Project Contracts - - -

import {PoolPolicyManager} from "./PoolPolicyManager.sol";

// TODO(high): subtract 1000 from initial depositors liquidity/erc6909 shares(i.e. when ) - to mimick univ2 to effectively guarantee 1000 liquidity is locked in the full range position

/**
 * @title FullRangeLiquidityManager
 * @notice Manages hook fees and liquidity for Spot pools
 * @dev Handles fee collection, reinvestment, and allows users to contribute liquidity
 */
contract FullRangeLiquidityManager is IFullRangeLiquidityManager, ERC6909Claims {
    using PoolIdLibrary for PoolKey;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    /// @notice Cooldown period between reinvestments (default: 1 day)
    uint256 public constant REINVEST_COOLDOWN = 1 days;

    /// @notice Minimum amount to reinvest to avoid dust
    uint256 public constant MIN_REINVEST_AMOUNT = 1e4;

    /// @notice The "constant" Spot hook contract address that can notify fees
    address public immutable override authorizedHookAddress;

    /// @notice The Uniswap V4 PoolManager
    IPoolManager public immutable poolManager;

    /// @notice The Uniswap V4 PositionManager for adding liquidity
    IPositionManager public immutable positionManager;

    /// @notice The policy manager contract that determines ownership
    PoolPolicyManager public immutable policyManager;

    struct PendingFees {
        uint256 amount0;
        uint256 amount1;
    }

    /// @notice Pending fees per pool
    mapping(PoolId => PendingFees) public pendingFees;

    /// @notice Last reinvestment timestamp per pool
    mapping(PoolId => uint256) public lastReinvestment;

    /// @notice NFT token IDs for full range positions
    mapping(PoolId => uint256) public positionIds;

    /**
     * @notice Constructs the FullRangeLiquidityManager
     * @param _poolManager The Uniswap V4 PoolManager
     * @param _positionManager The Uniswap V4 PositionManager
     * @param _policyManager The policy manager contract
     * @param _authorizedHookAddress The hook address that can notify fees
     */
    constructor(
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        PoolPolicyManager _policyManager,
        address _authorizedHookAddress
    ) {
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();
        if (address(_positionManager) == address(0)) revert Errors.ZeroAddress();
        if (address(_policyManager) == address(0)) revert Errors.ZeroAddress();
        if (_authorizedHookAddress == address(0)) revert Errors.ZeroAddress();

        if (_positionManager.poolManager() != _poolManager) revert Errors.PoolPositionManagerMismatch();

        poolManager = _poolManager;
        positionManager = _positionManager;
        policyManager = _policyManager;
        authorizedHookAddress = _authorizedHookAddress;
    }

    /**
     * @notice Modifier to check if the caller is the policy manager owner
     */
    modifier onlyPolicyOwner() {
        if (msg.sender != policyManager.owner()) revert Errors.UnauthorizedCaller(msg.sender);
        _;
    }

    /**
     * @notice Modifier to ensure only the Spot hook can call
     */
    modifier onlyAuthorizedHook() {
        if (msg.sender != authorizedHookAddress) revert Errors.UnauthorizedCaller(msg.sender);
        _;
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function notifyFee(PoolKey calldata poolKey, uint256 fee0, uint256 fee1) external override onlyAuthorizedHook {
        PoolId poolId = poolKey.toId();
        // Update pending fees
        if (fee0 > 0) {
            pendingFees[poolId].amount0 += fee0;
        }

        if (fee1 > 0) {
            pendingFees[poolId].amount1 += fee1;
        }
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function reinvest(PoolKey calldata key) external override returns (bool success) {
        return _tryReinvest(key);
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function getPendingFees(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = (pendingFees[poolId].amount0, pendingFees[poolId].amount1);
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function getNextReinvestmentTime(PoolId poolId) external view override returns (uint256 timestamp) {
        uint256 last = lastReinvestment[poolId];
        if (last == 0) return block.timestamp;
        return last + REINVEST_COOLDOWN;
    }

    function getPositionInfo(PoolId poolId)
        external
        view
        returns (uint256 positionId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        // TODO: implement
    }

    function getLiquidityForShares(PoolId poolId, uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        // TODO: implement
    }

    function getProtocolOwnedLiquidity(PoolId poolId)
        external
        view
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        // TODO: implement
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function deposit(
        PoolKey calldata key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external payable override onlyPolicyOwner returns (uint256 shares, uint256 amount0, uint256 amount1) {
        // Placeholder for deposit implementation
        // Implementation will:
        // 1. Verify the pool is initialized
        // 2. Handle any ETH wrapping if a currency is native ETH
        // 3. Transfer tokens from user to this contract
        // 4. Increase liquidity on the NFT position or create a new one
        // 5. Mint ERC6909 shares to the recipient based on liquidity contribution
        // 6. Return shares and actual amounts used

        // This is a placeholder - actual implementation will follow
        revert("Not implemented");
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function withdraw(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external override onlyPolicyOwner returns (uint256 amount0, uint256 amount1) {
        // Placeholder for withdraw implementation
        // Implementation will:
        // 1. Verify the pool is initialized and user has sufficient shares
        // 2. Calculate proportion of position to withdraw
        // 3. Decrease liquidity on the NFT position
        // 4. Burn ERC6909 shares
        // 5. Transfer tokens to recipient
        // 6. Unwrap ETH if a currency is native ETH and recipient is not a contract

        // This is a placeholder - actual implementation will follow
        revert("Not implemented");
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function emergencyWithdraw(Currency token, address to, uint256 amount) external override onlyPolicyOwner {
        poolManager.take(token, to, amount);
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function withdrawProtocolLiquidity(
        PoolKey calldata key,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external override onlyPolicyOwner returns (uint256 amount0, uint256 amount1) {
        // Implementation will:
        // 1. Get the protocol-owned ERC6909 balance (shares owned by address(this))
        // 2. Get the NFT position ID for the pool
        // 4. Call PositionManager to decrease liquidity on the NFT by sharesToBurn since shares correspond 1:1 with NFT liquidity
        // 5. Transfer resulting tokens to the recipient
        // 6. Return the amounts of tokens received

        // Placeholder - actual implementation will depend on PositionManager interface
        revert("Not implemented");
    }

    /**
     * @notice Attempts to reinvest pending fees for a pool
     * @param poolKey The PoolKey
     * @return success Whether the reinvestment was successful
     */
    function _tryReinvest(PoolKey calldata poolKey) internal returns (bool success) {
        // Check cooldown period
        PoolId poolId = poolKey.toId();
        if (block.timestamp < lastReinvestment[poolId] + REINVEST_COOLDOWN) {
            return false;
        }

        // Get pending fees
        (uint256 amount0, uint256 amount1) = (pendingFees[poolId].amount0, pendingFees[poolId].amount1);

        // Check minimum thresholds
        if (amount0 < MIN_REINVEST_AMOUNT || amount1 < MIN_REINVEST_AMOUNT) {
            return false;
        }

        // Placeholder for reinvestment logic
        // Implementation will:
        // 1. Check if position exists, if not, create one
        // 2. Calculate liquidity to add
        // 3. Increase liquidity on the NFT position
        // 4. Update accounting

        return false;
    }
}
