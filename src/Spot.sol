// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

// --- V4 Core Imports (Using src) ---
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";

// --- V4 Periphery Imports (Using Remappings) ---
import { BaseHook } from "v4-periphery/src/utils/BaseHook.sol";
import { IFeeReinvestmentManager } from "./interfaces/IFeeReinvestmentManager.sol";
import { IPoolPolicy } from "./interfaces/IPoolPolicy.sol";
import { IFullRangeLiquidityManager } from "./interfaces/IFullRangeLiquidityManager.sol"; // Use interface
import { FullRangeDynamicFeeManager } from "./FullRangeDynamicFeeManager.sol";
import { TruncatedOracle } from "./libraries/TruncatedOracle.sol";
import { TruncGeoOracleMulti } from "./oracle/TruncGeoOracleMulti.sol";

// --- OZ Imports (Using Remappings) ---
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { ReentrancyGuard } from "solmate/src/utils/ReentrancyGuard.sol";

// --- Project Imports ---
import { ISpot, DepositParams, WithdrawParams } from "./interfaces/ISpot.sol";
import { ISpotHooks } from "./interfaces/ISpotHooks.sol";
import { IUnlockCallback } from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { Errors } from "./errors/Errors.sol";
import { ITruncGeoOracleMulti } from "./interfaces/ITruncGeoOracleMulti.sol";

/**
 * @title Spot
 * @notice Optimized Uniswap V4 Hook contract with minimized bytecode size, supporting multiple pools.
 * @dev Implements ISpot and uses delegate calls to manager contracts for complex logic.
 *      Inherits from BaseHook to provide default hook implementations.
 *      A single instance manages state for multiple pools, identified by PoolId.
 */
