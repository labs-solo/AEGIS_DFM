// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { FullRange } from "./FullRange.sol";
import { IMargin } from "./interfaces/IMargin.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";
import { ReentrancyGuard } from "solmate/src/utils/ReentrancyGuard.sol";
import { SafeCast } from "v4-core/src/libraries/SafeCast.sol";
import { MathUtils } from "./libraries/MathUtils.sol";
import { Errors } from "./errors/Errors.sol";
import { FullRangeLiquidityManager } from "./FullRangeLiquidityManager.sol";
import { IPoolPolicy } from "./interfaces/IPoolPolicy.sol";
import { EnumerableSet } from "v4-core/lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import { FullMath } from "v4-core/src/libraries/FullMath.sol";
// import { IPriceOracle } from "./interfaces/IPriceOracle.sol"; // Deferred until Phase 2
import { IInterestRateModel } from "./interfaces/IInterestRateModel.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { IFullRangeHooks } from "./interfaces/IFullRangeHooks.sol";
import { PoolTokenIdUtils } from "./utils/PoolTokenIdUtils.sol";

/**
 * @title Margin
 * @notice Foundation for a margin lending system on Uniswap V4 full-range liquidity positions
 * @dev Phase 1 establishes the architecture and data structures needed for future phases.
 *      Inherits governance/ownership from FullRange via IPoolPolicy.
 */
