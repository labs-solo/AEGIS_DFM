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

/**
 * @title HookHandler
 * @notice Unified handler for Uniswap V4 hooks with policy-based validation
 * @dev Combines functionality from DefaultHookHandler and EnhancedHookHandler
 */
contract HookHandler {
    // References to required contracts
    IPoolPolicy public immutable policyManager;
    IPoolManager public immutable poolManager;
    address public immutable fullRangeAddress;
    
    // Policy initialization events for better observability
    event PolicyInitializationFailed(PoolId indexed poolId, string reason);
    event PolicyInitializationSucceeded(PoolId indexed poolId);
    
    /**
     * @notice Constructor initializes contract dependencies with validation
     * @param _policyManager The policy manager contract
     * @param _poolManager The pool manager contract
     * @param _fullRangeAddress The address of the FullRange contract
     * @dev Uses custom errors instead of require statements for gas efficiency
     */
    constructor(
        IPoolPolicy _policyManager,
        IPoolManager _poolManager,
        address _fullRangeAddress
    ) {
        // Validate parameters using custom errors instead of require statements
        if (address(_policyManager) == address(0)) revert Errors.ValidationZeroAddress("policyManager");
        if (address(_poolManager) == address(0)) revert Errors.ValidationZeroAddress("poolManager");
        if (_fullRangeAddress == address(0)) revert Errors.ValidationZeroAddress("fullRange");
        
        policyManager = _policyManager;
        poolManager = _poolManager;
        fullRangeAddress = _fullRangeAddress;
    }
    
    /**
     * @notice Performs pool parameter validation for initialization
     * @param sender The sender of the initialize call
     * @param key The pool key
     * @param sqrtPriceX96 The initial sqrt price
     * @return selector The hook selector to return
     * @dev Validates all pool parameters before allowing initialization to proceed
     */
    function validatePoolParameters(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) external view returns (bytes4 selector) {
        // Check hook address
        if (address(key.hooks) != fullRangeAddress) {
            revert Errors.HookInvalidAddress(address(key.hooks));
        }
        
        // Get pool ID
        PoolId poolId = PoolIdLibrary.toId(key);
        
        // Validate initial sqrt price is within valid range
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
     * @notice Processes pool initialization through the policy system
     * @param sender The sender of the initialize call
     * @param key The pool key
     * @param sqrtPriceX96 The initial sqrt price
     * @param tick The initial tick
     * @return selector The hook selector to return
     * @dev Handles both policy initialization and registration with appropriate error handling
     */
    function processPoolInitialization(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) external returns (bytes4 selector) {
        // Get pool ID
        PoolId poolId = PoolIdLibrary.toId(key);
        
        // Prepare policy implementations array
        address[] memory implementations = _getPoolPolicyImplementations(poolId);
        
        // Initialize policies with proper error handling
        _initializePolicies(poolId, implementations);
        
        // Notify the policy manager about the pool initialization
        try policyManager.handlePoolInitialization(poolId, key, sqrtPriceX96, tick, fullRangeAddress) {
            // Successfully handled pool initialization
        } catch {
            // Continue even if handler fails - this is non-critical
        }
        
        return IHooks.afterInitialize.selector;
    }
    
    /**
     * @notice Gets all policy implementations for a pool
     * @param poolId The pool ID
     * @return implementations Array of policy implementations
     * @dev Centralizes the logic for gathering all policy implementations by type
     */
    function _getPoolPolicyImplementations(PoolId poolId) internal view returns (address[] memory implementations) {
        implementations = new address[](4);
        
        implementations[uint8(IPoolPolicy.PolicyType.FEE)] = policyManager.getPolicy(
            poolId, IPoolPolicy.PolicyType.FEE
        );
        
        implementations[uint8(IPoolPolicy.PolicyType.TICK_SCALING)] = policyManager.getPolicy(
            poolId, IPoolPolicy.PolicyType.TICK_SCALING
        );
        
        implementations[uint8(IPoolPolicy.PolicyType.VTIER)] = policyManager.getPolicy(
            poolId, IPoolPolicy.PolicyType.VTIER
        );
        
        implementations[uint8(IPoolPolicy.PolicyType.REINVESTMENT)] = policyManager.getPolicy(
            poolId, IPoolPolicy.PolicyType.REINVESTMENT
        );
        
        return implementations;
    }
    
    /**
     * @notice Initializes pool policies with proper error handling
     * @param poolId The pool ID
     * @param implementations Array of policy implementations
     * @dev This function handles three error scenarios:
     *      1. Successful initialization - emits success event
     *      2. Revert with string reason - emits failure event with reason
     *      3. Low-level revert - emits failure event with "Unknown error"
     *      The function allows execution to continue even if policy initialization fails,
     *      as this is considered a non-critical failure that should not block pool creation.
     */
    function _initializePolicies(PoolId poolId, address[] memory implementations) internal {
        // Use the policy manager's initializePolicies method directly
        try policyManager.initializePolicies(poolId, policyManager.getSoloGovernance(), implementations) {
            emit PolicyInitializationSucceeded(poolId);
        } catch Error(string memory reason) {
            emit PolicyInitializationFailed(poolId, reason);
        } catch (bytes memory /*lowLevelData*/) {
            emit PolicyInitializationFailed(poolId, "Unknown error");
        }
    }

    /**
     * @notice Checks if a pool has all required policies set up
     * @param poolId The pool ID to check
     * @return isInitialized Whether all policies are properly set up
     * @dev Helper view function for external contracts to verify policy setup
     */
    function isPolicySetupComplete(PoolId poolId) external view returns (bool isInitialized) {
        // Check if all required policies are set to non-zero addresses
        for (uint8 i = 0; i < 4; i++) {
            if (policyManager.getPolicy(poolId, IPoolPolicy.PolicyType(i)) == address(0)) {
                return false;
            }
        }
        return true;
    }
    
    /**
     * @notice Retrieves all policies for a given pool as a structured response
     * @param poolId The pool ID
     * @return policyAddresses Array of policy addresses in order of policy type enum
     * @dev Useful for frontends and external contracts to inspect the current policy setup
     */
    function getPoolPolicies(PoolId poolId) external view returns (address[] memory policyAddresses) {
        return _getPoolPolicyImplementations(poolId);
    }

    // Standard Hook Handlers with optimized implementations
    
    /**
     * @notice Handles beforeAddLiquidity hook calls
     * @return The function selector
     */
    function handleBeforeAddLiquidity() external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    /**
     * @notice Handles afterAddLiquidity hook calls
     * @return The function selector and zero balance delta
     */
    function handleAfterAddLiquidity() external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Handles beforeRemoveLiquidity hook calls
     * @return The function selector
     */
    function handleBeforeRemoveLiquidity() external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /**
     * @notice Handles afterRemoveLiquidity hook calls
     * @return The function selector and zero balance delta
     */
    function handleAfterRemoveLiquidity() external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Handles beforeSwap hook calls
     * @return The function selector, zero swap delta, and zero fee
     */
    function handleBeforeSwap() external pure returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @notice Handles afterSwap hook calls
     * @return The function selector and zero int128 value
     */
    function handleAfterSwap() external pure returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    /**
     * @notice Handles beforeDonate hook calls
     * @return The function selector
     */
    function handleBeforeDonate() external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    /**
     * @notice Handles afterDonate hook calls
     * @return The function selector
     */
    function handleAfterDonate() external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
} 