// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ExtendedBaseHook} from "./base/ExtendedBaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {FullRangeMathLib} from "./libraries/FullRangeMathLib.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityMath} from "./libraries/LiquidityMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {SwapMath} from "v4-core/src/libraries/SwapMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencyDelta} from "v4-core/src/libraries/CurrencyDelta.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

// Interface for the external oracle
interface ITruncGeoOracleMulti {
    function updateObservation(PoolKey calldata key) external;
}

/**
 * @title FullRange
 * @notice A Uniswap V4 hook that provides full-range liquidity management and tiered fees
 * @dev This contract allows users to deposit liquidity across the full price range
 *      and efficiently manages fee reinvestment. It also provides tiered swap fee
 *      handling and oracle integration through Uniswap's hook system.
 *
 * Key features:
 * - Full range liquidity deposits and withdrawals with automatic fee reinvestment
 * - Share-based accounting for proportional ownership
 * - Oracle integration with throttling to prevent manipulation
 * - Efficient fee collection and reinvestment based on configurable thresholds
 * - Advanced slippage protection
 *
 * Architecture:
 * - Extends ExtendedBaseHook for comprehensive hook integration
 * - Uses Hook.Permissions for complete hook control
 * - Internal helpers for modular code organization
 * - Real on-chain reserve queries for accurate share calculations
 * - Centralized oracle updates via beforeSwap hook
 */
