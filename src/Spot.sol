// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { ISpot, DepositParams, WithdrawParams } from "./interfaces/ISpot.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
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
import { ISpotHooks } from "./interfaces/ISpotHooks.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { IERC20Minimal } from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import { TruncGeoOracleMulti } from "./TruncGeoOracleMulti.sol";
import { IFullRangeDynamicFeeManager } from "./interfaces/IFullRangeDynamicFeeManager.sol";
import { IFullRangeLiquidityManager } from "./interfaces/IFullRangeLiquidityManager.sol";
import { TruncatedOracle } from "./libraries/TruncatedOracle.sol";
import { BaseHook } from "lib/v4-periphery/src/utils/BaseHook.sol";

/**
 * @title Spot
 * @notice Optimized Uniswap V4 Hook contract with minimized bytecode size
 * @dev Implements ISpot and uses delegate calls to manager contracts for complex logic
 *      Inherits from BaseHook to provide default hook implementations.
 */
contract Spot is BaseHook, ISpot, ISpotHooks, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    
    // =========================================================================
    // Constants for hook selectors - No longer needed as BaseHook handles this
    // =========================================================================
    // bytes4 internal constant BEFORE_INITIALIZE_SELECTOR = IHooks.beforeInitialize.selector;
    // bytes4 internal constant AFTER_INITIALIZE_SELECTOR = IHooks.afterInitialize.selector;
    // bytes4 internal constant BEFORE_ADD_LIQUIDITY_SELECTOR = IHooks.beforeAddLiquidity.selector;
    // bytes4 internal constant AFTER_ADD_LIQUIDITY_SELECTOR = IHooks.afterAddLiquidity.selector;
    // bytes4 internal constant BEFORE_REMOVE_LIQUIDITY_SELECTOR = IHooks.beforeRemoveLiquidity.selector;
    // bytes4 internal constant AFTER_REMOVE_LIQUIDITY_SELECTOR = IHooks.afterRemoveLiquidity.selector;
    // bytes4 internal constant BEFORE_SWAP_SELECTOR = IHooks.beforeSwap.selector;
    // bytes4 internal constant AFTER_SWAP_SELECTOR = IHooks.afterSwap.selector;
    // bytes4 internal constant BEFORE_DONATE_SELECTOR = IHooks.beforeDonate.selector;
    // bytes4 internal constant AFTER_DONATE_SELECTOR = IHooks.afterDonate.selector;
    
    // Immutable core contracts and managers
    IPoolPolicy public immutable policyManager;
    FullRangeLiquidityManager public immutable liquidityManager;
    FullRangeDynamicFeeManager public dynamicFeeManager;
    
    // Add a storage variable to track the current active dynamic fee manager
    FullRangeDynamicFeeManager private activeDynamicFeeManager;

    // Optimized storage layout - pack related data together
    struct PoolData {
        bool initialized;      // Whether pool is initialized (1 byte)
        bool emergencyState;   // Whether pool is in emergency (1 byte)
        uint256 tokenId;       // Pool token ID (32 bytes)
        // No reserves - they'll be calculated on demand
    }
    
    // Single mapping for pool data instead of multiple mappings
    mapping(PoolId => PoolData) public poolData;
    
    // Pool keys stored separately since they're larger structures
    mapping(PoolId => PoolKey) public poolKeys;
    
    // Internal callback data structure - minimized to save gas
    struct CallbackData {
        PoolId poolId;           // Pool ID
        uint8 callbackType;      // 1=deposit, 2=withdraw
        uint128 shares;          // Shares amount
        uint256 amount0;         // Amount of token0
        uint256 amount1;         // Amount of token1
        address recipient;       // Recipient of liquidity
    }
    
    // Events
    event FeeUpdateFailed(PoolId indexed poolId);
    event ReinvestmentSuccess(PoolId indexed poolId, uint256 amount0, uint256 amount1);
    event ReinvestmentFailed(PoolId indexed poolId, string reason);
    event PoolEmergencyStateChanged(PoolId indexed poolId, bool isEmergency);
    event PolicyInitializationFailed(PoolId indexed poolId, string reason);
    event Deposit(address indexed sender, PoolId indexed poolId, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdraw(address indexed sender, PoolId indexed poolId, uint256 amount0, uint256 amount1, uint256 shares);
    event FeeExtractionProcessed(PoolId indexed poolId, uint256 amount0, uint256 amount1);
    event FeeExtractionFailed(PoolId indexed poolId, string reason);
    event OracleTickUpdated(PoolId indexed poolId, int24 tick, uint32 blockNumber);
    event OracleUpdated(PoolId indexed poolId, int24 tick, uint32 blockTimestamp);
    event OracleUpdateFailed(PoolId indexed poolId, int24 uncappedTick, bytes reason);
    event CAPEventDetected(PoolId indexed poolId, int24 currentTick);
    event OracleInitialized(PoolId indexed poolId, int24 initialTick, int24 maxAbsTickMove);
    event OracleInitializationFailed(PoolId indexed poolId, bytes reason);
    
    // Oracle data storage - reverse authorization model for gas optimization
    // Stores tick data directly in Spot instead of calling DynamicFeeManager
    // This eliminates expensive cross-contract validation and improves gas efficiency
    mapping(PoolId => int24) public lastOracleTicks;
    mapping(PoolId => uint32) public lastOracleUpdateBlocks;
    
    // Oracle tracking variables - only store fallbacks (used when oracle fails)
    // Kept minimal to reduce storage costs 
    mapping(PoolId => int24) private lastFallbackTicks;
    mapping(PoolId => uint32) private lastFallbackBlocks;
    
    // Add to state variables section near the top with other state variables
    TruncGeoOracleMulti public truncGeoOracle;
    
    // Modifiers
    modifier onlyGovernance() {
        if (msg.sender != policyManager.getSoloGovernance()) {
            revert Errors.AccessOnlyGovernance(msg.sender);
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
        FullRangeLiquidityManager _liquidityManager
    ) BaseHook(_manager) {
        if (address(_manager) == address(0)) revert Errors.ZeroAddress();
        if (address(_policyManager) == address(0)) revert Errors.ZeroAddress();
        if (address(_liquidityManager) == address(0)) revert Errors.ZeroAddress();

        policyManager = _policyManager;
        liquidityManager = _liquidityManager;
    }

    /**
     * @notice Receive function for ETH payments
     */
    receive() external payable {}

    /**
     * @notice Get hook permissions for Uniswap V4
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
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
    // validateHookAddress is handled by BaseHook

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
        PoolData storage data = poolData[params.poolId];
        
        // Validation
        if (!data.initialized) revert Errors.PoolNotInitialized(params.poolId);
        if (data.emergencyState) revert Errors.PoolInEmergencyState(params.poolId);
        
        // Get pool key to check for native ETH
        PoolKey memory key = poolKeys[params.poolId];
        
        // Validate native ETH usage
        bool hasNative = key.currency0.isAddressZero() || key.currency1.isAddressZero();
        if (msg.value > 0 && !hasNative) revert Errors.NonzeroNativeValue();
        
        // Delegate to liquidity manager
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
     * @notice Withdraw liquidity from a pool
     * @dev Delegates to liquidity manager for withdrawals
     */
    function withdraw(WithdrawParams calldata params)
        external
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        // Validation
        PoolData storage data = poolData[params.poolId];
        if (!data.initialized) revert Errors.PoolNotInitialized(params.poolId);
        
        // Delegate to liquidity manager
        (amount0, amount1) = liquidityManager.withdraw(
            params.poolId,
            params.sharesToBurn,
            params.amount0Min,
            params.amount1Min,
            msg.sender
        );
        
        emit Withdraw(msg.sender, params.poolId, amount0, amount1, params.sharesToBurn);
        return (amount0, amount1);
    }

    /**
     * @notice Safe transfer token with ETH handling
     */
    function _safeTransferToken(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        
        Currency currency = Currency.wrap(token);
        if (currency.isAddressZero()) {
            SafeTransferLib.safeTransferETH(to, amount);
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
     * @notice Get pool information
     * @param poolId The pool ID
     * @return isInitialized Whether the pool is initialized
     * @return reserves Array of pool reserves [reserve0, reserve1]
     * @return totalShares Total shares in the pool
     * @return tokenId Pool token ID
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
            // Get reserves from liquidity manager
            (reserves[0], reserves[1]) = liquidityManager.getPoolReserves(poolId);
            
            // Get total shares from liquidity manager
            (totalShares, , ) = liquidityManager.poolInfo(poolId);
            
            // Get token ID from stored data
            tokenId = data.tokenId;
        }
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
        // Get reserves directly from the liquidity manager instead of storing them
        (reserve0, reserve1) = liquidityManager.getPoolReserves(poolId);
        totalShares = liquidityManager.totalShares(poolId);
    }

    /**
     * @notice Callback function for Uniswap V4 unlock pattern
     * @dev Called by the pool manager during deposit/withdraw operations
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        CallbackData memory cbData = abi.decode(data, (CallbackData));
        PoolKey memory key = poolKeys[cbData.poolId];

        if (cbData.callbackType == 1) {
            // DEPOSIT
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: int256(uint256(cbData.shares)),
                salt: bytes32(0)
            });
            
            (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, params, "");
            liquidityManager.handlePoolDelta(key, delta);
            
            return abi.encode(delta);
        } else if (cbData.callbackType == 2) {
            // WITHDRAW
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: -int256(uint256(cbData.shares)),
                salt: bytes32(0)
            });
            
            (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, params, "");
            liquidityManager.handlePoolDelta(key, delta);
            
            return abi.encode(delta);
        }
        
        return abi.encode("Unknown callback type");
    }

    /**
     * @notice Implementation for beforeInitialize hook
     */
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        virtual
        override
        returns (bytes4)
    {
        // BaseHook returns the selector automatically
        return this.beforeInitialize.selector;
    }

    /**
     * @notice After initialize hook implementation
     * @dev Sets up the pool data and initializes the liquidity manager
     */
    function _afterInitialize(
        address sender, 
        PoolKey calldata key, 
        uint160 sqrtPriceX96, 
        int24 tick
    ) internal virtual override returns (bytes4) {
        _afterInitializeInternal(sender, key, sqrtPriceX96, tick);
        return this.afterInitialize.selector;
    }

    /**
     * @notice Internal function containing the core logic for afterInitialize
     * @dev Moved logic here to allow overriding contracts to call it without `super` on an external function.
     */
    function _afterInitializeInternal(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal virtual {
        PoolId poolId = key.toId();

        // Validation
        if (poolData[poolId].initialized) {
            revert Errors.PoolAlreadyInitialized(poolId);
        }

        if (sqrtPriceX96 == 0) {
            revert Errors.InvalidPrice(sqrtPriceX96);
        }

        // Store pool data
        poolData[poolId] = PoolData({
            initialized: true,
            emergencyState: false,
            tokenId: PoolTokenIdUtils.toTokenId(poolId)
        });

        poolKeys[poolId] = key;

        // Register pool with liquidity manager
        liquidityManager.registerPool(poolId, key, sqrtPriceX96);

        // Enhanced security: Only initialize oracle if:
        // 1. We're using dynamic fee flag (0x800000) OR fee is 0
        // 2. The actual hook address matches this contract
        // 3. Oracle is set up
        if ((key.fee == 0x800000 || key.fee == 0) &&
            address(key.hooks) == address(this) &&
            address(truncGeoOracle) != address(0)) {

            // Get max tick move from policy if available, otherwise use TruncatedOracle's constant
            int24 maxAbsTickMove = TruncatedOracle.MAX_ABS_TICK_MOVE; // Default from library

            int24 scalingFactor = policyManager.getTickScalingFactor();
            // Dynamic calculation based on policy scaling factor
            if (scalingFactor > 0) {
                // Calculate dynamic maxAbsTickMove based on policy
                // Makes use of policy manager rather than hardcoding
                maxAbsTickMove = int24(uint24(3000 / uint256(uint24(scalingFactor))));
            }

            // Initialize the oracle without try/catch
            truncGeoOracle.enableOracleForPool(key, maxAbsTickMove);
            emit OracleInitialized(poolId, tick, maxAbsTickMove);
        }

        // Initialize policies if required
        if (address(policyManager) != address(0)) {
            policyManager.handlePoolInitialization(poolId, key, sqrtPriceX96, tick, address(this));
        }

        // Call the internal hook for potential overrides in inheriting contracts
        _afterPoolInitialized(poolId, key, sqrtPriceX96, tick);
    }

    /**
     * @notice Implementation for beforeSwap hook
     * @dev Returns dynamic fee for the pool
     */
    function _beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Ensure dynamic fee manager has been set
        if (address(dynamicFeeManager) == address(0)) {
            revert Errors.NotInitialized("DynamicFeeManager");
        }
        
        // Return dynamic fee and no delta
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            uint24(dynamicFeeManager.getCurrentDynamicFee(key.toId()))
        );
    }

    /**
     * @notice Implementation for afterSwap hook
     * @dev Reverse Authorization Model: Stores oracle data locally and emits event
     *      instead of calling into DynamicFeeManager, which eliminates validation overhead
     *      and significantly reduces gas costs while maintaining security.
     */
    function _afterSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        
        // Ensure dynamic fee manager is set before proceeding if oracle depends on it
        // (Assuming truncGeoOracle might implicitly depend on dynamic fee setup)
        if (address(dynamicFeeManager) == address(0)) {
             revert Errors.NotInitialized("DynamicFeeManager");
        }

        // Security: Only process pools that are initialized in this contract
        // This prevents oracle updates for unrelated pools
        if (poolData[poolId].initialized && address(truncGeoOracle) != address(0)) {
            // Additional security: Verify the hook in the key is this contract
            // This ensures we're updating the oracle for the correct pool
            if (address(key.hooks) != address(this)) {
                revert Errors.InvalidPoolKey();
            }
            
            // Get current tick from pool manager
            (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
            
            // Gas optimization: Only attempt oracle update when needed
            bool shouldUpdateOracle = truncGeoOracle.shouldUpdateOracle(poolId);
            
            if (shouldUpdateOracle) {
                // Update the oracle through TruncGeoOracleMulti without try/catch
                // If this fails, the entire transaction will revert
                truncGeoOracle.updateObservation(key);
                emit OracleUpdated(poolId, currentTick, uint32(block.timestamp));
            }
        }
        
        return (this.afterSwap.selector, 0);
    }

    /**
     * @notice Implementation for beforeAddLiquidity hook
     */
    function _beforeAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4)
    {
        return this.beforeAddLiquidity.selector;
    }

    /**
     * @notice After Add Liquidity hook
     * @dev Reverse Authorization Model: Only handles fee processing logic directly
     *      to reduce gas and remove DynamicFeeManager dependency.
     * @param sender The sender address
     * @param key The pool key
     * @param params Modify liquidity parameters
     * @param delta The balance delta
     * @param feesAccrued The fees accrued during the operation
     * @param hookData Additional hook data
     * @return bytes4 Selector for afterAddLiquidity hook
     * @return BalanceDelta The fee delta
     */
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        // Reserves are calculated on demand, no need to update storage
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Implementation for beforeRemoveLiquidity hook
     */
    function _beforeRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4)
    {
        return this.beforeRemoveLiquidity.selector;
    }

    /**
     * @notice After Remove Liquidity hook
     * @dev Reverse Authorization Model: Only handles fee processing logic directly
     *      to reduce gas and remove DynamicFeeManager dependency.
     * @param sender The sender address
     * @param key The pool key
     * @param params Modify liquidity parameters
     * @param delta The balance delta
     * @param feesAccrued The fees accrued during the operation
     * @param hookData Additional hook data
     * @return bytes4 Selector for afterRemoveLiquidity hook
     * @return BalanceDelta The fee delta
     */
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        // Track fees reinvestment
        if (poolData[poolId].initialized) {
            // Process fees if any
            if (feesAccrued.amount0() != 0 || feesAccrued.amount1() != 0) {
                _processFees(poolId, IFeeReinvestmentManager.OperationType.WITHDRAWAL, feesAccrued);
            }
        }
        
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Implementation for beforeDonate hook
     */
    function _beforeDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4)
    {
        return this.beforeDonate.selector; // Should rely on BaseHook revert if not implemented
    }

    /**
     * @notice After Donate hook
     * @dev Processes fees related to donations if reinvestment policy is enabled.
     * @param sender The sender address
     * @param key The pool key
     * @param amount0 Amount of token0 donated
     * @param amount1 Amount of token1 donated
     * @param hookData Additional hook data
     * @return bytes4 Selector for afterDonate hook
     */
    function _afterDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        internal
        virtual
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        return this.afterDonate.selector; // Should rely on BaseHook revert if not implemented
    }

    /**
     * @notice Placeholder for beforeSwapReturnDelta hook (required by ISpotHooks)
     */
    function beforeSwapReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external virtual override returns (bytes4, BeforeSwapDelta) {
        // Return bytes4(0) as the hook is not implemented/used in base Spot
        return (bytes4(0), BeforeSwapDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Placeholder for afterSwapReturnDelta hook (not implemented)
     */
    function afterSwapReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external virtual override returns (bytes4, BalanceDelta) {
        return (ISpotHooks.afterSwapReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Placeholder for afterRemoveLiquidityReturnDelta hook
     * @dev Processes fees similar to afterRemoveLiquidity
     */
    function afterRemoveLiquidityReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external virtual override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        // Track fees reinvestment
        if (poolData[poolId].initialized) {
            // Process fees if any
            if (feesAccrued.amount0() != 0 || feesAccrued.amount1() != 0) {
                _processFees(poolId, IFeeReinvestmentManager.OperationType.WITHDRAWAL, feesAccrued);
            }
        }
        
        return (ISpotHooks.afterRemoveLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Placeholder for afterAddLiquidityReturnDelta hook (not implemented)
     */
    function afterAddLiquidityReturnDelta(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, bytes calldata hookData)
        external
        virtual
        override
        returns (bytes4, BalanceDelta)
    {
        // If this is a self-call from unlockCallback, process fees if needed
        PoolId poolId = key.toId();
        if (poolData[poolId].initialized) {
            // Process fees if any
            _processFees(poolId, IFeeReinvestmentManager.OperationType.DEPOSIT, BalanceDeltaLibrary.ZERO_DELTA);
        }
        
        return (ISpotHooks.afterAddLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Internal function called after a pool is initialized.
     * @dev Sets up initial state, potentially including oracle and fee configurations.
     */
    function _afterPoolInitialized(PoolId poolId, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick) internal virtual {
        // Placeholder for potential logic in inheriting contracts
        // No base implementation needed here beyond what _afterInitializeInternal does
    }

    /**
     * @notice Get oracle data for a specific pool
     * @dev Returns data from TruncGeoOracleMulti when available, falls back to local storage
     * @param poolId The ID of the pool to get oracle data for
     * @return tick The latest recorded tick
     * @return blockTimestamp The block timestamp when the tick was last updated
     */
    function getOracleData(PoolId poolId) external view returns (int24 tick, uint32 blockTimestamp) {
        // Check if oracle is set
        if (address(truncGeoOracle) == address(0)) {
            return (lastFallbackTicks[poolId], lastFallbackBlocks[poolId]);
        }
        
        // Get data directly from oracle - this never reverts even if pool isn't initialized
        (uint32 timestamp, int24 observedTick, , ) = truncGeoOracle.getLastObservation(poolId);
        
        // If we get valid data, return it
        if (timestamp > 0) {
            return (observedTick, timestamp);
        }
        
        // Otherwise fall back to local storage
        return (lastFallbackTicks[poolId], lastFallbackBlocks[poolId]);
    }

    /**
     * @notice Set the TruncGeoOracleMulti address 
     * @dev Only callable by governance
     * @param _oracleAddress The TruncGeoOracleMulti address
     */
    function setOracleAddress(address _oracleAddress) external onlyGovernance {
        if (_oracleAddress == address(0)) revert Errors.ZeroAddress();
        truncGeoOracle = TruncGeoOracleMulti(_oracleAddress);
    }

    // NEW FUNCTION: Setter for Dynamic Fee Manager
    /**
     * @notice Sets the dynamic fee manager address after deployment.
     * @dev Breaks circular dependency during initialization. Can only be called by governance.
     * @param _dynamicFeeManager The address of the deployed dynamic fee manager.
     */
    function setDynamicFeeManager(FullRangeDynamicFeeManager _dynamicFeeManager) external onlyGovernance {
        // Prevent setting if already initialized
        if (address(dynamicFeeManager) != address(0)) revert Errors.AlreadyInitialized("DynamicFeeManager");
        if (address(_dynamicFeeManager) == address(0)) revert Errors.ZeroAddress();
        
        dynamicFeeManager = _dynamicFeeManager;
        activeDynamicFeeManager = _dynamicFeeManager; // Set active manager as well
    }
}