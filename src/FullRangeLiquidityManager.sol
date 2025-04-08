// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {MathUtils} from "./libraries/MathUtils.sol";
import {Errors} from "./errors/Errors.sol";
import {FullRangePositions} from "./token/FullRangePositions.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PoolTokenIdUtils} from "./utils/PoolTokenIdUtils.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "./interfaces/IFullRangeLiquidityManager.sol";
import {CurrencySettlerExtension} from "./utils/CurrencySettlerExtension.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import "forge-std/console2.sol";

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
            
    /// @dev The Uniswap V4 PoolManager reference
    IPoolManager public immutable manager;
    
    /// @dev ERC6909Claims token for position tokenization
    FullRangePositions public immutable positions;
    
    /// @dev Stored pool data
    mapping(PoolId => uint128) public poolTotalShares;
    
    /// @dev Pool keys for lookups
    mapping(PoolId => PoolKey) private _poolKeys;
    
    /// @dev User position data
    mapping(PoolId => mapping(address => AccountPosition)) public userPositions;
    
    /// @dev Maximum reserve cap to prevent unbounded growth
    uint256 public constant MAX_RESERVE = type(uint128).max;
    
    /// @dev Address of the FullRange main contract
    address public fullRangeAddress;
    
    // Constants for minimum liquidity locking
    uint128 private constant MIN_LIQUIDITY = 1000; // Mimics Uniswap V3 Minimum Liquidity
    uint128 private constant MIN_LOCKED_LIQUIDITY = 1000; // Lock 1000 units of liquidity
    
    // Emergency controls
    bool public emergencyWithdrawalsEnabled = false;
    mapping(PoolId => bool) public poolEmergencyState;
    address public emergencyAdmin;
            
    // Tracking locked liquidity
    mapping(PoolId => uint256) public lockedLiquidity;
    
    // Constants
    uint256 private constant MIN_VIABLE_RESERVE = 100;
    uint256 private constant PRECISION = 1_000_000; // 10^6 precision for percentage calculations
    
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
                
    // Storage slot constants for V4 state access
    bytes32 private constant POOLS_SLOT = bytes32(uint256(6));
    uint256 private constant POSITIONS_OFFSET = 6;
    
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
     * @notice Allows the contract to receive ETH
     */
    receive() external payable {}
    
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
    
    // === POOL MANAGEMENT FUNCTIONS ===
    
    /**
     * @notice Register a pool with the liquidity manager
     * @dev Called by FullRange when a pool is initialized
     */
    function registerPool(PoolId poolId, PoolKey memory key, uint160 sqrtPriceX96) external onlyFullRange {
        // Store pool key
        _poolKeys[poolId] = key;
        
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
        uint256 usableLiquidity,
        uint256 amount0,
        uint256 amount1
    ) {
        // Enhanced validation
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(poolId);
        
        // Get pool key and necessary pool data
        PoolKey memory key = _poolKeys[poolId];
        ( , uint160 sqrtPriceX96) = getPositionData(poolId);

        if (sqrtPriceX96 == 0 && poolTotalShares[poolId] == 0) { // Need price for first deposit calculation
            // Try to read from pool state directly if position data failed initially
             bytes32 stateSlot = _getPoolStateSlot(poolId);
             try manager.extsload(stateSlot) returns (bytes32 slot0Data) {
                 sqrtPriceX96 = uint160(uint256(slot0Data));
             } catch {
                 revert Errors.FailedToReadPoolData(poolId); // Still failed
             }
             if (sqrtPriceX96 == 0) revert Errors.ValidationInvalidInput("Pool price is zero");
        }
                
        // Check for native ETH
        bool hasToken0Native = key.currency0.isAddressZero();
        bool hasToken1Native = key.currency1.isAddressZero();
        
        // Get current internal state
        uint128 totalLiquidityInternal = poolTotalShares[poolId]; // Treat as total liquidity
        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId); // Still use reserves for ratio calc in _calculateDepositAmounts

        // Calculate deposit amounts and liquidity using V4 math
        (uint256 actual0, uint256 actual1, uint128 liquidityToAdd, uint128 lockedLiquidityAmount) = 
            _calculateDepositAmounts(
                totalLiquidityInternal,
                sqrtPriceX96,
                key.tickSpacing,
                amount0Desired,
                amount1Desired,
                reserve0,
                reserve1
            );
        
        // Rename amount0/1 for clarity
        amount0 = actual0; 
        amount1 = actual1;

        // Validate minimum amounts against V4-calculated actuals
        if (amount0 < amount0Min || amount1 < amount1Min) {
            uint256 requiredMin = (amount0 < amount0Min) ? amount0Min : amount1Min;
            uint256 actualOut = (amount0 < amount0Min) ? amount0 : amount1;
            revert Errors.SlippageExceeded(requiredMin, actualOut);
        }
        
        // Validate and handle ETH
        if (msg.value > 0) {
            // Calculate required ETH
            uint256 ethNeeded = 0;
            if (hasToken0Native) ethNeeded += amount0;
            if (hasToken1Native) ethNeeded += amount1;
            
            // Ensure enough ETH was sent
            if (msg.value < ethNeeded) {
                revert Errors.InsufficientETH(ethNeeded, msg.value);
            }
        }
        
        // Update total internal liquidity tracking
        uint128 oldTotalLiquidityInternal = totalLiquidityInternal;
        poolTotalShares[poolId] += liquidityToAdd; // Add total liquidity
        
        // If this is first deposit with locked liquidity, record it
        if (lockedLiquidityAmount > 0 && lockedLiquidity[poolId] == 0) {
            lockedLiquidity[poolId] = lockedLiquidityAmount;
            emit MinimumLiquidityLocked(poolId, lockedLiquidityAmount);
        }
        
        // Mint position tokens to user (only the usable liquidity)
        usableLiquidity = uint256(liquidityToAdd - lockedLiquidityAmount);
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        positions.mint(recipient, tokenId, usableLiquidity);
                
        // Transfer tokens from recipient (the user)
        if (amount0 > 0 && !hasToken0Native) {
            IERC20Minimal(Currency.unwrap(key.currency0)).transferFrom(recipient, address(this), amount0);
        }
        if (amount1 > 0 && !hasToken1Native) {
            IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(recipient, address(this), amount1);
        }
                
        // Create callback data for the FullRange hook to handle
        CallbackData memory callbackData = CallbackData({
            poolId: poolId,
            callbackType: CallbackType.DEPOSIT,
            shares: liquidityToAdd,
            oldTotalShares: oldTotalLiquidityInternal,
            amount0: amount0,
            amount1: amount1,
            recipient: recipient
        });
        
        // Call unlock to add liquidity via FullRange's unlockCallback
        manager.unlock(abi.encode(callbackData));
        
        // Refund excess ETH if there is any
        if (msg.value > 0) {
            uint256 ethUsed = 0;
            if (hasToken0Native) ethUsed += amount0;
            if (hasToken1Native) ethUsed += amount1;
            if (msg.value > ethUsed) SafeTransferLib.safeTransferETH(msg.sender, msg.value - ethUsed);
        }
        
        // Emit events (Update event names/params if needed later)
        emit LiquidityAdded(
            poolId,
            recipient,
            amount0,
            amount1,
            oldTotalLiquidityInternal, // Use liquidity here
            uint128(usableLiquidity), // Emit usable liquidity minted
            block.timestamp
        );
        
        emit TotalLiquidityUpdated(poolId, oldTotalLiquidityInternal, poolTotalShares[poolId]);
        
        return (usableLiquidity, amount0, amount1);
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
                        
        // Get the user's share balance
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        uint256 userShareBalance = positions.balanceOf(recipient, tokenId);
        
        // Validate shares to withdraw
        if (sharesToBurn > userShareBalance) {
            revert Errors.InsufficientShares(sharesToBurn, userShareBalance);
        }
        
        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId);
        uint128 totalShares = poolTotalShares[poolId];

        // Calculate amounts to withdraw
        (amount0, amount1) = _calculateWithdrawAmounts(
            totalShares,
            sharesToBurn,
            reserve0,
            reserve1
        );
        
        // Check slippage
        if (amount0 < amount0Min || amount1 < amount1Min) {
            uint256 requiredMin = (amount0 < amount0Min) ? amount0Min : amount1Min;
            uint256 actualOut = (amount0 < amount0Min) ? amount0 : amount1;
            revert Errors.SlippageExceeded(requiredMin, actualOut);
        }
        
        // Get token addresses from pool key
        PoolKey memory key = _poolKeys[poolId];

        // Update total shares with more comprehensive SafeCast
        // TODO: look into this cast
        uint128 oldTotalShares = poolTotalShares[poolId];
        poolTotalShares[poolId] = oldTotalShares - uint128(sharesToBurn);
        
        // Burn position tokens *before* calling unlock, consistent with CEI pattern
        // This prevents reentrancy issues where unlockCallback might see stale token balances.
        positions.burn(msg.sender, tokenId, sharesToBurn); // Burn from msg.sender who initiated withdraw
                
        // Create callback data for the FullRange hook to handle
        CallbackData memory callbackData = CallbackData({
            poolId: poolId,
            callbackType: CallbackType.WITHDRAW,
            shares: uint128(sharesToBurn),
            oldTotalShares: oldTotalShares,
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
            uint128(sharesToBurn),
            block.timestamp
        );
        
        emit TotalLiquidityUpdated(poolId, oldTotalShares, poolTotalShares[poolId]);
        
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
        if (!isPoolInitialized(params.poolId)) revert Errors.PoolNotInitialized(params.poolId);

        // Validate emergency state
        if (!emergencyWithdrawalsEnabled && !poolEmergencyState[params.poolId]) {
            revert Errors.InvalidInput();
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
        
        (uint256 reserve0, uint256 reserve1) = getPoolReserves(params.poolId);
        uint128 totalShares = poolTotalShares[params.poolId];

        // Calculate amounts to withdraw (no slippage check in emergency)
        (amount0Out, amount1Out) = _calculateWithdrawAmounts(
            totalShares,
            sharesToBurn,
            reserve0,
            reserve1
        );
        
        // Get token addresses from pool key
        PoolKey memory key = _poolKeys[params.poolId];
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        
        // Update total shares
        uint128 oldTotalShares = poolTotalShares[params.poolId];
        poolTotalShares[params.poolId] = oldTotalShares - uint128(sharesToBurn);
        
        // Burn position tokens
        positions.burn(user, tokenId, sharesToBurn);
                
        // Create callback data for the FullRange hook to handle
        CallbackData memory callbackData = CallbackData({
            poolId: params.poolId,
            callbackType: CallbackType.WITHDRAW,
            shares: uint128(sharesToBurn),
            oldTotalShares: oldTotalShares,
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
        // TODO: probably don't need to emit three different events here
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
        
        emit TotalLiquidityUpdated(params.poolId, oldTotalShares, poolTotalShares[params.poolId]);
        
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
            
    // === INTERNAL HELPER FUNCTIONS ===
    
    /**
     * @notice Calculate deposit amounts and liquidity
     * @param totalLiquidityInternal Current total liquidity managed by this contract
     * @param sqrtPriceX96 Current sqrt price of the pool
     * @param tickSpacing Tick spacing of the pool
     * @param amount0Desired Desired amount of token0
     * @param amount1Desired Desired amount of token1
     * @param reserve0 Current token0 reserves (used for ratio calculation in subsequent deposits)
     * @param reserve1 Current token1 reserves (used for ratio calculation in subsequent deposits)
     * @return actual0 Actual token0 amount to deposit
     * @return actual1 Actual token1 amount to deposit
     * @return liquidity Liquidity to add to the pool
     * @return lockedLiquidityAmount Liquidity to lock (for minimum liquidity on first deposit)
     */
    function _calculateDepositAmounts(
        uint128 totalLiquidityInternal,
        uint160 sqrtPriceX96,
        int24 tickSpacing,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (
        uint256 actual0,
        uint256 actual1,
        uint128 liquidity,
        uint128 lockedLiquidityAmount
    ) {
        // Calculate tick boundaries
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        if (totalLiquidityInternal == 0) {
            // First deposit case
            if (amount0Desired == 0 || amount1Desired == 0) revert Errors.ZeroAmount();
            if (sqrtPriceX96 == 0) revert Errors.ValidationInvalidInput("Initial price is zero");

            // Use MathUtils to calculate liquidity based on desired amounts and current price
            liquidity = MathUtils.computeLiquidityFromAmounts(
                sqrtPriceX96,
                sqrtPriceAX96,
                sqrtPriceBX96,
                amount0Desired,
                amount1Desired
            );

            if (liquidity < MIN_LIQUIDITY) {
                revert Errors.InitialDepositTooSmall(MIN_LIQUIDITY, liquidity);
            }

            // Calculate actual amounts required for this liquidity
            (actual0, actual1) = MathUtils.computeAmountsFromLiquidity(
                sqrtPriceX96,
                sqrtPriceAX96,
                sqrtPriceBX96,
                liquidity,
                true // Round up for deposits
            );

            // Lock minimum liquidity
            lockedLiquidityAmount = MIN_LOCKED_LIQUIDITY;
            // Ensure locked doesn't exceed total and some usable exists
            if (lockedLiquidityAmount >= liquidity) lockedLiquidityAmount = liquidity - 1;
            if (lockedLiquidityAmount == 0 && liquidity > 1) lockedLiquidityAmount = 1; // Lock at least 1 if possible
            if (liquidity <= lockedLiquidityAmount) { // Check if enough usable liquidity remains
                revert Errors.InitialDepositTooSmall(lockedLiquidityAmount + 1, liquidity);
            }
        } else {
            // Subsequent deposits - Calculate ratio-matched amounts first, then liquidity
            if (reserve0 == 0 && reserve1 == 0) {
                revert Errors.InconsistentState("Reserves are zero but total liquidity exists");
            }

            // Calculate optimal amounts based on current reserves/ratio
            if (reserve0 > 0 && reserve1 > 0) {
                uint256 optimalAmount1 = FullMath.mulDiv(amount0Desired, reserve1, reserve0);
                uint256 optimalAmount0 = FullMath.mulDiv(amount1Desired, reserve0, reserve1);

                if (optimalAmount1 <= amount1Desired) {
                    actual0 = amount0Desired;
                    actual1 = optimalAmount1;
                } else {
                    actual1 = amount1Desired;
                    actual0 = optimalAmount0;
                }
            } else if (reserve0 > 0) { // Only token0 in reserves
                if (amount0Desired == 0) revert Errors.ZeroAmount();
                actual0 = amount0Desired;
                actual1 = 0;
            } else { // Only token1 in reserves
                if (amount1Desired == 0) revert Errors.ZeroAmount();
                actual0 = 0;
                actual1 = amount1Desired;
            }

            // Use MathUtils to calculate liquidity based on the chosen actual amounts
            liquidity = MathUtils.computeLiquidityFromAmounts(
                sqrtPriceX96,
                sqrtPriceAX96,
                sqrtPriceBX96,
                actual0,
                actual1
            );

            if (liquidity == 0 && (amount0Desired > 0 || amount1Desired > 0)) {
                // This might happen if desired amounts are non-zero but ratio calculation leads to zero actuals,
                // or if amounts are too small for the price.
                revert Errors.DepositTooSmall();
            }

            // Recalculate actual amounts to ensure consistency with V4 core
            (actual0, actual1) = MathUtils.computeAmountsFromLiquidity(
                sqrtPriceX96,
                sqrtPriceAX96,
                sqrtPriceBX96,
                liquidity,
                true // Round up for deposits
            );

            lockedLiquidityAmount = 0; // No locking for subsequent deposits
        }

        return (actual0, actual1, liquidity, lockedLiquidityAmount);
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
            SafeTransferLib.safeTransferETH(to, amount);
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
        uint128 oldTotalShares = poolTotalShares[poolId];
        poolTotalShares[poolId] = newTotalShares;
        
        // TODO: probably don't need to emit the oldTotalShares here
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
    // TODO: why is this function passed the currentTotalShares?
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
        if (poolTotalShares[poolId] != currentTotalShares) {
            revert Errors.ValidationInvalidInput("Total shares mismatch");
        }
        
        // First execute external call (tokens.burn) before state changes
        positions.burn(user, tokenId, sharesToBurn);
        
        // Then update contract state
        newTotalShares = currentTotalShares - uint128(sharesToBurn);
        poolTotalShares[poolId] = newTotalShares;
        
        // Simplified event emission
        emit UserSharesRemoved(poolId, user, sharesToBurn);
        emit PoolStateUpdated(poolId, newTotalShares, 2); // 2 = withdraw
        
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
        PoolKey memory key = _poolKeys[poolId];
        uint128 oldTotalShares = poolTotalShares[poolId];
        
        // *** CRITICAL CHANGE: Execute pool interactions BEFORE state changes ***
        
        // Add POL to Uniswap pool first
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            liquidityDelta: int256(shares),
            salt: bytes32(0)
        });
        
        // Call modifyLiquidity and handle settlement
        (BalanceDelta delta, ) = manager.modifyLiquidity(key, params, new bytes(0));
        _handleDelta(delta, Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        
        // Only update state AFTER successful external calls
        poolTotalShares[poolId] = oldTotalShares + uint128(shares);
        
        // Mint shares to POL treasury
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        address polTreasury = owner; // Use contract owner as POL treasury
        positions.mint(polTreasury, tokenId, shares);
        
        // Single event for the operation - reduced from multiple events
        // TODO: probably don't need to emit two different events here
        emit ReinvestmentProcessed(poolId, polAmount0, polAmount1, shares, oldTotalShares, poolTotalShares[poolId]);
        emit PoolStateUpdated(poolId, poolTotalShares[poolId], 3); // 3 = reinvest
        
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
        if (poolTotalShares[poolId] == 0 || shares == 0) return (0, 0);

        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId);
        
        // Calculate proportional amounts based on shares
        amount0 = (reserve0 * shares) / poolTotalShares[poolId];
        amount1 = (reserve1 * shares) / poolTotalShares[poolId];
        
        return (amount0, amount1);
    }  

    /**
     * @notice Extract protocol fees from the pool and prepare to reinvest them as protocol-owned liquidity
     * @param poolId The pool ID to extract and reinvest fees for
     * @param amount0 Amount of token0 to extract for reinvestment
     * @param amount1 Amount of token1 to extract for reinvestment
     * @param recipient Address to receive the extracted fees (typically the FeeReinvestmentManager)
     * @return success Whether the extraction for reinvestment was successful
     * @dev Properly removes liquidity from the position to extract the tokens, maintaining accounting consistency
     */
    function reinvestProtocolFees(
        PoolId poolId,
        uint256 amount0,
        uint256 amount1,
        address recipient
    ) external onlyFullRange returns (bool success) {
        // Validation
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(poolId);
        if (amount0 == 0 && amount1 == 0) revert Errors.ZeroAmount();
                
        // Get current pool data for proper liquidity calculation
        (uint128 currentLiquidity, ) = getPositionData(poolId);
        
        // Get current total shares (needed for calculating proportion to remove)
        uint128 totalShares = poolTotalShares[poolId];
        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId);
        
        // Calculate percentage of liquidity to remove based on amounts requested
        // We can't be more precise than this without recomputing the exact amounts for the liquidity
        uint256 liquidityPercentage0 = 0;
        uint256 liquidityPercentage1 = 0;
        
        if (reserve0 > 0 && amount0 > 0) {
            liquidityPercentage0 = (amount0 * PRECISION) / reserve0;
        }
        
        if (reserve1 > 0 && amount1 > 0) {
            liquidityPercentage1 = (amount1 * PRECISION) / reserve1;
        }
        
        // Take the maximum percentage to ensure we get at least the requested amounts
        uint256 liquidityPercentage = liquidityPercentage0 > liquidityPercentage1 ? 
                                      liquidityPercentage0 : liquidityPercentage1;
        
        // Calculate liquidity to remove (proportional to the tokens requested)
        uint256 liquidityToRemove = (currentLiquidity * liquidityPercentage) / PRECISION;
        
        // Ensure we're removing at least 1 unit of liquidity if any was requested
        if (liquidityToRemove == 0 && (amount0 > 0 || amount1 > 0)) {
            liquidityToRemove = 1; // Minimum removal
        }
        
        // Create callback data for the unlock operation
        CallbackData memory callbackData = CallbackData({
            poolId: poolId,
            callbackType: CallbackType.REINVEST_PROTOCOL_FEES,
            shares: uint128(liquidityToRemove),
            oldTotalShares: totalShares,
            amount0: amount0,
            amount1: amount1,
            recipient: recipient
        });
        
        // Call unlock to extract fees via unlock callback
        // This will properly reduce the position's liquidity and transfer tokens
        manager.unlock(abi.encode(callbackData));
        
        // Emit event for fee extraction
        emit ProtocolFeesReinvested(poolId, recipient, amount0, amount1);
        
        return true;
    }

    /**
     * @notice Process unlock callback from the PoolManager
     * @param data Callback data
     * @return Result data
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // Only allow calls from the pool manager
        if (msg.sender != address(manager)) {
            revert Errors.AccessNotAuthorized(msg.sender);
        }
        
        // Decode the callback data
        CallbackData memory cbData = abi.decode(data, (CallbackData));
        
        // Verify the pool ID exists
        PoolKey memory key = _poolKeys[cbData.poolId];
        if (key.tickSpacing == 0) revert Errors.PoolNotInitialized(cbData.poolId);
        
        BalanceDelta delta;
        
        // Create ModifyLiquidityParams based on callback type
        int256 liquidityDelta;
        address recipient;
        
        if (cbData.callbackType == CallbackType.DEPOSIT) {
            liquidityDelta = int256(uint256(cbData.shares));
            recipient = address(this); // For deposits, tokens stay in this contract
        } else if (cbData.callbackType == CallbackType.WITHDRAW || 
                  cbData.callbackType == CallbackType.BORROW || 
                  cbData.callbackType == CallbackType.REINVEST_PROTOCOL_FEES) {
            liquidityDelta = -int256(uint256(cbData.shares));
            recipient = cbData.recipient; // For withdrawals/borrows/reinvests, send to recipient
        } else {
            revert Errors.InvalidCallbackType(uint8(cbData.callbackType));
        }
        
        // Execute the liquidity modification
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            liquidityDelta: liquidityDelta,
            salt: bytes32(0)
        });
        
        (delta, ) = manager.modifyLiquidity(key, params, "");
        
        // Handle settlement
        CurrencySettlerExtension.handlePoolDelta(manager, delta, key.currency0, key.currency1, recipient);
        
        return abi.encode(delta);
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
        (uint128 liquidity, uint160 sqrtPriceX96) = getPositionData(poolId);
                
        // If still no usable data, return zeros
        // TODO: is this needed?
        if (liquidity == 0 || sqrtPriceX96 == 0) {
            return (0, 0);
        }
        
        return MathUtils.computeAmountsFromLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity,
            true
        );
    }
    
    /**
     * @notice Direct read of position data from Uniswap v4 pool
     * @param poolId The pool ID
     * @return liquidity The current liquidity of the position
     * @return sqrtPriceX96 The current sqrt price of the pool
     */
    function getPositionData(PoolId poolId) public view returns (uint128 liquidity, uint160 sqrtPriceX96) {
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(poolId);
        
        PoolKey memory key = _poolKeys[poolId];
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        bool readSuccess = false;
        
        // Get position data via extsload - use this contract's address as owner
        bytes32 positionKey = Position.calculatePositionKey(address(this), tickLower, tickUpper, bytes32(0));
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
        
        return (liquidity, sqrtPriceX96);
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
     * @notice Special internal function for Margin contract to borrow liquidity without burning LP tokens
     * @param poolId The pool ID to borrow from
     * @param sharesToBorrow Amount of shares to borrow (determines token amounts)
     * @param recipient Address to receive the tokens (typically the Margin contract)
     * @return amount0 Amount of token0 received
     * @return amount1 Amount of token1 received
     * @dev Unlike withdraw, this function doesn't burn user LP tokens. It uses manager.modifyLiquidity
     *      to extract tokens from the pool while maintaining the accounting of shares.
     */
    function borrowImpl(
        PoolId poolId,
        uint256 sharesToBorrow,
        address recipient
    ) external onlyFullRange returns (
        uint256 amount0,
        uint256 amount1
    ) {
        // Validation
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(poolId);
        if (sharesToBorrow == 0) revert Errors.ZeroAmount();
        
        // Get pool details
        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId);
        uint128 totalShares = poolTotalShares[poolId];

        // Verify pool has sufficient shares/liquidity
        if (totalShares == 0) revert Errors.ZeroShares();
        
        // Calculate amounts to withdraw based on shares
        (amount0, amount1) = _calculateWithdrawAmounts(
            totalShares,
            sharesToBorrow,
            reserve0,
            reserve1
        );
        
        // Get current position data for V4 liquidity calculation
        (uint128 currentV4Liquidity, uint160 sqrtPriceX96) = getPositionData(poolId);

        if (sqrtPriceX96 == 0) revert Errors.ValidationInvalidInput("Pool price is zero");
        
        // Calculate V4 liquidity to withdraw proportionally to shares borrowed
        uint256 liquidityToWithdraw = FullMath.mulDiv(sharesToBorrow, currentV4Liquidity, totalShares);
        if (liquidityToWithdraw > type(uint128).max) liquidityToWithdraw = type(uint128).max; // Cap at uint128
        if (liquidityToWithdraw == 0 && sharesToBorrow > 0) {
            // Handle case where shares are borrowed but calculated liquidity is 0 (dust amount)
            liquidityToWithdraw = 1;
        }
        
        // Create callback data for the unlock operation
        CallbackData memory callbackData = CallbackData({
            poolId: poolId,
            callbackType: CallbackType.BORROW,
            shares: uint128(sharesToBorrow),
            oldTotalShares: totalShares,
            amount0: amount0,
            amount1: amount1,
            recipient: recipient
        });
        
        // Call unlock to remove liquidity via FullRange's unlockCallback
        manager.unlock(abi.encode(callbackData));
        
        // Do NOT update totalShares or burn LP tokens - that's the key difference from withdraw
        
        // Emit a special event for borrowing
        emit TokensBorrowed(poolId, recipient, amount0, amount1, sharesToBorrow);
        
        return (amount0, amount1);
    }
} 