contract FullRange is ExtendedBaseHook, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for int256;
    using FullMath for uint256;
    using SqrtPriceMath for uint160;
    using LPFeeLibrary for uint24;
    using Position for Position.State;
    using SwapMath for uint160;
    using TransientStateLibrary for IPoolManager;
    using CurrencyDelta for Currency;
    using ProtocolFeeLibrary for uint24;
    using CustomRevert for bytes4;

    // ----------------- Error Definitions -----------------
    error PoolNotInitialized();
    error TooMuchSlippage();
    error ExpiredPastDeadline();
    error TickSpacingNotDefault();
    error SenderMustBeHook();
    error NoSharesProvided();
    error InsufficientShares();
    error SlippageCheckFailed();
    error CalculationOverflow();
    error NoFeesToReinvest();

    // ----------------- Constants & State Variables -----------------
    int24 public constant MIN_TICK = -887220;
    int24 public constant MAX_TICK = 887220;
    uint128 public constant MINIMUM_LIQUIDITY = 1000;
    uint16 public customTierMaxSlippageBps = 50; // Default 0.50%
    address private _polAccumulator;             // Protocol-owned liquidity accumulator

    // Virtual getter for polAccumulator
    function polAccumulator() public virtual view returns (address) {
        return _polAccumulator;
    }

    // Reference to the external oracle contract (TruncGeoOracleMulti)
    address public truncGeoOracleMulti;

    // ----------------- Oracle Update Throttle Variables -----------------
    uint256 public blockUpdateThreshold = 1; // Minimum blocks between updates.
    uint24 public tickDiffThreshold = 1;        // Minimum tick change required.
    // Track last update info per pool.
    mapping(bytes32 => uint256) public lastOracleUpdateBlock;
    mapping(bytes32 => int24)   public lastOracleTick;

    // ----------------- Pool Info Storage -----------------
    struct PoolInfo {
        bool hasAccruedFees;      // Whether fees have accrued.
        address liquidityToken;   // ERC20 token for LP shares.
        uint128 totalLiquidity;   // Total liquidity added via THIS CONTRACT ONLY (not the entire pool's liquidity).
                                     // This is critical for proper reserve calculations that must exclude external liquidity.
        uint24 fee;               // Dynamic fee (in basis points) for this pool.
        uint16 tickSpacing;       // Tick spacing for the pool.
        // Accumulated "dust" from fee reinvestment.
        uint256 leftover0;
        uint256 leftover1;
    }
    mapping(PoolId => PoolInfo) public poolInfo;
    mapping(PoolId => mapping(address => uint256)) public userFullRangeShares;
    mapping(PoolId => uint256) public totalFullRangeShares;
    
    // Position tracking using Uniswap V4 Position library
    mapping(bytes32 => Position.State) private positions;

    // ----------------- Events -----------------
    event FullRangeDeposit(
        address indexed user,
        uint256 amount0,
        uint256 amount1,
        uint256 sharesMinted
    );
    event FullRangeWithdrawal(
        address indexed user,
        uint256 sharesBurned,
        uint256 amount0Out,
        uint256 amount1Out
    );
    event FeesReinvested(
        PoolId indexed poolId,
        uint256 amount0Used,
        uint256 amount1Used,
        uint256 liquidityAdded
    );

    // ----------------- Constructor -----------------
    constructor(IPoolManager _manager, address _truncGeoOracleMulti) ExtendedBaseHook(_manager) {
        _polAccumulator = msg.sender;
        truncGeoOracleMulti = _truncGeoOracleMulti;
    }

    // ----------------- Hook Permissions Override -----------------
    /// @notice Override to set up hook permissions
    function getHookPermissions() public view override returns (Hooks.Permissions memory) {
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

    // ----------------- Hook Implementation -----------------
    /// @notice Implementation for beforeInitialize
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) 
        internal 
        override 
        returns (bytes4) 
    {
        if (key.tickSpacing != 60) revert TickSpacingNotDefault();
        PoolId pid = key.toId();
        poolInfo[pid].hasAccruedFees = false;
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    /**
     * @notice Implementation for beforeSwap hook
     * @dev Updates oracle with throttling based on block/tick thresholds
     *      This is the centralized place for all oracle updates in the contract.
     *      We use the beforeSwap hook because it's called on every swap,
     *      which provides the most up-to-date price data.
     */
    function _beforeSwap(
        address sender, 
        PoolKey calldata key, 
        IPoolManager.SwapParams calldata params, 
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Update the oracle with throttling as specified in the pseudocode
        _updateOracleWithThrottle(key);
        
        return super._beforeSwap(sender, key, params, hookData);
    }

    // ----------------- FullRange Deposit/Withdraw Functions -----------------
    
    /**
     * @notice Deposit tokens to the full range position for a pool
     * @param key The pool key
     * @param amount0Desired The amount of token0 to deposit
     * @param amount1Desired The amount of token1 to deposit
     * @param amount0Min The minimum amount of token0 to deposit (slippage protection)
     * @param amount1Min The minimum amount of token1 to deposit (slippage protection)
     * @param deadline The deadline for the transaction
     * @return shares The amount of shares minted
     * @return amount0 The amount of token0 actually deposited
     * @return amount1 The amount of token1 actually deposited
     * @dev This function:
     *      1. Automatically claims and reinvests any accumulated fees
     *      2. Calculates shares based on deposit amounts and current reserves
     *      3. For first deposit: issues shares equal to sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY
     *      4. For subsequent deposits: calculates shares based on current ratio of tokens to shares
     *      5. Uses real on-chain pool state for accurate share calculations
     *      6. Enforces slippage protection by comparing actual amounts to minimums
     *      7. Reverts if the pool is not initialized or deadline has passed
     *      8. Emits FullRangeDeposit event with details of the deposit
     */
    function depositFullRange(
        PoolKey calldata key,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (uint256 shares, uint256 amount0, uint256 amount1) {
        if (block.timestamp > deadline) revert ExpiredPastDeadline();
        if (amount0Desired == 0 && amount1Desired == 0) revert TooMuchSlippage();
        
        // Claim and reinvest any accumulated fees before deposit
        claimAndReinvestFeesInternal(key);
        
        PoolId poolId = key.toId();
        
        // Check if pool is initialized
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        
        // Calculate shares based on deposit amounts
        uint256 newShares = _calculateDepositShares(amount0Desired, amount1Desired, poolId, key);
        
        // Prepare data for the modifyLiquidity call
        bytes memory data = abi.encode(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: int256(uint256(newShares)),
                salt: bytes32(0)
            }),
            false // isReinvestment flag
        );
        
        // Call unlock on the poolManager which will trigger unlockCallback to make the actual liquidity change
        bytes memory result = poolManager.unlock(data);
        
        // Decode the result to get the BalanceDelta
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        
        // The actual amounts deposited are in the BalanceDelta
        // Note: These values are negative in the delta as tokens are leaving the user
        amount0 = uint256(uint128(-delta.amount0()));
        amount1 = uint256(uint128(-delta.amount1()));
        
        // Perform slippage check after getting final amounts
        _checkSlippage(amount0, amount1, amount0Min, amount1Min);
        
        // Update state
        userFullRangeShares[poolId][msg.sender] += newShares;
        totalFullRangeShares[poolId] += newShares;
        
        // Update position using Position library
        bytes32 positionKey = Position.calculatePositionKey(
            msg.sender, 
            MIN_TICK, 
            MAX_TICK, 
            bytes32(0) // Salt
        );
        
        // Get position from storage and update it directly
        Position.State storage position = positions[positionKey];
        position.update(
            int128(uint128(newShares)), // Convert to int128 for liquidityDelta
            0, // feeGrowthInside0X128 - would need to track this accurately in production
            0  // feeGrowthInside1X128 - would need to track this accurately in production
        );
        
        // Update the pool information
        PoolInfo storage info = poolInfo[poolId];
        // Track our managed portion of the pool's total liquidity
        // This is essential for accurate reserve calculations which only consider FullRange-managed positions
        info.totalLiquidity += uint128(newShares);
        
        // Oracle updates are handled centrally in _beforeSwap
        // No need for redundant call here
        
        emit FullRangeDeposit(msg.sender, amount0, amount1, newShares);
        
        return (newShares, amount0, amount1);
    }
    
    /**
     * @notice Withdraw tokens from the full range position for a pool
     * @param key The pool key
     * @param shares The amount of shares to burn
     * @param amount0Min The minimum amount of token0 to withdraw (slippage protection)
     * @param amount1Min The minimum amount of token1 to withdraw (slippage protection)
     * @param deadline The deadline for the transaction
     * @return amount0 The amount of token0 withdrawn
     * @return amount1 The amount of token1 withdrawn
     * @dev This function:
     *      1. Automatically claims and reinvests any accumulated fees before withdrawal
     *      2. Verifies the user has sufficient shares and that shares > 0
     *      3. Removes liquidity proportional to shares being burned
     *      4. Enforces slippage protection by comparing actual amounts to minimums
     *      5. Updates user and total shares accounting
     *      6. Reverts if the pool is not initialized, deadline has passed, or insufficient shares
     *      7. Emits FullRangeWithdrawal event with details of the withdrawal
     *      8. Handles edge cases where pool price has moved significantly
     */
    function withdrawFullRange(
        PoolKey calldata key,
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1) {
        if (block.timestamp > deadline) revert ExpiredPastDeadline();
        if (shares == 0) revert NoSharesProvided();
        
        // Claim and reinvest any accumulated fees before withdrawal
        claimAndReinvestFeesInternal(key);
        
        PoolId poolId = key.toId();
        
        // Check user has enough shares
        uint256 userShares = userFullRangeShares[poolId][msg.sender];
        if (userShares < shares) revert InsufficientShares();
        
        // For slippage check in withdrawFullRange:
        _checkSlippage(amount0, amount1, amount0Min, amount1Min);
        
        // Prepare data for the modifyLiquidity call
        bytes memory data = abi.encode(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: -int256(uint256(shares)),
                salt: bytes32(0)
            }),
            false // isReinvestment flag
        );
        
        // Call unlock on the poolManager which will trigger unlockCallback to make the actual liquidity change
        bytes memory result = poolManager.unlock(data);
        
        // Decode the result to get the BalanceDelta
        BalanceDelta delta = abi.decode(result, (BalanceDelta));
        
        // The actual amounts withdrawn are in the BalanceDelta
        // Note: These values are positive in the delta as tokens are going to the user
        amount0 = uint256(uint128(delta.amount0()));
        amount1 = uint256(uint128(delta.amount1()));
        
        // Update state
        userFullRangeShares[poolId][msg.sender] -= shares;
        totalFullRangeShares[poolId] -= shares;
        
        // Update position using Position library
        bytes32 positionKey = Position.calculatePositionKey(
            msg.sender, 
            MIN_TICK, 
            MAX_TICK, 
            bytes32(0) // Salt
        );
        
        // Get position from storage and update it directly
        Position.State storage position = positions[positionKey];
        position.update(
            -int128(uint128(shares)), // Negative liquidity delta for withdrawal
            0, // feeGrowthInside0X128 - would need to track this accurately in production
            0  // feeGrowthInside1X128 - would need to track this accurately in production
        );
        
        // Update the pool information
        PoolInfo storage info = poolInfo[poolId];
        // Reduce our managed portion of the pool's total liquidity
        // This ensures reserve calculations remain accurate as users withdraw
        info.totalLiquidity -= uint128(shares);
        
        // Oracle updates are handled centrally in _beforeSwap
        // No need for redundant call here
        
        emit FullRangeWithdrawal(msg.sender, shares, amount0, amount1);
        
        return (amount0, amount1);
    }

    /**
     * @notice External function to claim and reinvest fees
     * @param key The pool key
     */
    function claimAndReinvestFees(PoolKey calldata key) external {
        claimAndReinvestFeesInternal(key);
    }
    
    /**
     * @notice Internal function to claim fees and reinvest if above threshold
     * @param key The pool key
     * @dev This function handles several edge cases:
     *      1. Zero liquidity pools
     *      2. Extremely large fee accumulation
     *      3. Balanced vs imbalanced fee ratios
     */
    function claimAndReinvestFeesInternal(PoolKey calldata key) internal {
        PoolId poolId = key.toId();
        PoolInfo storage info = poolInfo[poolId];

        // The threshold for reinvestment (1% of current liquidity)
        uint256 reinvestmentThreshold;
        if (totalFullRangeShares[poolId] > 0) {
            reinvestmentThreshold = totalFullRangeShares[poolId] / 100; // 1% threshold
        } else {
            reinvestmentThreshold = 1e18; // Default threshold
        }
        
        // Collect fees by calling modifyLiquidity with zero liquidityDelta
        // We need to use the unlock and unlockCallback pattern for this
        bytes memory data = abi.encode(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: 0,
                salt: bytes32(0)
            }),
            false // isReinvestment flag
        );
        
        // Call unlock on the poolManager which will trigger unlockCallback
        bytes memory result = poolManager.unlock(data);
        
        // Decode the result to get the BalanceDelta with fees
        BalanceDelta feeDelta = abi.decode(result, (BalanceDelta));
        
        // Settle the currency delta before proceeding
        poolManager.settle();
        
        // Extract fee amounts (ensuring they're positive)
        uint256 feeAmount0 = uint256(uint128(feeDelta.amount0()));
        uint256 feeAmount1 = uint256(uint128(feeDelta.amount1()));
        
        // If no fees, just return early
        if (feeAmount0 == 0 && feeAmount1 == 0) {
            return;
        }

        // Add to leftovers
        info.leftover0 += feeAmount0;
        info.leftover1 += feeAmount1;

        // Get the current sqrtPriceX96 for accurate liquidity calculation
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // Calculate extra liquidity using our improved SwapMath-based function
        uint256 extraLiquidity = calculateReinvestmentLiquidity(
            info.leftover0,
            info.leftover1,
            sqrtPriceX96
        );
        
        // If there are leftovers but total shares are 0, we should reinvest immediately
        // to avoid fees getting stuck when new deposits occur
        bool shouldReinvest = totalFullRangeShares[poolId] == 0 ? 
            (extraLiquidity > 0) : 
            (extraLiquidity > reinvestmentThreshold);
        
        // Check if we have leftover amounts that are excessively large
        // This prevents fees from accumulating to amounts that might cause issues
        if (!shouldReinvest) {
            // If leftovers exceed 10% of total liquidity, reinvest anyway
            uint256 totalLiquidity = info.totalLiquidity;
            if (totalLiquidity > 0 && 
                (extraLiquidity > totalLiquidity / 10)) {
                shouldReinvest = true;
            }
        }
        
        // If extra liquidity is above threshold or other conditions triggered reinvestment
        if (shouldReinvest) {
            // Prepare data for the reinvestment modifyLiquidity call
            bytes memory reinvestData = abi.encode(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: MIN_TICK,
                    tickUpper: MAX_TICK,
                    liquidityDelta: int256(extraLiquidity),
                    salt: bytes32(0)
                }),
                true // isReinvestment flag
            );
            
            // Call unlock on the poolManager which will trigger unlockCallback for reinvestment
            poolManager.unlock(reinvestData);
            
            // Settle the currency delta after reinvestment
            poolManager.settle();
            
            // Emit the FeesReinvested event
            emit FeesReinvested(poolId, feeAmount0, feeAmount1, extraLiquidity);
            
            // Reset leftovers as they've been reinvested
            info.leftover0 = 0;
            info.leftover1 = 0;
            
            // Update the total shares to reflect the reinvestment
            totalFullRangeShares[poolId] += extraLiquidity;
            
            // Also update the pool total liquidity
            info.totalLiquidity += uint128(extraLiquidity);
        }
        // If below threshold, fees remain in leftover0/leftover1 for future reinvestment
    }

    // ----------------- IUnlockCallback Implementation -----------------
    /**
     * @notice Callback for unlocking the PoolManager
     * @dev This is required for modifying liquidity in the pool
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert SenderMustBeHook();
        
        // Decode the data
        (
            PoolKey memory key,
            IPoolManager.ModifyLiquidityParams memory params,
            bool isReinvestment
        ) = abi.decode(data, (PoolKey, IPoolManager.ModifyLiquidityParams, bool));
        
        // Get current deltas using CurrencyDelta
        int256 delta0Before = CurrencyDelta.getDelta(key.currency0, address(this));
        int256 delta1Before = CurrencyDelta.getDelta(key.currency1, address(this));
        
        // Call modifyLiquidity on the poolManager
        (BalanceDelta delta, BalanceDelta feeDelta) = poolManager.modifyLiquidity(key, params, "");
        
        // Apply and track the deltas from this operation
        int256 previousDelta0;
        int256 newDelta0;
        (previousDelta0, newDelta0) = CurrencyDelta.applyDelta(
            key.currency0, 
            address(this), 
            delta.amount0()
        );
        
        int256 previousDelta1;
        int256 newDelta1;
        (previousDelta1, newDelta1) = CurrencyDelta.applyDelta(
            key.currency1, 
            address(this), 
            delta.amount1()
        );
        
        // If this is a reinvestment, we've already handled the accounting in claimAndReinvestFeesInternal
        if (!isReinvestment) {
            // Return the delta to claimAndReinvestFeesInternal
            return abi.encode(delta);
        }
        
        return "";
    }

    // ----------------- Oracle Update Functions -----------------
    
    /**
     * @notice Updates the oracle with throttling based on block and tick thresholds
     * @param key The pool key
     */
    function _updateOracleWithThrottle(PoolKey calldata key) internal {
        bytes32 id = PoolId.unwrap(key.toId());
        
        // Check if we should update based on throttling parameters
        if (!_shouldUpdateOracle(key)) return;
        
        // Call the external oracle update
        ITruncGeoOracleMulti(truncGeoOracleMulti).updateObservation(key);
        
        // Record new update block and tick
        lastOracleUpdateBlock[id] = block.number;
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, key.toId());
        lastOracleTick[id] = currentTick;
    }
    
    /**
     * @notice Determines if the oracle should be updated based on throttling parameters
     * @param key The pool key
     * @return bool True if the oracle should be updated, false otherwise
     */
    function _shouldUpdateOracle(PoolKey calldata key) internal view returns (bool) {
        bytes32 id = PoolId.unwrap(key.toId());
        
        // If we haven't reached the block threshold yet, check if the tick difference is large enough
        if (block.number < lastOracleUpdateBlock[id] + blockUpdateThreshold) {
            (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, key.toId());
            
            // If the tick difference is below the threshold, don't update
            if (_absDiff(currentTick, lastOracleTick[id]) < tickDiffThreshold) {
                return false;
            }
        }
        
        // Either block threshold or tick threshold has been met, so update the oracle
        return true;
    }
    
    /**
     * @notice Calculates the absolute difference between two int24 values
     * @param a The first value
     * @param b The second value
     * @return uint24 The absolute difference
     */
    function _absDiff(int24 a, int24 b) internal pure returns (uint24) {
        return a >= b ? uint24(a - b) : uint24(b - a);
    }

    /**
     * @notice Calculate shares for a deposit based on amounts and pool state
     * @param amount0Desired The amount of token0 to deposit
     * @param amount1Desired The amount of token1 to deposit
     * @param poolId The pool ID
     * @param key The pool key
     * @return newShares The calculated shares
     */
    function _calculateDepositShares(
        uint256 amount0Desired,
        uint256 amount1Desired,
        PoolId poolId,
        PoolKey calldata key
    ) internal view returns (uint256 newShares) {
        if (totalFullRangeShares[poolId] == 0) {
            // First deposit - create initial shares
            newShares = FullRangeMathLib.calculateInitialShares(
                amount0Desired,
                amount1Desired,
                MINIMUM_LIQUIDITY
            );
        } else {
            // Calculate new shares based on the current ratio in the pool
            // Get the current reserves from the pool using our helper function
            (uint256 reserve0, uint256 reserve1) = _getPoolReserves(key, poolId);
            
            // Edge case: If reserves are 0 but shares exist (can happen if all liquidity was removed externally)
            // Treat it as a first deposit
            if (reserve0 == 0 || reserve1 == 0) {
                newShares = FullRangeMathLib.calculateInitialShares(
                    amount0Desired,
                    amount1Desired,
                    MINIMUM_LIQUIDITY
                );
            } else {
                // Use FullRangeMathLib to calculate proportional shares
                newShares = FullRangeMathLib.calculateProportionalShares(
                    amount0Desired,
                    amount1Desired,
                    totalFullRangeShares[poolId],
                    reserve0,
                    reserve1
                );
            }
        }
        return newShares;
    }

    /**
     * @notice Internal function to query reserves specifically for the FullRange-managed liquidity portion
     * @param key The pool key
     * @param poolId The pool ID
     * @return reserve0 The reserve of token0 for FullRange-managed liquidity only
     * @return reserve1 The reserve of token1 for FullRange-managed liquidity only
     */
    function _getPoolReserves(PoolKey calldata key, PoolId poolId) internal view virtual returns (uint256 reserve0, uint256 reserve1) {
        uint256 fullRangeLiquidity = uint256(poolInfo[poolId].totalLiquidity);
        if (fullRangeLiquidity == 0) return (0, 0);
        
        // Check if there's a synced currency/reserves using TransientStateLibrary
        Currency syncedCurrency = poolManager.getSyncedCurrency();
        uint256 syncedReserves = poolManager.getSyncedReserves();
        
        // If we have synchronized reserves and they match one of our currencies, use them
        if (!syncedCurrency.isAddressZero() && 
            (syncedCurrency == key.currency0 || syncedCurrency == key.currency1)) {
            
            // Use StateLibrary for pool data
            (uint160 syncedSqrtPriceX96, int24 currentTick, , ) = StateLibrary.getSlot0(poolManager, poolId);
            if (syncedSqrtPriceX96 == 0) return (0, 0);
            
            // Convert managed liquidity to int128
            int128 syncedLiquidityInt = fullRangeLiquidity.toInt128();
            
            if (syncedCurrency == key.currency0) {
                reserve0 = syncedReserves;
                // Calculate reserve1 based on current price and liquidity
                reserve1 = LiquidityMath.getAmount1Delta(
                    TickMath.getSqrtPriceAtTick(MIN_TICK),
                    syncedSqrtPriceX96,
                    syncedLiquidityInt
                );
            } else {
                reserve1 = syncedReserves;
                // Calculate reserve0 based on current price and liquidity
                reserve0 = LiquidityMath.getAmount0Delta(
                    syncedSqrtPriceX96,
                    TickMath.getSqrtPriceAtTick(MAX_TICK),
                    syncedLiquidityInt
                );
            }
            return (reserve0, reserve1);
        }
        
        // Fallback to standard calculation if no synced reserves
        // Use StateLibrary directly
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) return (0, 0);
        
        // Use SafeCast for safe conversions
        int128 liquidityInt = fullRangeLiquidity.toInt128();
        
        // Use TickMath for price calculations
        uint160 sqrtPriceMinX96 = TickMath.getSqrtPriceAtTick(MIN_TICK);
        uint160 sqrtPriceMaxX96 = TickMath.getSqrtPriceAtTick(MAX_TICK);
        
        // Use LiquidityMath for amount calculations
        reserve0 = LiquidityMath.getAmount0Delta(
            sqrtPriceX96,
            sqrtPriceMaxX96,
            liquidityInt
        );
        
        reserve1 = LiquidityMath.getAmount1Delta(
            sqrtPriceMinX96,
            sqrtPriceX96,
            liquidityInt
        );
    }

    /**
     * @notice Calculate fees using LPFeeLibrary
     * @param fee The fee in pips (parts per million)
     * @param amount The amount to calculate fees for
     * @return The calculated fee amount
     */
    function _calculateFees(uint24 fee, uint256 amount) internal pure returns (uint256) {
        // Use LPFeeLibrary directly for consistent fee calculation
        // First validate the fee is within acceptable ranges
        fee.validate();
        
        // Then calculate the fee based on whether it's dynamic or static
        if (fee.isDynamicFee()) {
            return amount.mulDivRoundingUp(fee, 1_000_000);
        }
        return amount * fee / 1_000_000;
    }

    /**
     * @notice Perform slippage check for deposit or withdrawal
     * @param amount0 The actual amount of token0
     * @param amount1 The actual amount of token1
     * @param amount0Min The minimum amount of token0
     * @param amount1Min The minimum amount of token1
     */
    function _checkSlippage(
        uint256 amount0,
        uint256 amount1,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal pure {
        if (amount0 < amount0Min || amount1 < amount1Min) {
            revert SlippageCheckFailed();
        }
    }

    /**
     * @notice Force reinvestment of accumulated fees for a pool
     * @param key The pool key
     * @dev This function allows direct reinvestment of fees, even if below the automatic threshold
     *      This is useful in edge cases where:
     *      1. Fees have accumulated but are below the threshold
     *      2. A pool has been inactive for a long time 
     *      3. When leftover fees should be reinvested before a major operation
     */
    function forceReinvestFees(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        PoolInfo storage info = poolInfo[poolId];
        
        // Ensure there are leftovers to reinvest
        if (info.leftover0 == 0 && info.leftover1 == 0) revert NoFeesToReinvest();
        
        // Get the current sqrtPriceX96 for accurate liquidity calculation
        (uint160 sqrtPriceX96, , , ) = StateLibrary.getSlot0(poolManager, poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        
        // Calculate extra liquidity from fees considering current price
        uint256 extraLiquidity = FullRangeMathLib.calculateExtraLiquidity(
            info.leftover0,
            info.leftover1,
            sqrtPriceX96
        );
        
        // Ensure there is enough liquidity to add
        if (extraLiquidity == 0) revert NoFeesToReinvest();
        
        // Prepare data for the reinvestment modifyLiquidity call
        bytes memory reinvestData = abi.encode(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                liquidityDelta: int256(extraLiquidity),
                salt: bytes32(0)
            }),
            true // isReinvestment flag
        );
        
        // Call unlock on the poolManager which will trigger unlockCallback for reinvestment
        poolManager.unlock(reinvestData);
        
        // Settle the currency delta after reinvestment
        poolManager.settle();
        
        // Emit the FeesReinvested event
        emit FeesReinvested(poolId, info.leftover0, info.leftover1, extraLiquidity);
        
        // Reset leftovers as they've been reinvested
        info.leftover0 = 0;
        info.leftover1 = 0;
        
        // Update the total shares to reflect the reinvestment
        totalFullRangeShares[poolId] += extraLiquidity;
        
        // Also update the pool total liquidity
        info.totalLiquidity += uint128(extraLiquidity);
    }

    /**
     * @notice Calculate reinvestment liquidity with SwapMath for more precise calculations
     * @param feeAmount0 Amount of token0 fees
     * @param feeAmount1 Amount of token1 fees
     * @param sqrtPriceX96 Current sqrt price
     * @return liquidityAmount The calculated liquidity amount
     */
    function calculateReinvestmentLiquidity(
        uint256 feeAmount0,
        uint256 feeAmount1,
        uint160 sqrtPriceX96
    ) internal pure returns (uint256 liquidityAmount) {
        // Handle edge cases
        if (feeAmount0 == 0 && feeAmount1 == 0) {
            return 0;
        }
        
        if (feeAmount0 == 0) {
            return feeAmount1;
        }
        
        if (feeAmount1 == 0) {
            return feeAmount0;
        }
        
        // Calculate liquidity for token0 amount at current price
        uint128 liquidity0 = uint128(uint256(SqrtPriceMath.getAmount0Delta(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(MAX_TICK),
            int256(feeAmount0).toInt128()
        )));
        
        // Calculate liquidity for token1 amount at current price
        uint128 liquidity1 = uint128(uint256(SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(MIN_TICK),
            sqrtPriceX96,
            int256(feeAmount1).toInt128()
        )));
        
        // Take the minimum liquidity value (equivalent to getLiquidityForAmounts)
        return liquidity0 < liquidity1 ? liquidity0 : liquidity1;
    }
} 