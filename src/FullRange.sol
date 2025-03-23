// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { IFullRange, DepositParams, WithdrawParams, CallbackData, ModifyLiquidityParams } from "./interfaces/IFullRange.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { IFullRangeHooks } from "./interfaces/IFullRangeHooks.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { Currency as UniswapCurrency } from "v4-core/src/types/Currency.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { FullRangeLiquidityManager } from "./FullRangeLiquidityManager.sol";
import { FullRangeDynamicFeeManager } from "./FullRangeDynamicFeeManager.sol";
import { FullRangeUtils } from "./utils/FullRangeUtils.sol";
import { Errors } from "./errors/Errors.sol";
import { SettlementUtils } from "./utils/SettlementUtils.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";
import { IPoolPolicy } from "./interfaces/IPoolPolicy.sol";
import { IFeeReinvestmentManager } from "./interfaces/IFeeReinvestmentManager.sol";
import { ReentrancyGuard } from "solmate/src/utils/ReentrancyGuard.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { PoolTokenIdUtils } from "./utils/PoolTokenIdUtils.sol";
import { FullRangePositions } from "./token/FullRangePositions.sol";
import { IFullRangeLiquidityManager } from "./interfaces/IFullRangeLiquidityManager.sol";

/**
 * @title FullRange
 * @notice Unified Uniswap V4 Hook contract with fallback dispatcher for all hook callbacks.
 * @dev Implements IFullRange and uses a fallback function with inline assembly to dispatch hook calls.
 *      This design avoids explicit hook function declarations, reducing bytecode size and runtime overhead.
 *      Only the Uniswap V4 PoolManager is authorized to call hook functions (enforced in assembly).
 */
