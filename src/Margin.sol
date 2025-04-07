// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { Spot, DepositParams, WithdrawParams } from "./Spot.sol";
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
import { IInterestRateModel } from "./interfaces/IInterestRateModel.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { ISpotHooks } from "./interfaces/ISpotHooks.sol";
import { PoolTokenIdUtils } from "./utils/PoolTokenIdUtils.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { Currency } from "lib/v4-core/src/types/Currency.sol";
import { CurrencyLibrary } from "lib/v4-core/src/types/Currency.sol";
import { TruncatedOracle } from "./libraries/TruncatedOracle.sol";
import { IFeeReinvestmentManager } from "./interfaces/IFeeReinvestmentManager.sol";
import { ISpot } from "./interfaces/ISpot.sol";

/**
 * @title Margin
 * @notice Foundation for a margin lending system on Uniswap V4 spot liquidity positions
 * @dev Phase 1 establishes the architecture and data structures needed for future phases.
 *      Phase 2 added basic collateral deposit/withdraw.
 *      Phase 3 implements borrowing, repayment, and interest accrual following the BAMM model.
 *      Phase 4 adds dynamic interest rates via IInterestRateModel, protocol fee tracking, and utilization limits.
 *      Inherits governance/ownership from Spot via IPoolPolicy.
 */
