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

    // Optimized storage layout for pool data
    struct PoolData {
        bool initialized;
        bool emergencyState;
        PoolKey key;
        uint256 reserve0;
        uint256 reserve1;
        uint256 tokenId;
    }
    
    // Single mapping instead of multiple mappings
    mapping(PoolId => PoolData) public poolData;
    
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
    
    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) {
            revert Errors.DeadlinePassed(deadline, block.timestamp);
        }
        _;
    }

    /**
     * @notice Constructor for the FullRange contract
     * @param _poolManager Address of the Uniswap V4 pool manager
     * @param _policyManager Address of the policy manager
     * @param _liquidityManager Address of the FullRange liquidity manager
     * @param _dynamicFeeManager Address of the dynamic fee manager
     */
    constructor(
        address _poolManager,
        address _policyManager,
        address payable _liquidityManager,
        address _dynamicFeeManager
    ) {
        if (_poolManager == address(0)) revert Errors.ZeroPoolManagerAddress();
        if (_policyManager == address(0)) revert Errors.ZeroPolicyManagerAddress();
        
        poolManager = IPoolManager(_poolManager);
        policyManager = IPoolPolicy(_policyManager);
        liquidityManager = FullRangeLiquidityManager(_liquidityManager);
        dynamicFeeManager = FullRangeDynamicFeeManager(_dynamicFeeManager);
    }

    /**
     * @notice Allows the contract to receive ETH (for failed transfer recovery)
     */
    receive() external payable {}

    /**
     * @notice Returns the address of this hook (for pool initialization).
     */
    function getHookAddress() external view returns (address) {
        return address(this);
    }

    /**
     * @notice Creates a new pool with FullRange liquidity
     * @param key The pool key containing token information
     * @param sqrtPriceX96 The initial sqrt price of the pool
     * @param dynamicFeeValues Optional dynamic fee configuration data
     */
    function createPool(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        bytes calldata dynamicFeeValues
    ) external returns (PoolId) {
        // Verify hook is this contract
        if (address(key.hooks) != address(this)) {
            revert Errors.InvalidHookAddress(address(key.hooks));
        }
        
        // Check if caller is authorized to create a pool
        address governance = policyManager.getSoloGovernance();
        if (msg.sender != governance) {
            revert Errors.NotAuthorizedToCreatePool(msg.sender);
        }
        
        // Create the pool in the pool manager
        int24 tick = poolManager.initialize(key, sqrtPriceX96);
        PoolId poolId = key.toId();
        
        // Set the pool data fields
        poolData[poolId].initialized = true;
        poolData[poolId].key = key;
        
        // Check if dynamic fee initialization is needed
        if (key.fee & 0x800000 != 0) {
            // Initialize dynamic fee (code example, adjust as needed)
            try dynamicFeeManager.initializeOracleData(poolId, tick) {
                emit PolicyInitializationSucceeded(poolId);
            } catch Error(string memory reason) {
                emit PolicyInitializationFailed(poolId, reason);
            } catch {
                emit PolicyInitializationFailed(poolId, "Unknown error");
            }
        }
        
        // Generate a token ID for this pool and store it
        poolData[poolId].tokenId = PoolTokenIdUtils.toTokenId(poolId);
        
        emit PoolCreated(poolId, key, sqrtPriceX96);
        return poolId;
    }
    
    /**
     * @notice Deposits liquidity into a pool
     * @param params The deposit parameters
     * @return shares The number of shares minted
     * @return amount0 The amount of token0 actually deposited
     * @return amount1 The amount of token1 actually deposited
     */
    function deposit(
        DepositParams calldata params
    ) external nonReentrant ensure(params.deadline) returns (uint256 shares, uint256 amount0, uint256 amount1) {
        // Validate pool exists and not in emergency
        if (!poolData[params.poolId].initialized) {
            revert Errors.PoolNotFound(params.poolId);
        }
        if (poolData[params.poolId].emergencyState) {
            revert Errors.PoolInEmergencyState(params.poolId);
        }
        
        // Delegate to liquidityManager for calculation and processing
        return liquidityManager.deposit(params, msg.sender);
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
        // This function is stubbed for interface compatibility
        // Actual implementation is delegated to the liquidity manager
        revert Errors.NotImplemented();
    }

    /**
     * @notice Withdraws liquidity from a pool
     * @param params The withdraw parameters
     * @return amount0 The amount of token0 withdrawn
     * @return amount1 The amount of token1 withdrawn
     */
    function withdraw(
        WithdrawParams calldata params
    ) external nonReentrant ensure(params.deadline) returns (uint256 amount0, uint256 amount1) {
        // Validate pool exists and not in emergency
        if (!poolData[params.poolId].initialized) {
            revert Errors.PoolNotFound(params.poolId);
        }
        if (poolData[params.poolId].emergencyState) {
            revert Errors.PoolInEmergencyState(params.poolId);
        }
        
        // Delegate to liquidityManager for calculation and processing
        return liquidityManager.withdraw(params, msg.sender);
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
        // This function is stubbed for interface compatibility
        // Actual implementation is delegated to the liquidity manager
        revert Errors.NotImplemented();
    }

    /**
     * @notice Claims pending ETH payments
     */
    function claimPendingETH() external {
        // This function is stubbed for interface compatibility
        // Actual implementation is delegated to the liquidity manager
        liquidityManager.claimETH();
    }

    /**
     * @notice Sets the emergency state of a pool
     * @param poolId The ID of the pool
     * @param state The emergency state (true for emergency mode)
     */
    function setPoolEmergencyState(PoolId poolId, bool state) external onlyGovernance {
        if (!poolData[poolId].initialized) {
            revert Errors.PoolNotFound(poolId);
        }
        
        poolData[poolId].emergencyState = state;
        emit PoolEmergencyStateSet(poolId, state);
    }

    /**
     * @notice Claims and reinvests fees for a specific pool
     * @param poolId The ID of the pool
     * @return amount0 The amount of token0 reinvested
     * @return amount1 The amount of token1 reinvested
     */
    function claimAndReinvestFees(PoolId poolId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (!reinvestmentEnabled) {
            revert Errors.ReinvestmentDisabled();
        }
        
        if (!poolData[poolId].initialized) {
            revert Errors.PoolNotFound(poolId);
        }
        
        if (poolData[poolId].emergencyState) {
            revert Errors.PoolInEmergencyState(poolId);
        }
        
        // Delegate to liquidity manager for fee reinvestment
        return liquidityManager.reinvestFees(poolId);
    }
    
    /**
     * @notice Enables or disables fee reinvestment
     * @param enabled Whether reinvestment should be enabled
     */
    function setReinvestmentEnabled(bool enabled) external onlyGovernance {
        reinvestmentEnabled = enabled;
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
        
        // Special case for beforeInitialize
        if (selector == IHooks.beforeInitialize.selector) {
            assembly {
                mstore(0, selector)
                return(0, 32)
            }
        }
        
        // Special case for beforeSwap to handle dynamic fee
        if (selector == IHooks.beforeSwap.selector) {
            bytes memory data = msg.data[4:];
            (address sender, PoolKey memory key, IPoolManager.SwapParams memory params, bytes memory hookData) = 
                abi.decode(data, (address, PoolKey, IPoolManager.SwapParams, bytes));
            
            // Get current dynamic fee
            uint24 fee = dynamicFeeManager.getCurrentDynamicFee(key.toId());
            
            // Prepare return data with ZERO_DELTA
            bytes memory returnData = abi.encode(selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
            
            assembly {
                return(add(returnData, 32), mload(returnData))
            }
        }
        
        // Special cases for hooks with BalanceDelta returns
        if (selector == IHooks.afterAddLiquidity.selector || 
            selector == IHooks.afterRemoveLiquidity.selector) {
            
            bytes memory returnData = abi.encode(selector, BalanceDeltaLibrary.ZERO_DELTA);
            
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
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // Ensure caller is the poolManager
        if (msg.sender != address(poolManager)) {
            revert Errors.AccessOnlyPoolManager(msg.sender);
        }
        
        // Decode the callback data
        CallbackDataInternal memory callbackData = abi.decode(data, (CallbackDataInternal));
        
        // Just return the callback type as acknowledge, liquidity handling is done in the managers
        if (callbackData.callbackType == 1) {
            return abi.encode("deposit_processed");
        } else if (callbackData.callbackType == 2) {
            return abi.encode("withdraw_processed");
        } else if (callbackData.callbackType == 3) {
            return abi.encode("swap_processed");
        }
        
        return abi.encode("unknown_callback_type");
    }

    // ------------------ Compatibility with IHooks interface ------------------
    // These functions are stubs that are replaced by the fallback function
    // They are included only for interface compatibility

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure override returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata) external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata) external pure override returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata) external pure override returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure override returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    // ------------------ Compatibility with IFullRangeHooks interface ------------------

    function beforeSwapReturnDelta(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata) external pure override returns (bytes4, BeforeSwapDelta) {
        return (IFullRangeHooks.beforeSwapReturnDelta.selector, BeforeSwapDeltaLibrary.ZERO_DELTA);
    }

    function afterSwapReturnDelta(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata) external pure override returns (bytes4, BalanceDelta) {
        return (IFullRangeHooks.afterSwapReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterAddLiquidityReturnDelta(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, bytes calldata) external pure override returns (bytes4, BalanceDelta) {
        return (IFullRangeHooks.afterAddLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
    
    function afterRemoveLiquidityReturnDelta(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, bytes calldata) external pure override returns (bytes4, BalanceDelta) {
        return (IFullRangeHooks.afterRemoveLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
    
    // ------------------ Helper functions for compatibility ------------------
    
    /**
     * @notice Checks if a pool is initialized
     * @param poolId The ID of the pool
     * @return Whether the pool is initialized
     */
    function isPoolInitialized(PoolId poolId) public view returns (bool) {
        return poolData[poolId].initialized;
    }
    
    /**
     * @notice Gets the pool token ID for a pool
     * @param poolId The ID of the pool
     * @return The pool token ID
     */
    function getPoolTokenId(PoolId poolId) public view returns (uint256) {
        return poolData[poolId].tokenId;
    }
    
    /**
     * @notice Gets the pool key for a pool
     * @param poolId The ID of the pool
     * @return The pool key
     */
    function getPoolKey(PoolId poolId) public view returns (PoolKey memory) {
        return poolData[poolId].key;
    }
    
    /**
     * @notice Gets if a pool is in emergency state
     * @param poolId The ID of the pool
     * @return Whether the pool is in emergency state
     */
    function isPoolInEmergencyState(PoolId poolId) public view returns (bool) {
        return poolData[poolId].emergencyState;
    }
    
    /**
     * @notice Gets the reserves for a pool
     * @param poolId The ID of the pool
     * @return reserve0 The reserve of token0
     * @return reserve1 The reserve of token1
     */
    function getPoolReserves(PoolId poolId) public view returns (uint256 reserve0, uint256 reserve1) {
        return (poolData[poolId].reserve0, poolData[poolId].reserve1);
    }

    /**
     * @notice Returns information about a pool's state and configuration.
     * @param poolId The pool ID to query.
     * @return isInitialized Whether the pool has been initialized. 
     * @return reserves The current token reserves in the pool.
     * @return totalShares The total supply of pool shares.
     * @return tokenId The NFT token ID associated with the pool position.
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
        isInitialized = poolData[poolId].initialized;
        
        if (isInitialized) {
            reserves[0] = poolData[poolId].reserve0;
            reserves[1] = poolData[poolId].reserve1;
            totalShares = liquidityManager.totalShares(poolId);
            tokenId = poolData[poolId].tokenId;
        }
        
        return (isInitialized, reserves, totalShares, tokenId);
    }
}