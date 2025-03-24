// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {MathUtils} from "./libraries/MathUtils.sol";
import {Errors} from "./errors/Errors.sol";
import {FullRangePositions} from "./token/FullRangePositions.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CurrencySettler} from "./libraries/CurrencySettler.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PoolTokenIdUtils} from "./utils/PoolTokenIdUtils.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {IFullRangeLiquidityManager} from "./interfaces/IFullRangeLiquidityManager.sol";

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
    
    // Consolidated pool information struct
    struct PoolInfo {
        uint128 totalShares;  // Total pool shares
        uint256 reserve0;     // Token0 reserves
        uint256 reserve1;     // Token1 reserves
    }
    
    /// @dev The Uniswap V4 PoolManager reference
    IPoolManager public immutable manager;
    
    /// @dev ERC6909Claims token for position tokenization
    FullRangePositions public immutable positions;
    
    /// @dev Stored pool data
    mapping(PoolId => PoolInfo) public pools;
    
    /// @dev Pool keys for lookups
    mapping(PoolId => PoolKey) public poolKeys;
    
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
     * @notice Registers a pool that was initialized through hook callbacks
     * @param poolId The ID of the pool
     * @param key The pool key
     * @param sqrtPriceX96 The initial square root price
     */
    function registerPool(PoolId poolId, PoolKey calldata key, uint160 sqrtPriceX96) external onlyFullRange {
        // Check if pool already registered
        if (poolKeys[poolId].tickSpacing != 0) {
            return; // Silently return if already registered
        }
        
        // Store the pool key for later reference
        poolKeys[poolId] = key;
        
        // Initialize pool info with zero values
        pools[poolId] = PoolInfo({
            totalShares: 0,
            reserve0: 0,
            reserve1: 0
        });
        
        emit PoolInitialized(poolId, key, sqrtPriceX96, key.fee);
    }
    
    /**
     * @notice Get the PoolKey for a given PoolId
     * @param poolId The Pool ID to look up
     * @return key The PoolKey associated with this Pool ID
     */
    function getPoolKey(PoolId poolId) external view returns (PoolKey memory key) {
        key = poolKeys[poolId];
        if (key.tickSpacing == 0) revert Errors.PoolNotInitialized(poolId);
        return key;
    }
    
    /**
     * @notice Get the tickSpacing for a given PoolId
     * @param poolId The Pool ID to look up
     * @return The tickSpacing associated with this Pool ID
     */
    function getPoolTickSpacing(PoolId poolId) external view returns (int24) {
        return poolKeys[poolId].tickSpacing;
    }
    
    /**
     * @notice Get pool information
     * @param poolId The pool ID
     * @return info The pool info struct
     */
    function poolInfo(PoolId poolId) external view returns (PoolInfo memory info) {
        return pools[poolId];
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
     * @notice Deposit liquidity for full-range position with position token minting
     * @param params Deposit parameters
     * @param user The depositor
     * @return delta Actual balance delta from the liquidity addition
     * @return sharesMinted Shares minted for this deposit
     */
    function deposit(IFullRangeLiquidityManager.DepositParams calldata params, address user)
        external
        nonReentrant
        returns (BalanceDelta delta, uint256 sharesMinted)
    {
        // Validate the deadline
        if (block.timestamp > params.deadline) {
            revert Errors.DeadlinePassed(params.deadline, block.timestamp);
        }
        
        // Ensure valid deposit amounts
        if (params.amount0Desired == 0 && params.amount1Desired == 0) {
            revert Errors.ZeroAmount();
        }
        
        // Get the pool and validate it exists
        PoolId poolId = params.poolId;
        PoolInfo storage pool = pools[poolId];
        if (poolKeys[poolId].tickSpacing == 0) {
            revert Errors.PoolNotInitialized(poolId);
        }
        
        // Calculate deposit amounts and shares
        (uint256 actual0, uint256 actual1, uint256 newShares, uint256 lockedShares) = 
            _calculateDepositAmounts(
                pool.totalShares,
                params.amount0Desired,
                params.amount1Desired,
                pool.reserve0,
                pool.reserve1
            );
        
        // Validate the results
        if (newShares == 0) {
            revert Errors.ZeroShares(user);
        }
        
        if (actual0 < params.amount0Min || actual1 < params.amount1Min) {
            uint256 requiredMin = (actual0 < params.amount0Min) ? params.amount0Min : params.amount1Min;
            uint256 actualOut = (actual0 < params.amount0Min) ? actual0 : actual1;
            revert Errors.SlippageExceeded(requiredMin, actualOut);
        }
        
        // Get token addresses from pool key
        PoolKey memory key = poolKeys[poolId];
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        
        // Transfer tokens from user
        SafeTransferLib.safeTransferFrom(ERC20(token0), user, address(this), actual0);
        SafeTransferLib.safeTransferFrom(ERC20(token1), user, address(this), actual1);
        
        // Update reserves
        pool.reserve0 += actual0;
        pool.reserve1 += actual1;
        
        // Update total shares
        uint128 oldTotalShares = pool.totalShares;
        pool.totalShares = oldTotalShares + uint128(newShares + lockedShares);
        
        // If this is first deposit with locked shares, record it
        if (lockedShares > 0 && lockedLiquidity[poolId] == 0) {
            lockedLiquidity[poolId] = lockedShares;
            emit MinimumLiquidityLocked(poolId, lockedShares);
        }
        
        // Mint position tokens to user (only the non-locked shares)
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        positions.mint(user, tokenId, newShares);
        
        // Approve tokens to the PoolManager
        SafeTransferLib.safeApprove(ERC20(token0), address(manager), actual0);
        SafeTransferLib.safeApprove(ERC20(token1), address(manager), actual1);
        
        // Call modifyLiquidity on PoolManager
        IPoolManager.ModifyLiquidityParams memory modifyLiqParams = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.MIN_TICK,
            tickUpper: TickMath.MAX_TICK,
            liquidityDelta: int256(uint256(newShares + lockedShares)),
            salt: bytes32(0)
        });
        
        (delta, ) = manager.modifyLiquidity(key, modifyLiqParams, new bytes(0));
        
        // Handle delta
        _handleDelta(delta, token0, token1);
        
        // Emit deposit event
        emit LiquidityAdded(
            poolId,
            user,
            actual0,
            actual1,
            oldTotalShares,
            uint128(newShares),
            block.timestamp
        );
        
        emit TotalLiquidityUpdated(poolId, oldTotalShares, pool.totalShares);
        
        return (delta, newShares);
    }
    
    /**
     * @notice Withdraw liquidity from a full-range position by burning position tokens
     * @param params Withdrawal parameters
     * @param user The user withdrawing liquidity
     * @return delta The balance delta from the liquidity removal
     * @return amount0Out Token0 amount withdrawn
     * @return amount1Out Token1 amount withdrawn
     */
    function withdraw(IFullRangeLiquidityManager.WithdrawParams calldata params, address user)
        external
        nonReentrant
        returns (BalanceDelta delta, uint256 amount0Out, uint256 amount1Out)
    {
        // Validate the deadline
        if (block.timestamp > params.deadline) {
            revert Errors.DeadlinePassed(params.deadline, block.timestamp);
        }
        
        // Get the pool and validate it exists
        PoolId poolId = params.poolId;
        PoolInfo storage pool = pools[poolId];
        if (poolKeys[poolId].tickSpacing == 0) {
            revert Errors.PoolNotInitialized(poolId);
        }
        
        // Get the user's share balance
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        uint256 userShareBalance = positions.balanceOf(user, tokenId);
        
        // Validate shares to withdraw
        uint256 sharesToBurn = params.shares;
        if (sharesToBurn == 0) {
            revert Errors.ZeroAmount();
        }
        if (sharesToBurn > userShareBalance) {
            revert Errors.InsufficientShares(sharesToBurn, userShareBalance);
        }
        
        // Calculate amounts to withdraw
        (amount0Out, amount1Out) = _calculateWithdrawAmounts(
            pool.totalShares,
            sharesToBurn,
            pool.reserve0,
            pool.reserve1
        );
        
        // Check slippage
        if (amount0Out < params.amount0Min || amount1Out < params.amount1Min) {
            uint256 requiredMin = (amount0Out < params.amount0Min) ? params.amount0Min : params.amount1Min;
            uint256 actualOut = (amount0Out < params.amount0Min) ? amount0Out : amount1Out;
            revert Errors.SlippageExceeded(requiredMin, actualOut);
        }
        
        // Get token addresses from pool key
        PoolKey memory key = poolKeys[poolId];
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
        
        (delta, ) = manager.modifyLiquidity(key, modifyLiqParams, new bytes(0));
        
        // Handle delta
        _handleDelta(delta, token0, token1);
        
        // Transfer tokens to user
        if (amount0Out > 0) {
            _safeTransferToken(token0, user, amount0Out);
        }
        
        if (amount1Out > 0) {
            _safeTransferToken(token1, user, amount1Out);
        }
        
        // Emit withdraw event
        emit LiquidityRemoved(
            poolId,
            user,
            amount0Out,
            amount1Out,
            oldTotalShares,
            uint128(sharesToBurn),
            block.timestamp
        );
        
        emit TotalLiquidityUpdated(poolId, oldTotalShares, pool.totalShares);
        
        return (delta, amount0Out, amount1Out);
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
        
        // Execute withdrawal with standard function but no slippage check
        IFullRangeLiquidityManager.WithdrawParams memory adjustedParams = IFullRangeLiquidityManager.WithdrawParams({
            poolId: params.poolId,
            shares: params.shares,
            amount0Min: 0, // No slippage check in emergency
            amount1Min: 0, // No slippage check in emergency
            deadline: params.deadline
        });
        
        (delta, amount0Out, amount1Out) = this.withdraw(adjustedParams, user);
        
        // Emit emergency-specific event
        emit EmergencyWithdrawalCompleted(
            params.poolId,
            user,
            amount0Out,
            amount1Out,
            params.shares
        );
        
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
     */
    function claimETH() external {
        uint256 amount = pendingETHPayments[msg.sender];
        if (amount == 0) revert Errors.ZeroAmount();
        
        pendingETHPayments[msg.sender] = 0;
        
        bool success = _safeTransferETH(msg.sender, amount);
        if (!success) {
            pendingETHPayments[msg.sender] = amount;
            revert Errors.EthTransferFailed(msg.sender, amount);
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
            uint256 share0 = (amount0Desired * totalSharesAmount) / reserve0;
            uint256 share1 = (amount1Desired * totalSharesAmount) / reserve1;
            
            if (share0 <= share1) {
                // Token0 is the limiting factor
                newShares = share0;
                actual0 = amount0Desired;
                actual1 = (actual0 * reserve1) / reserve0;
            } else {
                // Token1 is the limiting factor
                newShares = share1;
                actual1 = amount1Desired;
                actual0 = (actual1 * reserve0) / reserve1;
            }
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
        // Handle token0 transfer
        int128 amount0 = delta.amount0();
        if (amount0 < 0) {
            uint256 amount = uint256(int256(-amount0));
            SafeTransferLib.safeApprove(ERC20(token0), address(manager), amount);
            // Settle token0 balance with the pool
            manager.settle();
        } else if (amount0 > 0) {
            // Need to receive tokens from the pool
            manager.take(Currency.wrap(token0), address(this), uint256(int256(amount0)));
        }
        
        // Handle token1 transfer
        int128 amount1 = delta.amount1();
        if (amount1 < 0) {
            uint256 amount = uint256(int256(-amount1));
            SafeTransferLib.safeApprove(ERC20(token1), address(manager), amount);
            // Settle token1 balance with the pool
            manager.settle();
        } else if (amount1 > 0) {
            // Need to receive tokens from the pool
            manager.take(Currency.wrap(token1), address(this), uint256(int256(amount1)));
        }
    }
    
    /**
     * @notice Transfer token to recipient, handling ETH and ERC20 correctly
     * @param token The token address (address(0) for ETH)
     * @param to The recipient address
     * @param amount The amount to transfer
     */
    function _safeTransferToken(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            // Handle ETH
            bool success = _safeTransferETH(to, amount);
            if (!success) {
                // If transfer fails, store as pending payment
                pendingETHPayments[to] += amount;
                emit ETHTransferFailed(to, amount);
            }
        } else {
            // Handle ERC20
            SafeTransferLib.safeTransfer(ERC20(token), to, amount);
        }
    }
    
    /**
     * @notice Transfer ETH to recipient with retry mechanism
     * @param to The recipient address
     * @param amount The amount of ETH to transfer
     * @return success Whether the transfer was successful
     */
    function _safeTransferETH(address to, uint256 amount) internal returns (bool success) {
        if (to == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) return true;
        
        // Try to transfer ETH with specified gas limit
        uint8 retries = 0;
        while (retries <= maxETHRetries) {
            (success, ) = to.call{value: amount, gas: ethTransferGasLimit}("");
            if (success) return true;
            retries++;
        }
        
        return false;
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
     * @notice Atomic operation for processing withdrawal share accounting
     * @dev Combines share burning and total share update in one call for atomicity
     * @param poolId The pool ID
     * @param user The user address
     * @param sharesToBurn Shares to burn
     * @param currentTotalShares Current total shares (for validation)
     * @return newTotalShares The new total shares amount
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
        
        // Burn shares
        positions.burn(user, tokenId, sharesToBurn);
        
        // Update total shares
        newTotalShares = currentTotalShares - uint128(sharesToBurn);
        pool.totalShares = newTotalShares;
        
        // Emit events
        emit UserSharesRemoved(poolId, user, sharesToBurn);
        emit PoolTotalSharesUpdated(poolId, currentTotalShares, newTotalShares);
        
        return newTotalShares;
    }
    
    /**
     * @notice Atomic operation for processing deposit share accounting
     * @dev Combines share minting and total share update in one call for atomicity
     * @param poolId The pool ID
     * @param user The user address
     * @param sharesToMint Shares to mint
     * @param currentTotalShares Current total shares (for validation)
     * @return newTotalShares The new total shares amount
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
        
        // Mint shares
        uint256 tokenId = PoolTokenIdUtils.toTokenId(poolId);
        positions.mint(user, tokenId, sharesToMint);
        
        // Update total shares
        newTotalShares = currentTotalShares + uint128(sharesToMint);
        pool.totalShares = newTotalShares;
        
        // Emit events
        emit UserSharesAdded(poolId, user, sharesToMint);
        emit PoolTotalSharesUpdated(poolId, currentTotalShares, newTotalShares);
        
        return newTotalShares;
    }

    /**
     * @notice Checks if a pool exists
     * @param poolId The pool ID to check
     * @return True if the pool exists
     */
    function poolExists(PoolId poolId) external view returns (bool) {
        return poolKeys[poolId].tickSpacing != 0;
    }
} 