contract Margin is Spot, IMargin {
    using SafeCast for uint256;
    using SafeCast for int256;
    using PoolIdLibrary for PoolKey;
    using EnumerableSet for EnumerableSet.AddressSet;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using FullMath for uint256;

    // =========================================================================
    // Constants (Updated for Phase 3)
    // =========================================================================

    /**
     * @notice Precision for fixed-point math (1e18)
     */
    uint256 public constant PRECISION = 1e18;

    /**
     * @notice Percent below which a position is considered solvent
     * @dev 98% (0.98 * PRECISION)
     */
    uint256 public constant SOLVENCY_THRESHOLD_LIQUIDATION = (980 * PRECISION) / 1000;

    /**
     * @notice Percent at which a position can be liquidated with max fee (Phase 6)
     * @dev 99% (0.99 * PRECISION)
     */
    uint256 public constant SOLVENCY_THRESHOLD_FULL_LIQUIDATION = (990 * PRECISION) / 1000;

    /**
     * @notice Liquidation fee percentage (Phase 6)
     * @dev 1% (0.01 * PRECISION)
     */
    uint256 public constant LIQUIDATION_FEE = (1 * PRECISION) / 100;

    /**
     * @notice Maximum utility rate for a pool
     * @dev 95% (0.95 * PRECISION)
     */
    uint256 public constant MAX_UTILITY_RATE = (95 * PRECISION) / 100;

    /**
     * @notice Minimum liquidity allowed in a pool (prevent division by zero)
     */
    uint256 public constant MINIMUM_LIQUIDITY = 1e4; // From Phase 2, still relevant

    // =========================================================================
    // State Variables (Updated for Phase 3)
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
     * @notice Tracks the total amount of rented liquidity per pool (LP share equivalent)
     */
    mapping(PoolId => uint256) public rentedLiquidity; // Phase 3 addition

    /**
     * @notice Interest multiplier used in calculations (1e18 precision)
     */
    mapping(PoolId => uint256) public interestMultiplier; // Phase 3 addition (replaces previous phase placeholder)

    /**
     * @notice Last time interest was accrued globally for a pool
     */
    mapping(PoolId => uint256) public lastInterestAccrualTime; // Phase 3 addition (replaces previous phase placeholder)

    /**
     * @notice Emergency pause switch
     */
    bool public paused;

    /**
     * @notice Interest rate model address (Used in Phase 4+)
     */
    address public interestRateModelAddress;

    /**
     * @notice Tracks protocol fees accrued from interest, denominated in share value
     * @dev Added in Phase 4
     */
    mapping(PoolId => uint256) public accumulatedFees; // Phase 4 Addition

    /**
     * @notice Storage gap for future extensions
     */
    uint256[48] private __gap;

    // =========================================================================
    // Events (Updated/Added for Phase 3)
    // =========================================================================
    // Note: Events are defined in IMargin interface and emitted here.
    event DepositCollateral(PoolId indexed poolId, address indexed user, uint256 amount0, uint256 amount1);
    event WithdrawCollateral(PoolId indexed poolId, address indexed user, uint256 sharesValue, uint256 amount0, uint256 amount1); // Updated shares parameter name
    // event VaultUpdated(PoolId indexed poolId, address indexed user, uint128 token0Balance, uint128 token1Balance, uint128 debtShare, uint256 timestamp); // Defined in IMargin
    event ETHTransferFailed(address indexed recipient, uint256 amount);
    event ETHClaimed(address indexed recipient, uint256 amount);
    // event PauseStatusChanged(bool isPaused); // Defined in IMargin
    // event InterestRateModelUpdated(address newModel); // Defined in IMargin

    // Phase 3 Events
    // event InterestAccrued(
    //     PoolId indexed poolId,
    //     address indexed user,     // address(0) for pool-level accrual
    //     uint256 interestRate,     // per second rate
    //     uint256 timeElapsed,      // elapsed time
    //     uint256 newMultiplier     // new interest multiplier
    // );
    // event Borrow(
    //     PoolId indexed poolId,
    //     address indexed user,
    //     uint256 shares,           // LP shares borrowed
    //     uint256 amount0,          // token0 received
    //     uint256 amount1           // token1 received
    // );
    // event Repay(
    //     PoolId indexed poolId,
    //     address indexed user,
    //     uint256 shares,           // LP shares repaid
    //     uint256 amount0,          // token0 used
    //     uint256 amount1           // token1 used
    // );
    // event WithdrawBorrowedTokens // Removed as per revised design

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
        // Initialization happens in _afterPoolInitialized
    }

    // =========================================================================
    // Core Utility Functions (Mostly unchanged from Phase 2)
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
        
        // event VaultUpdated(
        //     poolId,
        //     user,
        //     vault.token0Balance,
        //     vault.token1Balance,
        //     vault.debtShare,
        //     block.timestamp
        // );
        
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
    // Phase 3+ Functions (Implementations for Phase 3)
    // =========================================================================

    /**
     * @notice Deposit tokens as collateral into the user's vault
     * @param poolId The pool ID
     * @param amount0 Amount of token0 to deposit
     * @param amount1 Amount of token1 to deposit
     * @dev Primarily Phase 2 logic, but accrues interest first in Phase 3.
     */
    function depositCollateral(
        PoolId poolId,
        uint256 amount0,
        uint256 amount1
    ) external payable whenNotPaused nonReentrant {
        // Verify the pool is initialized
        _verifyPoolInitialized(poolId);

        // Accrue interest before modifying vault state
        _accrueInterestForUser(poolId, msg.sender);
        
        // Get the pool key and check for native ETH
        PoolKey memory key = getPoolKey(poolId);
        
        // Check for native ETH usage
        bool hasNative = key.currency0.isAddressZero() || key.currency1.isAddressZero();
        if (msg.value > 0 && !hasNative) {
            revert Errors.NonzeroNativeValue();
        }

        // Ensure at least one token is being deposited
        if (amount0 == 0 && amount1 == 0) {
            revert Errors.ZeroAmount();
        }

        // Get the vault
        Vault storage vault = vaults[poolId][msg.sender];

        // Transfer tokens from the user to the contract
        _transferTokensIn(key, msg.sender, amount0, amount1);

        // Update the vault's token balances (use SafeCast)
        vault.token0Balance = (uint256(vault.token0Balance) + amount0).toUint128();
        vault.token1Balance = (uint256(vault.token1Balance) + amount1).toUint128();

        // vault.lastAccrual updated within _accrueInterestForUser

        // Create a memory copy to pass to _updateVault
        Vault memory updatedVault = vault;

        // Update the vault state, emit events, and manage user tracking
        _updateVault(poolId, msg.sender, updatedVault);

        emit DepositCollateral(poolId, msg.sender, amount0, amount1);
    }

    /**
     * @notice Withdraw collateral from the user's vault by specifying token amounts
     * @param poolId The pool ID
     * @param amount0 Amount of token0 to withdraw
     * @param amount1 Amount of token1 to withdraw
     * @return sharesValue The LP-equivalent value of the withdrawn tokens
     * @dev Updated for Phase 3 to include solvency checks.
     */
    function withdrawCollateral(
        PoolId poolId,
        uint256 amount0,
        uint256 amount1
    ) external whenNotPaused nonReentrant returns (uint256 sharesValue) {
        // Verify the pool is initialized
        _verifyPoolInitialized(poolId);

        // Update interest for the user
        _accrueInterestForUser(poolId, msg.sender);

        // Get the vault
        Vault storage vault = vaults[poolId][msg.sender];

        // Ensure the user has enough balance to withdraw
        if (amount0 > vault.token0Balance) {
            revert Errors.InsufficientBalance(amount0, vault.token0Balance);
        }
        if (amount1 > vault.token1Balance) {
            revert Errors.InsufficientBalance(amount1, vault.token1Balance);
        }

        // Calculate the LP-equivalent value of the withdrawal
        sharesValue = _lpEquivalent(poolId, amount0, amount1);

        // Create hypothetical balances after withdrawal
        uint128 newToken0Balance = (uint256(vault.token0Balance) - amount0).toUint128();
        uint128 newToken1Balance = (uint256(vault.token1Balance) - amount1).toUint128();
        uint128 currentDebtShare = vault.debtShare; // Debt doesn't change here

        // Check if the withdrawal would make the vault insolvent using internal helper
        // Debt share is passed directly as it's already updated by _accrueInterestForUser
        if (!_isVaultSolventWithBalances(
            poolId,
            newToken0Balance,
            newToken1Balance,
            currentDebtShare // Use current debt share
        )) {
            revert Errors.WithdrawalWouldMakeVaultInsolvent(); // Use specific error
        }

        // Update the vault's token balances
        vault.token0Balance = newToken0Balance;
        vault.token1Balance = newToken1Balance;

        // Transfer tokens to the user
        PoolKey memory key = getPoolKey(poolId);
        _transferTokensOut(key, msg.sender, amount0, amount1);

        // Create a memory copy to pass to _updateVault
        Vault memory updatedVault = vault;

        // Update the vault state, emit events, and manage user tracking
        _updateVault(poolId, msg.sender, updatedVault);

        // Emit event (using updated name for shares parameter)
        emit WithdrawCollateral(poolId, msg.sender, sharesValue, amount0, amount1);

        return sharesValue;
    }

    /**
     * @notice Borrow assets by burning LP shares and adding the resulting tokens to the user's vault
     * @param poolId The pool ID to borrow from
     * @param sharesToBorrow The amount of LP shares to borrow
     * @return amount0 Amount of token0 received from unwinding LP
     * @return amount1 Amount of token1 received from unwinding LP
     */
    function borrow(PoolId poolId, uint256 sharesToBorrow)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        // Verify the pool is initialized
        _verifyPoolInitialized(poolId);

        // Update interest for the user BEFORE checking capacity
        _accrueInterestForUser(poolId, msg.sender);

        // Check if the user can borrow the requested amount
        _checkBorrowingCapacity(poolId, msg.sender, sharesToBorrow);

        // Get the vault
        Vault storage vault = vaults[poolId][msg.sender];

        // Withdraw tokens from the pool using internal implementation
        (amount0, amount1) = _withdrawImpl(
            WithdrawParams({
                poolId: poolId,
                sharesToBurn: sharesToBorrow,
                amount0Min: 0,  // no minimum for internal operations
                amount1Min: 0,  // no minimum for internal operations
                deadline: block.timestamp // Use current time for internal deadline
            })
        );

        // --- State Updates ---
        // Update the user's debt shares
        vault.debtShare = (uint256(vault.debtShare) + sharesToBorrow).toUint128();

        // Update global rented liquidity tracking
        rentedLiquidity[poolId] = rentedLiquidity[poolId] + sharesToBorrow;

        // Add the borrowed tokens to the user's vault balance (BAMM Pattern)
        vault.token0Balance = (uint256(vault.token0Balance) + amount0).toUint128();
        vault.token1Balance = (uint256(vault.token1Balance) + amount1).toUint128();

        // lastAccrual already updated by _accrueInterestForUser

        // --- Post-State Updates ---
        // Update the vault state (also adds user to poolUsers if needed)
        Vault memory updatedVault = vault; // Create memory copy for event/update function
        _updateVault(poolId, msg.sender, updatedVault);

        // Emit event
        // event InterestAccrued(
        //     poolId,
        //     msg.sender,
        //     getInterestRatePerSecond(poolId),
        //     block.timestamp - vault.lastAccrual,
        //     interestMultiplier[poolId]
        // );
        // event Borrow(
        //     poolId,
        //     msg.sender,
        //     sharesToBorrow,
        //     amount0,
        //     amount1
        // );

        return (amount0, amount1);
    }

    /**
     * @notice Repay debt by providing tokens to mint back liquidity
     * @param poolId The pool ID
     * @param amount0 Amount of token0 to use for repayment
     * @param amount1 Amount of token1 to use for repayment
     * @param useVaultBalance Whether to use tokens from the vault (true) or transfer from user (false)
     * @return sharesRepaid The amount of LP shares repaid (actual debt reduction)
     */
    function repay(
        PoolId poolId,
        uint256 amount0,
        uint256 amount1,
        bool useVaultBalance
    ) external payable whenNotPaused nonReentrant returns (uint256 sharesRepaid) {
        // Verify the pool is initialized
        _verifyPoolInitialized(poolId);

        // Update interest for the user BEFORE checking debt
        _accrueInterestForUser(poolId, msg.sender);

        // Get the vault
        Vault storage vault = vaults[poolId][msg.sender];
        uint128 currentDebtShare = vault.debtShare; // Snapshot debt *after* accrual

        // Ensure user has debt to repay
        if (currentDebtShare == 0) {
            revert Errors.NoDebtToRepay(); // Use specific error
        }

        // Ensure the user is providing at least one token
        if (amount0 == 0 && amount1 == 0) {
            revert Errors.ZeroAmount();
        }

        // --- Prepare Tokens for Deposit ---
        PoolKey memory key = getPoolKey(poolId); // Needed for transfers if not using vault balance
        if (useVaultBalance) {
            // Check vault has sufficient balance
            if (amount0 > vault.token0Balance) {
                revert Errors.InsufficientBalance(amount0, vault.token0Balance);
            }
            if (amount1 > vault.token1Balance) {
                revert Errors.InsufficientBalance(amount1, vault.token1Balance);
            }
            // Note: Balances are deducted *after* successful deposit
        } else {
            // Transfer tokens from user to this contract first
            _transferTokensIn(key, msg.sender, amount0, amount1);
        }

        // --- Perform Deposit ---
        // Deposit tokens into the pool to mint LP using internal implementation
        // Perform this *before* modifying vault state related to debt/balances
        (uint256 mintedShares, uint256 actualAmount0, uint256 actualAmount1) = _depositImpl(
            DepositParams({
                poolId: poolId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,  // no minimum for internal operations
                amount1Min: 0,  // no minimum for internal operations
                deadline: block.timestamp // Use current time for internal deadline
            })
        );

        // If deposit somehow failed to mint shares when amounts were > 0, revert.
        if (mintedShares == 0 && (amount0 > 0 || amount1 > 0)) {
             revert Errors.DepositFailed(); // Requires DepositFailed error in Errors.sol
        }

        // --- State Updates (Post-Deposit) ---
        // Order: 1. Balances (if using vault), 2. Debt Share, 3. Global rentedLiquidity
        // This ensures consistency if any step fails (though unlikely post-deposit)

        // 1. If using vault balance, deduct now that deposit succeeded
        if (useVaultBalance) {
            // Use actual amounts deposited if they differ from desired (shouldn't with 0 min)
            vault.token0Balance = (uint256(vault.token0Balance) - actualAmount0).toUint128();
            vault.token1Balance = (uint256(vault.token1Balance) - actualAmount1).toUint128();
        }

        // 2. Cap the shares repaid to the user's current debt
        uint128 debtReduction = mintedShares > currentDebtShare ? currentDebtShare : mintedShares.toUint128();
        vault.debtShare = currentDebtShare - debtReduction;

        // 3. Update global rented liquidity tracking (use capped amount)
        rentedLiquidity[poolId] = rentedLiquidity[poolId] > debtReduction
            ? rentedLiquidity[poolId] - debtReduction
            : 0;

        // lastAccrual already updated by _accrueInterestForUser

        // --- Post-State Updates ---
        // Update the vault state (also removes user from poolUsers if empty)
        _updateVault(poolId, msg.sender, vault); // Pass storage ref

        // Emit event (use actual amounts deposited, and capped shares)
        // event Repay(
        //     poolId,
        //     msg.sender,
        //     debtReduction, // Emit the actual debt reduction
        //     actualAmount0,
        //     actualAmount1
        // );

        sharesRepaid = debtReduction; // Assign to return variable
        return sharesRepaid; // Return the actual debt reduction
    }

    // =========================================================================
    // View Functions (Updated for Phase 3)
    // =========================================================================

    /**
     * @notice Get vault information
     */
    function getVault(PoolId poolId, address user) external view override returns (Vault memory) {
        return vaults[poolId][user];
    }

    /**
     * @notice Get the value of a vault's collateral in LP-equivalent shares
     * @param poolId The pool ID
     * @param user The user address
     * @return value The LP-equivalent value of the vault collateral
     * @dev In BAMM, this includes borrowed tokens held in the vault.
     */
    function getVaultValue(PoolId poolId, address user) external view returns (uint256 value) {
        Vault memory vault = vaults[poolId][user];
        // Value is purely collateral balances (which include borrowed tokens per BAMM)
        return _lpEquivalent(poolId, vault.token0Balance, vault.token1Balance);
    }

    /**
     * @notice Get detailed information about a vault's collateral
     * @param poolId The pool ID
     * @param user The user address
     * @return token0Balance Amount of token0 in the vault
     * @return token1Balance Amount of token1 in the vault
     * @return equivalentLPShares The LP-equivalent value of the vault collateral
     * @dev Collateral includes borrowed tokens held in vault per BAMM model.
     */
    function getVaultCollateral(PoolId poolId, address user) external view returns (
        uint256 token0Balance,
        uint256 token1Balance,
        uint256 equivalentLPShares
    ) {
        Vault memory vault = vaults[poolId][user];
        token0Balance = vault.token0Balance;
        token1Balance = vault.token1Balance;
        equivalentLPShares = _lpEquivalent(poolId, vault.token0Balance, vault.token1Balance);
        return (token0Balance, token1Balance, equivalentLPShares);
    }

    /**
     * @notice Check if a vault is solvent based on debt-to-collateral ratio
     * @param poolId The pool ID
     * @param user The user address
     * @return True if the vault is solvent
     */
    function isVaultSolvent(PoolId poolId, address user) external view override returns (bool) {
        Vault memory vault = vaults[poolId][user];

        // If user has no debt, the vault is solvent
        if (vault.debtShare == 0) {
            return true;
        }

        // Calculate current collateral value in LP shares using vault balances
        uint256 collateralValue = _lpEquivalent(
            poolId,
            vault.token0Balance,
            vault.token1Balance
        );

        // If collateral value is zero but debt exists, it's insolvent
        if (collateralValue == 0) {
            return false;
        }

        // Calculate the debt considering interest accrual using the current multiplier
        // Note: This view function doesn't update the global multiplier, it uses the latest recorded one.
        // For on-chain checks, _accrueInterestForUser/_updateInterestForPool MUST be called first.
        uint256 currentDebt = FullMath.mulDiv(
            vault.debtShare,
            interestMultiplier[poolId], // Use the stored multiplier
            PRECISION
        );

        // Check if collateral value satisfies the solvency threshold
        // debt / collateral < threshold <=> debt * PRECISION / collateral < threshold * PRECISION
        // <=> debt * PRECISION < threshold * collateral ( rearranged to avoid division)
        return FullMath.mulDiv(currentDebt, PRECISION, collateralValue) < SOLVENCY_THRESHOLD_LIQUIDATION;
    }

    /**
     * @notice Calculate loan-to-value ratio for a vault
     * @param poolId The pool ID
     * @param user The user address
     * @return LTV ratio (scaled by PRECISION)
     */
    function getVaultLTV(PoolId poolId, address user) external view override returns (uint256) {
        Vault memory vault = vaults[poolId][user];

        // If user has no debt, LTV is 0
        if (vault.debtShare == 0) {
            return 0;
        }

        // Calculate current collateral value in LP shares
        uint256 collateralValue = _lpEquivalent(
            poolId,
            vault.token0Balance,
            vault.token1Balance
        );

        // If no collateral, LTV is effectively infinite, return max value
        if (collateralValue == 0) {
            // Return > PRECISION to indicate insolvency clearly if debt > 0
            return type(uint256).max;
        }

        // Calculate current debt with interest using stored multiplier
        uint256 currentDebt = FullMath.mulDiv(
            vault.debtShare,
            interestMultiplier[poolId], // Use stored multiplier for view function
            PRECISION
        );

        // Calculate LTV ratio (debt / collateral)
        return FullMath.mulDiv(currentDebt, PRECISION, collateralValue);
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
    // Admin Functions (Unchanged for Phase 3)
    // =========================================================================

    /**
     * @notice Set the contract pause state
     */
    function setPaused(bool _paused) external onlyGovernance {
        paused = _paused;
        // event PauseStatusChanged(bool isPaused);
    }

    /**
     * @notice Set the interest rate model address (Phase 4+)
     */
    function setInterestRateModel(address _interestRateModel) external onlyGovernance {
        if (_interestRateModel == address(0)) revert Errors.ZeroAddress();
        address oldModel = interestRateModelAddress;
        interestRateModelAddress = _interestRateModel;
        // event InterestRateModelUpdated(address newModel);
    }

    // =========================================================================
    // Access Control Modifiers (Unchanged for Phase 3)
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
    // Overrides and Hook Security (Updated for Phase 3)
    // =========================================================================

    /**
     * @notice Set up initial pool state when a pool is initialized
     * @dev Extends Spot._afterPoolInitialized to set Phase 3 variables
     */
    function _afterPoolInitialized(
        PoolId poolId,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal virtual override {
        // Call Spot's internal implementation first
        Spot._afterPoolInitialized(poolId, key, sqrtPriceX96, tick);

        // Initialize interest multiplier (Phase 3+)
        interestMultiplier[poolId] = PRECISION;

        // Initialize last interest accrual time (Phase 3+)
        lastInterestAccrualTime[poolId] = block.timestamp;

        // rentedLiquidity defaults to 0
    }

    // --- Hook Overrides with onlyPoolManager ---
    // Ensure ALL hooks callable by the PoolManager are overridden and protected.

    // _beforeInitialize remains the same
    // _afterInitialize remains the same (calls _afterInitializeInternal)
    // _beforeAddLiquidity remains the same

    /**
     * @notice Hook called after adding liquidity to a pool
     * @dev Updated for Phase 3 to handle internal operations like repaying
     */
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override onlyPoolManager returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();

        // Check if this is an internal repay operation from Margin itself
        if (sender == address(this) && params.liquidityDelta > 0) {
            // No specific accounting action needed here.
            // The repay() function has already updated the user's debtShare
            // and the global rentedLiquidity based on the shares minted (_depositImpl return value).
        }

        // Process fees as normal (from Spot layer)
        if (poolData[poolId].initialized) {
            if (feesAccrued.amount0() != 0 || feesAccrued.amount1() != 0) {
                _processFees(poolId, IFeeReinvestmentManager.OperationType.DEPOSIT, feesAccrued);
            }
        }

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // _beforeRemoveLiquidity remains the same

    /**
     * @notice Hook called after removing liquidity from a pool
     * @dev Updated for Phase 3 to handle internal operations like borrowing
     */
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override onlyPoolManager returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();

        // Check if this is an internal borrow operation from Margin itself
        if (sender == address(this) && params.liquidityDelta < 0) {
            // No specific accounting action needed here.
            // The borrow() function handles adding tokens to the vault,
            // updating debtShare, and rentedLiquidity based on the shares burned (params.liquidityDelta).
        }

        // Process fees as normal (from Spot layer)
        if (poolData[poolId].initialized) {
            if (feesAccrued.amount0() != 0 || feesAccrued.amount1() != 0) {
                _processFees(poolId, IFeeReinvestmentManager.OperationType.WITHDRAWAL, feesAccrued);
            }
        }

        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // _beforeSwap remains the same
    // _afterSwap remains the same

    // Donate hooks remain commented out as in base

    // Return delta hooks remain commented out/minimal as in base
    // afterRemoveLiquidityReturnDelta remains the same

    // =========================================================================
    // Helper Functions (Added/Modified for Phase 3)
    // =========================================================================

    /**
     * @notice Safe transfer ETH with fallback to pending payments
     * @param recipient The address to send ETH to
     * @param amount The amount of ETH to send
     * @dev Re-added for Phase 3 as it's used by _transferTokensOut.
     */
    function _safeTransferETH(address recipient, uint256 amount) internal {
        if (amount == 0) return;

        (bool success, ) = recipient.call{value: amount, gas: 50000}(""); // Use fixed gas stipend
        if (!success) {
            pendingETHPayments[recipient] += amount;
            // event ETHTransferFailed(recipient, amount);
        }
    }

    /**
     * @notice Helper function for transferring tokens into the contract from a user
     * @param key The pool key (for currency types)
     * @param from The sender address
     * @param amount0 Amount of token0 to transfer
     * @param amount1 Amount of token1 to transfer
     * @dev Handles native ETH payments via msg.value. Refunds excess ETH.
     */
    function _transferTokensIn(PoolKey memory key, address from, uint256 amount0, uint256 amount1) internal {
        uint256 ethAmountRequired = 0;
        // Transfer token0 if needed
        if (amount0 > 0) {
            if (key.currency0.isAddressZero()) {
                ethAmountRequired += amount0;
            } else {
                SafeTransferLib.safeTransferFrom(
                    ERC20(Currency.unwrap(key.currency0)),
                    from,
                    address(this),
                    amount0
                );
            }
        }

        // Transfer token1 if needed
        if (amount1 > 0) {
            if (key.currency1.isAddressZero()) {
                ethAmountRequired += amount1;
            } else {
                SafeTransferLib.safeTransferFrom(
                    ERC20(Currency.unwrap(key.currency1)),
                    from,
                    address(this),
                    amount1
                );
            }
        }

        // Check if enough ETH was sent if required
        if (ethAmountRequired > 0 && msg.value < ethAmountRequired) {
             revert Errors.InsufficientETH(ethAmountRequired, msg.value);
        }

        // Refund excess ETH
        if (msg.value > ethAmountRequired) {
            SafeTransferLib.safeTransferETH(from, msg.value - ethAmountRequired);
        }
    }

    /**
     * @notice Helper function to transfer tokens out from the contract to a user
     * @param key The pool key (contains currency information)
     * @param to Recipient address
     * @param amount0 Amount of token0 to transfer
     * @param amount1 Amount of token1 to transfer
     * @dev Uses _safeTransferETH for native currency.
     */
    function _transferTokensOut(PoolKey memory key, address to, uint256 amount0, uint256 amount1) internal {
        if (amount0 > 0) {
            if (key.currency0.isAddressZero()) {
                _safeTransferETH(to, amount0);
            } else {
                SafeTransferLib.safeTransfer(
                    ERC20(Currency.unwrap(key.currency0)),
                    to,
                    amount0
                );
            }
        }

        if (amount1 > 0) {
            if (key.currency1.isAddressZero()) {
                _safeTransferETH(to, amount1);
            } else {
                SafeTransferLib.safeTransfer(
                    ERC20(Currency.unwrap(key.currency1)),
                    to,
                    amount1
                );
            }
        }
    }

    // =========================================================================
    // Phase 4 Interest Accrual Logic
    // =========================================================================

    /**
     * @notice Updates the global interest multiplier for a pool based on elapsed time and utilization.
     * @param poolId The pool ID
     * @dev Replaces Phase 3 placeholder with Phase 4 logic using IInterestRateModel and fee calculation.
     */
    function _updateInterestForPool(PoolId poolId) internal {
        uint256 lastUpdate = lastInterestAccrualTime[poolId];

        // Optimization: If already updated in this block, skip redundant calculation.
        // Also handles the case where pool was *just* initialized in this block.
        if (lastUpdate == block.timestamp) return;

        uint256 timeElapsed = block.timestamp - lastUpdate;
        // If pool was initialized *before* this block but this is the first action
        // causing accrual, timeElapsed could be non-zero but lastUpdate might be 0
        // if _afterPoolInitialized wasn't triggered yet or happened before this code path.
        // The logic below handles initialization correctly.
        if (timeElapsed == 0 && lastUpdate != 0) return; // No time passed since last *valid* update

        // Address of the interest rate model
        address modelAddr = interestRateModelAddress;

        // If no interest rate model is set, cannot accrue interest.
        // Only update timestamp to prevent state where accrual seems perpetually outdated.
        if (modelAddr == address(0)) {
            lastInterestAccrualTime[poolId] = block.timestamp;
            return;
        }

        // Get current pool state for utilization calculation
        // Assuming liquidityManager reference is available (inherited via Spot)
        uint128 totalShares = liquidityManager.poolTotalShares(poolId);
        uint256 rentedShares = rentedLiquidity[poolId]; // 'borrowed' measure

        // If no shares rented or no total liquidity provided yet, no interest accrues on debt.
        if (rentedShares == 0 || totalShares == 0) {
            lastInterestAccrualTime[poolId] = block.timestamp; // Update time even if no interest accrued
            // Ensure multiplier is initialized if it's the very first interaction
            if (interestMultiplier[poolId] == 0) interestMultiplier[poolId] = PRECISION;
            return;
        }

        // Ensure multiplier is initialized (should happen in _afterPoolInitialized, but safety check)
        uint256 currentMultiplier = interestMultiplier[poolId];
        if (currentMultiplier == 0) {
             currentMultiplier = PRECISION;
             // If multiplier was 0, it implies lastUpdate was likely 0 too, or pool just init'd.
             // Reset timeElapsed based on a potential 0 lastUpdate.
             if (lastUpdate == 0) {
                 timeElapsed = 0; // Cannot calculate interest delta from an uninitialized state
             }
             // Assign PRECISION back to storage if it was uninitialized
             interestMultiplier[poolId] = currentMultiplier;
        }

        // If no time elapsed after initialization checks, just update time and exit
        if (timeElapsed == 0) {
             lastInterestAccrualTime[poolId] = block.timestamp;
             return;
        }

        // Calculate utilization using the model's helper function
        uint256 utilization = IInterestRateModel(modelAddr)
            .getUtilizationRate(poolId, rentedShares, uint256(totalShares));

        // Get the current interest rate per second from the model
        uint256 interestRatePerSecond = IInterestRateModel(modelAddr)
            .getBorrowRate(poolId, utilization);

        // Calculate the new global interest multiplier using linear compounding
        // newMultiplier = currentMultiplier * (1 + rate * timeElapsed)
        uint256 interestFactor = interestRatePerSecond * timeElapsed; // Total interest rate over the period
        uint256 newMultiplier = FullMath.mulDiv(
            currentMultiplier,
            PRECISION + interestFactor, // Interest factor added to 1 (PRECISION)
            PRECISION
        );

        // --- Protocol Fee Calculation ---
        // Calculate the total interest accrued *on the rented shares* during this period, denominated in share value.
        // This represents the increase in the *value* of the debt due to interest.
        // Interest Value Increase (shares) = RentedShares * (NewMultiplier / OldMultiplier - 1)
        // Interest Value Increase (shares) = RentedShares * (NewMultiplier - OldMultiplier) / OldMultiplier
        // We calculate the increase relative to PRECISION (1.0) as the multipliers grow from PRECISION.
        // interestAmountShares = rentedShares * (newMultiplier - currentMultiplier) / PRECISION
        uint256 interestAmountShares = FullMath.mulDiv(
            rentedShares,
            newMultiplier - currentMultiplier, // The increase in multiplier represents the interest factor per share
            PRECISION // Scale back down because multiplier diff is scaled by PRECISION^2 conceptually
        );

        // Get protocol fee percentage from Policy Manager
        // Assuming policyManager reference is available (inherited via Spot -> OwnablePolicy)
        uint256 protocolFeePercentage = policyManager.getProtocolFeePercentage(poolId);

        if (protocolFeePercentage > 0 && interestAmountShares > 0) {
            // Calculate the protocol's share of the accrued interest value (in shares)
            uint256 protocolFeeShares = FullMath.mulDiv(
                interestAmountShares,
                protocolFeePercentage, // Already scaled by PRECISION
                PRECISION
            );

            // Add to accumulated fees for later processing
            accumulatedFees[poolId] += protocolFeeShares;
        }

        // --- Update State ---
        // Update the global multiplier *after* fee calculation which uses the delta
        interestMultiplier[poolId] = newMultiplier;

        // Update the last accrual time AFTER all calculations
        lastInterestAccrualTime[poolId] = block.timestamp;

        // Emit event for pool-level accrual (matches IMargin definition)
        emit InterestAccrued(
            poolId,
            address(0), // Zero address signifies pool-level update
            interestRatePerSecond,
            timeElapsed,
            newMultiplier
        );
    }


    /**
     * @notice Updates user's last accrual time after ensuring pool interest is current.
     * @param poolId The pool ID
     * @param user The user address
     * @dev Ensures the global pool interest multiplier is up-to-date before any user action.
     *      Actual debt value is calculated dynamically using the global multiplier.
     *      Replaces Phase 3 logic.
     */
    function _accrueInterestForUser(PoolId poolId, address user) internal {
        // 1. Update the global interest multiplier for the pool first.
        // This computes and stores interest, and calculates protocol fees.
        _updateInterestForPool(poolId);

        // 2. Update the user's vault timestamp.
        //    No per-user interest calculation or state update is needed here because
        //    the user's debt value is derived dynamically using their `debtShare`
        //    and the latest `interestMultiplier[poolId]`.
        //    This timestamp marks the point in time relative to the global multiplier
        //    up to which the user's state is considered current (for off-chain purposes mostly).
        Vault storage vault = vaults[poolId][user];
        // Update timestamp regardless of debt, signifies interaction time relative to global multiplier.
        vault.lastAccrual = uint64(block.timestamp);

        // Note: No separate InterestAccrued event needed here as the pool-level one covers the multiplier update.
    }

    /**
     * @notice Calculate a user's current debt including accrued interest
     * @param poolId The pool ID
     * @param user The user address
     * @return Current debt value including interest, scaled by PRECISION
     */
    function getCurrentUserDebt(PoolId poolId, address user) public view returns (uint256) {
        Vault memory vault = vaults[poolId][user];

        // If user has no debt, return 0
        if (vault.debtShare == 0) {
            return 0;
        }

        // Calculate debt including interest using the latest recorded multiplier
        // Note: This does NOT update the multiplier based on block.timestamp difference
        // like _updateInterestForPool does. It reflects debt based on last chain update.
        return FullMath.mulDiv(
            vault.debtShare,
            interestMultiplier[poolId], // Use stored multiplier
            PRECISION
        );
    }

    /**
     * @notice Gets the current interest rate per second for a pool from the model.
     * @param poolId The pool ID
     * @return rate The interest rate per second (scaled by PRECISION)
     * @dev Calculates utilization and queries the interest rate model. Replaces Phase 3 placeholder.
     */
    function getInterestRatePerSecond(PoolId poolId) public view returns (uint256 rate) {
        // If no interest rate model is set, return 0
        address modelAddr = interestRateModelAddress; // Cache storage read
        if (modelAddr == address(0)) return 0;

        // Get total and rented shares
        // Assuming liquidityManager reference is available (likely inherited via Spot)
        uint128 totalShares = liquidityManager.poolTotalShares(poolId);
        uint256 rentedShares = rentedLiquidity[poolId]; // Already tracks borrowed shares

        if (totalShares == 0) return 0; // Avoid division by zero if pool somehow has no shares

        // Use model's helper for utilization
        uint256 utilization = IInterestRateModel(modelAddr)
            .getUtilizationRate(poolId, rentedShares, uint256(totalShares));

        // Get rate from model
        rate = IInterestRateModel(modelAddr).getBorrowRate(poolId, utilization);
        return rate;
    }

    /**
     * @notice Verify if a borrowing operation would keep the vault solvent and pool within utilization limits.
     * @param poolId The pool ID
     * @param user The user address
     * @param sharesToBorrow The amount of LP shares to borrow
     * @dev Updated for Phase 4 to check pool utilization against the Interest Rate Model.
     */
    function _checkBorrowingCapacity(PoolId poolId, address user, uint256 sharesToBorrow) internal view {
        // Ensure pool is initialized (redundant if called after _verifyPoolInitialized, but safe)
        // _verifyPoolInitialized(poolId); // Assuming already called by public entry points like borrow()

        // Ensure interest rate model is set
        address modelAddr = interestRateModelAddress;
        require(modelAddr != address(0), "Margin: Interest model not set"); // Use specific error if available

        // --- NEW (Phase 4): Check Pool Utilization Limit ---
        uint128 totalSharesLM = liquidityManager.poolTotalShares(poolId);
        // This check should ideally be redundant due to _verifyPoolInitialized, but belts-and-suspenders:
        if (totalSharesLM == 0) revert Errors.PoolNotInitialized(poolId); // Safety check

        uint256 currentBorrowed = rentedLiquidity[poolId];
        uint256 newBorrowed = currentBorrowed + sharesToBorrow;

        // Use the model's helper for utilization calculation
        uint256 utilization = IInterestRateModel(modelAddr)
            .getUtilizationRate(poolId, newBorrowed, uint256(totalSharesLM));

        // Get max allowed utilization from the interest rate model
        uint256 maxAllowedUtilization = IInterestRateModel(modelAddr).maxUtilizationRate();

        // Check against the model's max utilization limit
        require(utilization <= maxAllowedUtilization, "Margin: Max pool utilization exceeded"); // Use specific error if available

        // --- EXISTING (Phase 3): Check User Vault Solvency ---
        // Note: _accrueInterestForUser should have been called by the public function (e.g., borrow)
        // *before* this check, ensuring interestMultiplier is up-to-date.
        Vault storage vault = vaults[poolId][user]; // Read vault *after* potential accrual

        // Calculate token amounts corresponding to sharesToBorrow
        (uint256 amount0FromShares, uint256 amount1FromShares) = _sharesTokenEquivalent(
            poolId,
            sharesToBorrow
        );

        // Calculate hypothetical new vault state after borrow
        // Note: Balances increase, Debt Share increases
        uint128 newToken0Balance = (uint256(vault.token0Balance) + amount0FromShares).toUint128();
        uint128 newToken1Balance = (uint256(vault.token1Balance) + amount1FromShares).toUint128();
        // Proposed new debt share *before* considering interest on the *newly borrowed* amount (interest starts next block)
        uint128 newDebtShareBase = (uint256(vault.debtShare) + sharesToBorrow).toUint128();

        // Check if the post-borrow position would be solvent using the internal helper
        // This helper uses the *current* interest multiplier for the solvency check
        if (!_isVaultSolventWithBalances(
            poolId,
            newToken0Balance,
            newToken1Balance,
            newDebtShareBase // Check solvency based on the proposed base debt share increase
        )) {
             // Calculate hypothetical collateral value for the error message
            uint256 hypotheticalCollateralValue = _lpEquivalent(poolId, newToken0Balance, newToken1Balance);
            // Calculate estimated debt value *using current multiplier* for the error message
            uint256 estimatedDebtValue = FullMath.mulDiv(newDebtShareBase, interestMultiplier[poolId], PRECISION);
            revert Errors.InsufficientCollateral(
                estimatedDebtValue,
                hypotheticalCollateralValue,
                SOLVENCY_THRESHOLD_LIQUIDATION
            ); // Use specific error
        }

        // Remove redundant utilization check from Phase 3 if it existed here.
        // The check against the model's maxUtilizationRate replaces the old hardcoded MAX_UTILITY_RATE check.
    }

    /**
     * @notice Internal function to check solvency with specified balances
     * @dev Used to check hypothetical solvency after potential withdrawal or before borrow
     * @param poolId The pool ID
     * @param token0Balance Hypothetical token0 balance
     * @param token1Balance Hypothetical token1 balance
     * @param debtShare The debt share amount (pre-interest for calculation)
     * @return True if solvent, False otherwise
     */
    function _isVaultSolventWithBalances(
        PoolId poolId,
        uint128 token0Balance,
        uint128 token1Balance,
        uint128 debtShare // Pass the base debt share
    ) internal view returns (bool) {
        // If user has no debt, the vault is solvent
        if (debtShare == 0) {
            return true;
        }

        // Calculate current collateral value in LP shares using provided balances
        uint256 collateralValue = _lpEquivalent(
            poolId,
            token0Balance,
            token1Balance
        );

        // If collateral is zero but debt exists, it's insolvent
        if (collateralValue == 0) {
            return false;
        }

        // Calculate the current debt value using the latest interest multiplier
        uint256 currentDebtValue = FullMath.mulDiv(
            debtShare,
            interestMultiplier[poolId], // Use the current stored multiplier
            PRECISION
        );

        // Check solvency: debt / collateral < threshold
        // Rearranged: debt * PRECISION < threshold * collateral
        return FullMath.mulDiv(currentDebtValue, PRECISION, collateralValue) < SOLVENCY_THRESHOLD_LIQUIDATION;
    }

    /**
     * @notice Placeholder: Calculate the number of shares repaid given token amounts
     * @dev This function is NOT used in the current repay logic, which calculates shares
     *      based on the actual deposit result (_depositImpl). Kept for reference/future.
     */
    function _calculateSharesForRepayment(
        PoolId poolId,
        uint256 amount0,
        uint256 amount1,
        uint256 currentDebt // Already includes interest
    ) internal view returns (uint256 sharesRepaid) {
        // Phase 3 Repay uses _depositImpl return value, not this calculation.
        // This is kept as a placeholder/reference from an earlier spec version.
        return _lpEquivalent(poolId, amount0, amount1);
    }

    // =========================================================================
    // Override withdraw function from Spot to add margin layer checks
    // =========================================================================

    /**
     * @notice Override withdraw function from Spot to add margin layer checks
     * @dev Prevents withdrawal of shares that are currently backing borrowed amounts (rented out)
     *      This applies to DIRECT withdrawals via Spot interface, not internal borrows.
     */
    function withdraw(WithdrawParams calldata params) 
        external 
        override // Override Spot which already implements ISpot
        whenNotPaused 
        nonReentrant 
        returns (uint256 amount0, uint256 amount1) 
    {
        _verifyPoolInitialized(params.poolId);

        // --- Margin Layer Check ---
        // Get total shares from the liquidity manager perspective
        uint128 totalSharesLM = liquidityManager.poolTotalShares(params.poolId);
        
        // Get currently rented liquidity (does NOT include interest multiplier here)
        uint256 borrowedBase = rentedLiquidity[params.poolId];
        
        // Calculate physically available shares in the pool
        uint256 physicallyAvailableShares = uint256(totalSharesLM) >= borrowedBase
                                            ? uint256(totalSharesLM) - borrowedBase
                                            : 0;
        
        // Ensure the withdrawal request doesn't exceed physically available shares
        if (params.sharesToBurn > physicallyAvailableShares) {
             revert Errors.InsufficientPhysicalShares(params.sharesToBurn, physicallyAvailableShares);
        }
        // --- End Margin Layer Check ---

        // Proceed with the normal withdrawal logic inherited from Spot
        // This handles deadline checks, delegation to liquidityManager, events etc.
        return ISpot(this).withdraw(params);
    }

    /**
     * @notice Internal implementation of withdraw that calls parent without Margin checks
     * @dev Bypasses the InsufficientPhysicalShares check in Margin's withdraw override.
     */
    function _withdrawImpl(WithdrawParams memory params)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        // Call parent's withdraw to access Spot's implementation directly
        return ISpot(this).withdraw(params);
    }

    /**
     * @notice Internal implementation of deposit that calls parent without Margin checks
     */
    function _depositImpl(DepositParams memory params)
        internal
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        // Call parent's deposit to access Spot's implementation directly
        return ISpot(this).deposit(params);
    }

    // =========================================================================
    // Phase 4+ Fee Reinvestment Interaction Functions
    // =========================================================================

    /**
     * @notice View function called by FeeReinvestmentManager to check pending interest fees.
     * @param poolId The pool ID.
     * @return amount0 Estimated token0 value of pending fees.
     * @return amount1 Estimated token1 value of pending fees.
     * @dev Converts accumulated fee share value to token amounts based on current reserves.
     *      Requires authorization check via PolicyManager.
     */
    function getPendingProtocolInterestTokens(PoolId poolId)
        external
        view
        override // from IMargin
        returns (uint256 amount0, uint256 amount1)
    {
        // Authorization: Allow calls from the designated Reinvestment Policy or Governance
        // Assuming policyManager is accessible (inherited via Spot -> OwnablePolicy)
        address reinvestmentPolicy = policyManager.getPolicy(poolId, IPoolPolicy.PolicyType.REINVESTMENT);
        require(
            msg.sender == reinvestmentPolicy ||
            policyManager.isAuthorizedReinvestor(msg.sender) || // Use check from policy manager
            msg.sender == policyManager.getSoloGovernance(), // Allow direct governance call
            "Margin: Not authorized"
        );

        // Get pending fees (denominated in share value)
        uint256 feeShares = accumulatedFees[poolId];

        // Convert share value to token amounts using the internal helper
        if (feeShares > 0) {
            (amount0, amount1) = _sharesTokenEquivalent(poolId, feeShares);
        }

        // Returns (0, 0) if no fees pending or conversion yields zero
        return (amount0, amount1);
    }

    /**
     * @notice Called by FeeReinvestmentManager after successfully processing interest fees.
     * @param poolId The pool ID.
     * @return previousValue The amount of fee shares that were just cleared.
     * @dev Resets the accumulated fee shares for the pool. Requires authorization via PolicyManager.
     */
    function resetAccumulatedFees(PoolId poolId)
        external
        override // from IMargin
        returns (uint256 previousValue)
    {
        // Authorization: Allow calls from the designated Reinvestment Policy or Governance
        // Assuming policyManager is accessible (inherited via Spot -> OwnablePolicy)
        address reinvestmentPolicy = policyManager.getPolicy(poolId, IPoolPolicy.PolicyType.REINVESTMENT);
         require(
            msg.sender == reinvestmentPolicy ||
            policyManager.isAuthorizedReinvestor(msg.sender) || // Use check from policy manager
            msg.sender == policyManager.getSoloGovernance(), // Allow direct governance call
            "Margin: Not authorized"
        );

        previousValue = accumulatedFees[poolId];

        if (previousValue > 0) {
            accumulatedFees[poolId] = 0;
            emit ProtocolFeesProcessed(poolId, previousValue); // Emit event on successful reset
        }

        return previousValue;
    }

} // End Contract Margin 