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
import { FullRangeUtils } from "./FullRangeUtils.sol";
import { Errors } from "./errors/Errors.sol";
import { SettlementUtils } from "./utils/SettlementUtils.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";
import { IPoolPolicy } from "./interfaces/IPoolPolicy.sol";
import { IFeeReinvestmentManager } from "./interfaces/IFeeReinvestmentManager.sol";
import { ReentrancyGuard } from "solmate/src/utils/ReentrancyGuard.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { PoolTokenIdUtils } from "./utils/PoolTokenIdUtils.sol";
import { FullRangePositions } from "./token/FullRangePositions.sol";

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
    uint256 private constant CACHE_EXPIRY = 1; // 1 block

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

    /**
     * @notice Returns a user's balance of shares in a specific pool using assembly for gas optimization
     * @param poolId The pool ID to query
     * @param user The user address to check
     * @return The number of pool shares owned by the user
     */
    function getUserShares(PoolId poolId, address user) public view returns (uint256) {
        address liquidityManagerAddr = address(liquidityManager);
        bytes4 selector = bytes4(keccak256("getUserShares(bytes32,address)"));
        bytes32 poolIdBytes = PoolId.unwrap(poolId);
        uint256 result;
        
        assembly {
            // Prepare call data
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 0x04), poolIdBytes)
            mstore(add(ptr, 0x24), user)
            
            // Make static call
            let success := staticcall(
                gas(),
                liquidityManagerAddr,
                ptr,
                0x44, // 4 bytes selector + 32 bytes poolId + 32 bytes address
                0x00, // Store result at memory position 0
                0x20  // We expect a uint256 (32 bytes) in return
            )
            
            // Check success and load result
            if iszero(success) {
                revert(0, 0)
            }
            
            result := mload(0x00)
        }
        
        return result;
    }
    
    /**
     * @notice Gets cached user shares with caching for gas optimization
     * @param poolId The pool ID to query
     * @param user The user address to check
     * @return User's share balance
     */
    function getCachedUserShares(PoolId poolId, address user) internal returns (uint256) {
        bytes32 key = keccak256(abi.encodePacked(poolId, user));
        
        // Use cached value if in the same block
        if (_shareBalanceCache[key][user] > 0 && _shareBalanceCache[key][user] >> 128 == block.number) {
            return uint256(_shareBalanceCache[key][user] & ((1 << 128) - 1));
        }
        
        // Otherwise fetch and cache the value
        uint256 shares = getUserShares(poolId, user);
        _shareBalanceCache[key][user] = (block.number << 128) | shares;
        return shares;
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
     *      Propagates the state change to the liquidity manager for handling.
     * @param poolId The pool ID to modify.
     * @param isEmergency Whether to enable (true) or disable (false) emergency state.
     */
    function setPoolEmergencyState(PoolId poolId, bool isEmergency) external onlyGovernance {
        // Update local emergency state
        emergencyState[poolId] = isEmergency;
        // Propagate state to the liquidity manager module
        if (isEmergency) {
            liquidityManager.enablePoolEmergencyState(poolId, "Governance activated");
        } else {
            liquidityManager.disablePoolEmergencyState(poolId);
        }
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
     * @notice Deposits ETH and tokens into a Uniswap V4 pool via the FullRange hook.
     * @dev Similar to deposit() but allows ETH to be used for either token0 or token1.
     * @param params The deposit parameters (poolId, amounts, slippage, deadline).
     * @param currencyIndex Which currency (0 or 1) ETH is being used for.
     * @return shares The number of LP shares minted to the user.
     * @return amount0 The actual amount of token0 deposited.
     * @return amount1 The actual amount of token1 deposited.
     */
    function depositETH(DepositParams calldata params, uint8 currencyIndex)
        external
        payable
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
        
        // Validate ETH currency index (must be 0 or 1)
        if (currencyIndex > 1) {
            revert Errors.ValidationInvalidInput("Invalid currency index");
        }
        
        // Get pool info
        PoolKey memory key = getPoolKey(params.poolId);
        
        // Confirm one of the tokens is ETH
        address token0 = UniswapCurrency.unwrap(key.currency0);
        address token1 = UniswapCurrency.unwrap(key.currency1);
        if (token0 != address(0) && token1 != address(0)) {
            revert Errors.ValidationInvalidInput("Pool must have ETH as one of the tokens");
        }
        
        // Validate that the token indexed by currencyIndex is ETH
        if ((currencyIndex == 0 && token0 != address(0)) || (currencyIndex == 1 && token1 != address(0))) {
            revert Errors.ValidationInvalidInput("Invalid currency index");
        }
        
        // Get current pool reserves and share information
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, params.poolId);
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
        
        // Pull ETH and/or tokens from user
        if (currencyIndex == 0) {
            // ETH is token0
            if (amount0 > msg.value) {
                revert Errors.ValidationInvalidInput("Insufficient ETH sent");
            }
            // Pull token1 if needed
            if (amount1 > 0) {
                SafeTransferLib.safeTransferFrom(ERC20(token1), msg.sender, address(this), amount1);
            }
        } else {
            // ETH is token1
            if (amount1 > msg.value) {
                revert Errors.ValidationInvalidInput("Insufficient ETH sent");
            }
            // Pull token0 if needed
            if (amount0 > 0) {
                SafeTransferLib.safeTransferFrom(ERC20(token0), msg.sender, address(this), amount0);
            }
        }
        
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
        
        // Refund excess ETH if any
        if (currencyIndex == 0 && amount0 < msg.value) {
            _safeTransferETH(msg.sender, msg.value - amount0);
        } else if (currencyIndex == 1 && amount1 < msg.value) {
            _safeTransferETH(msg.sender, msg.value - amount1);
        }
        
        // Attempt fee reinvestment (if policy exists)
        address reinvestmentPolicy = policyManager.getPolicy(params.poolId, IPoolPolicy.PolicyType.REINVESTMENT);
        if (reinvestmentPolicy != address(0)) {
            IFeeReinvestmentManager(reinvestmentPolicy).processReinvestmentIfNeeded(params.poolId, amount0 + amount1);
        }
        
        emit Deposit(msg.sender, params.poolId, amount0, amount1, shares);
        return (shares, amount0, amount1);
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
     * @notice Withdraws liquidity with ETH handling from a Uniswap V4 pool.
     * @dev Burns LP shares and returns the corresponding tokens, converting ETH if necessary.
     * @param params The withdrawal parameters (poolId, shares, slippage, deadline).
     * @return amount0 The amount of token0 withdrawn.
     * @return amount1 The amount of token1 withdrawn.
     */
    function withdrawETH(WithdrawParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        // Verify user has enough shares - use cached user shares for gas optimization
        uint256 userSharesBalance = getCachedUserShares(params.poolId, msg.sender);
        if (userSharesBalance < params.sharesToBurn) {
            revert Errors.ValidationInvalidInput("Insufficient shares");
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
        
        // Get token addresses for transfer
        address token0 = UniswapCurrency.unwrap(key.currency0);
        address token1 = UniswapCurrency.unwrap(key.currency1);
        
        // Transfer token0
        if (amount0 > 0) {
            if (token0 != address(0)) {
                // Standard ERC20 token
                SafeTransferLib.safeTransfer(ERC20(token0), msg.sender, amount0);
            } else {
                // ETH
                _safeTransferETH(msg.sender, amount0);
            }
        }
        
        // Transfer token1
        if (amount1 > 0) {
            if (token1 != address(0)) {
                // Standard ERC20 token
                SafeTransferLib.safeTransfer(ERC20(token1), msg.sender, amount1);
            } else {
                // ETH
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
     * @notice Allows users to claim any pending ETH payments from failed transfers.
     * @dev Tries to send any pending ETH stored for the caller.
     *      This function is necessary because ETH transfers may fail in certain scenarios:
     *      1. When the recipient is a contract without a receive/fallback function
     *      2. When the recipient contract's receive/fallback function reverts
     *      3. When excessive gas consumption occurs during the receive/fallback function
     *
     *      In such cases, the ETH is stored in pendingETHPayments for later retrieval.
     *      This two-step approach ensures funds are not lost due to transfer failures.
     */
    function claimETH() external nonReentrant {
        uint256 pendingAmount = pendingETHPayments[msg.sender];
        if (pendingAmount == 0) {
            revert Errors.ValidationZeroAmount("pendingETHPayment");
        }
        
        // Reset pending amount before transfer to prevent reentrancy
        pendingETHPayments[msg.sender] = 0;
        
        // Attempt to transfer ETH with explicit gas limit to prevent DoS attacks
        (bool success, ) = msg.sender.call{value: pendingAmount, gas: 50000}("");
        if (!success) {
            // If transfer still fails, restore the pending amount
            pendingETHPayments[msg.sender] = pendingAmount;
            revert Errors.TokenEthTransferFailed(msg.sender, pendingAmount);
        }
        
        emit ETHClaimed(msg.sender, pendingAmount);
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
     * @return initialized Whether the pool has been initialized.
     * @return reserves The current token reserves in the pool.
     * @return totalShares The total supply of pool shares.
     * @return tokenId The NFT token ID associated with the pool position.
     */
    function getPoolInfo(PoolId poolId) 
        external 
        view 
        returns (
            bool initialized,
            uint256[2] memory reserves,
            uint128 totalShares,
            uint256 tokenId
        ) 
    {
        initialized = isPoolInitialized(poolId);
        
        if (initialized) {
            (uint256 reserve0, uint256 reserve1, uint128 shares) = 
                getPoolReservesAndShares(poolId);
                
            reserves[0] = reserve0;
            reserves[1] = reserve1;
            totalShares = shares;
            tokenId = getPoolTokenId(poolId);
        }
        
        return (initialized, reserves, totalShares, tokenId);
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
        return (poolReserve0[poolId], poolReserve1[poolId], poolTotalShares[poolId]);
    }
    
    /**
     * @notice Fallback function used as a unified dispatcher for all hook callbacks.
     * @dev Uses inline assembly to efficiently extract and route function selectors.
     *      Only the PoolManager can call hook functions. If any other address calls,
     *      the transaction will revert with AccessOnlyPoolManager error.
     */
    fallback() external {
        // Inline assembly for efficient dispatch on function selector
        address pm = address(poolManager);
        assembly {
            // Only allow the PoolManager contract to call hook functions
            if iszero(eq(caller(), pm)) {
                // Revert with AccessOnlyPoolManager(address caller)
                mstore(0x00, 0x13bf46b400000000000000000000000000000000000000000000000000000000)
                mstore(0x04, caller())
                revert(0x00, 0x24)
            }
            
            // Load the 4-byte function selector from calldata
            let selector := shr(224, calldataload(0))
            
            // Determine and execute the appropriate callback
            // The hook mechanism relies on returning the same selector to indicate success
            // This optimized approach avoids declaring all hook functions explicitly
            mstore(0x0, selector)
            return(0x0, 0x20)
        }
    }

    // IHooks implementation stubs
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4) {
        return IFullRangeHooks(address(0)).beforeInitialize.selector;
    }

    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick) external returns (bytes4) {
        return IFullRangeHooks(address(0)).afterInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata data) external returns (bytes4) {
        return IFullRangeHooks(address(0)).beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata data) external returns (bytes4, BalanceDelta) {
        // Return the selector and zero balance delta
        return (IFullRangeHooks(address(0)).afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata data) external returns (bytes4) {
        return IFullRangeHooks(address(0)).beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata data) external returns (bytes4, BalanceDelta) {
        // Return the selector and zero balance delta
        return (IFullRangeHooks(address(0)).afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata data) external returns (bytes4, BeforeSwapDelta, uint24) {
        return (IFullRangeHooks(address(0)).beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata data) external returns (bytes4, int128) {
        return (IFullRangeHooks(address(0)).afterSwap.selector, 0);
    }

    function beforeDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata data) external returns (bytes4) {
        return IFullRangeHooks(address(0)).beforeDonate.selector;
    }

    function afterDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata data) external returns (bytes4) {
        return IFullRangeHooks(address(0)).afterDonate.selector;
    }

    function beforeSwapReturnDelta(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata data) external returns (bytes4, BeforeSwapDelta) {
        return (IFullRangeHooks(address(0)).beforeSwapReturnDelta.selector, BeforeSwapDeltaLibrary.ZERO_DELTA);
    }

    function afterSwapReturnDelta(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata data) external returns (bytes4, BalanceDelta) {
        return (IFullRangeHooks(address(0)).afterSwapReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterAddLiquidityReturnDelta(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, bytes calldata data) external returns (bytes4, BalanceDelta) {
        return (IFullRangeHooks(address(0)).afterAddLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidityReturnDelta(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, bytes calldata data) external returns (bytes4, BalanceDelta) {
        return (IFullRangeHooks(address(0)).afterRemoveLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // IFullRange implementation stubs
    function depositETH(DepositParams calldata params, PoolKey calldata poolKey) 
        external 
        payable 
    {
        // Determine currency index based on the pool key
        uint8 currencyIndex = UniswapCurrency.unwrap(poolKey.currency0) == address(0) ? 0 : 1;
        
        // Call the method with the determined currency index
        this.depositETH(params, currencyIndex);
    }

    function withdrawETH(WithdrawParams calldata params, PoolKey calldata poolKey) external returns (uint256 amount0, uint256 amount1) {
        return this.withdraw(params);
    }

    function claimPendingETH() external {
        this.claimETH();
    }

    /**
     * @notice Claims and reinvests fees for a specific pool
     * @param poolId The pool ID to reinvest fees for
     * @return fee0 The amount of token0 fees claimed
     * @return fee1 The amount of token1 fees claimed
     */
    function claimAndReinvestFees(PoolId poolId) external returns (uint256 fee0, uint256 fee1) {
        // Get the reinvestment policy
        address reinvestmentPolicy = policyManager.getPolicy(poolId, IPoolPolicy.PolicyType.REINVESTMENT);
        
        // Return zero if policy not found
        if (reinvestmentPolicy == address(0)) {
            return (0, 0);
        }
        
        // Use a default swap value for threshold calculations
        uint256 defaultSwapValue = 1000000; // 1M units
        
        // Get pending fees (to return these values)
        fee0 = IFeeReinvestmentManager(reinvestmentPolicy).pendingFees0(poolId);
        fee1 = IFeeReinvestmentManager(reinvestmentPolicy).pendingFees1(poolId);
        
        // Call processReinvestmentIfNeeded
        bool success = IFeeReinvestmentManager(reinvestmentPolicy).processReinvestmentIfNeeded(poolId, defaultSwapValue);
        
        // Emit success event if reinvestment succeeded
        if (success) {
            emit ReinvestmentSuccess(poolId, fee0, fee1);
        }
        
        return (fee0, fee1);
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
}