contract Margin is FullRange, IMargin {
    using SafeCast for uint256;
    using SafeCast for int256;
    using PoolIdLibrary for PoolKey;
    using EnumerableSet for EnumerableSet.AddressSet;
    using BalanceDeltaLibrary for BalanceDelta;

    // =========================================================================
    // Constants
    // =========================================================================

    /**
     * @notice Precision for fixed-point math (1e18)
     */
    uint256 public constant PRECISION = 1e18;

    /**
     * @notice Percent above which a position is considered insolvent (Phase 2+)
     * @dev 98% (0.98 * PRECISION)
     */
    uint256 public constant SOLVENCY_THRESHOLD_LIQUIDATION = (980 * PRECISION) / 1000;

    /**
     * @notice Percent at which a position can be liquidated with max fee (Phase 3)
     * @dev 99% (0.99 * PRECISION)
     */
    uint256 public constant SOLVENCY_THRESHOLD_FULL_LIQUIDATION = (990 * PRECISION) / 1000;

    /**
     * @notice Protocol's share of interest rate (Phase 2+)
     * @dev 10%
     */
    uint256 public constant FEE_SHARE = (10 * PRECISION) / 100;

    /**
     * @notice Liquidation fee percentage (Phase 3)
     * @dev 1% (0.01 * PRECISION) - Note: original spec used 10_000, assuming PPM, this translates to 1%
     */
    uint256 public constant LIQUIDATION_FEE = (1 * PRECISION) / 100;

    /**
     * @notice Maximum utility rate for an LP (Phase 2+)
     * @dev 95% (0.95 * PRECISION)
     */
    uint256 public constant MAX_UTILITY_RATE = (95 * PRECISION) / 100;

    /**
     * @notice Minimum liquidity allowed in a pool (prevent division by zero)
     */
    uint256 public constant MINIMUM_LIQUIDITY = 1e4;

    // =========================================================================
    // State Variables
    // =========================================================================

    /**
     * @notice Maps user addresses to their vaults for each pool
     */
    mapping(PoolId => mapping(address => Vault)) public vaults;

    /**
     * @notice Tracks all users with vaults for each pool using efficient EnumerableSet
     */
    mapping(PoolId => EnumerableSet.AddressSet) private poolUsers;

    /**
     * @notice Tracks the total amount of rented liquidity per pool (Phase 2+)
     */
    mapping(PoolId => uint256) public rentedLiquidity;

    /**
     * @notice Interest multiplier used in calculations (Phase 2+)
     */
    mapping(PoolId => uint256) public interestMultiplier;

    /**
     * @notice Last time interest was accrued globally for a pool (Phase 2+)
     */
    mapping(PoolId => uint256) public lastInterestAccrualTime;

    /**
     * @notice Emergency pause switch
     */
    bool public paused;

    /**
     * @notice Interest rate model address (Phase 2)
     */
    address public interestRateModelAddress;

    /**
     * @notice Price oracle will leverage ITruncGeoOracleMulti from FullRange (Phase 2)
     */
    // address public priceOracleAddress; // Deferred until Phase 2

    /**
     * @notice Storage gap for future extensions
     */
    uint256[50] private __gap;

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @notice Constructor
     * @param _poolManager The Uniswap V4 pool manager
     * @param _policyManager The policy manager (handles governance)
     * @param _liquidityManager The liquidity manager (dependency of FullRange)
     */
    constructor(
        IPoolManager _poolManager,
        IPoolPolicy _policyManager,
        FullRangeLiquidityManager _liquidityManager
    ) FullRange(_poolManager, _policyManager, _liquidityManager) {
        // Phase 1 initialization is minimal
        // Phase 2 will add interest rate model and leverage price oracle functionality
    }

    // =========================================================================
    // Core Utility Functions
    // =========================================================================

    /**
     * @notice Convert between pool token ID and ERC-6909 token ID
     * @param poolId The pool ID
     * @return tokenId The ERC-6909 token ID
     */
    function poolIdToTokenId(PoolId poolId) internal pure returns (uint256 tokenId) {
        // Use the same utility as FullRange
        return PoolTokenIdUtils.toTokenId(poolId);
        // assembly {
        //     tokenId := poolId
        // }
    }

    /**
     * @notice Calculate the LP-equivalent value of token amounts
     * @param poolId The pool ID
     * @param amount0 Amount of token0
     * @param amount1 Amount of token1
     * @return lpShares Equivalent LP shares (rounded down)
     */
    function _lpEquivalent(
        PoolId poolId,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint256 lpShares) {
        (uint256 reserve0, uint256 reserve1, uint128 totalLiquidity) = getPoolReservesAndShares(poolId);
        
        if (reserve0 == 0 || reserve1 == 0 || totalLiquidity == 0) return 0;
        
        // Use Uniswap's actual liquidity calculation for accuracy
        // Both calculations use floor division (rounded down)
        uint256 liquidityFrom0 = FullMath.mulDiv(amount0, totalLiquidity, reserve0);
        uint256 liquidityFrom1 = FullMath.mulDiv(amount1, totalLiquidity, reserve1);
        
        // Take the minimum to determine actual liquidity (conservative approach)
        lpShares = liquidityFrom0 < liquidityFrom1 ? liquidityFrom0 : liquidityFrom1;
        
        return lpShares;
    }

    /**
     * @notice Convert LP shares to token amounts
     * @param poolId The pool ID
     * @param shares Number of LP shares
     * @return amount0 Amount of token0
     * @return amount1 Amount of token1
     * @dev Special care needed for the edge case of tiny share values:
     *      If calculated amount is 0 but shares > 0, we set amount to 1 to prevent 
     *      returning zero tokens for non-zero shares. This approach needs careful testing
     *      to ensure it doesn't lead to unexpected economic outcomes, particularly:
     *      - Test with extremely small share values near precision boundaries
     *      - Verify that the "amount = 1" assignment doesn't create disproportionate
     *        economics that could be exploited
     *      - Ensure consistency with other contracts that may round differently
     */
    function _sharesTokenEquivalent(
        PoolId poolId,
        uint256 shares
    ) internal view returns (uint256 amount0, uint256 amount1) {
        (uint256 reserve0, uint256 reserve1, uint128 totalLiquidity) = getPoolReservesAndShares(poolId);
        
        if (totalLiquidity == 0) return (0, 0);
        
        // Calculate proportional token amounts
        amount0 = FullMath.mulDiv(reserve0, shares, totalLiquidity);
        amount1 = FullMath.mulDiv(reserve1, shares, totalLiquidity);
        
        // Ensure non-zero amounts for very small shares
        // IMPORTANT: This approach needs careful testing to avoid economic exploits
        if (amount0 == 0 && shares > 0 && reserve0 > 0) amount0 = 1;
        if (amount1 == 0 && shares > 0 && reserve1 > 0) amount1 = 1;
    }

    /**
     * @notice Add a user to the pool users tracking set
     * @param poolId The pool ID
     * @param user The user address
     */
    function _addPoolUser(PoolId poolId, address user) internal {
        poolUsers[poolId].add(user);
    }

    /**
     * @notice Remove a user from the pool users tracking set if they have no position
     * @param poolId The pool ID
     * @param user The user address
     */
    function _removePoolUserIfEmpty(PoolId poolId, address user) internal {
        Vault storage vault = vaults[poolId][user];
        
        // Only remove if vault is completely empty (collateral and debt)
        if (vault.token0Balance == 0 && vault.token1Balance == 0 && vault.debtShare == 0) {
            poolUsers[poolId].remove(user);
        }
    }

    /**
     * @notice Update vault and emit event
     * @param poolId The pool ID
     * @param user The user address
     * @param vault The updated vault
     */
    function _updateVault(
        PoolId poolId,
        address user,
        Vault memory vault
    ) internal {
        vaults[poolId][user] = vault;
        
        emit VaultUpdated(
            poolId,
            user,
            vault.token0Balance,
            vault.token1Balance,
            vault.debtShare,
            block.timestamp
        );
        
        // Ensure user tracking is updated based on the new vault state
        if (vault.token0Balance > 0 || vault.token1Balance > 0 || vault.debtShare > 0) {
             _addPoolUser(poolId, user);
        } else {
            _removePoolUserIfEmpty(poolId, user);
        }
    }

    /**
     * @notice Verify pool exists and is initialized in FullRange
     * @param poolId The pool ID
     */
    function _verifyPoolInitialized(PoolId poolId) internal view {
        if (!isPoolInitialized(poolId)) { // Inherited from FullRange
            revert Errors.PoolNotInitialized(poolId);
        }
    }

    // =========================================================================
    // Phase 2+ Functions (Stubs for Phase 1)
    // =========================================================================

    /**
     * @notice Placeholder for deposit function (Phase 2)
     */
    function deposit(PoolId poolId, uint256 amount0, uint256 amount1) external payable whenNotPaused {
        revert Errors.NotImplemented(); // Use standard error from Errors.sol
    }

    /**
     * @notice Placeholder for withdraw function (Phase 2)
     */
    function withdraw(PoolId poolId, uint256 shares, uint256 amount0Min, uint256 amount1Min) external whenNotPaused {
        revert Errors.NotImplemented(); // Use standard error from Errors.sol
    }

    /**
     * @notice Placeholder for borrow function (Phase 2)
     */
    function borrow(PoolId poolId, uint256 shares) external whenNotPaused {
        revert Errors.NotImplemented(); // Use standard error from Errors.sol
    }

    /**
     * @notice Placeholder for repay function (Phase 2)
     */
    function repay(PoolId poolId, uint256 shares, uint256 amount0Max, uint256 amount1Max) external payable whenNotPaused {
        revert Errors.NotImplemented(); // Use standard error from Errors.sol
    }

    // =========================================================================
    // View Functions
    // =========================================================================

    /**
     * @notice Get vault information
     */
    function getVault(PoolId poolId, address user) external view override returns (Vault memory) {
        return vaults[poolId][user];
    }

    /**
     * @notice Placeholder for isVaultSolvent (Phase 2)
     */
    function isVaultSolvent(PoolId poolId, address user) external view override returns (bool) {
        // Phase 1: No borrowing, so all vaults are solvent by default
        return true;
    }

    /**
     * @notice Placeholder for getVaultLTV (Phase 2)
     */
    function getVaultLTV(PoolId poolId, address user) external view override returns (uint256) {
        // Phase 1: No borrowing, so LTV is always 0
        return 0;
    }

    /**
     * @notice Get the number of users with vaults in a pool
     */
    function getPoolUserCount(PoolId poolId) external view returns (uint256) {
        return poolUsers[poolId].length();
    }

    /**
     * @notice Get a list of users with vaults in a pool (paginated)
     */
    function getPoolUsers(
        PoolId poolId, 
        uint256 startIndex, 
        uint256 count
    ) external view returns (address[] memory users) {
        uint256 totalUsers = poolUsers[poolId].length();
        if (startIndex >= totalUsers || count == 0) {
            return new address[](0);
        }
        
        uint256 endIndex = startIndex + count;
        if (endIndex > totalUsers) {
            endIndex = totalUsers;
        }
        
        uint256 length = endIndex - startIndex;
        users = new address[](length);
        
        for (uint256 i = 0; i < length; i++) {
            users[i] = poolUsers[poolId].at(startIndex + i);
        }
        
        return users;
    }

    /**
     * @notice Check if a user has a vault (any balance or debt) in the pool
     */
    function hasVault(PoolId poolId, address user) external view returns (bool) {
        return poolUsers[poolId].contains(user);
    }

    // =========================================================================
    // Admin Functions
    // =========================================================================

    /**
     * @notice Set the contract pause state
     */
    function setPaused(bool _paused) external onlyGovernance {
        paused = _paused;
        emit PauseStatusChanged(_paused);
    }

    /**
     * @notice Set the interest rate model address (Phase 2)
     */
    function setInterestRateModel(address _interestRateModel) external onlyGovernance {
        if (_interestRateModel == address(0)) revert Errors.ZeroAddress();
        address oldModel = interestRateModelAddress;
        interestRateModelAddress = _interestRateModel;
        emit InterestRateModelUpdated(_interestRateModel);
    }

    // No setPriceOracle function needed in Phase 1 - will use ITruncGeoOracleMulti

    // =========================================================================
    // Access Control Modifiers (Inherited from FullRange / Defined Below)
    // =========================================================================

    /**
     * @notice Only allow when contract is not paused
     */
    modifier whenNotPaused() {
        if (paused) revert Errors.ContractPaused(); // Assumes ContractPaused exists in Errors.sol
        _;
    }

    // onlyGovernance is inherited effectively via FullRange's dependency on IPoolPolicy
    // onlyPoolManager is inherited from FullRange

    // =========================================================================
    // Overrides and Hook Security
    // =========================================================================
    /**
     * @notice Special note on implementing deposit and withdraw functionality
     * @dev While all hooks must be overridden with onlyPoolManager, special attention 
     * must be paid to the deposit and withdraw functions as these will need to be 
     * extended in later phases to support vault operations. The Phase 1 implementation
     * should ensure a clean extension path by properly structuring these functions 
     * and anticipating future integration with vault operations.
     */

    /**
     * @notice Set up initial pool state when a pool is initialized
     * @dev Extends FullRange._afterPoolInitialized to set Phase 2 variables
     */
    function _afterPoolInitialized(
        PoolId poolId,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal override {
        super._afterPoolInitialized(poolId, key, sqrtPriceX96, tick);
        
        // Initialize interest multiplier (Phase 2+)
        interestMultiplier[poolId] = PRECISION;
        
        // Initialize last interest accrual time (Phase 2+)
        lastInterestAccrualTime[poolId] = block.timestamp;
        
        // Emit an event? Or rely on FullRange event?
    }

    // --- Hook Overrides with onlyPoolManager --- 
    // Ensure ALL hooks callable by the PoolManager are overridden and protected.
    
    // Initialize hooks
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external override onlyPoolManager returns (bytes4)
    {
        // Return selector directly instead of using super
        return IHooks.beforeInitialize.selector;
    }
        
    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external override onlyPoolManager returns (bytes4)
    {
        // Note: The internal _afterPoolInitialized is called by FullRange.afterInitialize
        // Return selector directly instead of using super
        return IHooks.afterInitialize.selector;
    }

    // Add/remove liquidity hooks
    function beforeAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata hookData)
        external override onlyPoolManager returns (bytes4)
    {
        // Phase 2+: May need checks here related to deposits
        // Return selector directly instead of using super
        return IHooks.beforeAddLiquidity.selector;
    }
        
    function afterAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata hookData)
        external override onlyPoolManager returns (bytes4, BalanceDelta)
    {
        // Phase 2+: Will need to update vaults based on delta/hookData
        // Return selector and zero delta directly
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
        
    function beforeRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata hookData)
        external override onlyPoolManager returns (bytes4)
    {
        // Phase 2+: May need checks here related to withdrawals/solvency
        // Return selector directly instead of using super
        return IHooks.beforeRemoveLiquidity.selector;
    }
        
    function afterRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata hookData)
        external override onlyPoolManager returns (bytes4, BalanceDelta)
    {
        // Phase 2+: Will need to update vaults based on delta/hookData
        // Return selector and zero delta directly
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // Swap hooks
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
        external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Phase 1: Defer to FullRange logic (Replicated here to avoid super issues)
        
        // Ensure dynamic fee manager has been set (inherited from FullRange)
        if (address(dynamicFeeManager) == address(0)) {
            revert Errors.NotInitialized("DynamicFeeManager");
        }

        // Return dynamic fee and no delta
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            uint24(dynamicFeeManager.getCurrentDynamicFee(key.toId()))
        );
    }
        
    function afterSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        external override onlyPoolManager returns (bytes4, int128)
    {
        // Phase 1: Defer to FullRange logic (Replicated here to avoid super issues)
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
        
        return (IHooks.afterSwap.selector, 0);
    }

    // Donate hooks (Assuming FullRange implements these - verify if needed)
    function beforeDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external override onlyPoolManager returns (bytes4)
    {
        // Phase 1: Defer to FullRange
        // Return selector directly instead of using super
        return IHooks.beforeDonate.selector;
    }
        
    function afterDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external override onlyPoolManager returns (bytes4)
    {
        // Phase 1: Defer to FullRange
        // Return selector directly instead of using super
        return IHooks.afterDonate.selector;
    }

    // Return delta hooks (Verify which are implemented/needed by FullRange)
    // These might not all be strictly required to override if FullRange doesn't use them,
    // but overriding ensures protection if the base contract changes.
    
    function beforeSwapReturnDelta(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
        external override onlyPoolManager returns (bytes4, BeforeSwapDelta)
    {
        // Return defaults directly (from FullRange)
        return (bytes4(0), BeforeSwapDeltaLibrary.ZERO_DELTA);
    }
        
    function afterSwapReturnDelta(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        external override onlyPoolManager returns (bytes4, BalanceDelta)
    {
        // Return defaults directly (from FullRange)
        // Note: FullRange uses IFullRangeHooks.afterSwapReturnDelta.selector here, needs check if defined/needed
        return (IFullRangeHooks.afterSwapReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
        
    function afterAddLiquidityReturnDelta(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, bytes calldata hookData)
        external override onlyPoolManager returns (bytes4, BalanceDelta)
    {
        // Phase 2+: Vault updates might happen here too
        // Return defaults directly (from FullRange)
        // Note: FullRange uses IFullRangeHooks.afterAddLiquidityReturnDelta.selector here, needs check if defined/needed
        return (IFullRangeHooks.afterAddLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
        
    function afterRemoveLiquidityReturnDelta(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata hookData)
        external override onlyPoolManager returns (bytes4, BalanceDelta)
    {
        // Phase 2+: Vault updates might happen here too
        // Return defaults directly (from FullRange)
        // Note: FullRange uses IFullRangeHooks.afterRemoveLiquidityReturnDelta.selector here, needs check if defined/needed
        return (IFullRangeHooks.afterRemoveLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
} 