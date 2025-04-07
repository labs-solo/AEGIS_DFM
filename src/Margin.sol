// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { Spot, DepositParams, WithdrawParams } from "./Spot.sol";
import { IMargin } from "./interfaces/IMargin.sol";
import { ISpot } from "./interfaces/ISpot.sol";
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
import { SolvencyUtils } from "./libraries/SolvencyUtils.sol";
import { TransferUtils } from "./utils/TransferUtils.sol";
import "forge-std/console2.sol";

/**
 * @title Margin
 * @notice Foundation for a margin lending system on Uniswap V4 spot liquidity positions
 * @dev Phase 1 establishes the architecture and data structures needed for future phases.
 *      Phase 2 added basic collateral deposit/withdraw.
 *      Phase 3 implements borrowing, repayment, and interest accrual following the BAMM model.
 *      Phase 4 adds dynamic interest rates via IInterestRateModel, protocol fee tracking, and utilization limits.
 *      Inherits governance/ownership from Spot via IPoolPolicy.
 */
contract Margin is ReentrancyGuard, Spot, IMargin {
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
    ) ReentrancyGuard() Spot(_poolManager, _policyManager, _liquidityManager) {
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
        
        // Get the pool key
        PoolKey memory key = getPoolKey(poolId);
        
        // Ensure at least one token is being deposited
        if (amount0 == 0 && amount1 == 0) {
            revert Errors.ZeroAmount();
        }

        // Transfer tokens using the helper
        _transferTokensIn(key, msg.sender, amount0, amount1);

        // Get the vault
        Vault storage vault = vaults[poolId][msg.sender];

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

        // Calculate the LP-equivalent value of the withdrawal using MathUtils
        (uint256 reserve0, uint256 reserve1, uint128 totalLiquidity) = getPoolReservesAndShares(poolId);
        sharesValue = MathUtils.calculateProportionalShares(
            amount0,
            amount1,
            totalLiquidity, // Use uint128 directly
            reserve0,
            reserve1,
            false // Standard precision
        );


        // Create hypothetical balances after withdrawal
        uint128 newToken0Balance = (uint256(vault.token0Balance) - amount0).toUint128();
        uint128 newToken1Balance = (uint256(vault.token1Balance) - amount1).toUint128();
        uint128 currentDebtShare = vault.debtShare; // Debt doesn't change here

        // Check if the withdrawal would make the vault insolvent using the helper
        if (!_isVaultSolventWithBalances(
            poolId,
            newToken0Balance,
            newToken1Balance,
            currentDebtShare // Use current debt share (already updated by _accrueInterestForUser)
        )) {
            revert Errors.WithdrawalWouldMakeVaultInsolvent(); // Use specific error
        }

        // Update the vault's token balances
        vault.token0Balance = newToken0Balance;
        vault.token1Balance = newToken1Balance;

        // Transfer tokens to the user using the helper
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

        // Use the new borrowImpl function in FullRangeLiquidityManager to actually take tokens from the pool
        // This removes liquidity from the Uniswap V4 position but doesn't burn LP tokens
        (amount0, amount1) = liquidityManager.borrowImpl(
            poolId,
            sharesToBorrow,
            address(this)
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
        emit Borrow(
            poolId,
            msg.sender,
            sharesToBorrow,
            amount0,
            amount1
        );

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
            // Transfer tokens from user to this contract first using the helper
            PoolKey memory key = getPoolKey(poolId); 
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
        (uint256 reserve0, uint256 reserve1, uint128 totalLiquidity) = getPoolReservesAndShares(poolId);
        return MathUtils.calculateProportionalShares(
            vault.token0Balance,
            vault.token1Balance,
            totalLiquidity, // Use uint128 directly
            reserve0,
            reserve1,
            false // Standard precision
        );
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
        (uint256 reserve0, uint256 reserve1, uint128 totalLiquidity) = getPoolReservesAndShares(poolId);
        equivalentLPShares = MathUtils.calculateProportionalShares(
            vault.token0Balance,
            vault.token1Balance,
            totalLiquidity, // Use uint128 directly
            reserve0,
            reserve1,
            false // Standard precision
        );
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

        // If there's no debt share, it's always solvent.
        if (vault.debtShare == 0) {
            return true;
        }

        // Fetch pool state
        (uint256 reserve0, uint256 reserve1, uint128 totalLiquidity) = getPoolReservesAndShares(poolId);
        uint256 multiplier = interestMultiplier[poolId];

        // Use the SolvencyUtils library helper function
        return SolvencyUtils.checkVaultSolvency(
            vault,
            reserve0,
            reserve1,
            totalLiquidity,
            multiplier,
            SOLVENCY_THRESHOLD_LIQUIDATION,
            PRECISION
        );
    }

    /**
     * @notice Calculate loan-to-value ratio for a vault
     * @param poolId The pool ID
     * @param user The user address
     * @return LTV ratio (scaled by PRECISION)
     */
    function getVaultLTV(PoolId poolId, address user) external view override returns (uint256) {
        Vault memory vault = vaults[poolId][user];

        // Fetch pool state
        (uint256 reserve0, uint256 reserve1, uint128 totalLiquidity) = getPoolReservesAndShares(poolId);
        uint256 multiplier = interestMultiplier[poolId];

        // Use the SolvencyUtils library helper function
        return SolvencyUtils.computeVaultLTV(
            vault,
            reserve0,
            reserve1,
            totalLiquidity,
            multiplier,
            PRECISION
        );
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
    // Helper Functions (Internal - Refactored to use TransferUtils where applicable)
    // =========================================================================

    /**
     * @notice Internal: Safe transfer ETH with fallback to pending payments (stateful)
     * @param recipient The address to send ETH to
     * @param amount The amount of ETH to send
     * @dev This function remains internal as it modifies contract state (pendingETHPayments).
     */
    function _safeTransferETH(address recipient, uint256 amount) internal {
        if (amount == 0) return;

        (bool success, ) = recipient.call{value: amount, gas: 50000}(""); // Use fixed gas stipend
        if (!success) {
            pendingETHPayments[recipient] += amount;
            emit ETHTransferFailed(recipient, amount); // Emit event here
        }
    }

    /**
     * @notice Internal: Helper for transferring tokens into the contract from a user.
     * @param key The pool key (for currency types)
     * @param from The sender address
     * @param amount0 Amount of token0 to transfer
     * @param amount1 Amount of token1 to transfer
     * @dev Handles ETH checks and refunds, calls TransferUtils for ERC20 transfers.
     */
    function _transferTokensIn(PoolKey memory key, address from, uint256 amount0, uint256 amount1) internal {
        uint256 ethAmountRequired = 0;
        if (key.currency0.isAddressZero()) ethAmountRequired += amount0;
        if (key.currency1.isAddressZero()) ethAmountRequired += amount1;

        // Check ETH value before calling library (which also checks, but good practice here)
        if (msg.value < ethAmountRequired) {
            revert Errors.InsufficientETH(ethAmountRequired, msg.value);
        }

        // Call library to handle transfers (ERC20s + ETH check)
        // The library function will revert if msg.value is insufficient, redundant but safe.
        uint256 actualEthRequired = TransferUtils.transferTokensIn(key, from, amount0, amount1, msg.value);
        // It's extremely unlikely actualEthRequired != ethAmountRequired, but double-check
        // if (actualEthRequired != ethAmountRequired) revert Errors.InternalError("ETH mismatch"); // REMOVED: Library already handles insufficient ETH check.

        // Refund excess ETH
        if (msg.value > ethAmountRequired) {
            // Use SafeTransferLib directly for refunds
            SafeTransferLib.safeTransferETH(from, msg.value - ethAmountRequired);
        }
    }

    /**
     * @notice Internal: Helper to transfer tokens out from the contract to a user.
     * @param key The pool key (contains currency information)
     * @param to Recipient address
     * @param amount0 Amount of token0 to transfer
     * @param amount1 Amount of token1 to transfer
     * @dev Calls TransferUtils library and handles ETH transfer failures via _safeTransferETH.
     */
    function _transferTokensOut(PoolKey memory key, address to, uint256 amount0, uint256 amount1) internal {
        // Call library to handle ERC20 transfers and attempt direct ETH transfers
        (bool eth0Success, bool eth1Success) = TransferUtils.transferTokensOut(key, to, amount0, amount1);

        // If ETH transfers failed, use internal stateful function to record pending payment
        if (!eth0Success) {
            _safeTransferETH(to, amount0); // Handles amount0 > 0 check internally
        }
        if (!eth1Success) {
            _safeTransferETH(to, amount1); // Handles amount1 > 0 check internally
        }
    }

    // =========================================================================
    // Phase 4 Interest Accrual Logic
    // =========================================================================

    /**
     * @notice Updates the global interest multiplier for a pool based on elapsed time and utilization.
     * @param poolId The pool ID
     */
    function _updateInterestForPool(PoolId poolId) internal {
        uint256 lastUpdate = lastInterestAccrualTime[poolId];
        // Optimization: If already updated in this block, skip redundant calculation
        if (lastUpdate == block.timestamp && lastUpdate != 0) return;

        uint256 timeElapsed = block.timestamp - lastUpdate;
        if (timeElapsed == 0) return; // No time passed since last update

        address modelAddress = interestRateModelAddress;
        // If no interest rate model is set, cannot accrue interest
        if (modelAddress == address(0)) {
            // Only update timestamp to prevent infinite loops if called again in same block
            lastInterestAccrualTime[poolId] = block.timestamp;
            // revert Errors.InterestModelNotSet(); // Reverting here might break things; log/return is safer
            return; // Silently return if no model set - ensures basic functions still work
        }

        IInterestRateModel model = IInterestRateModel(modelAddress);

        // Get current pool state for utilization calculation
        uint128 totalShares = liquidityManager.poolTotalShares(poolId);
        uint256 rentedShares = rentedLiquidity[poolId]; // 'borrowed' measure

        // If no shares rented or no total liquidity, no interest accrues on debt
        if (rentedShares == 0 || totalShares == 0) {
            lastInterestAccrualTime[poolId] = block.timestamp; // Update time even if no interest accrued
            return;
        }

        // Calculate utilization using the model's helper function
        uint256 utilization = model.getUtilizationRate(poolId, rentedShares, uint256(totalShares));

        // Get the current interest rate per second from the model
        uint256 interestRatePerSecond = model.getBorrowRate(poolId, utilization);

        // Calculate the new global interest multiplier using linear compounding
        uint256 currentMultiplier = interestMultiplier[poolId];
        if (currentMultiplier == 0) currentMultiplier = PRECISION; // Initialize if needed

        uint256 newMultiplier = FullMath.mulDiv(
            currentMultiplier,
            PRECISION + (interestRatePerSecond * timeElapsed), // Interest factor
            PRECISION
        );

        // Update the global multiplier
        interestMultiplier[poolId] = newMultiplier;

        // --- Protocol Fee Calculation ---
        if (currentMultiplier > 0 && rentedShares > 0) {
            // Interest Amount (Shares) = RentedShares * (NewMultiplier / OldMultiplier - 1)
            //                      = RentedShares * (NewMultiplier - OldMultiplier) / OldMultiplier
            uint256 interestAmountShares = FullMath.mulDiv(
                rentedShares,
                newMultiplier - currentMultiplier,
                currentMultiplier // Divide by old multiplier
            );

            // Get protocol fee percentage from Policy Manager
            uint256 protocolFeePercentage = policyManager.getProtocolFeePercentage(poolId);

            // Calculate the protocol's share of the accrued interest value
            uint256 protocolFeeShares = FullMath.mulDiv(
                interestAmountShares,
                protocolFeePercentage,
                PRECISION
            );

            // Add to accumulated fees for later processing
            accumulatedFees[poolId] += protocolFeeShares;
        }

        // Update the last accrual time AFTER all calculations
        lastInterestAccrualTime[poolId] = block.timestamp;

        // Emit event for pool-level accrual
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
     *      Actual debt value is calculated dynamically using the user's `debtShare`
     *      and the latest `interestMultiplier[poolId]`.
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
     * @notice Verify if a borrowing operation would keep the vault solvent and pool within utilization limits.
     * @param poolId The pool ID
     * @param user The user address
     * @param sharesToBorrow The amount of LP shares to borrow
     * @dev Updated for Phase 4 to check pool utilization against the Interest Rate Model.
     */
    function _checkBorrowingCapacity(PoolId poolId, address user, uint256 sharesToBorrow) internal view {
        // Ensure interest rate model is set
        address modelAddr = interestRateModelAddress;
        require(modelAddr != address(0), "Margin: Interest model not set"); // Use specific error if available

        // --- Check Pool Utilization Limit ---
        uint128 totalSharesLM = liquidityManager.poolTotalShares(poolId);
        if (totalSharesLM == 0) revert Errors.PoolNotInitialized(poolId); // Safety check

        uint256 currentBorrowed = rentedLiquidity[poolId];
        uint256 newBorrowed = currentBorrowed + sharesToBorrow;

        IInterestRateModel model = IInterestRateModel(modelAddr);

        // Use the model's helper for utilization calculation
        uint256 utilization = model.getUtilizationRate(poolId, newBorrowed, uint256(totalSharesLM));

        // Get max allowed utilization from the interest rate model
        uint256 maxAllowedUtilization = model.maxUtilizationRate();
        if (utilization > maxAllowedUtilization) {
             revert Errors.MaxPoolUtilizationExceeded(utilization, maxAllowedUtilization);
        }

        // --- Check User Vault Solvency ---
        // Note: Interest already accrued for user by calling function (e.g., borrow)

        // Calculate token amounts corresponding to sharesToBorrow using MathUtils
        (uint256 reserve0, uint256 reserve1, uint128 totalLiquidity) = getPoolReservesAndShares(poolId);
        (uint256 amount0FromShares, uint256 amount1FromShares) = MathUtils.computeWithdrawAmounts(
            totalLiquidity, // Use uint128 directly
            sharesToBorrow,
            reserve0,
            reserve1,
            false // Standard precision
        );

        // Calculate hypothetical new vault state after borrow
        Vault memory currentVault = vaults[poolId][user];
        uint128 newToken0Balance = (uint256(currentVault.token0Balance) + amount0FromShares).toUint128();
        uint128 newToken1Balance = (uint256(currentVault.token1Balance) + amount1FromShares).toUint128();
        // Proposed new debt share *after* accrual but *before* adding the new borrow amount interest.
        // Interest on the new borrowed amount starts accruing from the *next* block/update.
        uint128 newDebtShareBase = (uint256(currentVault.debtShare) + sharesToBorrow).toUint128(); 

        // Check if the post-borrow position would be solvent using the helper
        // Use the *current* interest multiplier as interest on new debt hasn't started yet
        if (!_isVaultSolventWithBalances(
            poolId,
            newToken0Balance,
            newToken1Balance,
            newDebtShareBase // Use the proposed base debt share
        )) {
            // Fetch necessary values for detailed error message (recalculate for clarity)
            (uint256 reserve0_err, uint256 reserve1_err, uint128 totalLiquidity_err) = getPoolReservesAndShares(poolId);
            uint256 multiplier_err = interestMultiplier[poolId];
            
            // Calculate hypothetical collateral value using MathUtils
            uint256 hypotheticalCollateralValue = MathUtils.calculateProportionalShares(
                newToken0Balance,
                newToken1Balance,
                totalLiquidity_err, 
                reserve0_err,
                reserve1_err,
                false // Standard precision
            );
            // Calculate estimated debt value *using current multiplier* on the proposed base debt share
            uint256 estimatedDebtValue;
            if (newDebtShareBase == 0) {
                 estimatedDebtValue = 0;
            } else if (multiplier_err == 0 || multiplier_err == PRECISION) {
                 estimatedDebtValue = newDebtShareBase;
            } else {
                 estimatedDebtValue = FullMath.mulDiv(newDebtShareBase, multiplier_err, PRECISION);
            }
            

            revert Errors.InsufficientCollateral(
                estimatedDebtValue,
                hypotheticalCollateralValue,
                SOLVENCY_THRESHOLD_LIQUIDATION
            );
        }
    }

    /**
     * @notice Internal function to check solvency with specified balances using SolvencyUtils.
     * @dev Used to check hypothetical solvency after potential withdrawal or before borrow.
     * @param poolId The pool ID
     * @param token0Balance Hypothetical token0 balance
     * @param token1Balance Hypothetical token1 balance
     * @param baseDebtShare The base debt share amount (before applying current interest multiplier).
     * @return True if solvent, False otherwise
     */
    function _isVaultSolventWithBalances(
        PoolId poolId,
        uint128 token0Balance,
        uint128 token1Balance,
        uint128 baseDebtShare // Pass the base debt share
    ) internal view returns (bool) {
        // If base debt share is 0, it's solvent.
        if (baseDebtShare == 0) {
            return true;
        }

        // Fetch pool state required by the utility function
        (uint256 reserve0, uint256 reserve1, uint128 totalLiquidity) = getPoolReservesAndShares(poolId);
        uint256 multiplier = interestMultiplier[poolId];

        // Use the SolvencyUtils library helper function
        return SolvencyUtils.checkSolvencyWithValues(
            token0Balance,
            token1Balance,
            baseDebtShare,
            reserve0,
            reserve1,
            totalLiquidity,
            multiplier,
            SOLVENCY_THRESHOLD_LIQUIDATION,
            PRECISION
        );
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
        override(Spot)
        whenNotPaused 
        nonReentrant 
        returns (uint256 amount0, uint256 amount1) 
    {
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

        // Proceed with the normal withdrawal logic by calling liquidityManager directly
        (amount0, amount1) = liquidityManager.withdraw(
            params.poolId,
            params.sharesToBurn,
            params.amount0Min,
            params.amount1Min,
            msg.sender
        );

        emit Withdraw(msg.sender, params.poolId, amount0, amount1, params.sharesToBurn);
        return (amount0, amount1);
    }

    /**
     * @notice Internal implementation of withdraw that calls parent without Margin checks
     * @dev Bypasses the InsufficientPhysicalShares check in Margin's withdraw override.
     *      Uses poolManager.take() instead of burning shares held by the Margin contract.
     */
    function _withdrawImpl(WithdrawParams memory params)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        // Call liquidityManager directly
        (amount0, amount1) = liquidityManager.withdraw(
            params.poolId,
            params.sharesToBurn,
            params.amount0Min,
            params.amount1Min,
            msg.sender
        );

        emit Withdraw(msg.sender, params.poolId, amount0, amount1, params.sharesToBurn);
        return (amount0, amount1);
    }

    /**
     * @notice Implements ISpot deposit function
     * @dev This implementation may be called by other contracts
     */
    function deposit(DepositParams calldata params)
        external
        override(Spot)
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        // Forward to Spot's deposit implementation
        // Use a different pattern to avoid infinite recursion
        PoolKey memory key = getPoolKey(params.poolId);
        
        // Validate native ETH usage
        bool hasNative = key.currency0.isAddressZero() || key.currency1.isAddressZero();
        if (msg.value > 0 && !hasNative) revert Errors.NonzeroNativeValue();
        
        // Delegate to liquidity manager
        (shares, amount0, amount1) = liquidityManager.deposit{value: msg.value}(
            params.poolId,
            params.amount0Desired,
            params.amount1Desired,
            params.amount0Min,
            params.amount1Min,
            msg.sender
        );
        
        emit Deposit(msg.sender, params.poolId, amount0, amount1, shares);
        return (shares, amount0, amount1);
    }

    /**
     * @notice Internal implementation of deposit used by repay function.
     */
    function _depositImpl(DepositParams memory params)
        internal
        returns (uint256 shares, uint256 actualAmount0, uint256 actualAmount1)
    {
       // Call liquidityManager directly
        (shares, actualAmount0, actualAmount1) = liquidityManager.deposit{value: address(this).balance}(
            params.poolId,
            params.amount0Desired,
            params.amount1Desired,
            params.amount0Min,
            params.amount1Min,
            msg.sender
        );
        
        emit Deposit(msg.sender, params.poolId, actualAmount0, actualAmount1, shares);
        return (shares, actualAmount0, actualAmount1);
    }

    // =========================================================================
    // Phase 4+ Fee Reinvestment Interaction Functions
    // =========================================================================

    /**
     * @notice View function called by FeeReinvestmentManager to check pending interest fees.
     * @param poolId The pool ID.
     * @return amount0 Estimated token0 value of pending fees.
     * @return amount1 Estimated token1 value of pending fees.
     * @dev This function calculates the interest accrual *as if* it happened now
     *      to get an accurate pending value, but does NOT modify state storage.
     *      It remains a `view` function.
     */
    function getPendingProtocolInterestTokens(PoolId poolId)
        external
        view
        override // Ensures it matches the interface
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 currentAccumulatedFeeShares = accumulatedFees[poolId];
        uint256 potentialFeeSharesToAdd = 0;

        // Calculate potential interest accrued since last update
        uint256 lastAccrual = lastInterestAccrualTime[poolId];
        uint256 nowTimestamp = block.timestamp;

        // Only calculate potential new fees if time has passed and a model exists
        if (nowTimestamp > lastAccrual && interestRateModelAddress != address(0)) {
            uint256 timeElapsed = nowTimestamp - lastAccrual;
            IInterestRateModel rateModel = IInterestRateModel(interestRateModelAddress);

            // Get current state needed for calculation
            (uint256 reserve0, uint256 reserve1, uint128 totalShares) = getPoolReservesAndShares(poolId); // Read-only call
            uint256 currentRentedLiquidity = rentedLiquidity[poolId]; // Read state
            uint256 currentMultiplier = interestMultiplier[poolId]; // Read state

            // Perform calculations (all view/pure operations)
            uint256 utilizationRate = rateModel.getUtilizationRate(poolId, currentRentedLiquidity, totalShares);
            uint256 ratePerSecond = rateModel.getBorrowRate(poolId, utilizationRate);

            uint256 potentialNewMultiplier = currentMultiplier; // Start with current
            uint256 interestFactor = ratePerSecond * timeElapsed;
            if (interestFactor > 0) {
                potentialNewMultiplier = FullMath.mulDiv(currentMultiplier, PRECISION + interestFactor, PRECISION);
            }

            if (potentialNewMultiplier > currentMultiplier && currentMultiplier > 0) { // Avoid division by zero if currentMultiplier is 0
                // Calculate potential total interest shares
                uint256 potentialInterestAmountShares = FullMath.mulDiv(
                    currentRentedLiquidity,
                    potentialNewMultiplier - currentMultiplier,
                    currentMultiplier
                );

                // Calculate potential protocol fee portion
                uint256 protocolFeePercentage = policyManager.getProtocolFeePercentage(poolId); // Correct: fetch from policy manager
                potentialFeeSharesToAdd = FullMath.mulDiv(
                    potentialInterestAmountShares,
                    protocolFeePercentage,
                    PRECISION
                );
            }
        }

        // Total potential fees = current fees + potential fees since last accrual
        uint256 totalPotentialFeeShares = currentAccumulatedFeeShares + potentialFeeSharesToAdd;

        if (totalPotentialFeeShares == 0) {
            return (0, 0);
        }

        // Convert the total potential fee shares to equivalent token amounts using MathUtils
        (uint256 reserve0_fee, uint256 reserve1_fee, uint128 totalLiquidity_fee) = getPoolReservesAndShares(poolId);
        (amount0, amount1) = MathUtils.computeWithdrawAmounts(
            totalLiquidity_fee, // Use uint128 directly
            totalPotentialFeeShares,
            reserve0_fee,
            reserve1_fee,
            false // Standard precision
        );
    }

    /**
     * @notice Called by FeeReinvestmentManager after successfully processing interest fees.
     * @param poolId The pool ID.
     * @return previousValue The amount of fee shares that were just cleared.
     */
    function resetAccumulatedFees(PoolId poolId)
        external
        override
        returns (uint256 previousValue)
    {
        // Authorization: Allow calls from the designated Reinvestment Policy or Governance
        address reinvestmentPolicy = policyManager.getPolicy(poolId, IPoolPolicy.PolicyType.REINVESTMENT);
        address governance = policyManager.getSoloGovernance(); // Fetch governance address

        // Add debug logging
        console2.log("Margin.resetAccumulatedFees called by:", msg.sender);
        console2.log("  Expected reinvestment policy:", reinvestmentPolicy);
        console2.log("  Expected governance:", governance);

        if (msg.sender != reinvestmentPolicy && msg.sender != governance) {
             revert Errors.AccessNotAuthorized(msg.sender);
        }

        previousValue = accumulatedFees[poolId];

        if (previousValue > 0) {
            accumulatedFees[poolId] = 0;
            emit ProtocolFeesProcessed(poolId, previousValue); // Emit event on successful reset
        }

        return previousValue;
    }

    /**
     * @notice Extract protocol fees from the liquidity pool and send them to the recipient.
     * @dev Called by FeeReinvestmentManager. This acts as an authorized forwarder to the liquidity manager.
     * @param poolId The pool ID to extract fees from.
     * @param amount0 Amount of token0 to extract.
     * @param amount1 Amount of token1 to extract.
     * @param recipient The address to receive the extracted fees (typically FeeReinvestmentManager).
     * @return success Boolean indicating if the extraction call to the liquidity manager succeeded.
     */
    function reinvestProtocolFees(
        PoolId poolId,
        uint256 amount0,
        uint256 amount1,
        address recipient
    ) external returns (bool success) {
        // Authorization: Only the designated REINVESTMENT policy for this pool can call this.
        address reinvestmentPolicy = policyManager.getPolicy(poolId, IPoolPolicy.PolicyType.REINVESTMENT);
        if (msg.sender != reinvestmentPolicy) {
            revert Errors.AccessNotAuthorized(msg.sender);
        }
        
        // Call the liquidity manager's function. Margin is authorized via fullRangeAddress.
        // The recipient (FeeReinvestmentManager) will receive the tokens.
        success = liquidityManager.reinvestProtocolFees(poolId, amount0, amount1, recipient);
        
        // No need to emit event here, FeeReinvestmentManager handles events.
        return success;
    }

    /**
     * @notice Gets the current interest rate per second for a pool from the model.
     * @param poolId The pool ID
     * @return rate The interest rate per second (scaled by PRECISION)
     */
    function getInterestRatePerSecond(PoolId poolId) public view override returns (uint256 rate) {
        address modelAddress = interestRateModelAddress;
        if (modelAddress == address(0)) return 0; // No model, no rate

        IInterestRateModel model = IInterestRateModel(modelAddress);

        uint128 totalShares = liquidityManager.poolTotalShares(poolId);
        uint256 rentedShares = rentedLiquidity[poolId];

        if (totalShares == 0) return 0; // Avoid division by zero if pool somehow has no shares

        // Use model's helper for utilization
        uint256 utilization = model.getUtilizationRate(poolId, rentedShares, uint256(totalShares));

        // Get rate from model
        rate = model.getBorrowRate(poolId, utilization);
        return rate;
    }

} // End Contract Margin 