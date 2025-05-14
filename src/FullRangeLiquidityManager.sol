// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {IFullRangeLiquidityManager} from "./interfaces/IFullRangeLiquidityManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Errors} from "./errors/Errors.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

import {ERC6909Claims} from "v4-core/src/ERC6909Claims.sol";
// TODO: remove OZ ERC6909
// import {ERC6909} from "@openzeppelin/contracts/token/ERC6909/ERC6909.sol";
// import {ERC6909Permit} from "@openzeppelin/contracts/token/ERC6909/extensions/ERC6909Permit.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";

// TODO: make Pausable - NOT NEEDED!!!
// TODO: make effective owner of FRLM the PolicyManager.owner; AND remove Owned from FRLM
// TODO: make deposit and withdraw limited to PolicyManager.owner
// TODO: subtract 1000 from initial depositors liquidity/erc6909 shares - to mimick univ2
// TODO: implement view functions for convenience e.g. get amounts for poolId's NFT?

/**
 * @title FullRangeLiquidityManager
 * @notice Manages hook fees and liquidity for Spot pools
 * @dev Handles fee collection, reinvestment, and allows users to contribute liquidity
 */
contract FullRangeLiquidityManager is IFullRangeLiquidityManager, Owned, ERC6909Claims {
    using PoolIdLibrary for PoolKey;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    /// @notice reason codes
    uint256 constant REASON_NONE = 0;
    uint256 constant REASON_COOLDOWN = 1;
    uint256 constant REASON_THRESHOLD = 2;
    uint256 constant REASON_FAILED = 3;
    uint256 constant REASON_NOT_INITIALIZED = 4;
    uint256 constant REASON_ZERO_LIQUIDITY = 5;
    uint256 constant REASON_PRICE_ERROR = 6;

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
     * @param _owner The owner of the contract
     */
    constructor(
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        address _owner,
        address _authorizedHookAddress
    ) Owned(_owner) {
        if (address(_poolManager) == address(0)) revert Errors.ZeroAddress();
        if (address(_positionManager) == address(0)) revert Errors.ZeroAddress();

        if (_positionManager.poolManager() != _poolManager) revert Errors.PoolPositionManagerMismatch();

        poolManager = _poolManager;
        positionManager = _positionManager;
        // NOTE: since we mine the hook address we can know the address of the hook before we deploy it
        // so We deploy this FRLM then deploy the Spot hook
        authorizedHookAddress = _authorizedHookAddress;
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
        // TODO: remove
        // emit FeeNotified(poolId, fee0, fee1);

        // TODO: move into separate public function and always called afterSwap
        // Emit events only for non-zero amounts
        if (fee0 > 0 || fee1 > 0) {

            // Check if we should try to reinvest
            if (block.timestamp >= lastReinvestment[poolId] + REINVEST_COOLDOWN) {
                _tryReinvest(poolKey);
            }
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

    /// @inheritdoc IFullRangeLiquidityManager
    function deposit(
        PoolKey calldata key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external payable override returns (uint256 shares, uint256 amount0, uint256 amount1) {
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
    ) external override returns (uint256 amount0, uint256 amount1) {
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
    function getPoolReserves(PoolId poolId) external view override returns (uint256 reserve0, uint256 reserve1) {
        // TODO: consider removing as there's not much benefit to this function
        // Placeholder for getPoolReserves implementation
        // Implementation will fetch position details from positionManager and return token amounts
        // This is a placeholder - actual implementation will follow
        return (0, 0);
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
            emit ReinvestmentSkipped(poolId, REASON_COOLDOWN);
            return false;
        }

        // Get pending fees
        (uint256 amount0, uint256 amount1) = (pendingFees[poolId].amount0, pendingFees[poolId].amount1);

        // Check minimum thresholds
        if (amount0 < MIN_REINVEST_AMOUNT || amount1 < MIN_REINVEST_AMOUNT) {
            // emit ReinvestmentSkipped(poolId, REASON_THRESHOLD); // TODO: remove all ReinvestmentSkipped events
            return false;
        }

        // Placeholder for reinvestment logic
        // Implementation will:
        // 1. Check if position exists, if not, create one
        // 2. Calculate liquidity to add
        // 3. Increase liquidity on the NFT position
        // 4. Update accounting

        // This is a placeholder - actual implementation will follow
        emit ReinvestmentSkipped(poolId, REASON_NONE);
        return false;
    }

    /// @inheritdoc IFullRangeLiquidityManager
    function emergencyWithdraw(Currency token, address to, uint256 amount) external override onlyOwner {
        poolManager.take(token, to, amount);
    }

    // TODO: the protocol owned liquidity should be ERC6909 minted to say address(0/1) then implement an onlyOwner function that essentially withdraws/decreases liquidity on the NFT by burning protocol owned liquidity
}
