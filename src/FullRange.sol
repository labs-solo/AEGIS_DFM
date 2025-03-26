// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { IFullRange, DepositParams, WithdrawParams } from "./interfaces/IFullRange.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
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
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";
import { IPoolPolicy } from "./interfaces/IPoolPolicy.sol";
import { IFeeReinvestmentManager } from "./interfaces/IFeeReinvestmentManager.sol";
import { ReentrancyGuard } from "solmate/src/utils/ReentrancyGuard.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { PoolTokenIdUtils } from "./utils/PoolTokenIdUtils.sol";
import { IFullRangeHooks } from "./interfaces/IFullRangeHooks.sol";

/**
 * @title FullRange
 * @notice Optimized Uniswap V4 Hook contract with minimized bytecode size
 * @dev Implements IFullRange and uses delegate calls to manager contracts for complex logic
 */
contract FullRange is IFullRange, IFullRangeHooks, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    
    // =========================================================================
    // Constants for hook selectors
    // =========================================================================
    bytes4 internal constant BEFORE_INITIALIZE_SELECTOR = IHooks.beforeInitialize.selector;
    bytes4 internal constant AFTER_INITIALIZE_SELECTOR = IHooks.afterInitialize.selector;
    bytes4 internal constant BEFORE_ADD_LIQUIDITY_SELECTOR = IHooks.beforeAddLiquidity.selector;
    bytes4 internal constant AFTER_ADD_LIQUIDITY_SELECTOR = IHooks.afterAddLiquidity.selector;
    bytes4 internal constant BEFORE_REMOVE_LIQUIDITY_SELECTOR = IHooks.beforeRemoveLiquidity.selector;
    bytes4 internal constant AFTER_REMOVE_LIQUIDITY_SELECTOR = IHooks.afterRemoveLiquidity.selector;
    bytes4 internal constant BEFORE_SWAP_SELECTOR = IHooks.beforeSwap.selector;
    bytes4 internal constant AFTER_SWAP_SELECTOR = IHooks.afterSwap.selector;
    bytes4 internal constant BEFORE_DONATE_SELECTOR = IHooks.beforeDonate.selector;
    bytes4 internal constant AFTER_DONATE_SELECTOR = IHooks.afterDonate.selector;
    
    // Immutable core contracts and managers
    IPoolManager public immutable poolManager;
    IPoolPolicy public immutable policyManager;
    FullRangeLiquidityManager public immutable liquidityManager;
    FullRangeDynamicFeeManager public immutable dynamicFeeManager;

    // Optimized storage layout - pack related data together
    struct PoolData {
        bool initialized;      // Whether pool is initialized (1 byte)
        bool emergencyState;   // Whether pool is in emergency (1 byte)
        uint128 reserve0;      // Token0 reserves (16 bytes)
        uint128 reserve1;      // Token1 reserves (16 bytes)
        uint256 tokenId;       // Pool token ID (32 bytes)
    }
    
    // Single mapping for pool data instead of multiple mappings
    mapping(PoolId => PoolData) public poolData;
    
    // Pool keys stored separately since they're larger structures
    mapping(PoolId => PoolKey) public poolKeys;
    
    // Mapping to track pending ETH withdrawals
    mapping(address => uint256) public pendingETHPayments;
    
    // Internal callback data structure - minimized to save gas
    struct CallbackData {
        uint8 callbackType;  // 1=deposit, 2=withdraw, 3=swap
        address sender;      // Original sender
        PoolId poolId;       // Pool ID
        uint128 amount0;     // Amount of token0
        uint128 amount1;     // Amount of token1
        uint256 shares;      // Shares amount
    }
    
    // Events
    event ETHTransferFailed(address indexed recipient, uint256 amount);
    event ETHClaimed(address indexed recipient, uint256 amount);
    event FeeUpdateFailed(PoolId indexed poolId);
    event ReinvestmentSuccess(PoolId indexed poolId, uint256 amount0, uint256 amount1);
    event ReinvestmentFailed(PoolId indexed poolId, string reason);
    event PoolEmergencyStateChanged(PoolId indexed poolId, bool isEmergency);
    event PolicyInitializationFailed(PoolId indexed poolId, string reason);
    event Deposit(address indexed sender, PoolId indexed poolId, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdraw(address indexed sender, PoolId indexed poolId, uint256 amount0, uint256 amount1, uint256 shares);
    event FeeExtractionProcessed(PoolId indexed poolId, uint256 amount0, uint256 amount1);
    event FeeExtractionFailed(PoolId indexed poolId, string reason);
    
    // Modifiers
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
            revert Errors.DeadlinePassed(uint32(deadline), uint32(block.timestamp));
        }
        _;
    }

    /**
     * @notice Constructor
     */
    constructor(
        IPoolManager _manager,
        IPoolPolicy _policyManager,
        FullRangeLiquidityManager _liquidityManager,
        FullRangeDynamicFeeManager _dynamicFeeManager
    ) {
        if (address(_manager) == address(0)) revert Errors.ZeroAddress();
        if (address(_policyManager) == address(0)) revert Errors.ZeroAddress();
        if (address(_liquidityManager) == address(0)) revert Errors.ZeroAddress();
        if (address(_dynamicFeeManager) == address(0)) revert Errors.ZeroAddress();

        poolManager = _manager;
        policyManager = _policyManager;
        liquidityManager = _liquidityManager;
        dynamicFeeManager = _dynamicFeeManager;
        
        validateHookAddress();
    }

    /**
     * @notice Receive function for ETH payments
     */
    receive() external payable {}

    /**
     * @notice Get hook permissions for Uniswap V4
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
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /**
     * @notice Validate hook address
     */
    function validateHookAddress() internal view {
        Hooks.validateHookPermissions(this, getHookPermissions());
    }

    /**
     * @notice Returns hook address
     */
    function getHookAddress() external view returns (address) {
        return address(this);
    }

    /**
     * @notice Set emergency state for a pool
     */
    function setPoolEmergencyState(PoolId poolId, bool isEmergency) external onlyGovernance {
        poolData[poolId].emergencyState = isEmergency;
        emit PoolEmergencyStateChanged(poolId, isEmergency);
    }

    /**
     * @notice Deposit into a Uniswap V4 pool
     * @dev Delegates main logic to FullRangeLiquidityManager, handling only hook callbacks
     */
    function deposit(DepositParams calldata params) 
        external 
        payable
        nonReentrant 
        ensure(params.deadline)
        returns (uint256 shares, uint256 amount0, uint256 amount1) 
    {
        // Verify pool is initialized and not in emergency state
        PoolData storage data = poolData[params.poolId];
        if (!data.initialized) revert Errors.PoolNotInitialized(params.poolId);
        if (data.emergencyState) revert Errors.PoolInEmergencyState(params.poolId);
        
        // Retrieve pool key for native ETH validation
        PoolKey memory key = poolKeys[params.poolId];
        
        // Validate native ETH usage using CurrencyLibrary abstraction
        bool hasNative = key.currency0.isAddressZero() || key.currency1.isAddressZero();
        if (msg.value > 0 && !hasNative) revert Errors.NonzeroNativeValue();
        
        // Delegate to liquidityManager with msg.value forwarded
        (shares, amount0, amount1) = liquidityManager.deposit{value: msg.value}(
            params.poolId,
            params.amount0Desired,
            params.amount1Desired,
            params.amount0Min,
            params.amount1Min,
            msg.sender
        );
        
        emit Deposit(msg.sender, params.poolId, amount0, amount1, shares);
        return (shares, amount0, amount1);
    }

    /**
     * @notice Deposit ETH and tokens into a Uniswap V4 pool
     */
    function depositETH(DepositParams calldata params, PoolKey calldata poolKey)
        external
        payable
    {
        revert Errors.NotImplemented();
    }

    /**
     * @notice Withdraw from a Uniswap V4 pool
     * @dev Delegates main logic to FullRangeLiquidityManager, handling only hook callbacks
     */
    function withdraw(WithdrawParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        // Verify pool is initialized
        PoolData storage data = poolData[params.poolId];
        if (!data.initialized) revert Errors.PoolNotInitialized(params.poolId);
        
        // Delegate to liquidityManager
        (amount0, amount1) = liquidityManager.withdraw(
            params.poolId,
            params.sharesToBurn,
            params.minAmount0,
            params.minAmount1,
            msg.sender
        );
        
        emit Withdraw(msg.sender, params.poolId, amount0, amount1, params.sharesToBurn);
        return (amount0, amount1);
    }

    /**
     * @notice Withdraw with ETH handling
     */
    function withdrawETH(WithdrawParams calldata params, PoolKey calldata poolKey)
        external
        returns (uint256 amount0Out, uint256 amount1Out)
    {
        revert Errors.NotImplemented();
    }

    /**
     * @notice Claim pending ETH payments
     * @dev Simple wrapper around liquidityManager functionality
     */
    function claimPendingETH() external {
        liquidityManager.claimETH();
    }

    /**
     * @notice Safe transfer ETH with fallback to pending payments
     */
    function _safeTransferETH(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        
        (bool success, ) = recipient.call{value: amount, gas: 50000}("");
        if (!success) {
            pendingETHPayments[recipient] += amount;
            emit ETHTransferFailed(recipient, amount);
        }
    }

    /**
     * @notice Safe transfer token with ETH handling
     */
    function _safeTransferToken(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        
        if (token == address(0)) {
            _safeTransferETH(to, amount);
        } else {
            SafeTransferLib.safeTransfer(ERC20(token), to, amount);
        }
    }

    /**
     * @notice Consolidated fee processing function
     * @param poolId The pool ID to process fees for
     * @param opType The operation type triggering the fee processing
     * @param feesAccrued Optional fees accrued during the operation
     */
    function _processFees(
        PoolId poolId,
        IFeeReinvestmentManager.OperationType opType,
        BalanceDelta feesAccrued
    ) internal {
        // Skip if no fees to process
        if (feesAccrued.amount0() <= 0 && feesAccrued.amount1() <= 0) return;
        
        uint256 fee0 = feesAccrued.amount0() > 0 ? uint256(uint128(feesAccrued.amount0())) : 0;
        uint256 fee1 = feesAccrued.amount1() > 0 ? uint256(uint128(feesAccrued.amount1())) : 0;
        
        address reinvestPolicy = policyManager.getPolicy(poolId, IPoolPolicy.PolicyType.REINVESTMENT);
        if (reinvestPolicy != address(0)) {
            try IFeeReinvestmentManager(reinvestPolicy).collectFees(poolId, opType) returns (bool success, uint256 amount0, uint256 amount1) {
                if (success) {
                    emit ReinvestmentSuccess(poolId, fee0, fee1);
                }
            } catch {
                emit ReinvestmentFailed(poolId, "Processing failed");
            }
        }
    }

    /**
     * @notice Get pool info
     */
    function getPoolInfo(PoolId poolId) 
        external 
        view 
        returns (
            bool isInitialized,
            uint256[2] memory reserves,
            uint128 totalShares,
            uint256 tokenId
        ) 
    {
        PoolData storage data = poolData[poolId];
        isInitialized = data.initialized;
        
        if (isInitialized) {
            reserves[0] = data.reserve0;
            reserves[1] = data.reserve1;
            totalShares = liquidityManager.totalShares(poolId);
            tokenId = data.tokenId;
        }
        
        return (isInitialized, reserves, totalShares, tokenId);
    }

    /**
     * @notice Check if a pool is initialized
     */
    function isPoolInitialized(PoolId poolId) public view returns (bool) {
        return poolData[poolId].initialized;
    }

    /**
     * @notice Get the pool key for a pool ID
     */
    function getPoolKey(PoolId poolId) public view returns (PoolKey memory) {
        return poolKeys[poolId];
    }

    /**
     * @notice Get the token ID for a pool
     */
    function getPoolTokenId(PoolId poolId) public view returns (uint256) {
        return poolData[poolId].tokenId;
    }

    /**
     * @notice Get pool reserves and shares
     */
    function getPoolReservesAndShares(PoolId poolId) public view returns (uint256 reserve0, uint256 reserve1, uint128 totalShares) {
        PoolData storage data = poolData[poolId];
        return (data.reserve0, data.reserve1, liquidityManager.totalShares(poolId));
    }

    /**
     * @notice Unlock callback implementation
     * @dev Delegates to liquidityManager for actual delta handling logic
     */
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        // Decode callback data
        CallbackData memory cbData = abi.decode(data, (CallbackData));
        PoolKey memory key = poolKeys[cbData.poolId];
        
        if (cbData.callbackType == 1) { // Deposit
            // Create ModifyLiquidityParams for full range position
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: int256(uint256(cbData.shares)),
                salt: bytes32(0)
            });
            
            // Call modifyLiquidity directly
            (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, params, "");
            
            // Delegate settlement to liquidityManager
            liquidityManager.handlePoolDelta(key, delta);
            
            return abi.encode(delta);
        } 
        else if (cbData.callbackType == 2) { // Withdraw
            // Create ModifyLiquidityParams with negative liquidity delta
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: -int256(cbData.shares),
                salt: bytes32(0)
            });
            
            // Call modifyLiquidity directly
            (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, params, "");
            
            // Delegate settlement to liquidityManager
            liquidityManager.handlePoolDelta(key, delta);
            
            return abi.encode(delta);
        }
        
        return abi.encode("Unknown callback type");
    }

    /**
     * @notice Implementation for beforeInitialize hook
     */
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) 
        external
        override
        returns (bytes4)
    {
        return IHooks.beforeInitialize.selector;
    }

    /**
     * @notice Implementation for afterInitialize hook
     */
    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        
        // Store pool key and initialize pool data
        poolData[poolId] = PoolData({
            initialized: true,
            emergencyState: false,
            reserve0: 0,
            reserve1: 0,
            tokenId: PoolTokenIdUtils.toTokenId(poolId)
        });
        
        poolKeys[poolId] = key;
        
        // Initialize any policies if required
        try policyManager.handlePoolInitialization(poolId, key, sqrtPriceX96, tick, address(this)) {
            // Successfully initialized policies
        } catch (bytes memory reason) {
            emit PolicyInitializationFailed(poolId, string(reason));
        }
        
        return IHooks.afterInitialize.selector;
    }

    /**
     * @notice Implementation for beforeSwap hook
     * @dev Returns dynamic fee for the pool
     */
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Return dynamic fee and no delta
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            uint24(dynamicFeeManager.getCurrentDynamicFee(key.toId()))
        );
    }

    /**
     * @notice Implementation for afterSwap hook
     */
    function afterSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        external
        override
        returns (bytes4, int128)
    {
        return (IHooks.afterSwap.selector, 0);
    }

    /**
     * @notice Implementation for beforeAddLiquidity hook
     */
    function beforeAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata hookData)
        external
        override
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    /**
     * @notice Implementation for afterAddLiquidity hook
     */
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Implementation for beforeRemoveLiquidity hook
     */
    function beforeRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata hookData)
        external
        override
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /**
     * @notice Implementation for afterRemoveLiquidity hook
     */
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Implementation for beforeDonate hook
     */
    function beforeDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    /**
     * @notice Implementation for afterDonate hook
     */
    function afterDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        override
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    /**
     * @notice Implementation for afterRemoveLiquidityReturnDelta hook
     * @dev This hook delegates all fee calculation and tracking logic to the FeeReinvestmentManager
     *     to keep the FullRange contract lean
     */
    function afterRemoveLiquidityReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        
        // Get the FeeReinvestmentManager
        address reinvestPolicy = policyManager.getPolicy(poolId, IPoolPolicy.PolicyType.REINVESTMENT);
        
        // Delegate all extraction logic to the FeeReinvestmentManager
        if (reinvestPolicy != address(0)) {
            try IFeeReinvestmentManager(reinvestPolicy).handleFeeExtraction(
                poolId, 
                feesAccrued
            ) returns (BalanceDelta extractDelta) {
                // Return whatever delta the FeeReinvestmentManager suggests
                return (IFullRangeHooks.afterRemoveLiquidityReturnDelta.selector, extractDelta);
            } catch {
                // If handler fails, extract nothing
            }
        }
        
        // Default to zero extraction
        return (IFullRangeHooks.afterRemoveLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Implementation for beforeSwapReturnDelta hook
     */
    function beforeSwapReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta) {
        return (IFullRangeHooks.beforeSwapReturnDelta.selector, BeforeSwapDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Implementation for afterSwapReturnDelta hook
     */
    function afterSwapReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        return (IFullRangeHooks.afterSwapReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Implementation for afterAddLiquidityReturnDelta hook
     */
    function afterAddLiquidityReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        return (IFullRangeHooks.afterAddLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}