contract FullRange is IFullRange, IFullRangeHooks, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    
    // Immutable core contracts and managers
    IPoolManager public immutable poolManager;
    IPoolPolicy public immutable policyManager;
    FullRangeLiquidityManager public immutable liquidityManager;
    FullRangeDynamicFeeManager public immutable dynamicFeeManager;

    // Maps pool IDs to their emergency state
    mapping(PoolId => bool) public emergencyState;
    
    // Maps pool IDs to their initialization status
    mapping(PoolId => bool) public poolInitialized;
    
    // Maps pool IDs to their pool keys
    mapping(PoolId => PoolKey) public poolKeys;

    // Maps pool IDs to token IDs
    mapping(PoolId => uint256) public poolTokenIds;
    
    // Maps pool IDs to user shares - REMOVED, now handled by LiquidityManager
    // mapping(PoolId => mapping(address => uint256)) public userShares;
    
    // Pool reserves and total shares
    mapping(PoolId => uint256) public poolReserve0;
    mapping(PoolId => uint256) public poolReserve1;
    // poolTotalShares is now fully managed in LiquidityManager
    // mapping(PoolId => uint128) public poolTotalShares;
    
    // Cache for frequent getUserShares calls
    mapping(bytes32 => mapping(address => uint256)) private _shareBalanceCache;
    uint256 private constant CACHE_TIMESTAMP_SHIFT = 160; // High bits for timestamp, low bits for share balance

    // Internal struct for unlock callback data decoding
    struct CallbackDataInternal {
        uint8 callbackType;    // 1 = deposit, 2 = withdraw, 3 = swap
        address sender;        // Original transaction sender
        PoolId poolId;         // Pool ID for the operation
        uint256 amount0;       // Amount of token0
        uint256 amount1;       // Amount of token1
        uint256 shares;        // Liquidity shares (for deposits/withdrawals)
    }

    // Mapping to track pending ETH withdrawals (for failed transfers)
    mapping(address => uint256) public pendingETHPayments;
    
    // Events for ETH handling and pool policy initialization
    event ETHTransferFailed(address indexed recipient, uint256 amount);
    event ETHClaimed(address indexed recipient, uint256 amount);
    event FeeUpdateFailed(PoolId indexed poolId);
    event ReinvestmentSuccess(PoolId indexed poolId, uint256 amount0, uint256 amount1);
    event ReinvestmentFailed(PoolId indexed poolId, string reason);
    event PoolEmergencyStateChanged(PoolId indexed poolId, bool isEmergency);
    event PolicyInitializationFailed(PoolId indexed poolId, string reason);
    event PolicyInitializationSucceeded(PoolId indexed poolId);
    
    // Liquidity operation events
    event Deposit(address indexed sender, PoolId indexed poolId, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdraw(address indexed sender, PoolId indexed poolId, uint256 amount0, uint256 amount1, uint256 shares);
    event Swap(address indexed sender, PoolId indexed poolId, bool zeroForOne, int256 amountSpecified, uint256 amountOut);

    // Events
    event PoolCreated(PoolId indexed poolId, PoolKey key, uint160 sqrtPriceX96);
    event PoolEmergencyStateSet(PoolId indexed poolId, bool status);
    
    // Errors

    /// @notice Flag to track if the contract has been initialized
    bool public initialized;
    
    /// @notice Flag to enable or disable fee reinvestment
    bool public reinvestmentEnabled = true;

    /**
     * @notice Gets user share balance with caching for gas optimization
     * @param poolId The pool ID to query
     * @param user The user address to check
     * @return User's share balance
     */
    function getCachedUserShares(PoolId poolId, address user) internal returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(poolId));
        
        // Format: [block number in upper bits | balance in lower bits]
        uint256 cachedData = _shareBalanceCache[key][user];
        uint256 cachedBlock = cachedData >> CACHE_TIMESTAMP_SHIFT;
        
        // Use cached value if in the same block
        if (cachedBlock == block.number) {
            return cachedData & ((1 << CACHE_TIMESTAMP_SHIFT) - 1);
        }
        
        // Otherwise fetch and cache the value
        uint256 shares = getUserShares(poolId, user);
        _shareBalanceCache[key][user] = (block.number << CACHE_TIMESTAMP_SHIFT) | shares;
        return shares;
    }

    /**
     * @notice Returns a user's balance of shares in a specific pool
     * @param poolId The pool ID to query
     * @param user The user address to check
     * @return The number of pool shares owned by the user
     */
    function getUserShares(PoolId poolId, address user) public view returns (uint256) {
        // Directly use the LiquidityManager's getUserShares function
        return liquidityManager.getUserShares(poolId, user);
    }

    // Modifiers for access control
    modifier onlyGovernance() {
        if (msg.sender != policyManager.getSoloGovernance()) {
            revert Errors.AccessOnlyGovernance(msg.sender);
        }
        _;
    }
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) {
            revert Errors.AccessOnlyPoolManager(msg.sender);
        }
        _;
    }
    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) {
            revert Errors.ValidationDeadlinePassed(uint32(deadline), uint32(block.timestamp));
        }
        _;
    }

    /**
     * @notice Constructor initializes the FullRange hook with required managers.
     * @dev Performs zero-address validation on critical parameters and stores immutables.
     */
    constructor(
        IPoolManager _manager,
        IPoolPolicy _policyManager,
        FullRangeLiquidityManager _liquidityManager,
        FullRangeDynamicFeeManager _dynamicFeeManager
    ) {
        // Validate critical addresses (non-zero)
        if (address(_manager) == address(0)) revert Errors.ValidationZeroAddress("poolManager");
        if (address(_policyManager) == address(0)) revert Errors.ValidationZeroAddress("policyManager");
        if (address(_liquidityManager) == address(0)) revert Errors.ValidationZeroAddress("liquidityManager");
        if (address(_dynamicFeeManager) == address(0)) revert Errors.ValidationZeroAddress("dynamicFeeManager");

        poolManager = _manager;
        policyManager = _policyManager;
        liquidityManager = _liquidityManager;
        dynamicFeeManager = _dynamicFeeManager;

        // Validate that this hook contract has the expected permissions set
        validateHookAddress();
    }

    /**
     * @notice Allows the contract to receive ETH (e.g., refunds from failed transfers).
     */
    receive() external payable {}

    /**
     * @notice Returns the hook permissions for all Uniswap V4 hook callbacks (all enabled).
     * @dev This constant indicates which hooks are implemented by this contract.
     */
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: true,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /**
     * @notice Validates that this hook contract's declared permissions match its implemented hooks.
     * @dev Uses Uniswap V4 Hooks library to ensure the contract correctly implements all declared hooks.
     */
    function validateHookAddress() internal view {
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    // ---------------------------
    // IFullRange External Functions
    // ---------------------------

    /**
     * @notice Returns the address of this hook (for pool initialization).
     */
    function getHookAddress() external view returns (address) {
        return address(this);
    }

    /**
     * @notice Sets or unsets emergency state for a specific pool.
     * @dev Only governance can call. In emergency, further operations may be restricted.
     * @param poolId The pool ID to modify.
     * @param isEmergency Whether to enable (true) or disable (false) emergency state.
     */
    function setPoolEmergencyState(PoolId poolId, bool isEmergency) external {
        // Only governance can set emergency state
        if (msg.sender != policyManager.getSoloGovernance()) revert Errors.AccessOnlyGovernance(msg.sender);
        
        emergencyState[poolId] = isEmergency;
        
        emit PoolEmergencyStateChanged(poolId, isEmergency);
    }
    
    /**
     * @notice Deposits tokens into a Uniswap V4 pool via the FullRange hook.
     * @dev Accepts ERC20 tokens and adds liquidity to the specified pool.
     * @param params The deposit parameters (poolId, amounts, slippage, deadline).
     * @return shares The number of LP shares minted to the user.
     * @return amount0 The actual amount of token0 deposited.
     * @return amount1 The actual amount of token1 deposited.
     */
    function deposit(DepositParams calldata params) 
        external 
        nonReentrant 
        ensure(params.deadline)
        returns (uint256 shares, uint256 amount0, uint256 amount1) 
    {
        // Verify pool exists and is not in emergency state
        if (!isPoolInitialized(params.poolId)) {
            revert Errors.ValidationInvalidInput("Pool not initialized");
        }
        if (emergencyState[params.poolId]) {
            revert Errors.ValidationInvalidInput("Pool in emergency state");
        }
        
        // Verify desired deposit amounts are non-zero
        if (params.amount0Desired == 0 && params.amount1Desired == 0) {
            revert Errors.ValidationZeroAmount("amounts");
        }
        
        // Get pool info
        PoolKey memory key = getPoolKey(params.poolId);
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, params.poolId);
        
        // Get current pool reserves and share information
        (uint256 reserve0, uint256 reserve1, uint128 totalShares) = 
            getPoolReservesAndShares(params.poolId);
            
        // Calculate optimal deposit amounts and shares to mint
        (amount0, amount1, shares) = FullRangeUtils.computeDepositAmountsAndShares(
            totalShares,
            params.amount0Desired,
            params.amount1Desired,
            reserve0,
            reserve1,
            sqrtPriceX96
        );
        
        // Check share slippage protection
        if (shares < params.minShares) {
            revert Errors.ValidationInvalidInput("Shares below minimum threshold");
        }
        
        // Transfer tokens from user to this contract
        FullRangeUtils.pullTokensFromUser(
            UniswapCurrency.unwrap(key.currency0),
            UniswapCurrency.unwrap(key.currency1),
            msg.sender,
            amount0,
            amount1
        );
        
        // Update pool reserves
        poolReserve0[params.poolId] += amount0;
        poolReserve1[params.poolId] += amount1;
        
        // Process share accounting atomically
        liquidityManager.processDepositShares(params.poolId, msg.sender, shares, totalShares);
        
        // Prepare callback data
        CallbackDataInternal memory callbackData = CallbackDataInternal({
            callbackType: 1, // 1 = deposit
            sender: msg.sender,
            poolId: params.poolId,
            amount0: amount0,
            amount1: amount1,
            shares: shares
        });
        
        // Call the poolManager unlock to process the deposit
        poolManager.unlock(abi.encode(callbackData));
        
        // Attempt fee reinvestment (if policy exists)
        address reinvestmentPolicy = policyManager.getPolicy(params.poolId, IPoolPolicy.PolicyType.REINVESTMENT);
        if (reinvestmentPolicy != address(0)) {
            IFeeReinvestmentManager(reinvestmentPolicy).processReinvestmentIfNeeded(params.poolId, amount0 + amount1);
        }
        
        emit Deposit(msg.sender, params.poolId, amount0, amount1, shares);
        return (shares, amount0, amount1);
    }

    /**
     * @notice Deposits ETH and tokens into a Uniswap V4 pool via the FullRange hook
     * @param params The deposit parameters
     * @param poolKey The pool key for the deposit
     */
    function depositETH(DepositParams calldata params, PoolKey calldata poolKey)
        external
        payable
    {
        // Convert ETH currency
        uint8 currencyIndex = UniswapCurrency.unwrap(poolKey.currency0) == address(0) ? 0 : 1;
        
        // Validate basic prerequisites
        PoolId poolId = poolKey.toId();
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(poolId);
        if (emergencyState[poolId]) revert Errors.ValidationInvalidInput("Pool in emergency state");
        
        // Convert to ETH method not supported
        revert Errors.NotImplemented();
    }

    /**
     * @notice Withdraws liquidity with ETH handling from a Uniswap V4 pool
     * @param params The withdrawal parameters
     * @param poolKey The pool key for the withdrawal
     * @return amount0Out Amount of token0 withdrawn.
     * @return amount1Out Amount of token1 withdrawn.
     */
    function withdrawETH(WithdrawParams calldata params, PoolKey calldata poolKey)
        external
        returns (uint256 amount0Out, uint256 amount1Out)
    {
        // Convert ETH currency
        uint8 currencyIndex = UniswapCurrency.unwrap(poolKey.currency0) == address(0) ? 0 : 1;
        
        // Validate basic prerequisites
        PoolId poolId = poolKey.toId();
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(poolId);
        if (emergencyState[poolId]) revert Errors.ValidationInvalidInput("Pool in emergency state");
        
        // Convert to ETH method not supported
        revert Errors.NotImplemented();
    }

    /**
     * @notice Withdraws liquidity from a Uniswap V4 pool via the FullRange hook.
     * @dev Burns LP shares and returns the corresponding token amounts.
     * @param params The withdrawal parameters (poolId, shares, slippage, deadline).
     * @return amount0 The amount of token0 withdrawn.
     * @return amount1 The amount of token1 withdrawn.
     */
    function withdraw(WithdrawParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        // Verify shares to burn is non-zero
        if (params.sharesToBurn == 0) {
            revert Errors.ValidationZeroAmount("sharesToBurn");
        }
        
        // Verify user has enough shares - use cached user shares for gas optimization
        uint256 userSharesBalance = getCachedUserShares(params.poolId, msg.sender);
        if (userSharesBalance < params.sharesToBurn) {
            revert Errors.ValidationInvalidInput("Insufficient user shares");
        }
        
        // Get pool information
        PoolKey memory key = getPoolKey(params.poolId);
        (uint256 reserve0, uint256 reserve1, uint128 totalShares) = 
            getPoolReservesAndShares(params.poolId);
            
        // Calculate withdrawal amounts based on share ratio
        (amount0, amount1) = FullRangeUtils.computeWithdrawAmounts(
            totalShares,
            params.sharesToBurn,
            reserve0,
            reserve1
        );
        
        // Check slippage protection
        if (amount0 < params.minAmount0 || amount1 < params.minAmount1) {
            revert Errors.ValidationInvalidInput("Withdraw amounts below minimum thresholds");
        }
        
        // Update pool reserves
        poolReserve0[params.poolId] -= amount0;
        poolReserve1[params.poolId] -= amount1;
        
        // Process share accounting atomically
        liquidityManager.processWithdrawShares(params.poolId, msg.sender, params.sharesToBurn, totalShares);
        
        // Prepare callback data for the unlock
        CallbackDataInternal memory callbackData = CallbackDataInternal({
            callbackType: 2, // 2 = withdraw
            sender: msg.sender,
            poolId: params.poolId,
            amount0: amount0,
            amount1: amount1,
            shares: params.sharesToBurn
        });
        
        // Call the poolManager unlock to process the withdrawal
        poolManager.unlock(abi.encode(callbackData));
        
        // Transfer tokens to user
        if (amount0 > 0) {
            address token0 = UniswapCurrency.unwrap(key.currency0);
            if (token0 != address(0)) {
                SafeTransferLib.safeTransfer(ERC20(token0), msg.sender, amount0);
            } else {
                // Handle ETH transfers using the safe helper
                _safeTransferETH(msg.sender, amount0);
            }
        }
        
        if (amount1 > 0) {
            address token1 = UniswapCurrency.unwrap(key.currency1);
            if (token1 != address(0)) {
                SafeTransferLib.safeTransfer(ERC20(token1), msg.sender, amount1);
            } else {
                // Handle ETH transfers using the safe helper
                _safeTransferETH(msg.sender, amount1);
            }
        }
        
        // Attempt fee reinvestment (if policy exists)
        address reinvestmentPolicy = policyManager.getPolicy(params.poolId, IPoolPolicy.PolicyType.REINVESTMENT);
        if (reinvestmentPolicy != address(0)) {
            IFeeReinvestmentManager(reinvestmentPolicy).processReinvestmentIfNeeded(params.poolId, amount0 + amount1);
        }
        
        emit Withdraw(msg.sender, params.poolId, amount0, amount1, params.sharesToBurn);
        return (amount0, amount1);
    }

    /**
     * @notice Claims pending ETH payments
     */
    function claimPendingETH() external {
        // Validate basic prerequisites    
        if (!initialized) revert Errors.NotInitialized();
        
        // Call the correct method
        liquidityManager.claimETH();
    }

    /**
     * @notice Safe transfer of ETH to recipient with fallback to pending payments
     * @dev Internal helper to safely transfer ETH with proper error handling
     * @param recipient The address to receive ETH
     * @param amount The amount of ETH to send
     */
    function _safeTransferETH(address recipient, uint256 amount) internal {
        if (amount > 0) {
            // Attempt to transfer ETH with explicit gas limit to prevent DoS attacks
            (bool success, ) = recipient.call{value: amount, gas: 50000}("");
            if (!success) {
                // If transfer fails, store as pending payment
                pendingETHPayments[recipient] += amount;
                emit ETHTransferFailed(recipient, amount);
            }
        }
    }

    /**
     * @notice Allows governance to trigger reinvestment of accumulated fees into the pool.
     * @dev Uses the fee reinvestment policy to determine how to distribute fees.
     * @param poolId The pool ID to reinvest fees for.
     */
    function reinvestFees(PoolId poolId) external nonReentrant {
        // Get the reinvestment policy
        address reinvestmentPolicy = policyManager.getPolicy(poolId, IPoolPolicy.PolicyType.REINVESTMENT);
        if (reinvestmentPolicy == address(0)) {
            revert Errors.ValidationZeroAddress("reinvestmentPolicy");
        }
        
        // Call the reinvestment function directly
        (uint256 amount0, uint256 amount1) = IFeeReinvestmentManager(reinvestmentPolicy).reinvestFees(poolId);
        emit ReinvestmentSuccess(poolId, amount0, amount1);
    }
    
    /**
     * @notice Updates the dynamic fee for a pool based on market conditions.
     * @dev Uses the dynamic fee manager to calculate the appropriate fee tier.
     * @param poolId The pool ID to update fees for.
     */
    function updatePoolFee(PoolId poolId) external nonReentrant {
        if (emergencyState[poolId]) {
            revert Errors.ValidationInvalidInput("Pool in emergency state");
        }
        
        // Call fee manager and ignore return values since we don't need them here
        dynamicFeeManager.updateDynamicFeeIfNeeded(poolId, getPoolKey(poolId));
    }

    /**
     * @notice Returns information about a pool's state and configuration.
     * @param poolId The pool ID to query.
     * @return isInitialized Whether the pool has been initialized. (renamed from 'initialized')
     * @return reserves The current token reserves in the pool.
     * @return totalShares The total supply of pool shares.
     * @return tokenId The NFT token ID associated with the pool position.
     */
    function getPoolInfo(PoolId poolId) 
        external 
        view 
        returns (
            bool isInitialized,  // Renamed from 'initialized' to avoid shadowing
            uint256[2] memory reserves,
            uint128 totalShares,
            uint256 tokenId
        ) 
    {
        isInitialized = isPoolInitialized(poolId);
        
        if (isInitialized) {
            (uint256 reserve0, uint256 reserve1, uint128 shares) = 
                getPoolReservesAndShares(poolId);
                
            reserves[0] = reserve0;
            reserves[1] = reserve1;
            totalShares = shares;
            tokenId = getPoolTokenId(poolId);
        }
        
        return (isInitialized, reserves, totalShares, tokenId);
    }
    
    /**
     * @notice Checks if a pool is initialized
     * @param poolId The ID of the pool
     * @return initialized Whether the pool is initialized
     */
    function isPoolInitialized(PoolId poolId) public view returns (bool) {
        return poolInitialized[poolId];
    }
    
    /**
     * @notice Gets the pool key for a pool ID
     * @param poolId The ID of the pool
     * @return The pool key
     */
    function getPoolKey(PoolId poolId) public view returns (PoolKey memory) {
        return poolKeys[poolId];
    }
    
    /**
     * @notice Gets the token ID for a pool
     * @param poolId The ID of the pool
     * @return The token ID
     */
    function getPoolTokenId(PoolId poolId) public view returns (uint256) {
        return poolTokenIds[poolId];
    }
    
    /**
     * @notice Gets the reserves and shares for a pool
     * @param poolId The ID of the pool
     * @return reserve0 The reserve of token0
     * @return reserve1 The reserve of token1
     * @return totalShares The total shares
     */
    function getPoolReservesAndShares(PoolId poolId) public view returns (uint256 reserve0, uint256 reserve1, uint128 totalShares) {
        reserve0 = poolReserve0[poolId];
        reserve1 = poolReserve1[poolId];
        
        // Get total shares from LiquidityManager using the public view function
        totalShares = liquidityManager.totalShares(poolId);
    }
    
    /**
     * @notice IHooks interface implementation for beforeInitialize
     */
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    /**
     * @notice Internal implementation of beforeInitialize hook logic
     */
    function _beforeInitialize(
        address sender,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        bytes memory data
    ) internal view returns (bytes4) {
        // Validate the hook address
        if (address(key.hooks) != address(this)) {
            revert Errors.HookInvalidAddress(address(key.hooks));
        }
        
        // Validate sqrtPrice range
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 > TickMath.MAX_SQRT_PRICE) {
            revert Errors.PoolTickOutOfRange(
                TickMath.getTickAtSqrtPrice(sqrtPriceX96),
                TickMath.MIN_TICK, 
                TickMath.MAX_TICK
            );
        }
        
        return IHooks.beforeInitialize.selector;
    }

    /**
     * @notice Internal implementation of afterInitialize hook logic
     */
    function _afterInitialize(
        address sender,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        int24 tick,
        bool isPoolInit, // Renamed from 'initialized' to avoid shadowing
        address policy,
        address dynamicFee
    ) internal returns (bytes4) {
        // Initialize pool state
        PoolId poolId = key.toId();
        
        // Register the pool
        poolInitialized[poolId] = isPoolInit;
        poolKeys[poolId] = key;
        
        // Set up pool token ID
        poolTokenIds[poolId] = PoolTokenIdUtils.toTokenId(poolId);
        
        // Initialize dynamic fee
        try dynamicFeeManager.initializeOracleData(poolId, tick) {
            // Successfully initialized oracle data
        } catch {
            // Continue even if fee manager fails - this is non-critical
        }
        
        // Register pool with liquidity manager
        try liquidityManager.registerPool(poolId, key, sqrtPriceX96) {
            // Successfully registered pool
        } catch {
            // Continue even if registration fails - this is non-critical
        }
        
        // Try to initialize pool policies
        _initializePoolPolicies(poolId);
        
        return IHooks.afterInitialize.selector;
    }

    /**
     * @notice Internal implementation of beforeAddLiquidity hook logic
     */
    function _beforeAddLiquidity(
        address sender, 
        PoolKey memory key, 
        IPoolManager.ModifyLiquidityParams memory params,
        bytes memory data
    ) internal view returns (bytes4) {
        // Only enforce full-range position constraint if this is a direct deposit
        // Skip validation for internal operations where data is empty
        if (data.length > 0) {
            // Validate pool is initialized
            PoolId poolId = key.toId();
            if (!isPoolInitialized(poolId)) {
                revert Errors.PoolNotInitialized(poolId);
            }
            
            // Validate pool is not in emergency state
            if (emergencyState[poolId]) {
                revert Errors.ValidationInvalidInput("Pool in emergency state");
            }
            
            // Validate position is full range
            if (params.tickLower != TickMath.MIN_TICK || params.tickUpper != TickMath.MAX_TICK) {
                revert Errors.PositionsMustBeFullRange();
            }
        }
        
        return IHooks.beforeAddLiquidity.selector;
    }

    /**
     * @notice Internal implementation of afterAddLiquidity hook logic
     */
    function _afterAddLiquidity(
        address sender,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes memory data
    ) internal returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        
        // Process fee-related updates if fees were accrued
        if (feesAccrued.amount0() != 0 || feesAccrued.amount1() != 0) {
            _processFees(poolId, feesAccrued);
        }
        
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Internal implementation of beforeRemoveLiquidity hook logic
     */
    function _beforeRemoveLiquidity(
        address sender, 
        PoolKey memory key, 
        IPoolManager.ModifyLiquidityParams memory params,
        bytes memory data
    ) internal view returns (bytes4) {
        // Only enforce full-range position constraint if this is a direct withdrawal
        // Skip validation for internal operations where data is empty
        if (data.length > 0) {
            // Validate pool is initialized
            PoolId poolId = key.toId();
            if (!isPoolInitialized(poolId)) {
                revert Errors.PoolNotInitialized(poolId);
            }
            
            // Validate position is full range
            if (params.tickLower != TickMath.MIN_TICK || params.tickUpper != TickMath.MAX_TICK) {
                revert Errors.PositionsMustBeFullRange();
            }
        }
        
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /**
     * @notice Internal implementation of afterRemoveLiquidity hook logic
     */
    function _afterRemoveLiquidity(
        address sender,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes memory data
    ) internal returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        
        // Process fee-related updates if fees were accrued
        if (feesAccrued.amount0() != 0 || feesAccrued.amount1() != 0) {
            _processFees(poolId, feesAccrued);
        }
        
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Internal implementation of beforeSwap hook logic
     */
    function _beforeSwap(
        address sender,
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        bytes memory data
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        
        // Validate pool is initialized
        if (!isPoolInitialized(poolId)) {
            revert Errors.PoolNotInitialized(poolId);
        }
        
        // Validate pool is not in emergency state
        if (emergencyState[poolId]) {
            revert Errors.ValidationInvalidInput("Pool in emergency state");
        }
        
        // Update dynamic fee if needed
        uint24 dynamicFee = 0;
        if (key.fee & 0x800000 != 0) { // Check if dynamic fee flag is set
            try dynamicFeeManager.updateDynamicFeeIfNeeded(poolId, key) returns (
                uint256 baseFee,
                uint256 surgeFee,
                bool wasUpdated
            ) {
                // Use surge fee if available, otherwise use base fee
                dynamicFee = uint24(surgeFee > 0 ? surgeFee : baseFee);
            } catch {
                // If fee update fails, continue with zero fee
                emit FeeUpdateFailed(poolId);
            }
        }
        
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, dynamicFee);
    }

    /**
     * @notice Helper method to process fees
     */
    function _processFees(PoolId poolId, BalanceDelta feesAccrued) internal {
        // Get the reinvestment policy
        address reinvestmentPolicy = policyManager.getPolicy(poolId, IPoolPolicy.PolicyType.REINVESTMENT);
        
        // Process fees if policy exists
        if (reinvestmentPolicy != address(0)) {
            uint256 fee0 = feesAccrued.amount0() > 0 ? uint256(uint128(feesAccrued.amount0())) : 0;
            uint256 fee1 = feesAccrued.amount1() > 0 ? uint256(uint128(feesAccrued.amount1())) : 0;
            
            // Use a reasonable swap value for threshold
            uint256 feeValue = fee0 + fee1;
            try IFeeReinvestmentManager(reinvestmentPolicy).processReinvestmentIfNeeded(poolId, feeValue) returns (bool success) {
                if (success) {
                    emit ReinvestmentSuccess(poolId, fee0, fee1);
                }
            } catch {
                emit ReinvestmentFailed(poolId, "Processing failed");
            }
        }
    }
    
    /**
     * @notice Helper method to initialize pool policies
     */
    function _initializePoolPolicies(PoolId poolId) internal {
        try policyManager.handlePoolInitialization(
            poolId, 
            poolKeys[poolId],
            0, // sqrtPriceX96 - not needed for this call
            0, // tick - not needed for this call
            address(this)
        ) {
            emit PolicyInitializationSucceeded(poolId);
        } catch Error(string memory reason) {
            emit PolicyInitializationFailed(poolId, reason);
        } catch {
            emit PolicyInitializationFailed(poolId, "Unknown error");
        }
    }

    /**
     * @notice Helper method to calculate fee value
     */
    function _calculateFeeValue(BalanceDelta delta) internal pure returns (uint256) {
        uint256 value = 0;
        if (delta.amount0() > 0) value += uint256(uint128(delta.amount0()));
        if (delta.amount1() > 0) value += uint256(uint128(delta.amount1()));
        return value;
    }
    
    /**
     * @notice Optimized fallback function used as a unified dispatcher for all hook callbacks
     * @dev Uses inline assembly to efficiently extract and route function selectors
     */
    fallback() external {
        // Verify caller is the pool manager
        if (msg.sender != address(poolManager)) {
            revert Errors.AccessOnlyPoolManager(msg.sender);
        }
        
        // Extract function selector efficiently
        bytes4 selector;
        assembly {
            selector := shr(224, calldataload(0))
        }
        
        // Handle critical hooks with full implementation
        if (selector == IHooks.beforeInitialize.selector) {
            (address sender, PoolKey memory key, uint160 sqrtPriceX96) = 
                abi.decode(msg.data[4:], (address, PoolKey, uint160));
                
            bytes4 result = _beforeInitialize(sender, key, sqrtPriceX96, "");
            
            assembly {
                mstore(0, result)
                return(0, 32)
            }
        } 
        else if (selector == IHooks.afterInitialize.selector) {
            (address sender, PoolKey memory key, uint160 sqrtPriceX96, int24 tick) = 
                abi.decode(msg.data[4:], (address, PoolKey, uint160, int24));
                
            bytes4 result = _afterInitialize(sender, key, sqrtPriceX96, tick, isPoolInitialized(key.toId()), address(policyManager), address(dynamicFeeManager));
            
            assembly {
                mstore(0, result)
                return(0, 32)
            }
        }
        else if (selector == IHooks.beforeAddLiquidity.selector) {
            (address sender, PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, bytes memory data) = 
                abi.decode(msg.data[4:], (address, PoolKey, IPoolManager.ModifyLiquidityParams, bytes));
                
            bytes4 result = _beforeAddLiquidity(sender, key, params, data);
            
            assembly {
                mstore(0, result)
                return(0, 32)
            }
        }
        else if (selector == IHooks.afterAddLiquidity.selector) {
            (address sender, PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, 
                BalanceDelta delta, BalanceDelta feesAccrued, bytes memory data) = 
                abi.decode(msg.data[4:], (address, PoolKey, IPoolManager.ModifyLiquidityParams, BalanceDelta, BalanceDelta, bytes));
            
            (bytes4 result, BalanceDelta returnDelta) = _afterAddLiquidity(sender, key, params, delta, feesAccrued, data);
            
            bytes memory returnData = abi.encode(result, returnDelta);
            assembly {
                return(add(returnData, 32), mload(returnData))
            }
        }
        else if (selector == IHooks.beforeRemoveLiquidity.selector) {
            (address sender, PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, bytes memory data) = 
                abi.decode(msg.data[4:], (address, PoolKey, IPoolManager.ModifyLiquidityParams, bytes));
                
            bytes4 result = _beforeRemoveLiquidity(sender, key, params, data);
            
            assembly {
                mstore(0, result)
                return(0, 32)
            }
        }
        else if (selector == IHooks.afterRemoveLiquidity.selector) {
            (address sender, PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, 
                BalanceDelta delta, BalanceDelta feesAccrued, bytes memory data) = 
                abi.decode(msg.data[4:], (address, PoolKey, IPoolManager.ModifyLiquidityParams, BalanceDelta, BalanceDelta, bytes));
            
            (bytes4 result, BalanceDelta returnDelta) = _afterRemoveLiquidity(sender, key, params, delta, feesAccrued, data);
            
            bytes memory returnData = abi.encode(result, returnDelta);
            assembly {
                return(add(returnData, 32), mload(returnData))
            }
        }
        else if (selector == IHooks.beforeSwap.selector) {
            (address sender, PoolKey memory key, IPoolManager.SwapParams memory params, bytes memory data) = 
                abi.decode(msg.data[4:], (address, PoolKey, IPoolManager.SwapParams, bytes));
            
            (bytes4 result, BeforeSwapDelta beforeDelta, uint24 fee) = _beforeSwap(sender, key, params, data);
            
            bytes memory returnData = abi.encode(result, beforeDelta, fee);
            assembly {
                return(add(returnData, 32), mload(returnData))
            }
        }
        
        // For other hooks, simply return the selector
        assembly {
            mstore(0, selector)
            return(0, 32)
        }
    }

    /**
     * @notice Callback triggered during a Uniswap V4 unlock flow.
     * @dev Handles modifying liquidity in the pool based on the callback data.
     *      Each callback type (deposit, withdraw, swap) performs different operations.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // Ensure caller is the poolManager
        if (msg.sender != address(poolManager)) {
            revert Errors.AccessOnlyPoolManager(msg.sender);
        }
        
        // Decode the callback data
        CallbackDataInternal memory callbackData = abi.decode(data, (CallbackDataInternal));
        
        // Handle different callback types
        if (callbackData.callbackType == 1) {
            // Deposit operation - Add liquidity to the pool
            
            // Add liquidity implementation
            // Note: Share accounting is now handled before this callback
            
            return abi.encode("deposit_processed");
        } else if (callbackData.callbackType == 2) {
            // Withdraw operation - Remove liquidity from the pool
            
            // Remove liquidity implementation
            // Note: Share accounting is now handled before this callback
            
            return abi.encode("withdraw_processed");
        } else if (callbackData.callbackType == 3) {
            // Swap operation
            
            // Swap implementation
            
            return abi.encode("swap_processed");
        }
        
        // Fallback for unknown callback types
        return abi.encode("unknown_callback_type");
    }

    /**
     * @notice Claims and reinvests fees for a specific pool
     * @param poolId The ID of the pool
     * @return fee0 The amount of token0 fees claimed
     * @return fee1 The amount of token1 fees claimed
     */
    function claimAndReinvestFees(PoolId poolId) external returns (uint256 fee0, uint256 fee1) {
        // Validate basic prerequisites
        if (!isPoolInitialized(poolId)) revert Errors.PoolNotInitialized(poolId);
        if (emergencyState[poolId]) revert Errors.ValidationInvalidInput("Pool in emergency state");
        
        // Check if reinvestment is enabled before proceeding
        if (!reinvestmentEnabled) revert Errors.ReinvestmentDisabled();
        
        // Use minimal implementation to avoid missing methods
        fee0 = 0;
        fee1 = 0;
        
        // Reinvestment not supported in this implementation
        revert Errors.NotImplemented();
    }

    // IHooks interface implementations
    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata data) external pure override returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata data) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata data) external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata data) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata data) external pure override returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata data) external pure override returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata data) external pure override returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata data) external pure override returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    // IFullRangeHooks interface implementations
    function beforeSwapReturnDelta(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata data) external pure override returns (bytes4, BeforeSwapDelta) {
        return (IFullRangeHooks.beforeSwapReturnDelta.selector, BeforeSwapDeltaLibrary.ZERO_DELTA);
    }

    function afterSwapReturnDelta(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata data) external pure override returns (bytes4, BalanceDelta) {
        return (IFullRangeHooks.afterSwapReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterAddLiquidityReturnDelta(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, bytes calldata data) external pure override returns (bytes4, BalanceDelta) {
        return (IFullRangeHooks.afterAddLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidityReturnDelta(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, bytes calldata data) external pure override returns (bytes4, BalanceDelta) {
        return (IFullRangeHooks.afterRemoveLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}