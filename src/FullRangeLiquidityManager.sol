// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {MathUtils} from "./libraries/MathUtils.sol";
import {Errors} from "./errors/Errors.sol";
import {FullRangePositions} from "./token/FullRangePositions.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PoolTokenIdUtils} from "./utils/PoolTokenIdUtils.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "./interfaces/IFullRangeLiquidityManager.sol";
import {FullRangeUtils} from "./utils/FullRangeUtils.sol";
import {SettlementUtils} from "./utils/SettlementUtils.sol";
import {CurrencySettlerExtension} from "./utils/CurrencySettlerExtension.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

using SafeCast for uint256;
using SafeCast for int256;

/**
 * @title FullRangeLiquidityManager
 * @notice Manages full-range liquidity positions across multiple pools
 * @dev This contract handles deposit, withdrawal, and rebalancing
 */
contract FullRangeLiquidityManager is Owned, ReentrancyGuard, IFullRangeLiquidityManager {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    
    // Constants for deposit/withdraw actions
    uint8 internal constant ACTION_DEPOSIT = 1;
    uint8 internal constant ACTION_WITHDRAW = 2;
    
    // Callback data structure for unlock pattern
    struct CallbackData {
        PoolId poolId;
        uint8 callbackType; // 1 for deposit, 2 for withdraw
        uint128 shares;
        uint256 amount0;
        uint256 amount1;
        address recipient;
    }
    
    // Consolidated pool information struct
    struct PoolInfo {
        uint128 totalShares;  // Total pool shares
        uint256 reserve0;     // Token0 reserves
        uint256 reserve1;     // Token1 reserves
    }
    
    // User position information
    struct AccountPosition {
        bool initialized;     // Whether the position has been initialized
        uint256 shares;       // User's share balance
    }
    
    /// @dev The Uniswap V4 PoolManager reference
    IPoolManager public immutable manager;
    
    /// @dev ERC6909Claims token for position tokenization
    FullRangePositions public immutable positions;
    
    /// @dev Stored pool data
    mapping(PoolId => PoolInfo) public pools;
    
    /// @dev Pool keys for lookups
    mapping(PoolId => PoolKey) private _poolKeys;
    
    /// @dev User position data
    mapping(PoolId => mapping(address => AccountPosition)) public userPositions;
    
    /// @dev Maximum reserve cap to prevent unbounded growth
    uint256 public constant MAX_RESERVE = type(uint128).max;
    
    /// @dev Address of the FullRange main contract
    address public fullRangeAddress;
    
    // Emergency controls
    bool public emergencyWithdrawalsEnabled = false;
    mapping(PoolId => bool) public poolEmergencyState;
    uint256 public emergencyWithdrawalCooldown = 1 days;
    mapping(address => mapping(PoolId => uint256)) public lastEmergencyWithdrawal;
    address public emergencyAdmin;
    
    // ETH handling
    mapping(address => uint256) public pendingETHPayments;
    uint256 public ethTransferGasLimit = 50000; // Default gas limit
    uint8 public maxETHRetries = 1; // Default to 1 retry attempt
    
    // Rate limiting for ETH refunds
    mapping(address => uint256) public lastRefundTimestamp;
    uint256 public refundCooldown = 1 minutes; // Default cooldown period
    uint256 public maxRefundPerPeriod = 10 ether; // Default max refund per period
    mapping(address => uint256) public refundAmountInPeriod;
    
    // Tracking locked liquidity
    mapping(PoolId => uint256) public lockedLiquidity;
    
    // Constants
    uint256 private constant MIN_VIABLE_RESERVE = 100;
    
    // Events for pool management
    event PoolInitialized(PoolId indexed poolId, PoolKey key, uint160 sqrtPrice, uint24 fee);
    event TotalLiquidityUpdated(PoolId indexed poolId, uint128 oldLiquidity, uint128 newLiquidity);
    
    // Events for liquidity operations
    event LiquidityAdded(
        PoolId indexed poolId,
        address indexed user,
        uint256 amount0,
        uint256 amount1,
        uint128 sharesTotal,
        uint128 sharesMinted,
        uint256 timestamp
    );
    event LiquidityRemoved(
        PoolId indexed poolId,
        address indexed user,
        uint256 amount0,
        uint256 amount1,
        uint128 sharesTotal,
        uint128 sharesBurned,
        uint256 timestamp
    );
    event ReserveCapped(PoolId indexed poolId, uint256 amount0Excess, uint256 amount1Excess);
    event MinimumLiquidityLocked(PoolId indexed poolId, uint256 amount);
    
    // Emergency events
    event EmergencyStateActivated(PoolId indexed poolId, address indexed activator, string reason);
    event EmergencyStateDeactivated(PoolId indexed poolId, address indexed deactivator);
    event GlobalEmergencyStateChanged(bool enabled, address indexed changedBy);
    event EmergencyWithdrawalCompleted(
        PoolId indexed poolId,
        address indexed user,
        uint256 amount0Out,
        uint256 amount1Out,
        uint256 sharesBurned
    );
    event EmergencyCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);
    
    // ETH handling events
    event ETHTransferFailed(address indexed recipient, uint256 amount);
    event ETHClaimed(address indexed recipient, uint256 amount);
    event ETHTransferGasLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event MaxETHRetriesUpdated(uint8 oldValue, uint8 newValue);
    
    /**
     * @notice Consolidated event for reinvestment operations
     * @dev Reduces gas costs by combining multiple events
     */
    event ReinvestmentProcessed(
        PoolId indexed poolId, 
        uint256 amount0, 
        uint256 amount1, 
        uint256 shares,
        uint128 oldTotalShares,
        uint128 newTotalShares
    );
    
    /**
     * @notice Simplified event for pool state updates
     * @dev Operation types: 1=deposit, 2=withdraw, 3=reinvest
     */
    event PoolStateUpdated(
        PoolId indexed poolId,
        uint128 totalShares,
        uint8 operationType
    );
    
    // Add new event for partial refunds
    event RefundPartiallyDelayed(address indexed recipient, uint256 refunded, uint256 pending);
    event RefundCooldownUpdated(uint256 oldValue, uint256 newValue);
    event MaxRefundPerPeriodUpdated(uint256 oldValue, uint256 newValue);
    
    // Add new events for retry mechanism
    event ETHTransferRetrySucceeded(address indexed recipient, uint256 amount, uint8 attempts, uint256 gasLimit);
    event ETHTransferRetryFailed(address indexed recipient, uint256 amount, uint8 attempts, uint256 gasLimit);
    
    // These are kept for backward compatibility but will be no-ops
    event PositionCacheUpdated(PoolId indexed poolId, uint128 liquidity, uint160 sqrtPriceX96);
    
    // Storage slot constants for V4 state access
    bytes32 private constant POOLS_SLOT = bytes32(uint256(6));
    uint256 private constant POSITIONS_OFFSET = 6;
    
    /**
     * @notice Constructor
     * @param _manager The Uniswap V4 pool manager
     * @param _owner The owner of the contract
     */
    constructor(IPoolManager _manager, address _owner) Owned(_owner) {
        manager = _manager;
        
        // Create position token contract
        positions = new FullRangePositions("FullRange Position", "FRP", address(this));
    }
    
    /**
     * @notice Sets the FullRange main contract address
     * @param _fullRangeAddress The address of the FullRange contract
     */
    function setFullRangeAddress(address _fullRangeAddress) external onlyOwner {
        if (_fullRangeAddress == address(0)) revert Errors.ZeroAddress();
        fullRangeAddress = _fullRangeAddress;
    }
    
    /**
     * @notice Sets the emergency admin address
     * @param _emergencyAdmin The new emergency admin address
     */
    function setEmergencyAdmin(address _emergencyAdmin) external onlyOwner {
        emergencyAdmin = _emergencyAdmin;
    }
    
    /**
     * @notice Access control modifier for FullRange or owner
     */
    modifier onlyFullRangeOrOwner() {
        if (msg.sender != fullRangeAddress && msg.sender != owner) {
            revert Errors.AccessNotAuthorized(msg.sender);
        }
        _;
    }
    
    /**
     * @notice Access control modifier for emergency admin
     */
    modifier onlyEmergencyAdmin() {
        if (msg.sender != emergencyAdmin && msg.sender != owner) {
            revert Errors.AccessOnlyEmergencyAdmin(msg.sender);
        }
        _;
    }
    
    /**
     * @notice Access control modifier to ensure only FullRange contract can call this function
     */
    modifier onlyFullRange() {
        if (msg.sender != fullRangeAddress) {
            revert Errors.AccessNotAuthorized(msg.sender);
        }
        _;
    }
    
    /**
     * @notice Allows the contract to receive ETH
     */
    receive() external payable {}
    
    // === POOL MANAGEMENT FUNCTIONS ===
    
    /**
     * @notice Register a pool with the liquidity manager
     * @dev Called by FullRange when a pool is initialized
     */
    function registerPool(PoolId poolId, PoolKey memory key, uint160 sqrtPriceX96) external onlyFullRange {
        // Store pool key
        _poolKeys[poolId] = key;
        
        // Initialize pool data
        pools[poolId] = PoolInfo({
            reserve0: 0,
            reserve1: 0,
            totalShares: 0
        });
        
        emit PoolInitialized(poolId, key, sqrtPriceX96, key.fee);
    }
    
    /**
     * @notice Get the PoolKey for a given PoolId (implements interface)
     * @param poolId The Pool ID to look up
     * @return Pool key associated with this Pool ID
     */
    function poolKeys(PoolId poolId) external view returns (PoolKey memory) {
        PoolKey memory key = _poolKeys[poolId];
        if (key.tickSpacing == 0) revert Errors.PoolNotInitialized(poolId);
        return key;
    }
    
    /**
     * @notice Get the tickSpacing for a given PoolId
     * @param poolId The Pool ID to look up
     * @return The tickSpacing associated with this Pool ID
     */
    function getPoolTickSpacing(PoolId poolId) external view returns (int24) {
        return _poolKeys[poolId].tickSpacing;
    }
    
    /**
     * @notice Get pool information
     * @param poolId The pool ID
     * @return shares The total shares of the pool
     * @return reserve0 The reserve of token0
     * @return reserve1 The reserve of token1
     */
    function poolInfo(PoolId poolId) external view returns (
        uint128 shares,
        uint256 reserve0,
        uint256 reserve1
    ) {
        PoolInfo storage info = pools[poolId];
        return (info.totalShares, info.reserve0, info.reserve1);
    }
    
    /**
     * @notice Get the total shares for a pool
     * @param poolId The pool ID
     * @return The total shares of the pool
     */
    function totalShares(PoolId poolId) external view returns (uint128) {
        return pools[poolId].totalShares;
    }
    
    /**
     * @notice Get the user's share balance for a pool
     * @param poolId The pool ID
     * @return The user's share balance
     */
    function userShares(PoolId poolId, address user) public view returns (uint256) {
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        return positions.balanceOf(user, tokenId);
    }
    
    /**
     * @notice Get the position token contract
     * @return The position token contract
     */
    function getPositionsContract() external view returns (FullRangePositions) {
        return positions;
    }
    
    // === LIQUIDITY MANAGEMENT FUNCTIONS ===
    
    /**
     * @notice Deposit tokens into a pool with native ETH support
     */
    function deposit(
        PoolId poolId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external payable override returns (
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    ) {
        // Enhanced validation
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(poolId);
        
        // Get direct position data before calculating deposit amounts
        (uint128 liquidity, uint160 sqrtPriceX96, bool readSuccess) = getPositionData(poolId);
        if (!readSuccess) {
            revert Errors.FailedToReadPoolData(poolId);
        }
        
        // Get pool info and validate
        PoolInfo storage pool = pools[poolId];
        if (_poolKeys[poolId].tickSpacing == 0) {
            revert Errors.PoolNotInitialized(poolId);
        }
        
        // Get pool key to check for native ETH
        PoolKey memory key = _poolKeys[poolId];
        bool hasToken0Native = key.currency0.isAddressZero();
        bool hasToken1Native = key.currency1.isAddressZero();
        
        // Calculate deposit amounts and shares
        (uint256 actual0, uint256 actual1, uint256 newShares, uint256 lockedShares) = 
            _calculateDepositAmounts(
                pool.totalShares,
                amount0Desired,
                amount1Desired,
                pool.reserve0,
                pool.reserve1
            );
        
        // Validate minimum amounts
        if (actual0 < amount0Min || actual1 < amount1Min) {
            uint256 requiredMin = (actual0 < amount0Min) ? amount0Min : amount1Min;
            uint256 actualOut = (actual0 < amount0Min) ? actual0 : actual1;
            revert Errors.SlippageExceeded(requiredMin, actualOut);
        }
        
        // Validate and handle ETH
        if (msg.value > 0) {
            // Calculate required ETH
            uint256 ethNeeded = 0;
            if (hasToken0Native) ethNeeded += actual0;
            if (hasToken1Native) ethNeeded += actual1;
            
            // Ensure enough ETH was sent
            if (msg.value < ethNeeded) {
                revert Errors.InsufficientETH(ethNeeded, msg.value);
            }
        }
        
        // Transfer tokens from recipient (the user)
        if (actual0 > 0 && !hasToken0Native) {
            IERC20Minimal(Currency.unwrap(key.currency0)).transferFrom(recipient, address(this), actual0);
        }
        
        if (actual1 > 0 && !hasToken1Native) {
            IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(recipient, address(this), actual1);
        }
        
        // Update reserves
        pool.reserve0 += actual0;
        pool.reserve1 += actual1;
        
        // Update total shares
        uint128 oldTotalShares = pool.totalShares;
        pool.totalShares += uint128(newShares + lockedShares);
        
        // If this is first deposit with locked shares, record it
        if (lockedShares > 0 && lockedLiquidity[poolId] == 0) {
            lockedLiquidity[poolId] = lockedShares;
            emit MinimumLiquidityLocked(poolId, lockedShares);
        }
        
        // Mint position tokens to user (only the non-locked shares)
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        positions.mint(recipient, tokenId, newShares);
        
        // Approve tokens to the PoolManager
        if (actual0 > 0 && !hasToken0Native) {
            IERC20Minimal(Currency.unwrap(key.currency0)).approve(address(manager), actual0);
        }
        
        if (actual1 > 0 && !hasToken1Native) {
            IERC20Minimal(Currency.unwrap(key.currency1)).approve(address(manager), actual1);
        }
        
        // Create callback data for the FullRange hook to handle
        CallbackData memory callbackData = CallbackData({
            poolId: poolId,
            callbackType: 1, // 1 for deposit
            shares: uint128(newShares),  // Only use the non-locked shares for the callback!
            amount0: actual0,
            amount1: actual1,
            recipient: recipient
        });
        
        // Call unlock to add liquidity via FullRange's unlockCallback
        manager.unlock(abi.encode(callbackData));
        
        // Refund excess ETH if there is any
        if (msg.value > 0) {
            uint256 ethUsed = 0;
            if (hasToken0Native) ethUsed += actual0;
            if (hasToken1Native) ethUsed += actual1;
            
            if (msg.value > ethUsed) {
                uint256 refundAmount = msg.value - ethUsed;
                
                // Validate refund amount is reasonable and process the refund
                if (refundAmount > 0 && refundAmount <= address(this).balance) {
                    // Return excess ETH with gas limit for safety
                    (bool success, ) = msg.sender.call{value: refundAmount, gas: ethTransferGasLimit}("");
                    if (!success) {
                        // Record failed transfer in pendingETHPayments
                        pendingETHPayments[msg.sender] += refundAmount;
                        emit ETHTransferFailed(msg.sender, refundAmount);
                    }
                }
            }
        }
        
        // Emit events
        emit LiquidityAdded(
            poolId,
            recipient,
            actual0,
            actual1,
            oldTotalShares,
            uint128(newShares),
            block.timestamp
        );
        
        emit TotalLiquidityUpdated(poolId, oldTotalShares, pool.totalShares);
        
        return (newShares, actual0, actual1);
    }
    
    /**
     * @notice Withdraw liquidity from a pool
     */
    function withdraw(
        PoolId poolId,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external override returns (
        uint256 amount0,
        uint256 amount1
    ) {
        // Enhanced validation
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(poolId);
        if (sharesToBurn == 0) revert Errors.ZeroAmount();
        
        // Check that user has enough shares
        AccountPosition storage userPosition = userPositions[poolId][msg.sender];
        if (!userPosition.initialized || userPosition.shares < sharesToBurn) {
            revert Errors.InsufficientShares(sharesToBurn, userPosition.shares);
        }
        
        // Get direct position data
        (uint128 liquidity, uint160 sqrtPriceX96, bool readSuccess) = getPositionData(poolId);
        if (!readSuccess) {
            revert Errors.FailedToReadPoolData(poolId);
        }
        
        // Get the pool and validate it exists
        PoolInfo storage pool = pools[poolId];
        if (_poolKeys[poolId].tickSpacing == 0) {
            revert Errors.PoolNotInitialized(poolId);
        }
        
        // Get the user's share balance
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        uint256 userShareBalance = positions.balanceOf(recipient, tokenId);
        
        // Validate shares to withdraw
        if (sharesToBurn > userShareBalance) {
            revert Errors.InsufficientShares(sharesToBurn, userShareBalance);
        }
        
        // Calculate amounts to withdraw
        (amount0, amount1) = _calculateWithdrawAmounts(
            pool.totalShares,
            sharesToBurn,
            pool.reserve0,
            pool.reserve1
        );
        
        // Check slippage
        if (amount0 < amount0Min || amount1 < amount1Min) {
            uint256 requiredMin = (amount0 < amount0Min) ? amount0Min : amount1Min;
            uint256 actualOut = (amount0 < amount0Min) ? amount0 : amount1;
            revert Errors.SlippageExceeded(requiredMin, actualOut);
        }
        
        // Get token addresses from pool key
        PoolKey memory key = _poolKeys[poolId];
        
        // Update state before external calls with more comprehensive SafeCast
        pool.reserve0 = uint128(uint256(pool.reserve0) - amount0);
        pool.reserve1 = uint128(uint256(pool.reserve1) - amount1);
        
        // Update total shares with more comprehensive SafeCast
        uint128 oldTotalShares = pool.totalShares;
        uint128 sharesToBurnSafe = sharesToBurn.toUint128();
        pool.totalShares = uint128(uint256(oldTotalShares) - sharesToBurnSafe);
        
        // Create ModifyLiquidityParams with negative liquidity delta
        IPoolManager.ModifyLiquidityParams memory modifyLiqParams = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.MIN_TICK,
            tickUpper: TickMath.MAX_TICK,
            liquidityDelta: -int256(uint256(sharesToBurnSafe)),
            salt: bytes32(0)
        });
        
        // Create callback data for the FullRange hook to handle
        CallbackData memory callbackData = CallbackData({
            poolId: poolId,
            callbackType: 2, // 2 for withdraw
            shares: sharesToBurnSafe,
            amount0: amount0,
            amount1: amount1,
            recipient: recipient
        });
        
        // Call unlock to remove liquidity via FullRange's unlockCallback
        manager.unlock(abi.encode(callbackData));
        
        // Transfer tokens to user using CurrencyLibrary
        if (amount0 > 0) {
            CurrencyLibrary.transfer(key.currency0, recipient, amount0);
        }
        
        if (amount1 > 0) {
            CurrencyLibrary.transfer(key.currency1, recipient, amount1);
        }
        
        // Emit withdraw event
        emit LiquidityRemoved(
            poolId,
            recipient,
            amount0,
            amount1,
            oldTotalShares,
            sharesToBurnSafe,
            block.timestamp
        );
        
        emit TotalLiquidityUpdated(poolId, oldTotalShares, pool.totalShares);
        
        return (amount0, amount1);
    }
    
    /**
     * @notice Emergency withdraw function, available only when emergency mode is enabled
     * @param params Withdrawal parameters
     * @param user The user withdrawing liquidity
     * @return delta The balance delta from the liquidity removal
     * @return amount0Out Token0 amount withdrawn
     * @return amount1Out Token1 amount withdrawn
     */
    function emergencyWithdraw(IFullRangeLiquidityManager.WithdrawParams calldata params, address user)
        external
        nonReentrant
        returns (BalanceDelta delta, uint256 amount0Out, uint256 amount1Out)
    {
        // Validate emergency state
        if (!emergencyWithdrawalsEnabled && !poolEmergencyState[params.poolId]) {
            revert Errors.InvalidInput();
        }
        
        // Check cooldown period
        if (block.timestamp < lastEmergencyWithdrawal[user][params.poolId] + emergencyWithdrawalCooldown) {
            revert Errors.DeadlinePassed(uint32(lastEmergencyWithdrawal[user][params.poolId] + emergencyWithdrawalCooldown), uint32(block.timestamp));
        }
        
        // Record this withdrawal
        lastEmergencyWithdrawal[user][params.poolId] = block.timestamp;
        
        // Execute withdrawal directly (don't try to call external function)
        PoolInfo storage pool = pools[params.poolId];
        if (_poolKeys[params.poolId].tickSpacing == 0) {
            revert Errors.PoolNotInitialized(params.poolId);
        }
        
        // Get the user's share balance
        uint256 tokenId = PoolTokenIdUtils.toTokenId(params.poolId);
        uint256 userShareBalance = positions.balanceOf(user, tokenId);
        
        // Validate shares to withdraw
        uint256 sharesToBurn = params.shares;
        if (sharesToBurn == 0) {
            revert Errors.ZeroAmount();
        }
        if (sharesToBurn > userShareBalance) {
            revert Errors.InsufficientShares(sharesToBurn, userShareBalance);
        }
        
        // Calculate amounts to withdraw (no slippage check in emergency)
        (amount0Out, amount1Out) = _calculateWithdrawAmounts(
            pool.totalShares,
            sharesToBurn,
            pool.reserve0,
            pool.reserve1
        );
        
        // Get token addresses from pool key
        PoolKey memory key = _poolKeys[params.poolId];
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        
        // Update state before external calls
        pool.reserve0 -= amount0Out;
        pool.reserve1 -= amount1Out;
        
        // Update total shares
        uint128 oldTotalShares = pool.totalShares;
        pool.totalShares = oldTotalShares - uint128(sharesToBurn);
        
        // Burn position tokens
        positions.burn(user, tokenId, sharesToBurn);
        
        // Call modifyLiquidity on PoolManager
        IPoolManager.ModifyLiquidityParams memory modifyLiqParams = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.MIN_TICK,
            tickUpper: TickMath.MAX_TICK,
            liquidityDelta: -int256(sharesToBurn),
            salt: bytes32(0)
        });
        
        // Create callback data for the FullRange hook to handle
        CallbackData memory callbackData = CallbackData({
            poolId: params.poolId,
            callbackType: 2, // 2 for withdraw
            shares: uint128(sharesToBurn),
            amount0: amount0Out,
            amount1: amount1Out,
            recipient: user
        });
        
        // Call unlock to remove liquidity via FullRange's unlockCallback
        // Result will include delta from FullRange
        bytes memory result = manager.unlock(abi.encode(callbackData));
        delta = abi.decode(result, (BalanceDelta));
        
        // Handle delta
        _handleDelta(delta, token0, token1);
        
        // Transfer tokens to user
        if (amount0Out > 0) {
            _safeTransferToken(token0, user, amount0Out);
        }
        
        if (amount1Out > 0) {
            _safeTransferToken(token1, user, amount1Out);
        }
        
        // Emit emergency-specific event
        emit EmergencyWithdrawalCompleted(
            params.poolId,
            user,
            amount0Out,
            amount1Out,
            params.shares
        );
        
        emit LiquidityRemoved(
            params.poolId,
            user,
            amount0Out,
            amount1Out,
            oldTotalShares,
            uint128(sharesToBurn),
            block.timestamp
        );
        
        emit TotalLiquidityUpdated(params.poolId, oldTotalShares, pool.totalShares);
        
        return (delta, amount0Out, amount1Out);
    }
    
    // === EMERGENCY CONTROLS ===
    
    /**
     * @notice Enable emergency withdrawals for a specific pool
     * @param poolId The pool ID
     * @param reason The reason for enabling emergency mode
     */
    function enablePoolEmergencyState(PoolId poolId, string calldata reason) external onlyEmergencyAdmin {
        poolEmergencyState[poolId] = true;
        emit EmergencyStateActivated(poolId, msg.sender, reason);
    }
    
    /**
     * @notice Disable emergency withdrawals for a specific pool
     * @param poolId The pool ID
     */
    function disablePoolEmergencyState(PoolId poolId) external onlyEmergencyAdmin {
        poolEmergencyState[poolId] = false;
        emit EmergencyStateDeactivated(poolId, msg.sender);
    }
    
    /**
     * @notice Enable or disable global emergency withdrawals
     * @param enabled Whether emergency withdrawals should be enabled
     */
    function setGlobalEmergencyState(bool enabled) external onlyEmergencyAdmin {
        emergencyWithdrawalsEnabled = enabled;
        emit GlobalEmergencyStateChanged(enabled, msg.sender);
    }
    
    /**
     * @notice Set the emergency withdrawal cooldown period
     * @param newCooldown The new cooldown period in seconds
     */
    function setEmergencyWithdrawalCooldown(uint256 newCooldown) external onlyEmergencyAdmin {
        uint256 oldCooldown = emergencyWithdrawalCooldown;
        emergencyWithdrawalCooldown = newCooldown;
        emit EmergencyCooldownUpdated(oldCooldown, newCooldown);
    }
    
    // === ETH HANDLING FUNCTIONS ===
    
    /**
     * @notice Set the gas limit for ETH transfers
     * @param newLimit The new gas limit
     */
    function setEthTransferGasLimit(uint256 newLimit) external onlyOwner {
        uint256 oldLimit = ethTransferGasLimit;
        ethTransferGasLimit = newLimit;
        emit ETHTransferGasLimitUpdated(oldLimit, newLimit);
    }
    
    /**
     * @notice Set the maximum number of ETH transfer retries
     * @param newValue The new maximum retry count
     */
    function setMaxEthRetries(uint8 newValue) external onlyOwner {
        uint8 oldValue = maxETHRetries;
        maxETHRetries = newValue;
        emit MaxETHRetriesUpdated(oldValue, newValue);
    }
    
    /**
     * @notice Claim pending ETH payments
     * @dev For failed native transfers that were recorded in pendingETHPayments
     */
    function claimETH() external {
        uint256 amount = pendingETHPayments[msg.sender];
        if (amount == 0) revert Errors.ZeroAmount();
        
        // Clear pending payment before transfer to prevent reentrancy
        pendingETHPayments[msg.sender] = 0;
        
        // Validate amount before transfer using CurrencyLibrary's method
        uint256 balance = Currency.wrap(address(0)).balanceOfSelf();
        if (amount > balance) {
            revert Errors.InsufficientContractBalance(amount, balance);
        }
        
        // Transfer ETH with gas limit for safety
        (bool success, ) = msg.sender.call{value: amount, gas: ethTransferGasLimit}("");
        if (!success) {
            // Restore pending payment if transfer fails
            pendingETHPayments[msg.sender] = amount;
            revert Errors.ETHTransferFailed(msg.sender, amount);
        }
        
        emit ETHClaimed(msg.sender, amount);
    }
    
    // === INTERNAL HELPER FUNCTIONS ===
    
    /**
     * @notice Calculate deposit amounts and shares
     * @param totalSharesAmount Current total shares
     * @param amount0Desired Desired amount of token0
     * @param amount1Desired Desired amount of token1
     * @param reserve0 Current token0 reserves
     * @param reserve1 Current token1 reserves
     * @return actual0 Actual token0 amount to deposit
     * @return actual1 Actual token1 amount to deposit
     * @return newShares New shares to mint
     * @return lockedShares Shares to lock (for minimum liquidity on first deposit)
     */
    function _calculateDepositAmounts(
        uint128 totalSharesAmount,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (
        uint256 actual0,
        uint256 actual1,
        uint256 newShares,
        uint256 lockedShares
    ) {
        // First deposit case - implement proportional first deposit with minimum liquidity locking
        if (totalSharesAmount == 0) {
            actual0 = amount0Desired;
            actual1 = amount1Desired;
            
            // Calculate shares as geometric mean of token amounts
            newShares = MathUtils.sqrt(actual0 * actual1);
            
            // Lock a small amount for minimum liquidity (1000 units = 0.001% of total)
            lockedShares = 1000;
            
            // Ensure we don't mint zero shares
            if (newShares == 0) newShares = MIN_VIABLE_RESERVE;
            
            return (actual0, actual1, newShares, lockedShares);
        }
        
        // Subsequent deposits - match the current reserve ratio
        if (reserve0 > 0 && reserve1 > 0) {
            // Calculate shares based on the minimum of the two ratios
            // Multiply before division to prevent precision loss
            uint256 share0 = (amount0Desired * totalSharesAmount) / reserve0;
            uint256 share1 = (amount1Desired * totalSharesAmount) / reserve1;
            
            if (share0 <= share1) {
                // Token0 is the limiting factor
                newShares = share0;
                // Use the calculated share ratio for consistent amounts
                actual0 = amount0Desired;
                // Multiply before dividing to prevent overflow/underflow
                actual1 = (amount0Desired * reserve1) / reserve0;
            } else {
                // Token1 is the limiting factor
                newShares = share1;
                // Use the calculated share ratio for consistent amounts
                actual1 = amount1Desired;
                // Multiply before dividing to prevent overflow/underflow
                actual0 = (amount1Desired * reserve0) / reserve1;
            }
            
            // Ensure actual amounts don't exceed the inputs, which could happen due to precision
            if (actual0 > amount0Desired) actual0 = amount0Desired;
            if (actual1 > amount1Desired) actual1 = amount1Desired;
        } else if (reserve0 > 0) {
            // Only token0 has reserves
            newShares = (amount0Desired * totalSharesAmount) / reserve0;
            actual0 = amount0Desired;
            actual1 = amount1Desired;
        } else {
            // Only token1 has reserves
            newShares = (amount1Desired * totalSharesAmount) / reserve1;
            actual0 = amount0Desired;
            actual1 = amount1Desired;
        }
        
        return (actual0, actual1, newShares, 0);
    }
    
    /**
     * @notice Calculate withdrawal amounts
     * @param totalSharesAmount Current total shares
     * @param sharesToBurn Shares to burn
     * @param reserve0 Current token0 reserves
     * @param reserve1 Current token1 reserves
     * @return amount0Out Token0 amount to withdraw
     * @return amount1Out Token1 amount to withdraw
     */
    function _calculateWithdrawAmounts(
        uint128 totalSharesAmount,
        uint256 sharesToBurn,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (
        uint256 amount0Out,
        uint256 amount1Out
    ) {
        // Calculate proportional amounts based on share ratio
        amount0Out = (reserve0 * sharesToBurn) / totalSharesAmount;
        amount1Out = (reserve1 * sharesToBurn) / totalSharesAmount;
        
        return (amount0Out, amount1Out);
    }
    
    /**
     * @notice Handle the balance delta from a modifyLiquidity operation
     * @param delta The balance delta from the operation
     * @param token0 The address of token0
     * @param token1 The address of token1
     */
    function _handleDelta(BalanceDelta delta, address token0, address token1) internal {
        // Convert addresses to Currency types for consistent abstraction
        Currency currency0 = Currency.wrap(token0);
        Currency currency1 = Currency.wrap(token1);
        
        // Handle token0 transfer
        int128 amount0 = delta.amount0();
        if (amount0 < 0) {
            uint256 amount = uint256(int256(-amount0));
            
            if (currency0.isAddressZero()) {
                // Handle native ETH
                manager.settle{value: amount}();
            } else {
                // Handle ERC20
                IERC20Minimal(token0).approve(address(manager), amount);
                manager.settle();
            }
        } else if (amount0 > 0) {
            // Need to receive tokens from the pool
            manager.take(currency0, address(this), uint256(int256(amount0)));
        }
        
        // Handle token1 transfer
        int128 amount1 = delta.amount1();
        if (amount1 < 0) {
            uint256 amount = uint256(int256(-amount1));
            
            if (currency1.isAddressZero()) {
                // Handle native ETH
                manager.settle{value: amount}();
            } else {
                // Handle ERC20
                IERC20Minimal(token1).approve(address(manager), amount);
                manager.settle();
            }
        } else if (amount1 > 0) {
            // Need to receive tokens from the pool
            manager.take(currency1, address(this), uint256(int256(amount1)));
        }
    }
    
    /**
     * @notice Transfer token to recipient, handling ETH and ERC20 correctly
     * @param token The token address (address(0) for ETH)
     * @param to The recipient address
     * @param amount The amount to transfer
     */
    function _safeTransferToken(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        
        Currency currency = Currency.wrap(token);
        if (currency.isAddressZero()) {
            // Handle ETH
            // Transfer ETH with gas limit for safety
            (bool success, ) = to.call{value: amount, gas: ethTransferGasLimit}("");
            if (!success) {
                // If transfer fails, store as pending payment
                pendingETHPayments[to] += amount;
                emit ETHTransferFailed(to, amount);
            }
        } else {
            // Handle ERC20 using SafeTransferLib for additional safety checks
            SafeTransferLib.safeTransfer(ERC20(token), to, amount);
        }
    }
    
    /**
     * @notice Handles delta settlement from FullRange's unlockCallback
     * @dev Uses CurrencySettlerExtension for efficient settlement
     */
    function handlePoolDelta(PoolKey memory key, BalanceDelta delta) external onlyFullRange {
        // Use our extension of Uniswap's CurrencySettler
        CurrencySettlerExtension.handlePoolDelta(
            manager,
            delta,
            key.currency0,
            key.currency1,
            address(this)
        );
    }

    /**
     * @notice Adds user share accounting (no token transfers)
     * @param poolId The pool ID
     * @param user The user address
     * @param shares Amount of shares to add
     */
    function addUserShares(PoolId poolId, address user, uint256 shares) external onlyFullRange {
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        positions.mint(user, tokenId, shares);
        
        emit UserSharesAdded(poolId, user, shares);
    }

    /**
     * @notice Removes user share accounting (no token transfers)
     * @param poolId The pool ID
     * @param user The user address
     * @param shares Amount of shares to remove
     */
    function removeUserShares(PoolId poolId, address user, uint256 shares) external onlyFullRange {
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        positions.burn(user, tokenId, shares);
        
        emit UserSharesRemoved(poolId, user, shares);
    }

    /**
     * @notice Retrieves user share balance
     * @param poolId The pool ID
     * @param user The user address
     * @return User's share balance
     */
    function getUserShares(PoolId poolId, address user) external view returns (uint256) {
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        return positions.balanceOf(user, tokenId);
    }

    /**
     * @notice Updates pool total shares
     * @param poolId The pool ID
     * @param newTotalShares The new total shares amount
     */
    function updateTotalShares(PoolId poolId, uint128 newTotalShares) external onlyFullRange {
        PoolInfo storage pool = pools[poolId];
        uint128 oldTotalShares = pool.totalShares;
        pool.totalShares = newTotalShares;
        
        emit PoolTotalSharesUpdated(poolId, oldTotalShares, newTotalShares);
    }
    
    /**
     * @notice Process withdraw shares operation
     * @dev This function is called by FullRange during withdrawals
     * @param poolId The pool ID
     * @param user The user address
     * @param sharesToBurn The number of shares to burn
     * @param currentTotalShares The current total shares in the pool
     * @return newTotalShares The new total shares
     */
    function processWithdrawShares(
        PoolId poolId, 
        address user, 
        uint256 sharesToBurn, 
        uint128 currentTotalShares
    ) external onlyFullRange returns (uint128 newTotalShares) {
        // Verify user has sufficient shares
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        uint256 userBalance = positions.balanceOf(user, tokenId);
        if (userBalance < sharesToBurn) {
            revert Errors.ValidationInvalidInput("Insufficient shares");
        }
        
        // Verify pool total shares match expected value (prevents race conditions)
        PoolInfo storage pool = pools[poolId];
        if (pool.totalShares != currentTotalShares) {
            revert Errors.ValidationInvalidInput("Total shares mismatch");
        }
        
        // First execute external call (tokens.burn) before state changes
        positions.burn(user, tokenId, sharesToBurn);
        
        // Then update contract state
        newTotalShares = currentTotalShares - uint128(sharesToBurn);
        pool.totalShares = newTotalShares;
        
        // Simplified event emission
        emit UserSharesRemoved(poolId, user, sharesToBurn);
        emit PoolStateUpdated(poolId, newTotalShares, 2); // 2 = withdraw
        
        return newTotalShares;
    }
    
    /**
     * @notice Process deposit shares operation
     * @dev This function is called by FullRange during deposits
     * @param poolId The pool ID
     * @param user The user address
     * @param sharesToMint The number of shares to mint
     * @param currentTotalShares The current total shares in the pool
     * @return newTotalShares The new total shares
     */
    function processDepositShares(
        PoolId poolId, 
        address user, 
        uint256 sharesToMint, 
        uint128 currentTotalShares
    ) external onlyFullRange returns (uint128 newTotalShares) {
        // Verify pool total shares match expected value (prevents race conditions)
        PoolInfo storage pool = pools[poolId];
        if (pool.totalShares != currentTotalShares) {
            revert Errors.ValidationInvalidInput("Total shares mismatch");
        }
        
        // First perform external call (mint tokens)
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        positions.mint(user, tokenId, sharesToMint);
        
        // Then update state
        newTotalShares = currentTotalShares + uint128(sharesToMint);
        pool.totalShares = newTotalShares;
        
        // Simplified event emission
        emit UserSharesAdded(poolId, user, sharesToMint);
        emit PoolStateUpdated(poolId, newTotalShares, 1); // 1 = deposit
        
        return newTotalShares;
    }

    /**
     * @notice Checks if a pool exists
     * @param poolId The pool ID to check
     * @return True if the pool exists
     */
    function poolExists(PoolId poolId) external view returns (bool) {
        return _poolKeys[poolId].tickSpacing != 0;
    }

    /**
     * @notice Reinvests fees for protocol-owned liquidity
     * @param poolId The pool ID
     * @param polAmount0 Amount of token0 for POL
     * @param polAmount1 Amount of token1 for POL
     * @return shares The number of shares minted
     */
    function reinvestFees(
        PoolId poolId,
        uint256 polAmount0,
        uint256 polAmount1
    ) external returns (uint256 shares) {
        // Authorization checks
        address reinvestmentPolicy = IPoolPolicy(owner).getPolicy(poolId, IPoolPolicy.PolicyType.REINVESTMENT);
        if (msg.sender != reinvestmentPolicy) {
            revert Errors.AccessNotAuthorized(msg.sender);
        }
        
        // Skip processing if no POL amounts
        if (polAmount0 == 0 && polAmount1 == 0) {
            return 0;
        }
        
        // Calculate POL shares using geometric mean
        shares = MathUtils.calculateGeometricShares(polAmount0, polAmount1);
        if (shares == 0 && (polAmount0 > 0 || polAmount1 > 0)) {
            shares = 1; // Minimum 1 share
        }
        
        // Get pool and key information
        PoolInfo storage pool = pools[poolId];
        PoolKey memory key = _poolKeys[poolId];
        uint128 oldTotalShares = pool.totalShares;
        
        // *** CRITICAL CHANGE: Execute pool interactions BEFORE state changes ***
        
        // Add POL to Uniswap pool first
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.MIN_TICK,
            tickUpper: TickMath.MAX_TICK,
            liquidityDelta: int256(shares),
            salt: bytes32(0)
        });
        
        // Call modifyLiquidity and handle settlement
        (BalanceDelta delta, ) = manager.modifyLiquidity(key, params, new bytes(0));
        _handleDelta(delta, Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        
        // Only update state AFTER successful external calls
        pool.reserve0 += polAmount0;
        pool.reserve1 += polAmount1;
        pool.totalShares = oldTotalShares + uint128(shares);
        
        // Mint shares to POL treasury
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        address polTreasury = owner; // Use contract owner as POL treasury
        positions.mint(polTreasury, tokenId, shares);
        
        // Single event for the operation - reduced from multiple events
        emit ReinvestmentProcessed(poolId, polAmount0, polAmount1, shares, oldTotalShares, pool.totalShares);
        emit PoolStateUpdated(poolId, pool.totalShares, 3); // 3 = reinvest
        
        return shares;
    }

    /**
     * @notice Get account position information (interface compatibility)
     */
    function getAccountPosition(
        PoolId poolId, 
        address account
    ) external view override returns (bool initialized, uint256 shares) {
        AccountPosition memory position = userPositions[poolId][account];
        return (position.initialized, position.shares);
    }
    
    /**
     * @notice Get the value of shares in token amounts (interface compatibility)
     */
    function getShareValue(
        PoolId poolId, 
        uint256 shares
    ) external view override returns (uint256 amount0, uint256 amount1) {
        PoolInfo memory pool = pools[poolId];
        if (pool.totalShares == 0 || shares == 0) return (0, 0);
        
        // Calculate proportional amounts based on shares
        amount0 = (pool.reserve0 * shares) / pool.totalShares;
        amount1 = (pool.reserve1 * shares) / pool.totalShares;
        
        return (amount0, amount1);
    }

    /**
     * @notice Set the refund cooldown period
     * @param newValue The new cooldown period in seconds
     */
    function setRefundCooldown(uint256 newValue) external onlyOwner {
        uint256 oldValue = refundCooldown;
        refundCooldown = newValue;
        emit RefundCooldownUpdated(oldValue, newValue);
    }
    
    /**
     * @notice Set the maximum refund amount per period
     * @param newValue The new maximum refund amount
     */
    function setMaxRefundPerPeriod(uint256 newValue) external onlyOwner {
        uint256 oldValue = maxRefundPerPeriod;
        maxRefundPerPeriod = newValue;
        emit MaxRefundPerPeriodUpdated(oldValue, newValue);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // Only allow calls from the pool manager
        if (msg.sender != address(manager)) {
            revert Errors.AccessNotAuthorized(msg.sender);
        }
        
        // Decode the callback data
        CallbackData memory cbData = abi.decode(data, (CallbackData));
        PoolKey memory key = _poolKeys[cbData.poolId];
        
        if (cbData.callbackType == 1) {
            // DEPOSIT
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: int256(uint256(cbData.amount0)),
                salt: bytes32(0)
            });
            
            (BalanceDelta delta, ) = manager.modifyLiquidity(key, params, "");
            CurrencySettlerExtension.handlePoolDelta(
                manager,
                delta,
                key.currency0,
                key.currency1,
                address(this)
            );
            
            return abi.encode(delta);
        } else if (cbData.callbackType == 2) {
            // WITHDRAW
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: -int256(uint256(cbData.shares)),
                salt: bytes32(0)
            });
            
            (BalanceDelta delta, ) = manager.modifyLiquidity(key, params, "");
            CurrencySettlerExtension.handlePoolDelta(
                manager,
                delta,
                key.currency0,
                key.currency1,
                address(this)
            );
            
            return abi.encode(delta);
        }
        
        return abi.encode(0);
    }

    /**
     * @notice Gets the current reserves for a pool
     * @param poolId The pool ID
     * @return reserve0 The amount of token0 in the pool
     * @return reserve1 The amount of token1 in the pool
     */
    function getPoolReserves(PoolId poolId) public view returns (uint256 reserve0, uint256 reserve1) {
        if (!isPoolInitialized(poolId)) {
            return (0, 0);
        }
        
        PoolKey memory key = _poolKeys[poolId];
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        
        // Get position data directly
        (uint128 liquidity, uint160 sqrtPriceX96, bool success) = getPositionData(poolId);
        
        // If direct query fails or returns no data but we have pool info
        if ((!success || liquidity == 0) && pools[poolId].totalShares > 0) {
            return (pools[poolId].reserve0, pools[poolId].reserve1);
        }
        
        // If still no usable data, return zeros
        if (liquidity == 0 || sqrtPriceX96 == 0) {
            return (0, 0);
        }
        
        // Calculate reserves from position data
        return _getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );
    }
    
    /**
     * @notice Direct read of position data from Uniswap v4 pool
     * @param poolId The pool ID
     * @return liquidity The current liquidity of the position
     * @return sqrtPriceX96 The current sqrt price of the pool
     * @return success Whether the read was successful
     */
    function getPositionData(PoolId poolId) public view returns (uint128 liquidity, uint160 sqrtPriceX96, bool success) {
        if (!isPoolInitialized(poolId)) {
            return (0, 0, false);
        }
        
        PoolKey memory key = _poolKeys[poolId];
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        bool readSuccess = false;
        
        // Get position data via extsload
        bytes32 positionKey = Position.calculatePositionKey(address(fullRangeAddress), tickLower, tickUpper, bytes32(0));
        bytes32 positionSlot = _getPositionInfoSlot(poolId, positionKey);
        
        try manager.extsload(positionSlot) returns (bytes32 liquidityData) {
            liquidity = uint128(uint256(liquidityData));
            readSuccess = true;
        } catch {
            // Leave liquidity as 0 if read fails
        }
        
        // Get slot0 data via extsload
        bytes32 stateSlot = _getPoolStateSlot(poolId);
        try manager.extsload(stateSlot) returns (bytes32 slot0Data) {
            sqrtPriceX96 = uint160(uint256(slot0Data));
            readSuccess = true;
        } catch {
            // Leave sqrtPriceX96 as 0 if read fails
        }
        
        return (liquidity, sqrtPriceX96, readSuccess);
    }

    /**
     * @notice Computes the token0 and token1 value for a given amount of liquidity
     * @param sqrtPriceX96 A sqrt price representing the current pool prices
     * @param sqrtPriceAX96 A sqrt price representing the first tick boundary
     * @param sqrtPriceBX96 A sqrt price representing the second tick boundary
     * @param liquidity The liquidity being valued
     * @return amount0 The amount of token0
     * @return amount1 The amount of token1
     */
    function _getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            amount0 = FullMath.mulDiv(liquidity, FixedPoint96.Q96, sqrtPriceAX96) * (sqrtPriceBX96 - sqrtPriceAX96) / sqrtPriceBX96;
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            amount0 = FullMath.mulDiv(liquidity, FixedPoint96.Q96, sqrtPriceX96) * (sqrtPriceBX96 - sqrtPriceX96) / sqrtPriceBX96;
            amount1 = FullMath.mulDiv(liquidity, sqrtPriceX96 - sqrtPriceAX96, FixedPoint96.Q96);
        } else {
            amount1 = FullMath.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, FixedPoint96.Q96);
        }
    }

    /**
     * @notice Updates the position cache for a pool
     * @dev Maintained for backward compatibility, but now directly reads position data
     * @param poolId The pool ID
     * @return success Whether the update was successful
     */
    function updatePositionCache(PoolId poolId) public returns (bool success) {
        // We don't need to update a cache anymore, but we'll return success
        // based on whether we can read the current position data
        (, , success) = getPositionData(poolId);
        return success;
    }
    
    /**
     * @notice Get the storage slot for a pool's state
     * @param poolId The pool ID
     * @return The storage slot for the pool's state
     */
    function _getPoolStateSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, POOLS_SLOT));
    }
    
    /**
     * @notice Get the storage slot for a position's info
     * @param poolId The pool ID
     * @param positionId The position ID
     * @return The storage slot for the position's info
     */
    function _getPositionInfoSlot(PoolId poolId, bytes32 positionId) internal pure returns (bytes32) {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = _getPoolStateSlot(poolId);

        // Pool.State: `mapping(bytes32 => Position.State) positions;`
        bytes32 positionMapping = bytes32(uint256(stateSlot) + POSITIONS_OFFSET);

        // slot of the mapping key: `pools[poolId].positions[positionId]
        return keccak256(abi.encodePacked(positionId, positionMapping));
    }

    /**
     * @notice Check if a pool is initialized
     * @param poolId The pool ID
     * @return initialized Whether the pool is initialized
     */
    function isPoolInitialized(PoolId poolId) public view returns (bool) {
        return _poolKeys[poolId].fee != 0; // If fee is set, the pool is initialized
    }

    /**
     * @notice Force position cache update for a pool
     * @dev Maintained for backward compatibility but just emits an event
     * @param poolId The ID of the pool to update
     * @param liquidity The liquidity value (not used)
     * @param sqrtPriceX96 The price value (not used)
     */
    function forcePositionCache(
        PoolId poolId,
        uint128 liquidity,
        uint160 sqrtPriceX96
    ) external onlyFullRangeOrOwner {
        // Only emits the event for compatibility, doesn't store anything
        emit PositionCacheUpdated(poolId, liquidity, sqrtPriceX96);
    }
} 