// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";
import {Errors} from "./errors/Errors.sol";
import {FullRangeDynamicFeeManager} from "./FullRangeDynamicFeeManager.sol";
import {FullRangeLiquidityManager} from "./FullRangeLiquidityManager.sol";
import {IFeeReinvestmentManager} from "./interfaces/IFeeReinvestmentManager.sol";

/**
 * @title HookHandler
 * @notice Unified handler for Uniswap V4 hooks with optimized dispatch mechanism
 * @dev Uses a hybrid approach with a mapping for common hooks and if/else for complex initialization hooks
 */
contract HookHandler {
    using PoolIdLibrary for PoolKey;
    
    // =========================================================================
    // Constants for hook selectors
    // =========================================================================
    // Using constants instead of hardcoded selectors improves readability
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

    // Constants for handler function selectors
    bytes4 internal constant DISPATCH_AND_EXECUTE_SELECTOR = this.dispatchAndExecute.selector;

    // =========================================================================
    // State variables
    // =========================================================================
    // References to required contracts
    IPoolPolicy public immutable policyManager;
    IPoolManager public immutable poolManager;
    address public immutable fullRangeAddress;
    FullRangeDynamicFeeManager public immutable dynamicFeeManager;
    FullRangeLiquidityManager public immutable liquidityManager;
    
    // Mapping of hook selectors to handler function selectors
    // Used for frequently called hooks (O(1) lookup)
    mapping(bytes4 => bytes4) public hookHandlers;
    
    // =========================================================================
    // Events
    // =========================================================================
    event PolicyInitializationFailed(PoolId indexed poolId, bytes reason);
    event PoolInitialized(PoolId indexed poolId, PoolKey key, uint160 sqrtPrice, address sender);
    event FeeUpdateFailed(PoolId indexed poolId);
    event OracleUpdateFailed(PoolId indexed poolId);
    event HookHandled(bytes4 indexed selector);
    event ReinvestmentProcessed(PoolId indexed poolId);
    
    /**
     * @notice Constructor initializes contract dependencies and sets up the hook handler mapping
     * @param _policyManager The policy manager contract
     * @param _poolManager The pool manager contract
     * @param _fullRangeAddress The address of the FullRange contract
     * @param _dynamicFeeManager The dynamic fee manager contract
     * @param _liquidityManager The liquidity manager contract
     */
    constructor(
        IPoolPolicy _policyManager,
        IPoolManager _poolManager,
        address _fullRangeAddress,
        FullRangeDynamicFeeManager _dynamicFeeManager,
        FullRangeLiquidityManager _liquidityManager
    ) {
        // Validate parameters
        if (address(_policyManager) == address(0)) revert Errors.ValidationZeroAddress("policyManager");
        if (address(_poolManager) == address(0)) revert Errors.ValidationZeroAddress("poolManager");
        if (_fullRangeAddress == address(0)) revert Errors.ValidationZeroAddress("fullRange");
        if (address(_dynamicFeeManager) == address(0)) revert Errors.ValidationZeroAddress("dynamicFeeManager");
        if (address(_liquidityManager) == address(0)) revert Errors.ValidationZeroAddress("liquidityManager");
        
        policyManager = _policyManager;
        poolManager = _poolManager;
        fullRangeAddress = _fullRangeAddress;
        dynamicFeeManager = _dynamicFeeManager;
        liquidityManager = _liquidityManager;
        
        // Initialize the hook handler mapping for frequent hooks
        // This provides O(1) lookups for common operations
        hookHandlers[BEFORE_SWAP_SELECTOR] = this.handleBeforeSwap.selector;
        hookHandlers[AFTER_SWAP_SELECTOR] = this.handleAfterSwap.selector;
        hookHandlers[BEFORE_ADD_LIQUIDITY_SELECTOR] = this.handleBeforeAddLiquidity.selector;
        hookHandlers[AFTER_ADD_LIQUIDITY_SELECTOR] = this.handleAfterAddLiquidity.selector;
        hookHandlers[BEFORE_REMOVE_LIQUIDITY_SELECTOR] = this.handleBeforeRemoveLiquidity.selector;
        hookHandlers[AFTER_REMOVE_LIQUIDITY_SELECTOR] = this.handleAfterRemoveLiquidity.selector;
        hookHandlers[BEFORE_DONATE_SELECTOR] = this.handleBeforeDonate.selector;
        hookHandlers[AFTER_DONATE_SELECTOR] = this.handleAfterDonate.selector;
        
        // Note: We intentionally don't map initialization hooks as they require special handling
        // and more complex parameter decoding. They will be handled via if/else for clarity.
    }
    
    /**
     * @notice Validates pool parameters for initialization
     * @param sender The sender of the initialize call
     * @param key The pool key
     * @param sqrtPriceX96 The initial sqrt price
     * @return selector The hook selector to return
     */
    function validatePoolParameters(
        address sender,
        PoolKey memory key,
        uint160 sqrtPriceX96
    ) public view returns (bytes4 selector) {
        // Check hook address
        if (address(key.hooks) != fullRangeAddress) {
            revert Errors.HookInvalidAddress(address(key.hooks));
        }
        
        // Get pool ID
        PoolId poolId = key.toId();
        
        // Validate initial sqrt price is within valid range
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 > TickMath.MAX_SQRT_PRICE) {
            revert Errors.PoolTickOutOfRange(
                TickMath.getTickAtSqrtPrice(sqrtPriceX96),
                TickMath.MIN_TICK,
                TickMath.MAX_TICK
            );
        }
        
        // Validate pool parameters via policy
        // Use direct call instead of try/catch
        // This won't revert even if validation fails
        (bool success, bytes memory returnData) = address(policyManager).staticcall(
            abi.encodeWithSelector(
                IPoolPolicy.isValidVtier.selector,
                key.fee,
                key.tickSpacing
            )
        );
        
        // If call succeeded and returned false, revert with invalid parameters
        if (success && returnData.length >= 32) {
            bool isValid = abi.decode(returnData, (bool));
            if (!isValid) {
                revert Errors.PoolInvalidFeeOrTickSpacing(key.fee, key.tickSpacing);
            }
        }
        
        return BEFORE_INITIALIZE_SELECTOR;
    }
    
    /**
     * @notice Processes pool initialization through the policy system
     * @param sender The sender of the initialize call
     * @param key The pool key
     * @param sqrtPriceX96 The initial sqrt price
     * @param tick The initial tick
     * @return selector The hook selector to return
     */
    function processPoolInitialization(
        address sender,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        int24 tick
    ) public returns (bytes4 selector) {
        // Get pool ID
        PoolId poolId = key.toId();
        
        // Register pool with liquidity manager - no try/catch
        (bool regSuccess,) = address(liquidityManager).call(
            abi.encodeWithSelector(
                FullRangeLiquidityManager.registerPool.selector,
                poolId,
                key,
                sqrtPriceX96
            )
        );
        
        // Initialize fee manager - no try/catch
        (bool feeSuccess,) = address(dynamicFeeManager).call(
            abi.encodeWithSelector(
                FullRangeDynamicFeeManager.initializeFeeData.selector,
                poolId
            )
        );
        
        if (!feeSuccess) {
            emit FeeUpdateFailed(poolId);
        }
        
        // Initialize dynamic fee oracle data - no try/catch
        (bool oracleSuccess,) = address(dynamicFeeManager).call(
            abi.encodeWithSelector(
                FullRangeDynamicFeeManager.initializeOracleData.selector,
                poolId,
                tick
            )
        );
        
        if (!oracleSuccess) {
            emit OracleUpdateFailed(poolId);
        }
        
        // Initialize policies - no try/catch
        (bool policySuccess, bytes memory returnData) = address(policyManager).call(
            abi.encodeWithSelector(
                IPoolPolicy.handlePoolInitialization.selector,
                poolId,
                key,
                sqrtPriceX96,
                tick,
                fullRangeAddress
            )
        );
        
        if (!policySuccess) {
            emit PolicyInitializationFailed(poolId, returnData);
        }
        
        emit PoolInitialized(poolId, key, sqrtPriceX96, sender);
        
        return AFTER_INITIALIZE_SELECTOR;
    }

    /**
     * @notice Handler for beforeInitialize hook
     */
    function handleBeforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) external view returns (bytes4) {
        return validatePoolParameters(sender, key, sqrtPriceX96);
    }

    /**
     * @notice Handler for afterInitialize hook
     */
    function handleAfterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) external returns (bytes4) {
        return processPoolInitialization(sender, key, sqrtPriceX96, tick);
    }

    /**
     * @notice Handle beforeSwap hook calls
     */
    function handleBeforeSwap(
        address sender, 
        PoolKey calldata key, 
        IPoolManager.SwapParams calldata params, 
        bytes calldata hookData
    ) external view returns (bytes4 selector, BeforeSwapDelta delta, uint24 dynamicFee) {
        PoolId poolId = key.toId();
        dynamicFee = uint24(dynamicFeeManager.getCurrentDynamicFee(poolId));
        
        return (
            BEFORE_SWAP_SELECTOR,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            dynamicFee
        );
    }

    /**
     * @notice Consolidated reinvestment processing
     * @param poolId Pool ID to process reinvestment
     * @param opType Operation type (SWAP, DEPOSIT, WITHDRAWAL)
     */
    function _processReinvestment(PoolId poolId, IFeeReinvestmentManager.OperationType opType) internal {
        address policy = policyManager.getPolicy(poolId, IPoolPolicy.PolicyType.REINVESTMENT);
        if (policy != address(0)) {
            // Non-reverting call pattern
            try IFeeReinvestmentManager(policy).collectFees(poolId, opType) {
                // Success case handled silently
            } catch {
                // Error case handled silently to avoid disrupting main operations
            }
        }
    }

    /**
     * @notice Handle afterSwap hook calls with integrated fee reinvestment
     */
    function handleAfterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        // Process reinvestment with swap context
        _processReinvestment(key.toId(), IFeeReinvestmentManager.OperationType.SWAP);
        
        // Return hook selector
        return (AFTER_SWAP_SELECTOR, 0);
    }

    /**
     * @notice Handles beforeAddLiquidity hook calls
     */
    function handleBeforeAddLiquidity() external pure returns (bytes4) {
        return BEFORE_ADD_LIQUIDITY_SELECTOR;
    }

    /**
     * @notice Handle afterAddLiquidity hook calls with integrated fee reinvestment
     */
    function handleAfterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        // Process reinvestment with deposit context
        _processReinvestment(key.toId(), IFeeReinvestmentManager.OperationType.DEPOSIT);
        
        // Return hook selector
        return (AFTER_ADD_LIQUIDITY_SELECTOR, BalanceDelta.wrap(0));
    }

    /**
     * @notice Handles beforeRemoveLiquidity hook calls
     */
    function handleBeforeRemoveLiquidity() external pure returns (bytes4) {
        return BEFORE_REMOVE_LIQUIDITY_SELECTOR;
    }

    /**
     * @notice Handle afterRemoveLiquidity hook calls with integrated fee reinvestment
     */
    function handleAfterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta) {
        // Process reinvestment with withdrawal context
        _processReinvestment(key.toId(), IFeeReinvestmentManager.OperationType.WITHDRAWAL);
        
        // Return hook selector
        return (AFTER_REMOVE_LIQUIDITY_SELECTOR, BalanceDelta.wrap(0));
    }

    /**
     * @notice Handles beforeDonate hook calls
     */
    function handleBeforeDonate() external pure returns (bytes4) {
        return BEFORE_DONATE_SELECTOR;
    }

    /**
     * @notice Handles afterDonate hook calls
     */
    function handleAfterDonate() external pure returns (bytes4) {
        return AFTER_DONATE_SELECTOR;
    }

    /**
     * @notice Main dispatch function for hook calls - uses hybrid approach
     * @dev Called via delegatecall from FullRange
     * @param callData The raw calldata from PoolManager
     * @return result The result to return to PoolManager
     */
    function dispatchAndExecute(bytes calldata callData) external returns (bytes memory result) {
        // Extract function selector from calldata
        // Memory layout:
        // - First 4 bytes: function selector
        // - Remaining bytes: encoded parameters
        bytes4 selector;
        assembly {
            // Read the first 4 bytes of the calldata and shift right
            // to get the selector in the correct format
            selector := shr(224, calldataload(0))
        }
        
        // OPTIMIZATION #1: First check mapping for common hooks
        bytes4 handlerSelector = hookHandlers[selector];
        if (handlerSelector != bytes4(0)) {
            // Use efficient parameter passing with assembly for common hooks
            // This avoids the gas cost of abi.decode for frequently called hooks
            // Memory layout during the call:
            // - First 4 bytes: handler selector
            // - Remaining bytes: original parameters from the calldata
            assembly {
                // Create a new call using the handler selector + original params
                let ptr := mload(0x40) // Free memory pointer
                
                // Copy the handler selector to memory
                mstore(ptr, handlerSelector)
                
                // Copy all remaining calldata (parameters)
                let size := sub(calldatasize(), 4)
                calldatacopy(add(ptr, 4), 4, size)
                
                // Execute the call - note this is a regular call, not delegatecall
                // since we're still inside the delegatecall context from FullRange
                let success := call(
                    gas(),
                    address(),          // This contract (in delegatecall context)
                    0,                  // No ETH
                    ptr,                // Call data
                    add(size, 4),       // Call data size
                    0,                  // Output location (to be allocated)
                    0                   // Output size (to be determined)
                )
                
                // If call failed, revert with the error
                if iszero(success) {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
                
                // Copy the return data to result
                let returnSize := returndatasize()
                returndatacopy(ptr, 0, returnSize)
                
                // Update the free memory pointer
                mstore(0x40, add(ptr, returnSize))
                
                // Return the result
                return(ptr, returnSize)
            }
        }
        
        // OPTIMIZATION #2: Special handling for initialization hooks
        // These hooks are called rarely but require more complex handling
        if (selector == BEFORE_INITIALIZE_SELECTOR) {
            // Decode parameters
            // Memory layout after decoding:
            // - sender: address (20 bytes)
            // - key: PoolKey struct (complex type)
            // - sqrtPriceX96: uint160 (20 bytes)
            (address sender, PoolKey memory key, uint160 sqrtPriceX96) = abi.decode(
                callData[4:], 
                (address, PoolKey, uint160)
            );
            
            // Call handler
            bytes4 resultSelector = validatePoolParameters(sender, key, sqrtPriceX96);
            return abi.encode(resultSelector);
        } 
        else if (selector == AFTER_INITIALIZE_SELECTOR) {
            // Decode parameters
            // Memory layout after decoding:
            // - sender: address (20 bytes)
            // - key: PoolKey struct (complex type)
            // - sqrtPriceX96: uint160 (20 bytes)
            // - tick: int24 (3 bytes)
            (address sender, PoolKey memory key, uint160 sqrtPriceX96, int24 tick) = abi.decode(
                callData[4:], 
                (address, PoolKey, uint160, int24)
            );
            
            // Call handler
            bytes4 resultSelector = processPoolInitialization(sender, key, sqrtPriceX96, tick);
            return abi.encode(resultSelector);
        }
        
        // OPTIMIZATION #3: Fallback for any unmapped hooks
        // Simply return the selector for hooks without specific implementation
        emit HookHandled(selector);
        return abi.encode(selector);
    }
} 