// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFeeReinvestmentManager} from "./interfaces/IFeeReinvestmentManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullRangeLiquidityManager} from "./FullRangeLiquidityManager.sol";
import {IFullRangeLiquidityManager} from "./interfaces/IFullRangeLiquidityManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {MathUtils} from "./libraries/MathUtils.sol";
import {Errors} from "./errors/Errors.sol";
import {Currency as UniswapCurrency} from "v4-core/src/types/Currency.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolPolicy} from "./interfaces/IPoolPolicy.sol";

/**
 * @title FeeReinvestmentManager
 * @notice Manages fee claiming, reinvestment, and protocol-owned liquidity (POL)
 */
contract FeeReinvestmentManager is IFeeReinvestmentManager {
    // Main Uniswap V4 pool manager
    IPoolManager public immutable poolManager;
    
    // The full range contract address 
    address public immutable fullRange;
    
    // Governance address for POL withdrawals
    address public governanceTreasury;
    
    // Fee reinvestment threshold (in basis points, default 10 = 0.1%)
    uint256 public feeReinvestmentThresholdBps = 10;
    
    // Fee claims and reinvestment tracking
    mapping(PoolId => uint256) public uninvestedFee0;
    mapping(PoolId => uint256) public uninvestedFee1;
    
    // Protocol-owned liquidity tracking
    mapping(PoolId => uint256) public protocolOwnedLiquidity;
    
    // Pool reserves tracking
    mapping(bytes32 => uint256) public token0Reserves;
    mapping(bytes32 => uint256) public token1Reserves;
    
    // Pool to track total liquidity
    mapping(PoolId => uint256) public totalLiquidity;
    
    // Circuit breaker state
    bool public reinvestmentPaused;
    mapping(PoolId => bool) public poolReinvestmentPaused;
    
    // Configuration for hook-triggered reinvestment
    bool public reinvestOnHooks = true;
    
    // Tracks pending ETH payments from failed transfers
    mapping(address => uint256) public pendingETHPayments;
    
    // Pending fees for each pool
    mapping(PoolId => uint256) public pendingFees0;
    mapping(PoolId => uint256) public pendingFees1;
    
    // Total fees reinvested for each pool
    mapping(PoolId => uint256) public totalFees0Reinvested;
    mapping(PoolId => uint256) public totalFees1Reinvested;
    
    /**
     * @dev Enum representing different fee reinvestment modes.
     */
    enum ReinvestmentMode {
        ALWAYS,           // Always reinvest
        THRESHOLD_CHECK,  // Reinvest based on a threshold check
        NEVER             // Never reinvest
    }
    
    // Default reinvestment mode.
    ReinvestmentMode public defaultReinvestmentMode = ReinvestmentMode.ALWAYS;
    
    // External contract references
    IFullRangeLiquidityManager public liquidityManager;
    address public fullRangePoolManager;
    
    // Events
    event ReservesUpdated(PoolId indexed poolId, uint256 reserve0Added, uint256 reserve1Added);
    event POLUpdated(PoolId indexed poolId, uint256 newPOL);
    event POLWithdrawn(PoolId indexed poolId, uint256 sharesToWithdraw, uint256 amount0, uint256 amount1);
    event FeesAccumulated(PoolId indexed poolId, uint256 fee0, uint256 fee1);
    event FeeReinvestmentThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event ReinvestmentModeChanged(ReinvestmentMode oldMode, ReinvestmentMode newMode);
    event ReinvestmentPaused(address indexed pauser);
    event ReinvestmentResumed(address indexed resumer);
    event PoolReinvestmentPaused(PoolId indexed poolId, address indexed pauser);
    event PoolReinvestmentResumed(PoolId indexed poolId, address indexed resumer);
    event ReinvestmentFailed(PoolId indexed poolId, string reason);
    event ConfigUpdated(string indexed key, address indexed newValue);
    event FeesReinvested(PoolId indexed poolId, uint256 amount0, uint256 amount1, uint256 shares);
    
    /**
     * @notice Constructor
     * @param _poolManager The Uniswap V4 pool manager
     * @param _fullRange The FullRange contract address
     * @param _governance The governance address for POL withdrawals
     */
    constructor(IPoolManager _poolManager, address _fullRange, address _governance) {
        poolManager = _poolManager;
        fullRange = _fullRange;
        governanceTreasury = _governance;
    }
    
    /**
     * @notice Set the liquidityManager address
     * @param _liquidityManager The address of the FullRangeLiquidityManager
     */
    function setLiquidityManager(address _liquidityManager) external onlyGovernance {
        if (_liquidityManager == address(0)) revert Errors.ValidationZeroAddress("liquidityManager");
        liquidityManager = IFullRangeLiquidityManager(_liquidityManager);
        emit ConfigUpdated("liquidityManager", _liquidityManager);
    }
    
    /**
     * @notice Set the fullRangePoolManager address
     * @param _fullRangePoolManager The address of the FullRangePoolManager
     */
    function setFullRangePoolManager(address _fullRangePoolManager) external onlyGovernance {
        if (_fullRangePoolManager == address(0)) revert Errors.ValidationZeroAddress("fullRangePoolManager");
        fullRangePoolManager = _fullRangePoolManager;
        emit ConfigUpdated("fullRangePoolManager", _fullRangePoolManager);
    }
    
    /**
     * @notice Modifier to ensure only the FullRange contract can call
     */
    modifier onlyFullRange() {
        if (msg.sender != fullRange) revert Errors.AccessNotAuthorized(msg.sender);
        _;
    }
    
    /**
     * @notice Modifier to ensure only governance can call
     */
    modifier onlyGovernance() {
        if (msg.sender != governanceTreasury) revert Errors.AccessOnlyGovernance(msg.sender);
        _;
    }
    
    /**
     * @notice Set the fee reinvestment threshold (in basis points)
     * @param newThresholdBps New threshold value (10 = 0.1%)
     */
    function setFeeReinvestmentThreshold(uint256 newThresholdBps) external onlyGovernance {
        if (newThresholdBps > 1000) revert Errors.ParameterOutOfRange(newThresholdBps, 0, 1000);
        
        uint256 oldThreshold = feeReinvestmentThresholdBps;
        feeReinvestmentThresholdBps = newThresholdBps;
        
        emit FeeReinvestmentThresholdUpdated(oldThreshold, newThresholdBps);
    }
    
    /**
     * @notice Sets the default reinvestment mode.
     * @param mode The new reinvestment mode to set
     */
    function setDefaultReinvestmentMode(ReinvestmentMode mode) external onlyGovernance {
        ReinvestmentMode oldMode = defaultReinvestmentMode;
        defaultReinvestmentMode = mode;
        emit ReinvestmentModeChanged(oldMode, mode);
    }
    
    /**
     * @notice Checks if a pool has pending fees above a threshold (internal implementation)
     */
    function _hasPendingFees(PoolId poolId, uint256 swapValue) internal view returns (bool) {
        // In the v4-core update, poolInfo is no longer available directly
        // We implement a simplified version that always returns false for now
        // This can be enhanced later with actual pool data querying
        
        // The original implementation was:
        // (bool hasAccruedFees, uint128 totalLiquidityValue, ) = poolManager.poolInfo(poolId);
        // if (!hasAccruedFees) return false;
        // if (totalLiquidityValue == 0) return true;
        
        // For now, return false to avoid disrupting operations
        return false;
    }

    /**
     * @notice Checks if a pool has pending fees above a threshold
     * @param poolId The pool ID
     * @param minFeeThreshold Minimum threshold to consider meaningful
     * @return hasMeaningfulFees True if there are meaningful pending fees
     */
    function hasPendingFees(PoolId poolId, uint256 minFeeThreshold) public view returns (bool hasMeaningfulFees) {
        // We just call our internal implementation for now
        return _hasPendingFees(poolId, minFeeThreshold);
    }
    
    /**
     * @notice Returns true if we should reinvest based on mode and conditions (internal implementation)
     */
    function _shouldReinvest(PoolId poolId, uint256 swapValue) internal view returns (bool) {
        // Quick return paths based on reinvestment mode
        if (defaultReinvestmentMode == ReinvestmentMode.NEVER) {
            return false;
        }
        
        if (defaultReinvestmentMode == ReinvestmentMode.ALWAYS) {
            return true;
        }
        
        // THRESHOLD_CHECK mode - use enhanced hasPendingFees check
        return _hasPendingFees(poolId, swapValue);
    }

    /**
     * @notice Checks if reinvestment should be performed based on the current mode and conditions
     * @param poolId The pool ID
     * @param swapValue Used for threshold calculations
     * @return shouldPerformReinvestment Whether reinvestment should be performed
     */
    function shouldReinvest(PoolId poolId, uint256 swapValue) public view returns (bool shouldPerformReinvestment) {
        return _shouldReinvest(poolId, swapValue);
    }
    
    /**
     * @notice Processes reinvestment if needed based on current reinvestment mode
     * @param poolId The pool ID
     * @param swapValue Used for threshold calculations
     * @return reinvested Whether fees were successfully reinvested
     */
    function processReinvestmentIfNeeded(PoolId poolId, uint256 swapValue) external returns (bool) {
        // Skip if reinvestment is paused
        if (reinvestmentPaused || poolReinvestmentPaused[poolId]) {
            return false;
        }
        
        // Check if reinvestment is needed according to policy
        if (!_shouldReinvest(poolId, swapValue)) {
            return false;
        }
        
        // Execute the reinvestment using the existing function
        (bool success, , ) = executeReinvestment(poolId, swapValue);
        
        return success;
    }
    
    /**
     * @notice Updates the pool's reserves to reflect reinvested fees
     * @dev This function handles the bookkeeping of reinvested fees by:
     *  1. Updating the token reserve amounts for the pool
     *  2. Calculating additional liquidity using the geometric mean
     *  3. Updating the total liquidity tracking
     *
     * We use the geometric mean (sqrt of the product) to represent liquidity
     * because it's a fair measure of value that balances the contribution
     * of both tokens, regardless of their relative prices. This approach:
     *  - Ensures fair representation of pool growth
     *  - Prevents manipulation via imbalanced fees
     *  - Aligns with Uniswap's liquidity concentration model
     * 
     * @param poolId The ID of the pool
     * @param amount0 Amount of token0 to add to reserves
     * @param amount1 Amount of token1 to add to reserves
     */
    function updateFullRangeReserves(
        PoolId poolId,
        uint256 amount0,
        uint256 amount1
    ) internal {
        bytes32 poolIdBytes = PoolId.unwrap(poolId);
        
        // Step 1: Update the stored reserves for each token
        token0Reserves[poolIdBytes] += amount0;
        token1Reserves[poolIdBytes] += amount1;
        
        // Step 2: Calculate the additional liquidity using geometric mean
        // Only if both amounts are positive (avoid unnecessary calculations)
        if (amount0 > 0 && amount1 > 0) {
            // Liquidity = sqrt(amount0 * amount1)
            // This provides a balanced measure regardless of token prices
            uint256 addedLiquidity = MathUtils.calculateGeometricShares(amount0, amount1);
            
            // Step 3: Update the total liquidity tracking
            totalLiquidity[poolId] += addedLiquidity;
        }
        
        // Emit event with the updated reserve information
        emit ReservesUpdated(poolId, amount0, amount1);
    }
    
    /**
     * @notice Calculates amounts of fees that can be reinvested while maintaining pool ratio
     * @param poolId The pool ID
     * @param fee0 The amount of token0 fees
     * @param fee1 The amount of token1 fees
     * @return investable0 Amount of token0 that can be reinvested
     * @return investable1 Amount of token1 that can be reinvested
     */
    function calculateReinvestableFees(
        PoolId poolId,
        uint256 fee0,
        uint256 fee1
    ) public view returns (uint256 investable0, uint256 investable1) {
        bytes32 poolIdBytes = PoolId.unwrap(poolId);
        
        // Step 1: Get current reserves for both tokens
        uint256 reserve0 = token0Reserves[poolIdBytes];
        uint256 reserve1 = token1Reserves[poolIdBytes];
        
        // Use the enhanced MathUtils implementation with advanced options
        return MathUtils.calculateReinvestableFees(
            fee0,
            fee1,
            reserve0,
            reserve1
        );
    }
    
    /**
     * @notice Allows governance to withdraw excess POL above the minimum target
     * @param poolId The ID of the pool
     * @param key The pool key
     * @param sharesToWithdraw Amount of shares to withdraw
     * @param policy The pool policy contract
     * @param dynamicFeePpm Current dynamic fee in PPM
     */
    function withdrawExcessPOL(
        PoolId poolId,
        PoolKey memory key,
        uint256 sharesToWithdraw,
        IPoolPolicy policy,
        uint256 dynamicFeePpm
    ) external onlyGovernance {
        // Check minimum POL requirement
        uint256 minPOL = policy.getMinimumPOLTarget(poolId, totalLiquidity[poolId], dynamicFeePpm);
        if (protocolOwnedLiquidity[poolId] <= minPOL) revert Errors.InsufficientBalance(address(0), address(this), minPOL, protocolOwnedLiquidity[poolId]);
        
        uint256 excessPOL = protocolOwnedLiquidity[poolId] - minPOL;
        if (sharesToWithdraw > excessPOL) revert Errors.InsufficientBalance(address(0), address(this), excessPOL, sharesToWithdraw);
        
        // Update POL tracking
        protocolOwnedLiquidity[poolId] -= sharesToWithdraw;
        
        // Calculate proportion of reserves to withdraw
        bytes32 poolIdBytes = PoolId.unwrap(poolId);
        uint256 totalValue = totalLiquidity[poolId];
        
        uint256 amount0ToWithdraw = (token0Reserves[poolIdBytes] * sharesToWithdraw) / totalValue;
        uint256 amount1ToWithdraw = (token1Reserves[poolIdBytes] * sharesToWithdraw) / totalValue;
        
        // Update reserves
        token0Reserves[poolIdBytes] -= amount0ToWithdraw;
        token1Reserves[poolIdBytes] -= amount1ToWithdraw;
        totalLiquidity[poolId] -= sharesToWithdraw;
        
        // Withdraw from the pool using modifyLiquidity with negative delta
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: TickMath.MIN_TICK,
            tickUpper: TickMath.MAX_TICK,
            liquidityDelta: -int256(sharesToWithdraw),
            salt: bytes32(0)
        });
        
        // Call modifyLiquidity to withdraw
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, params, new bytes(0));
        
        // Transfer tokens to treasury
        address token0 = UniswapCurrency.unwrap(key.currency0);
        address token1 = UniswapCurrency.unwrap(key.currency1);
        
        // Safely convert the negative amounts to uint256
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        
        uint256 amount0Out = delta0 < 0 ? uint256(uint128(-delta0)) : 0;
        uint256 amount1Out = delta1 < 0 ? uint256(uint128(-delta1)) : 0;
        
        if (amount0Out > 0) {
            SafeTransferLib.safeTransfer(ERC20(token0), governanceTreasury, amount0Out);
        }
        
        if (amount1Out > 0) {
            SafeTransferLib.safeTransfer(ERC20(token1), governanceTreasury, amount1Out);
        }
        
        emit POLWithdrawn(poolId, sharesToWithdraw, amount0Out, amount1Out);
    }
    
    /**
     * @notice Sets a new governance treasury address
     * @param _treasury New treasury address
     */
    function setGovernanceTreasury(address _treasury) external onlyGovernance {
        if (_treasury == address(0)) revert Errors.ValidationZeroAddress("treasury");
        governanceTreasury = _treasury;
    }
    
    /**
     * @notice Get the total reserves for a pool
     * @param poolId The ID of the pool
     * @return reserve0 Amount of token0 reserves
     * @return reserve1 Amount of token1 reserves
     */
    function getReserves(PoolId poolId) external view returns (uint256 reserve0, uint256 reserve1) {
        bytes32 poolIdBytes = PoolId.unwrap(poolId);
        return (token0Reserves[poolIdBytes], token1Reserves[poolIdBytes]);
    }

    /**
     * @notice Pause global fee reinvestment functionality
     */
    function pauseReinvestment() external onlyGovernance {
        reinvestmentPaused = true;
        emit ReinvestmentPaused(msg.sender);
    }

    /**
     * @notice Resume global fee reinvestment functionality
     */
    function resumeReinvestment() external onlyGovernance {
        reinvestmentPaused = false;
        emit ReinvestmentResumed(msg.sender);
    }

    /**
     * @notice Pause fee reinvestment for a specific pool
     * @param poolId The pool to pause reinvestment for
     */
    function pausePoolReinvestment(PoolId poolId) external onlyGovernance {
        poolReinvestmentPaused[poolId] = true;
        emit PoolReinvestmentPaused(poolId, msg.sender);
    }

    /**
     * @notice Resume fee reinvestment for a specific pool
     * @param poolId The pool to resume reinvestment for
     */
    function resumePoolReinvestment(PoolId poolId) external onlyGovernance {
        poolReinvestmentPaused[poolId] = false;
        emit PoolReinvestmentResumed(poolId, msg.sender);
    }

    /**
     * @notice Execute fee reinvestment (callable by external components)
     * @param poolId The pool ID
     * @param swapValue Swap value to use for threshold calculations
     * @return success Whether reinvestment was successful
     * @return amount0 Amount of token0 reinvested
     * @return amount1 Amount of token1 reinvested
     */
    function executeReinvestment(
        PoolId poolId, 
        uint256 swapValue
    ) 
        internal 
        returns (bool success, uint256 amount0, uint256 amount1) 
    {
        // Check circuit breaker state first
        if (reinvestmentPaused) {
            return (false, 0, 0);
        }
        
        // Check if reinvestment needed
        if (!_shouldReinvest(poolId, swapValue)) {
            return (false, 0, 0);
        }
        
        // Process reinvestment directly
        // For now, we just return a placeholder success
        success = false;
        amount0 = 0;
        amount1 = 0;
        
        if (!success) {
            emit ReinvestmentFailed(poolId, "Reinvestment condition check failed");
        }
        
        return (success, amount0, amount1);
    }

    /**
     * @notice Reinvests accumulated fees for a specific pool 
     * @param poolId The pool ID to reinvest fees for
     * @return amount0 The amount of token0 fees reinvested
     * @return amount1 The amount of token1 fees reinvested
     */
    function reinvestFees(PoolId poolId) external returns (uint256 amount0, uint256 amount1) {
        // Skip if reinvestment is paused
        if (reinvestmentPaused || poolReinvestmentPaused[poolId]) {
            return (0, 0);
        }
        
        // Use a default swap value for threshold calculations
        uint256 defaultSwapValue = 1000000; // 1M units
        
        // Call existing function with the default swap value
        bool success;
        (success, amount0, amount1) = executeReinvestment(poolId, defaultSwapValue);
        
        // Return the reinvestment amounts
        return success ? (amount0, amount1) : (0, 0);
    }

    /**
     * @notice Attempts to reinvest fees after a user operation (deposit/withdraw)
     * @dev This function is called from operations and silently returns if it fails,
     *      to avoid disrupting the main transaction
     * @param poolId The pool ID to reinvest fees for
     * @param operationValue The value of the operation (for threshold calculation)
     */
    function attemptReinvestmentAfterOperation(PoolId poolId, uint256 operationValue) external {
        // Early exit if paused or not needed - this check makes it very gas efficient
        if (reinvestmentPaused || poolReinvestmentPaused[poolId] || !_shouldReinvest(poolId, operationValue)) {
            return;
        }
        
        // Process reinvestment - no need to return any values since this is a "best effort" function
        bool success;
        uint256 amount0;
        uint256 amount1;
        (success, amount0, amount1) = executeReinvestment(poolId, operationValue);
        
        // Emit event if successful
        if (success) {
            emit FeesReinvested(poolId, amount0, amount1, 0); // Share info not available at this level
        }
    }

    /**
     * @notice Handle any pending ETH from reinvestment operations
     * @param user The user to send ETH to
     * @param amount Amount of ETH to send
     */
    function _sendETH(address user, uint256 amount) internal {
        // Safe check for empty amounts
        if (amount == 0) return;
        
        // Send ETH
        (bool success, ) = user.call{value: amount}("");
        
        // Handle failure
        if (!success) {
            pendingETHPayments[user] += amount;
        }
    }

    /**
     * @notice Withdraw excess Protocol-Owned Liquidity
     * @dev Executes withdraw from FullRange contract
     */
    function _executeWithdraw(
        PoolId poolId,
        PoolKey memory key,
        uint256 shares,
        uint256 minAmount0,
        uint256 minAmount1
    ) internal returns (uint256, uint256) {
        // Create withdrawal parameters
        IFullRangeLiquidityManager.WithdrawParams memory params = IFullRangeLiquidityManager.WithdrawParams({
            poolId: poolId,
            shares: shares,
            amount0Min: minAmount0,
            amount1Min: minAmount1,
            deadline: block.timestamp
        });

        // Execute withdrawal
        (BalanceDelta delta, uint256 amount0Out, uint256 amount1Out) = liquidityManager.withdraw(params, address(this));
        
        // Return withdrawn amounts
        return (amount0Out, amount1Out);
    }
} 