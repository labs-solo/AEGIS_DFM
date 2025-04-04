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
     * @notice Storage gap for future extensions
     */
    uint256[49] private __gap;

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
    // Phase 3+ Interest Accrual Logic
    // =========================================================================

    /**
     * @notice Updates the global interest multiplier for a pool based on elapsed time
     * @param poolId The pool ID
     */
    function _updateInterestForPool(PoolId poolId) internal {
        uint256 lastUpdate = lastInterestAccrualTime[poolId];

        // If pool just initialized or first interaction
        if (lastUpdate == 0) {
            lastInterestAccrualTime[poolId] = block.timestamp;
            // Ensure multiplier is initialized if not already
            if (interestMultiplier[poolId] == 0) {
                 interestMultiplier[poolId] = PRECISION;
            }
            return;
        }

        uint256 timeElapsed = block.timestamp - lastUpdate;
        if (timeElapsed == 0) return; // No time passed

        // Calculate interest using the interest rate model (placeholder for now)
        uint256 interestRate = getInterestRatePerSecond(poolId); // Per second rate
        uint256 interestFactor = interestRate * timeElapsed; // Simple interest factor

        // Update interest multiplier: multiplier = multiplier * (1 + interestFactor/PRECISION)
        // Using FullMath: multiplier * (PRECISION + interestFactor) / PRECISION
        uint256 currentMultiplier = interestMultiplier[poolId];
        uint256 newMultiplier = FullMath.mulDiv(
            currentMultiplier,
            PRECISION + interestFactor, // Assuming interestFactor needs scaling if rate isn't PRECISION based
            PRECISION
        );

        interestMultiplier[poolId] = newMultiplier;
        lastInterestAccrualTime[poolId] = block.timestamp;

        // event InterestAccrued(
        //     poolId,
        //     address(0), // address(0) for pool-level accrual
        //     interestRate,
        //     timeElapsed,
        //     newMultiplier
        // );
    }

    /**
     * @notice Updates user's last accrual time after ensuring pool interest is current.
     * @param poolId The pool ID
     * @param user The user address
     * @dev Debt calculation is dynamic via getCurrentUserDebt. This only updates timestamp.
     */
    function _accrueInterestForUser(PoolId poolId, address user) internal {
        // Update global interest first
        _updateInterestForPool(poolId);

        Vault storage vault = vaults[poolId][user];

        // If user has no debt, just ensure lastAccrual is initialized if needed.
        // If debt exists, update lastAccrual time. The actual debt value
        // will be calculated using the global multiplier when needed.
        if (vault.lastAccrual == 0 || vault.debtShare > 0) {
             vault.lastAccrual = uint64(block.timestamp);
        }
        // If debtShare is 0 and lastAccrual is already set, no update needed.
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
     * @notice Placeholder: Get the current interest rate per second for a pool
     * @param poolId The pool ID
     * @return rate The interest rate per second (scaled by PRECISION)
     * @dev Phase 3 uses a fixed rate placeholder. Phase 4+ will use model.
     */
    function getInterestRatePerSecond(PoolId poolId) internal view returns (uint256 rate) {
        // Placeholder: Fixed rate of 1% APR (needs PRECISION scaling)
        // 1% APR = 0.01 per year
        // Per second rate = (0.01 / seconds_in_year) * PRECISION
        // seconds_in_year = 365 * 24 * 3600 = 31,536,000
        // Rate = (1 * PRECISION / 100) / 31536000 = PRECISION / 3153600000
        // uint256 secondsPerYear = 365 days * 24 hours * 3600 seconds; // 31536000
        // return FullMath.mulDiv(PRECISION, 1, 100 * secondsPerYear); // 1% APR expressed per second
        return PRECISION / 3153600000; // Approx 1% APR

        // Phase 4+ Implementation using interestRateModelAddress:
        // if (interestRateModelAddress == address(0)) return 0; // Or revert
        // (uint128 totalLiquidityLM, , ) = liquidityManager.poolInfo(poolId);
        // if (totalLiquidityLM == 0) return 0; // Avoid division by zero
        // uint256 currentBorrowedShares = rentedLiquidity[poolId]; // Snapshot
        // uint256 currentTotalShares = uint256(totalLiquidityLM);
        // // Calculate utilization = borrowed / total_available (total = collateral + borrowed)
        // uint256 utilization = FullMath.mulDiv(currentBorrowedShares, PRECISION, currentTotalShares);
        // // Clip utilization at MAX_UTILITY_RATE? Or let model handle > 100%? Typically model handles.
        // rate = IInterestRateModel(interestRateModelAddress).getInterestRate(utilization);
        // return rate; // Ensure model returns rate per second scaled by PRECISION
    }

    /**
     * @notice Verify if a borrowing operation would keep the vault solvent and pool within limits
     * @param poolId The pool ID
     * @param user The user address
     * @param sharesToBorrow The amount of LP shares to borrow
     */
    function _checkBorrowingCapacity(PoolId poolId, address user, uint256 sharesToBorrow) internal view {
        // Get the vault (debtShare is already updated via _accrueInterestForUser call)
        Vault memory vault = vaults[poolId][user];

        // Calculate token amounts corresponding to sharesToBorrow
        (uint256 amount0FromShares, uint256 amount1FromShares) = _sharesTokenEquivalent(
            poolId,
            sharesToBorrow
        );

        // Calculate hypothetical new vault state after borrow
        uint128 newToken0Balance = (uint256(vault.token0Balance) + amount0FromShares).toUint128();
        uint128 newToken1Balance = (uint256(vault.token1Balance) + amount1FromShares).toUint128();
        uint128 newDebtShare = (uint256(vault.debtShare) + sharesToBorrow).toUint128();

        // Check if the post-borrow position would be solvent using internal helper
        if (!_isVaultSolventWithBalances(
            poolId,
            newToken0Balance,
            newToken1Balance,
            newDebtShare // Use the proposed new debt share
        )) {
             // Calculate collateral value for the error message
            uint256 hypotheticalCollateralValue = _lpEquivalent(poolId, newToken0Balance, newToken1Balance);
            revert Errors.InsufficientCollateral(
                FullMath.mulDiv(newDebtShare, interestMultiplier[poolId], PRECISION), // Estimated debt value
                hypotheticalCollateralValue,
                SOLVENCY_THRESHOLD_LIQUIDATION
            ); // Use specific error
        }

        // Also check system-wide pool utilization to prevent too much borrowing
        (uint128 totalSharesLM, , ) = liquidityManager.poolInfo(poolId);
        if (totalSharesLM == 0) revert Errors.PoolNotInitialized(poolId); // Should not happen if _verifyPoolInitialized passed

        uint256 totalBorrowedAfter = rentedLiquidity[poolId] + sharesToBorrow;
        // Utilization = borrowed / total_available (where total_available = total_lp_shares in PoolManager)
        // We use totalSharesLM from our Liquidity Manager which should track PoolManager's total shares
        if (FullMath.mulDiv(totalBorrowedAfter, PRECISION, uint256(totalSharesLM)) > MAX_UTILITY_RATE) {
            revert Errors.PoolUtilizationTooHigh(); // Use specific error
        }
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
        (uint128 totalSharesLM, , ) = liquidityManager.poolInfo(params.poolId);
        
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

} // End Contract Margin 