contract Spot is BaseHook, ISpot, ISpotHooks, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
        
    // Immutable core contracts and managers
    IPoolPolicy public immutable policyManager;
    IFullRangeLiquidityManager public immutable liquidityManager; // Use interface type
    FullRangeDynamicFeeManager public dynamicFeeManager;
    
    // Optimized storage layout - pack related data together
    // Manages data for multiple pools, keyed by PoolId
    struct PoolData {
        bool initialized;      // Whether pool is initialized *by this hook instance* (1 byte)
        bool emergencyState;   // Whether pool is in emergency (1 byte)
        // Removed tokenId - can be derived from PoolId: uint256(PoolId.unwrap(poolId))
        // No reserves - they'll be calculated on demand via liquidityManager
    }
    
    // Single mapping for pool data instead of multiple mappings
    mapping(bytes32 => PoolData) public poolData; // Keyed by PoolId
    
    // Pool keys stored separately since they're larger structures
    mapping(bytes32 => PoolKey) public poolKeys; // Keyed by PoolId
    
    // Internal callback data structure - minimized to save gas
    // Note: Callback must ensure correct pool context (PoolId)
    struct CallbackData {
        bytes32 poolId;          // Pool ID
        uint8 callbackType;      // 1=deposit, 2=withdraw
        uint128 shares;          // Shares amount
        uint256 amount0;         // Amount of token0
        uint256 amount1;         // Amount of token1
        address recipient;       // Recipient of liquidity
    }
    
    // Events (Ensure PoolId is indexed and bytes32 where applicable)
    event FeeUpdateFailed(bytes32 indexed poolId);
    event ReinvestmentSuccess(bytes32 indexed poolId, uint256 amount0, uint256 amount1);
    event PoolEmergencyStateChanged(bytes32 indexed poolId, bool isEmergency);
    event PolicyInitializationFailed(bytes32 indexed poolId, string reason);
    event Deposit(address indexed sender, bytes32 indexed poolId, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdraw(address indexed sender, bytes32 indexed poolId, uint256 amount0, uint256 amount1, uint256 shares);
    event FeeExtractionProcessed(bytes32 indexed poolId, uint256 amount0, uint256 amount1);
    event FeeExtractionFailed(bytes32 indexed poolId, string reason);
    event OracleTickUpdated(bytes32 indexed poolId, int24 tick, uint32 blockNumber);
    event OracleUpdated(bytes32 indexed poolId, int24 tick, uint32 blockTimestamp);
    event OracleUpdateFailed(bytes32 indexed poolId, int24 uncappedTick, bytes reason);
    event CAPEventDetected(bytes32 indexed poolId, int24 currentTick);
    event OracleInitialized(bytes32 indexed poolId, int24 initialTick, int24 maxAbsTickMove);
    event OracleInitializationFailed(bytes32 indexed poolId, bytes reason);
    
    // Fallback oracle storage (if truncGeoOracle is not set or fails)
    mapping(bytes32 => int24) private oracleTicks;    // Keyed by PoolId
    mapping(bytes32 => uint32) private oracleBlocks;  // Keyed by PoolId
    
    // TruncGeoOracle instance (optional, set via setOracleAddress)
    TruncGeoOracleMulti public truncGeoOracle;
    
    // Modifiers
    modifier onlyGovernance() {
        address currentOwner = policyManager.getSoloGovernance();
        if (msg.sender != currentOwner) {
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
     * @param _manager PoolManager address
     * @param _policyManager PolicyManager address
     * @param _liquidityManager The single LiquidityManager instance this hook will interact with. Must support multiple pools.
     */
    constructor(
        IPoolManager _manager,
        IPoolPolicy _policyManager,
        IFullRangeLiquidityManager _liquidityManager // Use interface
    ) BaseHook(_manager) {
        if (address(_manager) == address(0)) revert Errors.ZeroAddress();
        if (address(_policyManager) == address(0)) revert Errors.ZeroAddress();
        if (address(_liquidityManager) == address(0)) revert Errors.ZeroAddress();

        policyManager = _policyManager;
        liquidityManager = _liquidityManager;
        // No poolId set here anymore
    }

    /**
     * @notice Receive function for ETH payments
     */
    receive() external payable {}

    /**
     * @notice Override `getHookPermissions` to specify which hooks `Spot` uses
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,  // ENABLED
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,  // ENABLED - Required for afterRemoveLiquidityReturnDelta to work
            beforeSwap: true,  // ENABLED
            afterSwap: true,  // ENABLED - Required for afterSwapReturnDelta to work
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,  // ENABLED
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true  // ENABLED
        });
    }

    /**
     * @notice Returns hook address
     */
    function getHookAddress() external view returns (address) {
        return address(this);
    }

    /**
     * @notice Set emergency state for a specific pool managed by this hook
     * @param poolId The Pool ID
     * @param isEmergency The new state
     */
    function setPoolEmergencyState(PoolId poolId, bool isEmergency) external virtual onlyGovernance {
        // Convert PoolId to bytes32 for internal storage access
        bytes32 _poolId = PoolId.unwrap(poolId);
        
        // Check if this hook instance manages the pool
        if (!poolData[_poolId].initialized) revert Errors.PoolNotInitialized(_poolId);
        poolData[_poolId].emergencyState = isEmergency;
        emit PoolEmergencyStateChanged(_poolId, isEmergency);
    }

    /**
     * @notice Deposit into a specific Uniswap V4 pool via this hook
     * @dev Delegates main logic to the single FullRangeLiquidityManager, passing PoolId.
     */
    function deposit(DepositParams calldata params) 
        external 
        virtual
        payable 
        nonReentrant 
        ensure(params.deadline)
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        bytes32 _poolId = PoolId.unwrap(params.poolId); // Convert PoolId to bytes32
        PoolData storage data = poolData[_poolId];
        
        // Validation
        if (!data.initialized) revert Errors.PoolNotInitialized(_poolId);
        if (data.emergencyState) revert Errors.PoolInEmergencyState(_poolId);
        
        // Get pool key to check for native ETH
        PoolKey memory key = poolKeys[_poolId]; // Use _poolId from params
        
        // Validate native ETH usage
        bool hasNative = key.currency0.isAddressZero() || key.currency1.isAddressZero();
        if (msg.value > 0 && !hasNative) revert Errors.NonzeroNativeValue();
        
        // Delegate to the single liquidity manager instance, passing the PoolId directly
        (shares, amount0, amount1) = liquidityManager.deposit{value: msg.value}(
            params.poolId, // Use PoolId directly
            params.amount0Desired,
            params.amount1Desired,
            params.amount0Min,
            params.amount1Min,
            msg.sender // recipient is msg.sender for deposits
        );
        
        emit Deposit(msg.sender, _poolId, amount0, amount1, shares);
        return (shares, amount0, amount1);
    }

    /**
     * @notice Withdraw liquidity from a specific pool via this hook
     * @dev Delegates to the single liquidity manager, passing PoolId.
     */
    function withdraw(WithdrawParams calldata params)
        external
        virtual
        nonReentrant
        ensure(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        bytes32 _poolId = PoolId.unwrap(params.poolId); // Convert PoolId to bytes32
        PoolData storage data = poolData[_poolId];

        // Validation
        if (!data.initialized) revert Errors.PoolNotInitialized(_poolId);
        // Note: Withdrawals might be allowed in emergency state, depending on policy. Add check if needed.
        
        // Delegate to the single liquidity manager instance, passing the PoolId directly
        (amount0, amount1) = liquidityManager.withdraw(
            params.poolId, // Use PoolId directly
            params.sharesToBurn,
            params.amount0Min,
            params.amount1Min,
            msg.sender // recipient is msg.sender for withdrawals
        );
        
        emit Withdraw(msg.sender, _poolId, amount0, amount1, params.sharesToBurn);
        return (amount0, amount1);
    }

    /**
     * @notice Safe transfer token with ETH handling (Internal helper)
     */
    function _safeTransferToken(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        
        Currency currency = Currency.wrap(token);
        if (currency.isAddressZero()) { // Native ETH
            SafeTransferLib.safeTransferETH(to, amount);
        } else { // ERC20 Token
            SafeTransferLib.safeTransfer(ERC20(token), to, amount);
        }
    }

    /**
     * @notice Consolidated fee processing function (Internal helper)
     * @param _poolId The pool ID to process fees for
     * @param opType The operation type triggering the fee processing
     * @param feesAccrued Fees accrued during the operation (can be zero)
     */
    function _processFees(
        bytes32 _poolId,
        IFeeReinvestmentManager.OperationType opType,
        BalanceDelta feesAccrued // Can be zero
    ) internal {
        // Skip if no fees to process or policy manager not set
        if ((feesAccrued.amount0() <= 0 && feesAccrued.amount1() <= 0) || address(policyManager) == address(0)) {
             return;
        }
        
        uint256 fee0 = feesAccrued.amount0() > 0 ? uint256(uint128(feesAccrued.amount0())) : 0;
        uint256 fee1 = feesAccrued.amount1() > 0 ? uint256(uint128(feesAccrued.amount1())) : 0;
        
        address reinvestPolicy = policyManager.getPolicy(PoolId.wrap(_poolId), IPoolPolicy.PolicyType.REINVESTMENT);
        if (reinvestPolicy != address(0)) {
            // Directly call collectFees - if it fails, the whole tx reverts
            // The reinvestment manager handles the actual fee amounts internally
            (bool success, , ) = IFeeReinvestmentManager(reinvestPolicy).collectFees(PoolId.wrap(_poolId), opType);
            if (success) {
                // Emit success, potentially with amounts if returned by collectFees (adjust if needed)
                emit ReinvestmentSuccess(_poolId, fee0, fee1); 
            }
            // Failure case: If collectFees reverts, the transaction reverts. 
            // If it returns false, consider emitting a failure event if needed, though spec implied only success emission.
        }
    }

    /**
     * @notice Internal helper to get pool reserves and shares from the Liquidity Manager
     * @dev Used by both internal and external getPoolInfo functions to avoid code duplication.
     *      The external function adds additional data like tokenId.
     * @param _poolId The pool ID
     * @return isInitialized Whether the pool is managed by *this hook* instance
     * @return reserve0 Current reserve0 from LM
     * @return reserve1 Current reserve1 from LM
     * @return totalShares Current total shares from LM
     */
    function _getPoolReservesAndShares(bytes32 _poolId) 
        internal 
        view 
        returns (
            bool isInitialized,
            uint256 reserve0,
            uint256 reserve1,
            uint128 totalShares
        ) 
    {
        PoolData storage data = poolData[_poolId];
        isInitialized = data.initialized; // Check if this hook manages the pool
        
        if (isInitialized) {
            // Get reserves and shares directly from the liquidity manager for the specific pool
            (reserve0, reserve1) = liquidityManager.getPoolReserves(PoolId.wrap(_poolId));
            totalShares = liquidityManager.poolTotalShares(PoolId.wrap(_poolId));
        }
        // If not initialized by this hook, reserves/shares return as 0 by default
    }

    /**
     * @notice Internal implementation of pool info retrieval
     * @dev Used by the external getPoolInfo function. This internal version provides the core
     *      functionality without the additional tokenId calculation.
     * @param _poolId The pool ID
     * @return isInitialized Whether the pool is initialized *by this hook instance*
     * @return reserves Array of pool reserves [reserve0, reserve1] from LM
     * @return totalShares Total shares in the pool from LM
     */
    function _getPoolInfo(bytes32 _poolId) 
        internal 
        view 
        returns (
            bool isInitialized,
            uint256[2] memory reserves,
            uint128 totalShares
        ) 
    {
        // Call the consolidated external getPoolReservesAndShares function
        uint256 reserve0;
        uint256 reserve1;
        (isInitialized, reserve0, reserve1, totalShares) = _getPoolReservesAndShares(_poolId);
        reserves[0] = reserve0;
        reserves[1] = reserve1;
        isInitialized = poolData[_poolId].initialized; // Still need the hook's initialized status
    }

    /**
     * @notice Checks if a specific pool is initialized and managed by this hook instance.
     * @dev Returns true only if _afterInitialize was successfully called for this poolId.
     *      Intended for external calls and potential overriding by subclasses.
     * @param poolId The pool ID to check.
     * @return True if the pool is initialized and managed by this hook instance.
     */
    function isPoolInitialized(PoolId poolId) external view virtual returns (bool) {
        return poolData[PoolId.unwrap(poolId)].initialized;
    }

    /**
     * @notice Gets the pool key for a pool ID managed by this hook.
     * @dev Validates initialization before returning the key.
     *      Intended for external calls and potential overriding by subclasses.
     * @param poolId The pool ID to get the key for.
     * @return The pool key if initialized.
     */
    function getPoolKey(PoolId poolId) external view virtual returns (PoolKey memory) {
        bytes32 _poolId = PoolId.unwrap(poolId);
        if (!poolData[_poolId].initialized) revert Errors.PoolNotInitialized(_poolId);
        return poolKeys[_poolId];
    }

    /**
     * @notice Get pool information for a specific pool
     * @dev External interface that builds upon the internal _getPoolInfo function,
     *      adding the tokenId calculation for external consumers.
     * @param poolId The pool ID
     * @return isInitialized Whether the pool is initialized
     * @return reserves Array of pool reserves [reserve0, reserve1]
     * @return totalShares Total shares in the pool
     * @return tokenId Token ID for the pool
     */
    function getPoolInfo(PoolId poolId) 
        external 
        view 
        virtual
        returns (
            bool isInitialized,
            uint256[2] memory reserves,
            uint128 totalShares,
            uint256 tokenId
        ) 
    {
        bytes32 _poolId = PoolId.unwrap(poolId);
        (isInitialized, reserves, totalShares) = _getPoolInfo(_poolId);
        return (isInitialized, reserves, totalShares, uint256(_poolId));
    }

    /**
     * @notice Gets the current reserves and total liquidity shares for a pool directly from the Liquidity Manager.
     * @dev Returns 0 if the pool is not initialized in the LiquidityManager or not managed by this hook.
     *      Intended for external calls and potential overriding by subclasses.
     * @param poolId The PoolId of the target pool.
     * @return reserve0 The reserve amount of token0.
     * @return reserve1 The reserve amount of token1.
     * @return totalShares The total liquidity shares outstanding for the pool from LM.
     */
    function getPoolReservesAndShares(PoolId poolId) external view virtual returns (uint256 reserve0, uint256 reserve1, uint128 totalShares) {
        bytes32 _poolId = PoolId.unwrap(poolId);
        if (poolData[_poolId].initialized) { // Check if this hook manages the pool
            // Get reserves and shares directly from the liquidity manager for the specific pool
            (reserve0, reserve1) = liquidityManager.getPoolReserves(poolId); // Use PoolId directly
            totalShares = liquidityManager.poolTotalShares(poolId); // Use PoolId directly
        }
        // If not initialized by this hook, reserves/shares return as 0 by default
    }

    /**
     * @notice Gets the token ID associated with a specific pool.
     * @param poolId The PoolId of the target pool.
     * @return The ERC1155 token ID representing the pool's LP shares.
     */
    function getPoolTokenId(PoolId poolId) external view virtual returns (uint256) {
        return uint256(PoolId.unwrap(poolId));
    }

    /**
     * @notice Callback function for Uniswap V4 unlock pattern
     * @dev Called by the pool manager during deposit/withdraw operations originating from this hook.
     *      Must correctly route based on PoolId in callback data.
     */
    function unlockCallback(bytes calldata data) external override(IUnlockCallback) returns (bytes memory) {
        // Only callable by the PoolManager associated with this hook instance
        // if (msg.sender != address(poolManager)) revert Errors.CallerNotPoolManager(msg.sender); // Pass caller address

        CallbackData memory cbData = abi.decode(data, (CallbackData));
        bytes32 _poolId = cbData.poolId;

        // Ensure this hook instance actually manages this poolId
        if (!poolData[_poolId].initialized) revert Errors.PoolNotInitialized(_poolId); 

        PoolKey memory key = poolKeys[_poolId]; // Use the stored key for this poolId

        // Define ModifyLiquidityParams - same for deposit/withdraw, only liquidityDelta differs
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(key.tickSpacing),
            tickUpper: TickMath.maxUsableTick(key.tickSpacing),
            liquidityDelta: 0, // Will be set below
            salt: bytes32(0) // Salt not typically used in basic LM
        });

        if (cbData.callbackType == 1) { // Deposit
            params.liquidityDelta = int256(uint256(cbData.shares)); // Positive delta
        } else if (cbData.callbackType == 2) { // Withdraw
            params.liquidityDelta = -int256(uint256(cbData.shares)); // Negative delta
        } else {
            revert("Unknown callback type"); // Should not happen
        }

        // Call modifyLiquidity on the PoolManager for the correct pool
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, params, ""); // Hook data not needed here

        // Return the resulting balance delta
        return abi.encode(delta);
    }

    // --- Hook Implementations ---

    /**
     * @notice Internal function containing the core logic for afterInitialize.
     * @dev Initializes pool-specific state within this hook instance's mappings. Overrides BaseHook.
     */
    function _afterInitialize(
        address sender, // PoolManager
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal virtual override returns (bytes4) {
        bytes32 _poolId = PoolId.unwrap(key.toId());

        // Prevent re-initialization *for this hook instance*
        if (poolData[_poolId].initialized) revert Errors.PoolAlreadyInitialized(_poolId);
        if (sqrtPriceX96 == 0) revert Errors.InvalidPrice(sqrtPriceX96); // Should be checked by PM, but good safeguard

        // Store PoolKey for later use (e.g., in callbacks)
        poolKeys[_poolId] = key;
        
        // Mark pool as initialized *within this hook instance*
        poolData[_poolId] = PoolData({
            initialized: true,       // Mark this pool as managed by this instance
            emergencyState: false    // Default emergency state
        });

        // --- External Interactions (Optional / Configurable) ---

        // 1. Liquidity Manager Interaction (Removed)
        // Assumption: The single LM instance handles pools implicitly based on PoolId passed in calls.
        // If the LM *requires* explicit registration, add a call here, e.g.:
        // if (address(liquidityManager) != address(0)) {
        //     liquidityManager.registerPool(PoolId.wrap(_poolId), key, sqrtPriceX96); // Requires LM interface update
        // } else {
        //     revert Errors.NotInitialized("LiquidityManager"); // If LM is mandatory
        // }

        // 2. Oracle Initialization (If applicable and hook matches)
        if (address(truncGeoOracle) != address(0) && address(key.hooks) == address(this)) {
            // Check if oracle already enabled for this pool (optional safeguard)
            // if (!truncGeoOracle.isOracleEnabled(PoolId.wrap(_poolId))) { // Wrap _poolId
                int24 maxAbsTickMove = TruncatedOracle.MAX_ABS_TICK_MOVE; // Or get from config
                try truncGeoOracle.enableOracleForPool(key, maxAbsTickMove) {
                     emit OracleInitialized(_poolId, tick, maxAbsTickMove);
                } catch (bytes memory reason) {
                    emit OracleInitializationFailed(_poolId, reason);
                    // Decide if this failure should revert initialization (likely yes)
                    // revert Errors.OracleSetupFailed(_poolId, reason); 
                }
            // }
        }

        // 3. Policy Manager Interaction (If applicable)
        if (address(policyManager) != address(0)) {
            try policyManager.handlePoolInitialization(PoolId.wrap(_poolId), key, sqrtPriceX96, tick, address(this)) { // Wrap _poolId
                // Success, potentially emit event if needed
            } catch (bytes memory reason) {
                 emit PolicyInitializationFailed(_poolId, string(reason)); // Assuming reason is string
                 // Decide if policy failure should revert initialization
                 // revert Errors.PolicySetupFailed(_poolId, string(reason));
            }
        }

        // Update Policy Manager
        if (address(policyManager) != address(0)) {
            policyManager.handlePoolInitialization(PoolId.wrap(_poolId), key, sqrtPriceX96, tick, address(this));
        }

        // Store the PoolKey in the Liquidity Manager
        if (address(liquidityManager) != address(0)) {
            liquidityManager.storePoolKey(PoolId.wrap(_poolId), key);
        }

        // Return the required selector
        return BaseHook.afterInitialize.selector;
    }

    /**
     * @notice Internal implementation for beforeSwap logic. Overrides BaseHook.
     * @dev Retrieves dynamic fee from the fee manager for the specific pool.
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, BeforeSwapDelta, uint24) {
        // Ensure dynamic fee manager is set
        if (address(dynamicFeeManager) == address(0)) revert Errors.NotInitialized("DynamicFeeManager");

        bytes32 _poolId = PoolId.unwrap(key.toId());
        uint24 dynamicFee = uint24(dynamicFeeManager.getCurrentDynamicFee(PoolId.wrap(_poolId)));

        // Return selector, zero delta adjustment, and the dynamic fee
        return (
            BaseHook.beforeSwap.selector, 
            BeforeSwapDeltaLibrary.ZERO_DELTA, // Spot hook doesn't adjust balances before swap
            dynamicFee
        );
    }

    /**
     * @notice Internal function containing the core logic for afterSwap. Overrides BaseHook.
     * @dev Updates the oracle observation for the specific pool if conditions met.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, int128) {
        bytes32 _poolId = PoolId.unwrap(key.toId());

        // Check if oracle exists, pool is managed here, and this hook is the registered hook for the pool
        if (address(truncGeoOracle) != address(0) && poolData[_poolId].initialized && address(key.hooks) == address(this)) {
            // It's redundant to check key.hooks == address(this) if PoolManager routing is correct, but adds safety.
            
            // Fetch the current tick directly after the swap
            (, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, PoolId.wrap(_poolId));

            // Check if the oracle conditions require an update
            bool shouldUpdateOracle = ITruncGeoOracleMulti(address(truncGeoOracle)).shouldUpdateOracle(PoolId.wrap(_poolId));
            if (shouldUpdateOracle) {
                 try truncGeoOracle.updateObservation(key) {
                    emit OracleUpdated(_poolId, currentTick, uint32(block.timestamp));
                 } catch (bytes memory reason) {
                    emit OracleUpdateFailed(_poolId, currentTick, reason);
                    // Non-critical failure, likely don't revert swap
                 }
            }
        }
        // Return selector and 0 kiss fee (hook takes no fee percentage from swap)
        return (BaseHook.afterSwap.selector, 0);
    }

    /**
     * @notice Internal function containing the core logic for afterAddLiquidity. Overrides BaseHook.
     * @dev Currently only returns selector; fee processing could be added if needed for deposits.
     */
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued, // Likely zero on initial add
        bytes calldata hookData
    ) internal virtual override returns (bytes4, BalanceDelta) {
        bytes32 _poolId = PoolId.unwrap(key.toId());

        // Optional: Process fees accrued during add liquidity (uncommon for standard full-range add)
        // _processFees(_poolId, IFeeReinvestmentManager.OperationType.DEPOSIT, feesAccrued);

        // Return selector and zero delta hook fee adjustment
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

     /**
     * @notice Internal function containing the core logic for afterRemoveLiquidity. Overrides BaseHook.
     * @dev Processes fees accrued by the liquidity position being removed.
     */
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued, // Fees collected by this LP position
        bytes calldata hookData
    ) internal virtual override returns (bytes4, BalanceDelta) {
        bytes32 _poolId = PoolId.unwrap(key.toId());

        // Process any fees collected by the liquidity being removed
        _processRemoveLiquidityFees(_poolId, feesAccrued);

        // Return selector and zero delta hook fee adjustment
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // --- ISpotHooks Delta-Returning Implementations ---
    // These are required by ISpotHooks and typically call the corresponding internal logic.
    // They return the delta adjustment made by the hook (usually zero for Spot).

    /**
     * @notice Implementation for beforeSwapReturnDelta hook (required by ISpotHooks)
     * @dev Calls the internal _beforeSwap logic and returns the delta (which is zero for Spot)
     */
    function beforeSwapReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override(ISpotHooks) returns (bytes4, BeforeSwapDelta) {
         // Basic validation (redundant if external beforeSwap called first, but safe)
        if (msg.sender != address(poolManager)) revert Errors.CallerNotPoolManager(msg.sender);
        
        bytes32 _poolId = PoolId.unwrap(key.toId());
        
        // Call internal logic to get delta (and dynamic fee, ignored here)
        (, BeforeSwapDelta delta, ) = _beforeSwap(sender, key, params, hookData);

        // Return selector and the BeforeSwapDelta (should be ZERO_DELTA)
        return (
            ISpotHooks.beforeSwapReturnDelta.selector,
            delta 
        );
    }

    /**
     * @notice Implementation for afterSwapReturnDelta hook (required by ISpotHooks)
     * @dev Calls internal _afterSwap logic. Returns zero BalanceDelta.
     */
    function afterSwapReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override(ISpotHooks) returns (bytes4, BalanceDelta) {
        // Basic validation
        if (msg.sender != address(poolManager)) revert Errors.CallerNotPoolManager(msg.sender);
        
        bytes32 _poolId = PoolId.unwrap(key.toId());
        
        // Call internal logic (updates oracle, etc.) - kiss fee ignored here
        _afterSwap(sender, key, params, delta, hookData);

        // Return selector and ZERO_DELTA for hook fee adjustment
        return (ISpotHooks.afterSwapReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Implementation for afterRemoveLiquidityReturnDelta hook (required by ISpotHooks)
     * @dev Calls internal _afterRemoveLiquidity logic. Returns zero BalanceDelta.
     */
    function afterRemoveLiquidityReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override(ISpotHooks) returns (bytes4, BalanceDelta) {
        // Basic validation
        if (msg.sender != address(poolManager)) revert Errors.CallerNotPoolManager(msg.sender);

        bytes32 _poolId = PoolId.unwrap(key.toId());

        // Call internal logic (processes fees, etc.)
        _afterRemoveLiquidity(sender, key, params, delta, feesAccrued, hookData);

        // Return selector and ZERO_DELTA for hook fee adjustment
        return (ISpotHooks.afterRemoveLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
    
    /**
     * @notice Implementation for afterAddLiquidityReturnDelta hook (required by ISpotHooks)
     * @dev Calls internal _afterAddLiquidity logic. Returns zero BalanceDelta.
     */
    function afterAddLiquidityReturnDelta(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData 
    ) external override(ISpotHooks) returns (bytes4, BalanceDelta) {
        // Basic validation
        if (msg.sender != address(poolManager)) revert Errors.CallerNotPoolManager(msg.sender);

        bytes32 _poolId = PoolId.unwrap(key.toId());

        // Call internal logic (currently minimal for add liquidity)
        // Passing ZERO_DELTA for feesAccrued based on current _afterAddLiquidity impl.
        _afterAddLiquidity(sender, key, params, delta, BalanceDeltaLibrary.ZERO_DELTA, hookData); 

        // Return selector and ZERO_DELTA for hook fee adjustment
        return (ISpotHooks.afterAddLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA); 
    }

    /**
     * @notice Internal helper to process fees after liquidity removal for a specific pool
     */
    function _processRemoveLiquidityFees(bytes32 _poolId, BalanceDelta feesAccrued) internal {
        // Only process if pool managed by hook, fees exist, and policy manager is set
        if (poolData[_poolId].initialized && (feesAccrued.amount0() != 0 || feesAccrued.amount1() != 0) && address(policyManager) != address(0)) {
            
             address reinvestPolicy = policyManager.getPolicy(PoolId.wrap(_poolId), IPoolPolicy.PolicyType.REINVESTMENT);
             if (reinvestPolicy != address(0)) {
                 try IFeeReinvestmentManager(reinvestPolicy).collectFees(PoolId.wrap(_poolId), IFeeReinvestmentManager.OperationType.WITHDRAWAL) returns (bool success, uint256 collected0, uint256 collected1) {
                     if (success) {
                         emit ReinvestmentSuccess(_poolId, collected0, collected1);
                     } else {
                         emit FeeExtractionFailed(_poolId, "Reinvestment manager returned false");
                     }
                 } catch (bytes memory reason) {
                     emit FeeExtractionFailed(_poolId, string(reason));
                 }
             }
        }
    }

    // --- Oracle Functionality ---

    /**
     * @notice Get oracle data for a specific pool
     * @dev Used by DynamicFeeManager to pull data
     * @param poolId The ID of the pool to get oracle data for
     * @return tick The latest recorded tick
     * @return blockNumber The block number when the tick was last updated
     */
    function getOracleData(PoolId poolId) external view virtual returns (int24 tick, uint32 blockNumber) {
        bytes32 _poolId = PoolId.unwrap(poolId);
        // If TruncGeoOracle is set and enabled for this pool, use it
        if (address(truncGeoOracle) != address(0) && truncGeoOracle.isOracleEnabled(poolId)) {
            // Get the latest observation from the oracle
            try truncGeoOracle.getLatestObservation(poolId) returns (int24 _tick, uint32 _blockTimestamp) {
                return (_tick, _blockTimestamp); // Return the latest tick and timestamp
            } catch {
                // Fall back to simple mapping storage if the oracle call fails
            }
        }
        
        // Default to the stored values from the hook's internal storage
        return (oracleTicks[_poolId], oracleBlocks[_poolId]);
    }

    /**
     * @notice Set the TruncGeoOracleMulti address 
     * @dev Only callable by governance. Allows setting/updating the oracle contract.
     * @param _oracleAddress The TruncGeoOracleMulti address (or address(0) to disable)
     */
    function setOracleAddress(address _oracleAddress) external onlyGovernance {
        if (_oracleAddress != address(0) && !isValidContract(_oracleAddress)) {
             revert Errors.ValidationInvalidAddress(_oracleAddress);
        }
        truncGeoOracle = TruncGeoOracleMulti(payable(_oracleAddress));
    }

    /**
     * @notice Sets the dynamic fee manager address after deployment.
     * @dev Breaks circular dependency during initialization. Can only be called by governance.
     * @param _dynamicFeeManager The address of the deployed dynamic fee manager.
     */
    function setDynamicFeeManager(address _dynamicFeeManager) external onlyGovernance {
        if (address(dynamicFeeManager) != address(0)) revert Errors.AlreadyInitialized("DynamicFeeManager");
        if (_dynamicFeeManager == address(0)) revert Errors.ZeroAddress();
        if (!isValidContract(_dynamicFeeManager)) {
            revert Errors.ValidationInvalidAddress(_dynamicFeeManager);
        }
        
        dynamicFeeManager = FullRangeDynamicFeeManager(payable(_dynamicFeeManager));
    }

    // --- Internal Helpers ---

    /**
     * @dev Internal helper to check if an address holds code. Basic check.
     */
    function isValidContract(address _addr) internal view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }
        return size > 0;
    }
}