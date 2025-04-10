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
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import "forge-std/console2.sol";
import {LiquidityMath} from "v4-core/src/libraries/LiquidityMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TransferUtils} from "./utils/TransferUtils.sol";

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
    uint8 internal constant ACTION_BORROW = 3;
    uint8 internal constant ACTION_REINVEST_PROTOCOL_FEES = 4;
    
    // Callback data structure for unlock pattern
    struct CallbackData {
        PoolId poolId;
        uint8 callbackType; // 1 for deposit, 2 for withdraw, 3 for borrow, 4 for reinvestProtocolFees
        uint128 shares;
        uint128 oldTotalShares;
        uint256 amount0;
        uint256 amount1;
        address recipient;
    }
        
    /// @dev The Uniswap V4 PoolManager reference
    IPoolManager public immutable manager;
    
    /// @dev ERC6909Claims token for position tokenization
    FullRangePositions public immutable positions;
    
    /// @dev Stored pool data
    mapping(PoolId => uint128) public poolTotalShares;
    
    /// @dev Pool keys for lookups
    mapping(PoolId => PoolKey) private _poolKeys;
    
    /// @dev Maximum reserve cap to prevent unbounded growth
    uint256 public constant MAX_RESERVE = type(uint128).max;
    
    /// @dev Address authorized to store pool keys (typically the associated hook contract)
    /// Set by the owner.
    address public authorizedHookAddress;
    
    // Constants for minimum liquidity locking
    uint256 private constant MIN_LOCKED_SHARES = 1000; // e.g., 1000 wei, adjust as needed
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
    event PoolKeyStored(PoolId indexed poolId, PoolKey key);
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
     * @notice Sets the address authorized to call `storePoolKey`.
     * @param _hookAddress The address of the authorized hook contract.
     */
    function setAuthorizedHookAddress(address _hookAddress) external onlyOwner {
        if (_hookAddress == address(0)) revert Errors.ZeroAddress();
        authorizedHookAddress = _hookAddress;
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
        if (msg.sender != authorizedHookAddress) {
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
     * @notice Stores the PoolKey associated with a PoolId.
     * @dev Called by the authorized hook during its afterInitialize phase.
     * @param poolId The Pool ID.
     * @param key The PoolKey corresponding to the Pool ID.
     */
    function storePoolKey(PoolId poolId, PoolKey calldata key) external override onlyFullRange {
        // Prevent overwriting existing keys? Optional check.
        // if (_poolKeys[poolId].tickSpacing != 0) revert PoolKeyAlreadyStored(poolId);
        _poolKeys[poolId] = key;
        emit PoolKeyStored(poolId, key);
    }
    
    /**
     * @notice Get the PoolKey for a given PoolId (implements interface)
     * @param poolId The Pool ID to look up
     * @return Pool key associated with this Pool ID
     */
    function poolKeys(PoolId poolId) external view override returns (PoolKey memory) {
        PoolKey memory key = _poolKeys[poolId];
        if (key.tickSpacing == 0) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
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
     * @notice Get the position token contract
     * @return The position token contract
     */
    function getPositionsContract() external view returns (FullRangePositions) {
        return positions;
    }
    
    // === LIQUIDITY MANAGEMENT FUNCTIONS ===
    
    /**
     * @notice Deposit tokens into a pool with native ETH support
     * @dev Uses PoolId to manage state for the correct pool.
     * @inheritdoc IFullRangeLiquidityManager
     */
    function deposit(
        PoolId poolId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external payable override nonReentrant returns (
        uint256 usableShares, // Renamed from usableLiquidity for clarity
        uint256 amount0,
        uint256 amount1
    ) {
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
        if (amount0Desired == 0 && amount1Desired == 0) revert Errors.ZeroAmount(); // Must desire some amount
        
        PoolKey memory key = _poolKeys[poolId]; // Use poolId
        ( , uint160 sqrtPriceX96, ) = getPositionData(poolId); // Use poolId
        // Note: getPositionData reads liquidity from the *pool*, not poolTotalShares mapping
        // We need poolTotalShares for share calculation consistency
        uint128 totalSharesInternal = poolTotalShares[poolId]; // Use poolId
        
        if (sqrtPriceX96 == 0 && totalSharesInternal == 0) { 
             bytes32 stateSlot = _getPoolStateSlot(poolId); // Use poolId
             try manager.extsload(stateSlot) returns (bytes32 slot0Data) {
                 sqrtPriceX96 = uint160(uint256(slot0Data));
             } catch {
                 revert Errors.FailedToReadPoolData(poolId); // Use poolId
             }
             if (sqrtPriceX96 == 0) revert Errors.ValidationInvalidInput("Pool price is zero");
        }
                
        bool hasToken0Native = key.currency0.isAddressZero();
        bool hasToken1Native = key.currency1.isAddressZero();
        
        // Use internal share count for calculations
        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId); // Use poolId

        // Calculate shares and amounts
        (uint256 actual0, uint256 actual1, uint128 sharesToAdd, uint128 lockedSharesAmount) = 
            _calculateDepositShares( // Renamed function
                totalSharesInternal, 
                sqrtPriceX96,
                key.tickSpacing,
                amount0Desired,
                amount1Desired,
                reserve0,
                reserve1
            );
        
        amount0 = actual0; 
        amount1 = actual1;

        if (amount0 < amount0Min || amount1 < amount1Min) {
            revert Errors.SlippageExceeded(
                (amount0 < amount0Min) ? amount0Min : amount1Min, 
                (amount0 < amount0Min) ? amount0 : amount1
            );
        }
        
        // ETH Handling
        uint256 ethNeeded = 0;
        if (hasToken0Native) ethNeeded += amount0;
        if (hasToken1Native) ethNeeded += amount1;
        if (msg.value < ethNeeded) {
            revert Errors.InsufficientETH(ethNeeded, msg.value);
        }
        
        uint128 oldTotalSharesInternal = totalSharesInternal;
        uint128 newTotalSharesInternal = oldTotalSharesInternal + sharesToAdd;
        poolTotalShares[poolId] = newTotalSharesInternal; // Update internal share count using poolId
        
        if (lockedSharesAmount > 0 && lockedLiquidity[poolId] == 0) { // Use poolId
            lockedLiquidity[poolId] = lockedSharesAmount; // Use poolId
            emit MinimumLiquidityLocked(poolId, lockedSharesAmount); // Use poolId
        }
        
        usableShares = uint256(sharesToAdd - lockedSharesAmount);
        if (usableShares > 0) { // Only mint if there are usable shares
            uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId); // Use poolId
            positions.mint(recipient, tokenId, usableShares);
        }
                
        // Transfer non-native tokens from msg.sender
        if (amount0 > 0 && !hasToken0Native) {
            SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(key.currency0)), msg.sender, address(this), amount0);
        }
        if (amount1 > 0 && !hasToken1Native) {
            SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(key.currency1)), msg.sender, address(this), amount1);
        }
                
        // Prepare callback data
        CallbackData memory callbackData = CallbackData({
            poolId: poolId, // Use poolId
            callbackType: ACTION_DEPOSIT, 
            shares: sharesToAdd,
            oldTotalShares: oldTotalSharesInternal,
            amount0: amount0,
            amount1: amount1,
            recipient: address(this) // Unlock target is this contract
        });
        
        // Unlock calls modifyLiquidity via hook and transfers tokens to PoolManager
        manager.unlock(abi.encode(callbackData));
        
        // Refund excess ETH
        if (msg.value > ethNeeded) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - ethNeeded);
        }
        
        emit LiquidityAdded(
            poolId, // Use poolId
            recipient,
            amount0,
            amount1,
            oldTotalSharesInternal, 
            uint128(usableShares),
            block.timestamp
        );
        emit PoolStateUpdated(poolId, newTotalSharesInternal, ACTION_DEPOSIT); // Use poolId
        
        return (usableShares, amount0, amount1);
    }
    
    /**
     * @notice Withdraw liquidity from a pool
     * @dev Uses PoolId to manage state for the correct pool.
     * @inheritdoc IFullRangeLiquidityManager
     */
    function withdraw(
        PoolId poolId,
        uint256 sharesToBurn,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) external override nonReentrant returns (
        uint256 amount0,
        uint256 amount1
    ) {
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
        if (sharesToBurn == 0) revert Errors.ZeroAmount();
        
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId); // Use poolId
        // Check shares of msg.sender who is burning tokens
        uint256 userShareBalance = positions.balanceOf(msg.sender, tokenId);
        if (userShareBalance < sharesToBurn) {
            revert Errors.InsufficientShares(sharesToBurn, userShareBalance);
        }
        
        uint128 totalSharesInternal = poolTotalShares[poolId]; // Use poolId
        if (totalSharesInternal == 0) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId)); // Use poolId, unwrap for error
        uint128 sharesToBurn128 = sharesToBurn.toUint128();
        if (sharesToBurn128 > totalSharesInternal) { 
             revert Errors.InsufficientShares(sharesToBurn, totalSharesInternal);
        }

        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId); // Use poolId

        // Calculate withdrawal amounts
        (amount0, amount1) = _calculateWithdrawAmounts(
            totalSharesInternal,
            sharesToBurn,
            reserve0,
            reserve1
        );
        
        if (amount0 < amount0Min || amount1 < amount1Min) {
             revert Errors.SlippageExceeded(
                (amount0 < amount0Min) ? amount0Min : amount1Min, 
                (amount0 < amount0Min) ? amount0 : amount1
            );
        }
        
        PoolKey memory key = _poolKeys[poolId]; // Use poolId

        uint128 oldTotalSharesInternal = totalSharesInternal;
        uint128 newTotalSharesInternal = oldTotalSharesInternal - sharesToBurn128;
        poolTotalShares[poolId] = newTotalSharesInternal; // Use poolId
        
        // Burn position tokens from msg.sender *before* calling unlock
        positions.burn(msg.sender, tokenId, sharesToBurn);
        
        // Prepare callback data
        CallbackData memory callbackData = CallbackData({
            poolId: poolId, // Use poolId
            callbackType: ACTION_WITHDRAW, 
            shares: sharesToBurn128,
            oldTotalShares: oldTotalSharesInternal,
            amount0: amount0,
            amount1: amount1,
            recipient: address(this) // Unlock target is this contract
        });
        
        // Unlock calls modifyLiquidity via hook and transfers tokens from PoolManager
        manager.unlock(abi.encode(callbackData));
        
        // Transfer withdrawn tokens to the recipient
        if (amount0 > 0) {
            CurrencyLibrary.transfer(key.currency0, recipient, amount0);
        }
        if (amount1 > 0) {
            CurrencyLibrary.transfer(key.currency1, recipient, amount1);
        }
        
        emit LiquidityRemoved(
            poolId, // Use poolId
            recipient,
            amount0,
            amount1,
            oldTotalSharesInternal,
            sharesToBurn128,
            block.timestamp
        );
        emit PoolStateUpdated(poolId, newTotalSharesInternal, ACTION_WITHDRAW); // Use poolId
        
        return (amount0, amount1);
    }
    
    /**
     * @notice Pull tokens from the pool manager to this contract
     * @param token The token address (address(0) for ETH)
     * @param amount The amount to pull
     */
    function _pullTokens(address token, uint256 amount) internal {
        if (amount == 0) return;
        Currency currency = Currency.wrap(token);
        manager.take(currency, address(this), amount);
    }

    /**
     * @notice Handles delta settlement from FullRange's unlockCallback
     * @dev Uses CurrencySettlerExtension for efficient settlement
     */
    function handlePoolDelta(PoolKey memory key, BalanceDelta delta) public override {
        // Only callable by the associated PoolManager instance
        if (msg.sender != address(manager)) revert Errors.CallerNotPoolManager(msg.sender);
        
        // Verify this LM knows the PoolKey (implicitly validates PoolId)
        PoolId poolId = key.toId();
        if (_poolKeys[poolId].tickSpacing == 0) {
             revert Errors.PoolNotInitialized(PoolId.unwrap(poolId)); // Or PoolKeyNotStored
        }
        
        int128 amount0Delta = delta.amount0();
        int128 amount1Delta = delta.amount1();
        
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        
        // Pull tokens owed TO this contract from the pool
        if (amount0Delta < 0) {
            uint256 pullAmount0 = uint256(uint128(-amount0Delta)); 
            _pullTokens(token0, pullAmount0);
        }
        if (amount1Delta < 0) {
            uint256 pullAmount1 = uint256(uint128(-amount1Delta)); 
            _pullTokens(token1, pullAmount1);
        }
        
        // Send tokens owed FROM this contract to the pool
        if (amount0Delta > 0) {
             _safeTransferToken(token0, address(manager), uint256(uint128(amount0Delta)));
        }
        if (amount1Delta > 0) {
             _safeTransferToken(token1, address(manager), uint256(uint128(amount1Delta)));
        }
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
        PoolId poolId = params.poolId; // Extract poolId
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));

        if (!emergencyWithdrawalsEnabled && !poolEmergencyState[poolId]) { // Use poolId
            revert Errors.ValidationInvalidInput("Emergency withdraw not enabled");
        }
                        
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId); // Use poolId
        uint256 userShareBalance = positions.balanceOf(user, tokenId);
        
        uint256 sharesToBurn = params.shares;
        if (sharesToBurn == 0) revert Errors.ZeroAmount();
        if (sharesToBurn > userShareBalance) {
            revert Errors.InsufficientShares(sharesToBurn, userShareBalance);
        }
        
        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId); // Use poolId
        uint128 totalSharesInternal = poolTotalShares[poolId]; // Use poolId

        (amount0Out, amount1Out) = _calculateWithdrawAmounts(
            totalSharesInternal,
            sharesToBurn,
            reserve0,
            reserve1
        );
        
        PoolKey memory key = _poolKeys[poolId]; // Use poolId
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        
        uint128 oldTotalShares = totalSharesInternal;
        uint128 newTotalShares = oldTotalShares - sharesToBurn.toUint128();
        poolTotalShares[poolId] = newTotalShares; // Use poolId
        
        positions.burn(user, tokenId, sharesToBurn);
        
        // CallbackData setup uses poolId correctly
        CallbackData memory callbackData = CallbackData({
            poolId: poolId, 
            callbackType: ACTION_WITHDRAW, 
            shares: sharesToBurn.toUint128(),
            oldTotalShares: oldTotalShares,
            amount0: amount0Out,
            amount1: amount1Out,
            recipient: user // Target recipient for withdrawal
        });
        
        // Unlock handles modifyLiquidity and initial token movement
        bytes memory result = manager.unlock(abi.encode(callbackData));
        delta = abi.decode(result, (BalanceDelta));
        
        // Handle delta - Pull tokens owed to this contract
        handlePoolDelta(key, delta); // Use handlePoolDelta logic
        
        // Transfer final tokens to user
        if (amount0Out > 0) {
            _safeTransferToken(token0, user, amount0Out);
        }
        if (amount1Out > 0) {
            _safeTransferToken(token1, user, amount1Out);
        }
        
        emit EmergencyWithdrawalCompleted(poolId, user, amount0Out, amount1Out, sharesToBurn);
        emit LiquidityRemoved(poolId, user, amount0Out, amount1Out, oldTotalShares, sharesToBurn.toUint128(), block.timestamp);
        emit PoolStateUpdated(poolId, newTotalShares, ACTION_WITHDRAW);
        
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
     * @notice Calculates deposit shares based on desired amounts and pool state.
     * @param totalSharesInternal Current total shares tracked internally.
     * @param sqrtPriceX96 Current sqrt price of the pool.
     * @param tickSpacing Tick spacing.
     * @param amount0Desired Desired amount of token0.
     * @param amount1Desired Desired amount of token1.
     * @param reserve0 Current token0 reserves (read from pool state).
     * @param reserve1 Current token1 reserves (read from pool state).
     * @return actual0 Actual token0 amount calculated.
     * @return actual1 Actual token1 amount calculated.
     * @return shares Shares to be minted.
     * @return lockedSharesAmount Shares to be locked if it's the first deposit.
     */
    function _calculateDepositShares( // Renamed function
        uint128 totalSharesInternal,
        uint160 sqrtPriceX96,
        int24 tickSpacing,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (
        uint256 actual0,
        uint256 actual1,
        uint128 shares,
        uint128 lockedSharesAmount
    ) {
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        if (totalSharesInternal == 0) {
            // First deposit
            if (amount0Desired == 0 || amount1Desired == 0) revert Errors.ZeroAmount();
            if (sqrtPriceX96 == 0) revert Errors.ValidationInvalidInput("Initial price is zero");

            // Calculate liquidity (shares) based on amounts and price range (full range)
            shares = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                amount0Desired,
                amount1Desired
            );
            if (shares < MIN_LIQUIDITY) revert Errors.InitialDepositTooSmall(MIN_LIQUIDITY, shares);

            // Calculate actual amounts based on the determined liquidity using SqrtPriceMath
            actual0 = SqrtPriceMath.getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, shares, false); // Use SqrtPriceMath
            actual1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, shares, false); // Use SqrtPriceMath

            // Lock minimum shares
            lockedSharesAmount = MIN_LOCKED_SHARES.toUint128(); 
            if (shares <= lockedSharesAmount) revert Errors.InitialDepositTooSmall(lockedSharesAmount, shares);

        } else {
            // Subsequent deposits - calculate liquidity (shares) based on one amount and reserves ratio
            if (reserve0 == 0 || reserve1 == 0) revert Errors.ValidationInvalidInput("Reserves are zero");
            
            uint256 shares0 = FullMath.mulDivRoundingUp(amount0Desired, totalSharesInternal, reserve0);
            uint256 shares1 = FullMath.mulDivRoundingUp(amount1Desired, totalSharesInternal, reserve1);
            uint256 optimalShares = shares0 < shares1 ? shares0 : shares1;
            shares = optimalShares.toUint128();
            if (shares == 0) revert Errors.ZeroAmount();

            // Calculate actual amounts based on the determined shares and reserves ratio
            actual0 = FullMath.mulDivRoundingUp(uint256(shares), reserve0, totalSharesInternal);
            actual1 = FullMath.mulDivRoundingUp(uint256(shares), reserve1, totalSharesInternal);
            
            lockedSharesAmount = 0;
        }

        // Cap amounts at MAX_RESERVE if needed
        if (actual0 > MAX_RESERVE) actual0 = MAX_RESERVE;
        if (actual1 > MAX_RESERVE) actual1 = MAX_RESERVE;
    }

    /**
     * @notice Calculate withdrawal amounts based on shares and pool state.
     * @param totalSharesInternal Current total shares tracked internally.
     * @param sharesToBurn Shares being burned.
     * @param reserve0 Current token0 reserves (read from pool state).
     * @param reserve1 Current token1 reserves (read from pool state).
     * @return amount0 Token0 amount to withdraw.
     * @return amount1 Token1 amount to withdraw.
     */
    function _calculateWithdrawAmounts(
        uint128 totalSharesInternal,
        uint256 sharesToBurn,
        uint256 reserve0,
        uint256 reserve1
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (totalSharesInternal == 0) revert Errors.PoolNotInitialized(bytes32(0));
        if (sharesToBurn == 0) return (0, 0);

        // Calculate amounts proportionally
        amount0 = FullMath.mulDiv(reserve0, sharesToBurn, totalSharesInternal);
        amount1 = FullMath.mulDiv(reserve1, sharesToBurn, totalSharesInternal);
    }

    /**
     * @notice Get position data directly from PoolManager state for full range.
     * @param poolId The pool ID.
     * @return liquidity Current liquidity in the full range position.
     * @return sqrtPriceX96 Current sqrt price.
     * @return success Boolean indicating if data read was successful.
     */
    function getPositionData(PoolId poolId) 
        public 
        view 
        returns (uint128 liquidity, uint160 sqrtPriceX96, bool success)
    {
        PoolKey memory key = _poolKeys[poolId]; // Use poolId
        if (key.tickSpacing == 0) return (0, 0, false); // Pool not registered here

        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        bytes32 posSlot = Position.calculatePositionKey(address(this), tickLower, tickUpper, bytes32(0)); // Use calculatePositionKey
        bytes32 stateSlot = _getPoolStateSlot(poolId); // Use poolId

        // Use assembly for multi-slot read
        assembly {
            let slot0Val := sload(stateSlot)
            // Mask for sqrtPriceX96 (lower 160 bits)
            sqrtPriceX96 := and(slot0Val, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            if gt(sqrtPriceX96, 0) {
                let posVal := sload(posSlot)
                liquidity := and(posVal, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) // Mask lower 128 bits
                success := 1
            } {
                success := 0
            }
        }
    }

    /**
     * @notice Gets the current reserves for a pool directly from PoolManager state.
     * @param poolId The pool ID.
     * @return reserve0 The amount of token0 in the pool.
     * @return reserve1 The amount of token1 in the pool.
     */
    function getPoolReserves(PoolId poolId) public view override returns (uint256 reserve0, uint256 reserve1) {
        (uint128 liquidity, uint160 sqrtPriceX96, bool success) = getPositionData(poolId);

        if (!success || liquidity == 0) {
            return (0, 0); // No position data or zero liquidity
        }

        PoolKey memory key = _poolKeys[poolId]; // Assume key exists if position data was successful
        if (key.tickSpacing == 0) {
             // This case should ideally not happen if success is true, but added as safeguard
            return (0, 0); 
        }

        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // Calculate token amounts based on liquidity and current price within the full range
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            // Price is below the full range
            reserve0 = SqrtPriceMath.getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, false);
            reserve1 = 0;
        } else if (sqrtPriceX96 >= sqrtRatioBX96) {
            // Price is above the full range
            reserve0 = 0;
            reserve1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, false);
        } else {
            // Price is within the full range
            reserve0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtRatioBX96, liquidity, false);
            reserve1 = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, liquidity, false);
        }
    }

    /**
     * @notice Check if a pool has been initialized (i.e., key stored).
     * @param poolId The pool ID.
     */
    function isPoolInitialized(PoolId poolId) public view returns (bool) {
        bytes32 _poolIdBytes = PoolId.unwrap(poolId); // Rename to avoid conflict
        // Check if tickSpacing is non-zero, indicating the key has been stored
        return _poolKeys[poolId].tickSpacing != 0; // Use original poolId for mapping access
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
     * @notice Get the storage slot for a pool's state
     * @param poolId The pool ID
     * @return The storage slot for the pool's state
     */
    function _getPoolStateSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, POOLS_SLOT));
    }

    /**
     * @notice Gets share balance for an account in a specific pool.
     * @dev The `initialized` flag is true if shares > 0.
     * @inheritdoc IFullRangeLiquidityManager
     */
    function getAccountPosition(PoolId poolId, address account) 
        external 
        view 
        override 
        returns (bool initialized, uint256 shares)
    {
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId); // Use poolId
        shares = positions.balanceOf(account, tokenId);
        initialized = shares > 0; 
    }

    /**
     * @notice Special internal function for Margin contract to borrow liquidity without burning LP tokens
     * @param poolId The pool ID to borrow from
     * @param sharesToBorrow Amount of shares to borrow (determines token amounts)
     * @param recipient Address to receive the tokens (typically the Margin contract)
     * @return amount0 Amount of token0 received
     * @return amount1 Amount of token1 received
     */
    function borrowImpl(
        PoolId poolId,
        uint256 sharesToBorrow,
        address recipient
    ) external returns (uint256 amount0, uint256 amount1) {
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
        if (recipient == address(0)) revert Errors.ZeroAddress();
        if (sharesToBorrow == 0) revert Errors.ZeroAmount();

        uint128 totalSharesInternal = poolTotalShares[poolId];
        if (totalSharesInternal == 0) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
        
        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId);
        
        // Calculate amounts based on shares
        amount0 = FullMath.mulDiv(reserve0, sharesToBorrow, totalSharesInternal);
        amount1 = FullMath.mulDiv(reserve1, sharesToBorrow, totalSharesInternal);
        
        // Prepare callback data
        CallbackData memory callbackData = CallbackData({
            poolId: poolId,
            callbackType: ACTION_BORROW,
            shares: sharesToBorrow.toUint128(),
            oldTotalShares: totalSharesInternal,
            amount0: amount0,
            amount1: amount1,
            recipient: recipient
        });
        
        // Unlock calls modifyLiquidity via hook and transfers tokens
        manager.unlock(abi.encode(callbackData));
        
        emit TokensBorrowed(poolId, recipient, amount0, amount1, sharesToBorrow);
        
        return (amount0, amount1);
    }

    /**
     * @notice Reinvests fees for protocol-owned liquidity
     * @param poolId The pool ID
     * @param polAmount0 Amount of token0 for protocol-owned liquidity
     * @param polAmount1 Amount of token1 for protocol-owned liquidity
     * @return shares The number of POL shares minted
     */
    function reinvestFees(
        PoolId poolId,
        uint256 polAmount0,
        uint256 polAmount1
    ) external returns (uint256 shares) {
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(PoolId.unwrap(poolId));
        if (polAmount0 == 0 && polAmount1 == 0) revert Errors.ZeroAmount();
        
        PoolKey memory key = _poolKeys[poolId];
        uint128 totalSharesInternal = poolTotalShares[poolId];
        
        // Get current pool state
        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId);
        
        // Calculate shares based on the ratio of provided amounts to current reserves
        uint256 shares0 = reserve0 > 0 ? FullMath.mulDivRoundingUp(polAmount0, totalSharesInternal, reserve0) : 0;
        uint256 shares1 = reserve1 > 0 ? FullMath.mulDivRoundingUp(polAmount1, totalSharesInternal, reserve1) : 0;
        
        // Use the smaller share amount to maintain ratio
        shares = shares0 < shares1 ? shares0 : shares1;
        if (shares == 0) revert Errors.ZeroAmount();
        
        // Prepare callback data
        CallbackData memory callbackData = CallbackData({
            poolId: poolId,
            callbackType: ACTION_REINVEST_PROTOCOL_FEES,
            shares: shares.toUint128(),
            oldTotalShares: totalSharesInternal,
            amount0: polAmount0,
            amount1: polAmount1,
            recipient: address(this)
        });
        
        // Unlock calls modifyLiquidity via hook and transfers tokens
        manager.unlock(abi.encode(callbackData));
        
        emit ProtocolFeesReinvested(poolId, address(this), polAmount0, polAmount1);
        
        return shares;
    }

    /**
     * @notice Get the value of shares in terms of underlying tokens
     * @param poolId The pool ID
     * @param shares The number of shares
     */
    function getShareValue(PoolId poolId, uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        uint128 totalShares = poolTotalShares[poolId];
        if (totalShares == 0) return (0, 0);
        
        (uint256 reserve0, uint256 reserve1) = getPoolReserves(poolId);
        amount0 = (reserve0 * shares) / totalShares;
        amount1 = (reserve1 * shares) / totalShares;
    }

    /**
     * @notice Get user's shares for a specific pool
     * @param poolId The pool ID
     * @param user The user address
     */
    function getUserShares(PoolId poolId, address user) external view returns (uint256) {
        return positions.balanceOf(user, uint256(PoolId.unwrap(poolId)));
    }

    /**
     * @notice Update position cache
     * @param poolId The pool ID
     */
    function updatePositionCache(PoolId poolId) external returns (bool success) {
        // Implementation specific to your needs
        return false;
    }

    /**
     * @notice Update total shares for a pool
     * @param poolId The pool ID
     * @param newTotalShares The new total shares value
     */
    function updateTotalShares(PoolId poolId, uint128 newTotalShares) external {
        // Implementation specific to your needs
        revert("Not implemented");
    }
} 