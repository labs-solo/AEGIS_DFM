// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { Spot } from "./Spot.sol";
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
import { ISpotHooks } from "./interfaces/ISpotHooks.sol";
import { PoolTokenIdUtils } from "./utils/PoolTokenIdUtils.sol";
import { BaseHook } from "lib/uniswap-hooks/src/base/BaseHook.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { Currency, CurrencyLibrary } from "v4-core/src/types/Currency.sol";

/**
 * @title Margin
 * @notice Foundation for a margin lending system on Uniswap V4 spot liquidity positions
 * @dev Phase 1 establishes the architecture and data structures needed for future phases.
 *      Inherits governance/ownership from Spot via IPoolPolicy.
 */
contract Margin is Spot, IMargin {
    using SafeCast for uint256;
    using SafeCast for int256;
    using PoolIdLibrary for PoolKey;
    using EnumerableSet for EnumerableSet.AddressSet;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

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
     * @notice Tracks pending ETH payments for failed transfers
     */
    mapping(address => uint256) public pendingETHPayments;

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
     * @notice Price oracle will leverage ITruncGeoOracleMulti from Spot (Phase 2)
     */
    // address public priceOracleAddress; // Deferred until Phase 2

    /**
     * @notice Storage gap for future extensions
     */
    uint256[49] private __gap;

    // =========================================================================
    // Events (Added/Renamed for Phase 2)
    // =========================================================================
    event DepositCollateral(PoolId indexed poolId, address indexed user, uint256 amount0, uint256 amount1);
    event WithdrawCollateral(PoolId indexed poolId, address indexed user, uint256 sharesReduced, uint256 amount0, uint256 amount1);
    event VaultUpdated(PoolId indexed poolId, address indexed user, uint128 token0Balance, uint128 token1Balance, uint128 debtShare, uint256 timestamp);
    event ETHTransferFailed(address indexed recipient, uint256 amount);
    event ETHClaimed(address indexed recipient, uint256 amount);
    event PauseStatusChanged(bool isPaused);
    event InterestRateModelUpdated(address newModel);

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @notice Constructor
     * @param _poolManager The Uniswap V4 pool manager
     * @param _policyManager The policy manager (handles governance)
     * @param _liquidityManager The liquidity manager (dependency of Spot)
     */
    constructor(
        IPoolManager _poolManager,
        IPoolPolicy _policyManager,
        FullRangeLiquidityManager _liquidityManager
    ) Spot(_poolManager, _policyManager, _liquidityManager) {
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
        // Use the same utility as Spot
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
     * @notice Verify pool exists and is initialized in Spot
     * @param poolId The pool ID
     */
    function _verifyPoolInitialized(PoolId poolId) internal view {
        if (!isPoolInitialized(poolId)) { // Inherited from Spot
            revert Errors.PoolNotInitialized(poolId);
        }
    }

    // =========================================================================
    // Phase 2+ Functions (Implementations for Phase 2)
    // =========================================================================

    /**
     * @notice Deposit tokens as collateral into the user's vault
     * @param poolId The pool ID
     * @param amount0 Amount of token0 to deposit
     * @param amount1 Amount of token1 to deposit
     * @dev No return value, LP shares are not calculated here.
     */
    function depositCollateral(
        PoolId poolId,
        uint256 amount0,
        uint256 amount1
    ) external payable whenNotPaused nonReentrant {
        // Verify the pool is initialized
        _verifyPoolInitialized(poolId);
        
        // Get the pool key and check for native ETH
        PoolKey memory key = getPoolKey(poolId);
        
        // Check for native ETH usage
        bool hasNative = key.currency0.isNative() || key.currency1.isNative();
        if (msg.value > 0 && !hasNative) {
            revert Errors.NonzeroNativeValue();
        }
        
        // Ensure at least one token is being deposited
        if (amount0 == 0 && amount1 == 0) {
            revert Errors.ZeroAmount();
        }
        
        // Get the vault
        Vault storage vault = vaults[poolId][msg.sender];
        
        // Calculate the LP-equivalent shares of the deposit
        // Removed: shares = _lpEquivalent(poolId, amount0, amount1); // Not needed in Phase 1/2 deposit
        
        // Transfer tokens from the user to the contract
        if (amount0 > 0) {
            if (key.currency0.isNative()) {
                // Ensure sufficient ETH was sent
                if (msg.value < amount0) {
                     revert Errors.InsufficientETH(amount0, msg.value);
                }
                // No WETH.wrap needed as we hold native ETH
            } else {
                SafeTransferLib.safeTransferFrom(
                    ERC20(Currency.unwrap(key.currency0)), 
                    msg.sender, 
                    address(this), 
                    amount0
                );
            }
        }
        
        if (amount1 > 0) {
            if (key.currency1.isNative()) {
                 // Adjust amount needed based on whether token0 was also ETH
                uint256 ethNeeded = key.currency0.isNative() ? amount0 + amount1 : amount1;
                if (msg.value < ethNeeded) {
                     revert Errors.InsufficientETH(ethNeeded, msg.value);
                }
                 // No WETH.wrap needed
            } else {
                SafeTransferLib.safeTransferFrom(
                    ERC20(Currency.unwrap(key.currency1)), 
                    msg.sender, 
                    address(this), 
                    amount1
                );
            }
        }

        // Refund excess ETH
        uint256 ethUsed = 0;
        if (key.currency0.isNative()) ethUsed += amount0;
        if (key.currency1.isNative()) ethUsed += amount1;
        if (msg.value > ethUsed) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - ethUsed);
        }
        
        // Update the vault's token balances (use SafeCast)
        vault.token0Balance = (uint256(vault.token0Balance) + amount0).toUint128();
        vault.token1Balance = (uint256(vault.token1Balance) + amount1).toUint128();
        
        // Initialize lastAccrual if first deposit (for Phase 3)
        if (vault.lastAccrual == 0) {
            vault.lastAccrual = uint64(block.timestamp);
        }
        
        // Create a memory copy to pass to _updateVault
        Vault memory updatedVault = vault; 
        
        // Update the vault state, emit events, and manage user tracking
        _updateVault(poolId, msg.sender, updatedVault); 
        
        emit DepositCollateral(poolId, msg.sender, amount0, amount1);
        
        // Removed return shares;
    }

    /**
     * @notice Withdraw collateral from the user's vault by specifying token amounts
     * @param poolId The pool ID
     * @param amount0 Amount of token0 to withdraw
     * @param amount1 Amount of token1 to withdraw
     * @return sharesReduced The equivalent LP shares of the withdrawn tokens
     */
    function withdrawCollateral(
        PoolId poolId,
        uint256 amount0,
        uint256 amount1
    ) external whenNotPaused nonReentrant returns (uint256 sharesReduced) {
        // Verify the pool is initialized
        _verifyPoolInitialized(poolId);
        
        // Get the pool key
        PoolKey memory key = getPoolKey(poolId);
        
        // Get the vault
        Vault storage vault = vaults[poolId][msg.sender];
        
        // Ensure the user has enough balance to withdraw
        if (amount0 > vault.token0Balance) {
            revert Errors.InsufficientBalance(amount0, vault.token0Balance);
        }
        if (amount1 > vault.token1Balance) {
            revert Errors.InsufficientBalance(amount1, vault.token1Balance);
        }
        
        // Calculate the LP-equivalent shares of the withdrawal
        sharesReduced = _lpEquivalent(poolId, amount0, amount1);
        
        // Update the vault's token balances (use SafeCast)
        vault.token0Balance = (uint256(vault.token0Balance) - amount0).toUint128();
        vault.token1Balance = (uint256(vault.token1Balance) - amount1).toUint128();
        
        // Transfer tokens to the user
        if (amount0 > 0) {
            if (key.currency0.isNative()) {
                _safeTransferETH(msg.sender, amount0);
            } else {
                SafeTransferLib.safeTransfer(
                    ERC20(Currency.unwrap(key.currency0)), 
                    msg.sender, 
                    amount0
                );
            }
        }
        
        if (amount1 > 0) {
            if (key.currency1.isNative()) {
                _safeTransferETH(msg.sender, amount1);
            } else {
                SafeTransferLib.safeTransfer(
                    ERC20(Currency.unwrap(key.currency1)), 
                    msg.sender, 
                    amount1
                );
            }
        }
        
        // Create a memory copy to pass to _updateVault
        Vault memory updatedVault = vault;

        // Update the vault state, emit events, and manage user tracking
        _updateVault(poolId, msg.sender, updatedVault);
        
        emit WithdrawCollateral(poolId, msg.sender, sharesReduced, amount0, amount1);
        
        return sharesReduced;
    }

    /**
     * @notice Placeholder for borrow function (Phase 3)
     */
    function borrow(PoolId poolId, uint256 shares) external override whenNotPaused {
        revert Errors.NotImplemented(); // Keep as not implemented for Phase 2
    }

    /**
     * @notice Placeholder for repay function (Phase 3)
     */
    function repay(PoolId poolId, uint256 shares, uint256 amount0Max, uint256 amount1Max) external payable override whenNotPaused {
        revert Errors.NotImplemented(); // Keep as not implemented for Phase 2
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
     * @notice Get the value of a vault in LP-equivalent shares
     * @param poolId The pool ID
     * @param user The user address
     * @return value The LP-equivalent value of the vault
     */
    function getVaultValue(PoolId poolId, address user) external view returns (uint256 value) {
        Vault memory vault = vaults[poolId][user];
        // Phase 2: Value is purely collateral
        return _lpEquivalent(poolId, vault.token0Balance, vault.token1Balance);
    }

    /**
     * @notice Get detailed information about a vault's collateral
     * @param poolId The pool ID
     * @param user The user address
     * @return token0Balance Amount of token0 in the vault
     * @return token1Balance Amount of token1 in the vault
     * @return equivalentLPShares The LP-equivalent value of the vault collateral
     */
    function getVaultCollateral(PoolId poolId, address user) external view returns (
        uint256 token0Balance,
        uint256 token1Balance,
        uint256 equivalentLPShares
    ) {
        Vault memory vault = vaults[poolId][user];
        token0Balance = vault.token0Balance;
        token1Balance = vault.token1Balance;
        // Phase 2: Value is purely collateral
        equivalentLPShares = _lpEquivalent(poolId, vault.token0Balance, vault.token1Balance);
        return (token0Balance, token1Balance, equivalentLPShares);
    }

    /**
     * @notice Placeholder for isVaultSolvent (Phase 3)
     */
    function isVaultSolvent(PoolId poolId, address user) external view override returns (bool) {
        // Phase 2: No borrowing, so all vaults are solvent by default
        return true;
    }

    /**
     * @notice Placeholder for getVaultLTV (Phase 3)
     */
    function getVaultLTV(PoolId poolId, address user) external view override returns (uint256) {
        // Phase 2: No borrowing, so LTV is always 0
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
    // Access Control Modifiers (Inherited from Spot / Defined Below)
    // =========================================================================

    /**
     * @notice Only allow when contract is not paused
     */
    modifier whenNotPaused() {
        if (paused) revert Errors.ContractPaused(); // Assumes ContractPaused exists in Errors.sol
        _;
    }

    // onlyGovernance is inherited effectively via Spot's dependency on IPoolPolicy
    // onlyPoolManager is inherited from Spot

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
     * @dev Extends Spot._afterPoolInitialized to set Phase 2 variables
     */
    function _afterPoolInitialized(
        PoolId poolId,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal virtual override {
        // Call Spot's internal implementation
        Spot._afterPoolInitialized(poolId, key, sqrtPriceX96, tick);
        
        // Initialize interest multiplier (Phase 2+)
        interestMultiplier[poolId] = PRECISION;
        
        // Initialize last interest accrual time (Phase 2+)
        lastInterestAccrualTime[poolId] = block.timestamp;
        
        // Emit an event? Or rely on Spot event?
    }

    // --- Hook Overrides with onlyPoolManager --- 
    // Ensure ALL hooks callable by the PoolManager are overridden and protected.
    
    // Initialize hooks
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal override onlyPoolManager returns (bytes4)
    {
        // Return selector directly instead of using super
        return this.beforeInitialize.selector;
    }
        
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal override onlyPoolManager returns (bytes4)
    {
        // Call the internal implementation from the base contract
        _afterInitializeInternal(sender, key, sqrtPriceX96, tick);
        // Margin-specific logic (if any) would go here
        // Return selector directly instead of using super's return value (which is the same)
        return this.afterInitialize.selector;
    }

    // Add/remove liquidity hooks
    function _beforeAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata hookData)
        internal override onlyPoolManager returns (bytes4)
    {
        // Phase 2+: May need checks here related to deposits
        // Return selector directly instead of using super
        return this.beforeAddLiquidity.selector;
    }
        
    function _afterAddLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata hookData)
        internal override onlyPoolManager returns (bytes4, BalanceDelta)
    {
        // Phase 2+: Will need to update vaults based on delta/hookData
        // Return selector and zero delta directly
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
        
    function _beforeRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, bytes calldata hookData)
        internal override onlyPoolManager returns (bytes4)
    {
        // Phase 2+: May need checks here related to withdrawals/solvency
        // Return selector directly instead of using super
        return this.beforeRemoveLiquidity.selector;
    }
        
    function _afterRemoveLiquidity(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata hookData)
        internal override onlyPoolManager returns (bytes4, BalanceDelta)
    {
        // Phase 2+: Will need to update vaults based on delta/hookData
        // Return selector and zero delta directly
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // Swap hooks
    function _beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
        internal override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Phase 1: Defer to Spot logic (Replicated here to avoid super issues)
        
        // Ensure dynamic fee manager has been set (inherited from Spot)
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
        
    function _afterSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        internal override onlyPoolManager returns (bytes4, int128)
    {
        // Phase 1: Defer to Spot logic (Replicated here to avoid super issues)
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

    // Donate hooks (Assuming Spot implements these - verify if needed)
    // function beforeDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
    //     external override onlyPoolManager returns (bytes4)
    // {
    //     // Phase 1: Defer to Spot
    //     // Return selector directly instead of using super
    //     return IHooks.beforeDonate.selector;
    // }
        
    // function afterDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata hookData)
    //     external override onlyPoolManager returns (bytes4)
    // {
    //     // Phase 1: Defer to Spot
    //     // Return selector directly instead of using super
    //     return IHooks.afterDonate.selector;
    // }

    // Return delta hooks (Verify which are implemented/needed by Spot)
    // These might not all be strictly required to override if Spot doesn't use them,
    // but overriding ensures protection if the base contract changes.
    
    // function beforeSwapReturnDelta(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
    //     external override onlyPoolManager returns (bytes4, BeforeSwapDelta)
    // {
    //     // Return defaults directly (from Spot)
    //     return (bytes4(0), BeforeSwapDeltaLibrary.ZERO_DELTA);
    // }
        
    // function afterSwapReturnDelta(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
    //     external override onlyPoolManager returns (bytes4, BalanceDelta)
    // {
    //     // Return defaults directly (from Spot)
    //     // Note: Spot uses ISpotHooks.afterSwapReturnDelta.selector here, needs check if defined/needed
    //     return (ISpotHooks.afterSwapReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    // }
        
    // function afterAddLiquidityReturnDelta(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, bytes calldata hookData)
    //     external override onlyPoolManager returns (bytes4, BalanceDelta)
    // {
    //     // Phase 2+: Vault updates might happen here too
    //     // Return defaults directly (from Spot)
    //     // Note: Spot uses ISpotHooks.afterAddLiquidityReturnDelta.selector here, needs check if defined/needed
    //     return (ISpotHooks.afterAddLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    // }
        
    function afterRemoveLiquidityReturnDelta(address sender, PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params, BalanceDelta delta, BalanceDelta feesAccrued, bytes calldata hookData)
        external override onlyPoolManager returns (bytes4, BalanceDelta)
    {
        // Phase 2+: Vault updates might happen here too
        // Return defaults directly (from Spot)
        // Note: Spot uses ISpotHooks.afterRemoveLiquidityReturnDelta.selector here, needs check if defined/needed
        return (ISpotHooks.afterRemoveLiquidityReturnDelta.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // =========================================================================
    // Helper Functions (Added for Phase 2)
    // =========================================================================
    
    /**
     * @notice Safe transfer ETH with fallback to pending payments
     * @param recipient The address to send ETH to
     * @param amount The amount of ETH to send
     */
    function _safeTransferETH(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        
        (bool success, ) = recipient.call{value: amount, gas: 50000}(""); // Use fixed gas stipend
        if (!success) {
            pendingETHPayments[recipient] += amount;
            emit ETHTransferFailed(recipient, amount);
        }
    }

    /**
     * @notice Claim pending ETH payments resulting from failed transfers during withdrawal
     */
    function claimPendingETH() external nonReentrant {
        uint256 amount = pendingETHPayments[msg.sender];
        if (amount == 0) return; // Nothing to claim
        
        // Clear pending amount *before* transfer (Reentrancy check)
        pendingETHPayments[msg.sender] = 0; 
        
        // Attempt transfer again
        (bool success, ) = msg.sender.call{value: amount, gas: 50000}(""); 
        if (!success) {
             // If it still fails, revert and restore the pending amount
            pendingETHPayments[msg.sender] = amount; 
            revert Errors.ETHTransferFailed(msg.sender, amount); 
        }
        
        emit ETHClaimed(msg.sender, amount);
    }
} 