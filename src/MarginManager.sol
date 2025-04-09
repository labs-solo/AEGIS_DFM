// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { SafeCast } from "v4-core/src/libraries/SafeCast.sol";
import { FullMath } from "v4-core/src/libraries/FullMath.sol"; // Might be needed later
import { IMarginManager } from "./interfaces/IMarginManager.sol";
import { IMarginData } from "./interfaces/IMarginData.sol";
import { IInterestRateModel } from "./interfaces/IInterestRateModel.sol";
import { IPoolPolicy } from "./interfaces/IPoolPolicy.sol"; // Added for Phase 4
import { FullRangeLiquidityManager } from "./FullRangeLiquidityManager.sol"; // Added for Phase 3
import { MathUtils } from "./libraries/MathUtils.sol"; // Added for Phase 3
import { Errors } from "./errors/Errors.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol"; // Added for Phase 2
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol"; // Added for Phase 2
import { Margin } from "./Margin.sol"; // Added for Phase 2
import { IERC20 } from "oz-contracts/token/ERC20/IERC20.sol"; // Use new remapping
import { SafeERC20 } from "oz-contracts/token/ERC20/utils/SafeERC20.sol"; // Use new remapping
import { TickMath } from "v4-core/src/libraries/TickMath.sol"; // Added src back
import { FixedPoint128 } from "v4-core/src/libraries/FixedPoint128.sol"; // Added src back

/**
 * @title MarginManager
 * @notice Core logic and state management contract for the Margin protocol.
 * @dev Handles vault management, debt/collateral accounting, interest accrual (logic deferred),
 *      solvency checks (logic deferred), and governance-updatable parameters.
 *      Designed to be called primarily by the associated Margin facade/hook contract.
 *      This is intended to be a non-upgradeable core contract.
 */
contract MarginManager is IMarginManager {
    using SafeCast for uint256;

    /// @inheritdoc IMarginManager
    uint256 public constant override PRECISION = 1e18;

    // =========================================================================
    // State Variables
    // =========================================================================

    /**
     * @notice Maps PoolId -> User Address -> User's Vault state.
     * @dev Made private to avoid conflict with explicit getter
     */
    mapping(PoolId => mapping(address => IMarginData.Vault)) private _vaults;

    /**
     * @notice Maps PoolId -> Total amount of borrowed/rented liquidity in shares.
     */
    mapping(PoolId => uint256) public override rentedLiquidity;

    /**
     * @notice Maps PoolId -> Current interest multiplier (starts at PRECISION).
     */
    mapping(PoolId => uint256) public override interestMultiplier;

    /**
     * @notice Maps PoolId -> Timestamp of the last global interest accrual.
     */
    mapping(PoolId => uint64) public override lastInterestAccrualTime;

    /**
     * @notice The address of the associated Margin facade/hook contract. Immutable.
     */
    address public immutable override marginContract;

    /**
     * @notice The address of the Uniswap V4 Pool Manager. Immutable.
     */
    IPoolManager public immutable override poolManager;

    /**
     * @notice The address of the FullRangeLiquidityManager used by the associated Spot/Margin contract. Immutable.
     */
    address public immutable override liquidityManager;

    /**
     * @notice The address of the governance entity authorized to change parameters. Immutable.
     */
    address public immutable governance;

    /**
     * @notice The currently active interest rate model contract. Settable by governance.
     */
    IInterestRateModel public override interestRateModel;

    /**
     * @notice Maps PoolId -> Protocol fees accrued from interest (in shares value). Added Phase 4.
     */
    mapping(PoolId => uint256) public accumulatedFees;

    /**
     * @notice The solvency threshold (collateral value / debt value) below which liquidation can occur. Settable by governance. Scaled by PRECISION.
     */
    uint256 public override solvencyThresholdLiquidation;

    /**
     * @notice The fee percentage charged during liquidations. Settable by governance. Scaled by PRECISION.
     */
    uint256 public override liquidationFee;

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @notice Constructor to link contracts and set initial parameters.
     * @param _marginContract The address of the Margin facade/hook contract.
     * @param _poolManager The address of the Uniswap V4 Pool Manager.
     * @param _liquidityManager The address of the FullRangeLiquidityManager contract.
     * @param _governance The address of the governance contract/entity.
     * @param _initialSolvencyThreshold The initial solvency threshold (e.g., 98 * 1e16 for 98%).
     * @param _initialLiquidationFee The initial liquidation fee (e.g., 1 * 1e16 for 1%).
     */
    constructor(
        /// @notice The address of the Margin facade/hook contract.
        address _marginContract,
        /// @notice The address of the Uniswap V4 Pool Manager.
        address _poolManager,
        /// @notice The address of the FullRangeLiquidityManager contract.
        address _liquidityManager,
        /// @notice The address of the governance contract/entity.
        address _governance,
        /// @notice The initial solvency threshold (e.g., 98e16 for 98%).
        uint256 _initialSolvencyThreshold,
        /// @notice The initial liquidation fee (e.g., 1e16 for 1%).
        uint256 _initialLiquidationFee
    ) {
        if (_marginContract == address(0) || _poolManager == address(0) || _liquidityManager == address(0) || _governance == address(0)) {
            revert Errors.ZeroAddress();
        }
        // Validate initial parameters
        if (_initialSolvencyThreshold == 0 || _initialSolvencyThreshold > PRECISION) {
             revert Errors.InvalidParameter("solvencyThresholdLiquidation", _initialSolvencyThreshold);
        }
        // Liquidation fee can technically be 0, but must be less than 100%
        if (_initialLiquidationFee >= PRECISION ) {
             revert Errors.InvalidParameter("liquidationFee", _initialLiquidationFee);
        }

        marginContract = _marginContract;
        poolManager = IPoolManager(_poolManager);
        liquidityManager = _liquidityManager;
        governance = _governance;
        solvencyThresholdLiquidation = _initialSolvencyThreshold;
        liquidationFee = _initialLiquidationFee;
        // interestRateModel is set via setInterestRateModel by governance post-deployment
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    /**
     * @dev Throws if called by any account other than the linked Margin contract.
     */
    modifier onlyMarginContract() {
        if (msg.sender != marginContract) {
            revert Errors.CallerNotMarginContract();
        }
        _;
    }

    /**
     * @dev Throws if called by any account other than the designated governance address.
     */
    modifier onlyGovernance() {
        // Note: AccessNotAuthorized includes the caller address for better debugging.
        if (msg.sender != governance) {
             revert Errors.AccessNotAuthorized(msg.sender);
        }
        _;
    }

    // =========================================================================
    // View Functions (Explicit implementations not needed for public state vars)
    // =========================================================================
    // Solidity auto-generates getters for public state variables like:
    // rentedLiquidity, interestMultiplier, lastInterestAccrualTime,
    // marginContract, poolManager, liquidityManager, solvencyThresholdLiquidation,
    // liquidationFee, PRECISION.

    // Explicit getter for vaults needed to match interface signature exactly
    function vaults(PoolId poolId, address user) external view override(IMarginManager) returns (IMarginData.Vault memory) {
        return _vaults[poolId][user];
    }

    // Explicit getter for interestRateModel is auto-generated if public override.

    // =========================================================================
    // State Modifying Functions (Placeholders for Phase 2+)
    // =========================================================================

    /**
     * @notice Initializes interest state for a newly created pool.
     * @inheritdoc IMarginManager
     * @param poolId The ID of the pool being initialized.
     * @dev Called by Margin.sol's _afterPoolInitialized hook.
     *      Sets the initial interest multiplier to PRECISION and records the creation time.
     */
    function initializePoolInterest(PoolId poolId) external override onlyMarginContract {
        if (lastInterestAccrualTime[poolId] != 0) {
            revert Errors.PoolAlreadyInitialized(poolId); // Prevent re-initialization
        }
        interestMultiplier[poolId] = PRECISION;
        lastInterestAccrualTime[poolId] = uint64(block.timestamp); // Safe cast
    }

    /**
     * @notice Executes a batch of actions.
     * @inheritdoc IMarginManager
     * @dev Phase 5: Implements gas optimization via memory caching of initial state.
     * @param user The end user performing the actions.
     * @param poolId The ID of the pool.
     * @param key The PoolKey associated with the poolId.
     * @param actions The array of batch actions to execute.
     */
    function executeBatch(address user, PoolId poolId, PoolKey calldata key, IMarginData.BatchAction[] calldata actions)
        external
        override
        onlyMarginContract
    {
        // --- Phase 5: Gas Optimization - Cache state reads --- //
        // Parameters (read once)
        uint256 _threshold = solvencyThresholdLiquidation; // SLOAD
        IInterestRateModel _rateModel = interestRateModel; // SLOAD
        IPoolPolicy _policyMgr = IPoolPolicy(Margin(marginContract).policyManager()); // External call

        // Pool State (read once initially)
        (uint256 initialReserve0, uint256 initialReserve1, uint128 initialTotalShares) = 
            Margin(marginContract).getPoolReservesAndShares(poolId); // External call via facade
        
        // Interest State (read once initially)
        uint256 _currentMultiplier = interestMultiplier[poolId]; // SLOAD
        uint64 _lastAccrual = lastInterestAccrualTime[poolId]; // SLOAD
        uint256 _rented = rentedLiquidity[poolId]; // SLOAD

        // Vault State (load to memory)
        IMarginData.Vault memory vaultMem = _vaults[poolId][user];
        uint256 startingDebt = vaultMem.debtShares; // Store starting debt if needed later

        // --- Accrue Interest (using cached values where possible) --- //
        _accrueInterestForUser(poolId, user, vaultMem, _lastAccrual, _currentMultiplier, _rented, initialTotalShares, _rateModel, _policyMgr);
        // _accrueInterestForUser updates vaultMem.lastAccrualTimestamp and global storage for multiplier, fees, time.

        // --- Process Actions (modifying vaultMem) --- //
        // Re-read multiplier *after* accrual for use in actions/solvency check
        _currentMultiplier = interestMultiplier[poolId]; // SLOAD (re-read)

        uint256 numActions = actions.length;
        if (numActions == 0) revert Errors.ZeroAmount(); // Already checked in Margin.sol but safe here too.

        for (uint256 i = 0; i < numActions; ++i) {
            // Pass memory struct and potentially relevant cached parameters
            // Pass initial pool state needed for calculations like repay
            _processSingleAction(poolId, user, key, actions[i], vaultMem, initialReserve0, initialReserve1, initialTotalShares, _rateModel, _threshold, _currentMultiplier);
        }

        // --- Final Solvency Check --- //
        // Fetch final pool state *after* actions have modified vaultMem
        (uint256 finalReserve0, uint256 finalReserve1, uint128 finalTotalShares) = 
            Margin(marginContract).getPoolReservesAndShares(poolId); 

        // Check solvency of the proposed final state in vaultMem using current multiplier
        if (!_isSolvent(poolId, vaultMem, finalReserve0, finalReserve1, finalTotalShares, _threshold, _currentMultiplier)) {
            // Calculate values needed for the error parameters
            uint256 collateralValueInShares = _calculateCollateralValueInShares(poolId, vaultMem, finalReserve0, finalReserve1, finalTotalShares);
            uint256 debtValueInShares = FullMath.mulDiv(vaultMem.debtShares, _currentMultiplier, PRECISION);
            revert Errors.InsufficientCollateral(debtValueInShares, collateralValueInShares, _threshold); 
        }

        // --- Commit Vault State --- //
        _vaults[poolId][user] = vaultMem; // Commit memory state back to private storage
    }

    /**
     * @notice Accrues interest for a specific pool up to the current block timestamp.
     * @inheritdoc IMarginManager
     * @param poolId The ID of the pool for which to accrue interest.
     * @dev This is intended to be called by the Margin contract hooks (e.g., beforeModifyLiquidity)
     *      to ensure interest is up-to-date before external actions modify pool state.
     *      It delegates to the internal _updateInterestForPool function.
     */
    function accruePoolInterest(PoolId poolId) external override onlyMarginContract {
        // Delegate to the internal function that reads current state and updates
        _updateInterestForPool(poolId);
    }

    // =========================================================================
    // Internal Logic Functions (Placeholders)
    // =========================================================================

    /**
     * @notice Processes a single action within a batch.
     * @inheritdoc IMarginManager
     * @dev Internal function called by executeBatch. Uses cached initial state where appropriate.
     * @param poolId The ID of the pool.
     * @param user The end user performing the action.
     * @param key The PoolKey associated with the poolId.
     * @param action The specific batch action details.
     * @param vaultMem The user's vault memory struct (will be modified).
     * @param initialReserve0 The initial reserve0 of the pool.
     * @param initialReserve1 The initial reserve1 of the pool.
     * @param initialTotalShares The initial total shares of the pool.
     */
    function _processSingleAction(
        /// @notice Processes a single action within a batch, modifying the memory vault state.
        /// @dev Internal function called by executeBatch. Uses cached initial state where appropriate.
        PoolId poolId,
        address user,
        PoolKey calldata key,
        IMarginData.BatchAction calldata action,
        IMarginData.Vault memory vaultMem,
        uint256 initialReserve0,
        uint256 initialReserve1,
        uint128 initialTotalShares,
        IInterestRateModel _rateModel,
        uint256 _threshold,
        uint256 _currentMultiplier
    ) internal {
        address recipient = action.recipient == address(0) ? user : action.recipient;

        if (action.actionType == IMarginData.ActionType.DepositCollateral) {
            _handleDepositCollateral(poolId, user, key, action, vaultMem);
        } else if (action.actionType == IMarginData.ActionType.WithdrawCollateral) {
            _handleWithdrawCollateral(poolId, user, key, action, vaultMem, recipient);
        } else if (action.actionType == IMarginData.ActionType.Borrow) {
            _handleBorrow(poolId, user, key, action, vaultMem, recipient, initialTotalShares, _rateModel);
        } else if (action.actionType == IMarginData.ActionType.Repay) {
            _handleRepay(poolId, user, key, action, vaultMem, initialReserve0, initialReserve1, initialTotalShares);
        } else {
            // Revert for unsupported actions in Phase 2
            revert("MarginManager: Unsupported action type");
            // Future phases will handle Borrow, Repay, Swap here.
        }
    }

    /**
     * @notice Checks if a vault is solvent.
     * @inheritdoc IMarginManager
     * @dev Implementation deferred.
     */
    function _isSolvent(
        /// @notice Checks if a vault's state (in memory) is solvent against current pool conditions.
        PoolId poolId,
        IMarginData.Vault memory vaultMem,
        uint256 reserve0,
        uint256 reserve1,
        uint128 totalShares,
        uint256 threshold,
        uint256 currentInterestMultiplier
    ) internal view returns (bool) {
        // If there's no debt, the vault is always solvent
        if (vaultMem.debtShares == 0) {
            return true;
        }

        // Calculate the value of the vault's collateral in terms of LP shares
        uint256 collateralValueInShares = _calculateCollateralValueInShares(
            poolId,
            vaultMem,
            reserve0,
            reserve1,
            totalShares
        );

        // Calculate the value of the vault's debt in terms of LP shares, applying interest
        uint256 debtValueInShares = FullMath.mulDiv(
            vaultMem.debtShares,
            currentInterestMultiplier,
            PRECISION
        );

        // Apply solvency threshold - collateral must exceed debt * threshold/PRECISION
        uint256 requiredCollateral = FullMath.mulDiv(
            debtValueInShares,
            threshold,
            PRECISION
        );

        // Vault is solvent if collateral value >= required collateral
        return collateralValueInShares >= requiredCollateral;
    }

    /**
     * @notice Calculates the value of vault collateral in terms of LP shares.
     * @dev Converts token balances to equivalent share value using pool reserves and total shares.
     * @param poolId The ID of the pool.
     * @param vaultMem The vault memory struct containing token balances.
     * @param reserve0 The current reserve of token0 in the pool.
     * @param reserve1 The current reserve of token1 in the pool.
     * @param totalShares The total shares in the pool.
     * @return sharesValue The value of the collateral in terms of LP shares.
     */
    function _calculateCollateralValueInShares(
        PoolId poolId,
        IMarginData.Vault memory vaultMem,
        uint256 reserve0,
        uint256 reserve1,
        uint128 totalShares
    ) internal view returns (uint256 sharesValue) {
        // If the pool has no reserves or shares, collateral has no value
        if (totalShares == 0 || (reserve0 == 0 && reserve1 == 0)) {
            return 0;
        }

        // Calculate share value based on both token0 and token1 balances
        // For each token: sharesForToken = tokenBalance * totalShares / tokenReserve

        uint256 sharesFromToken0 = 0;
        if (reserve0 > 0 && vaultMem.token0Balance > 0) {
            sharesFromToken0 = FullMath.mulDiv(
                uint256(vaultMem.token0Balance),
                totalShares,
                reserve0
            );
        }

        uint256 sharesFromToken1 = 0;
        if (reserve1 > 0 && vaultMem.token1Balance > 0) {
            sharesFromToken1 = FullMath.mulDiv(
                uint256(vaultMem.token1Balance),
                totalShares,
                reserve1
            );
        }

        // Take the smaller of the two share values to ensure conservative valuation
        // This prevents manipulation by depositing only the less valuable token
        return sharesFromToken0 < sharesFromToken1 ? sharesFromToken0 : sharesFromToken1;
    }

    /**
     * @notice Accrues interest for a user by updating the pool's global state. Placeholder for Phase 4+.
     * @dev Implementation deferred. Calls _updateInterestForPool.
     */
    function _accrueInterestForUser(
        /// @notice Ensures pool interest is up-to-date and updates user's accrual timestamp.
        /// @inheritdoc IMarginManager
        /// @dev Called at the beginning of executeBatch before processing actions.
        ///      Passes cached values to `_updateInterestForPoolWithCache`.
        PoolId poolId,
        address user,
        IMarginData.Vault memory vaultMem,
        uint64 _lastUpdate,
        uint256 _currentMultiplier,
        uint256 _rentedShares,
        uint128 _totalShares,
        IInterestRateModel _rateModel,
        IPoolPolicy _policyMgr
    ) internal {
        // Suppress unused var warning
        user;

        // 1. Update the global pool interest first.
        _updateInterestForPoolWithCache(
            poolId,
            _lastUpdate,
            _currentMultiplier,
            _rentedShares,
            _totalShares,
            _rateModel,
            _policyMgr
        );

        // 2. Update the user's timestamp in the memory struct.
        // This marks the vault state as current relative to the global multiplier.
        vaultMem.lastAccrualTimestamp = uint64(block.timestamp); // SafeCast not needed block.timestamp -> uint64
    }

    /**
     * @notice Updates the global interest multiplier for a pool. Placeholder for Phase 4+.
     * @dev Implementation deferred. Uses IInterestRateModel.
     */
    function _updateInterestForPool(PoolId poolId) internal {
        _updateInterestForPoolWithCache(
            poolId,
            lastInterestAccrualTime[poolId],
            interestMultiplier[poolId],
            rentedLiquidity[poolId],
            FullRangeLiquidityManager(liquidityManager).poolTotalShares(poolId),
            interestRateModel,
            IPoolPolicy(Margin(marginContract).policyManager()) // Get policy manager via facade
        );
    }

    /**
     * @notice Internal implementation of _updateInterestForPool using cached parameters.
     * @dev Separated for clarity and testability with cached values.
     *      Updates storage directly for multiplier, time, and fees.
     */
    function _updateInterestForPoolWithCache(
        PoolId poolId,
        uint64 _lastUpdate,
        uint256 _currentMultiplier,
        uint256 _rentedShares,
        uint128 _totalShares,
        IInterestRateModel _rateModel, // Renamed from _interestRateModel
        IPoolPolicy _policyMgr // Added policy manager param
    ) internal {
        // Check if model is set
        /// @dev Reverts if no interest rate model is set, preventing interest-related actions.
        if (address(_rateModel) == address(0)) {
            revert Errors.InterestModelNotSet(); 
        }

        uint64 _currentTime = uint64(block.timestamp); // Cast current time

        if (_currentTime <= _lastUpdate) {
            return; // No time elapsed or clock went backwards
        }

        uint256 timeElapsed = _currentTime - _lastUpdate; // Use cached last update time

        uint256 newMultiplier = _currentMultiplier; // Use cached multiplier
        uint256 protocolFeeSharesDelta = 0;
        uint256 ratePerSecond = 0;

        if (_rentedShares > 0 && _totalShares > 0) {
            // Only calculate interest if there is debt and liquidity
            uint256 utilization = _rateModel.getUtilizationRate(poolId, _rentedShares, _totalShares);
            ratePerSecond = _rateModel.getBorrowRate(poolId, utilization);

            if (ratePerSecond > 0) {
                uint256 interestFactor = ratePerSecond * timeElapsed; // No overflow expected with reasonable rates/time
                newMultiplier = FullMath.mulDiv(_currentMultiplier, PRECISION + interestFactor, PRECISION); // Use cached multiplier

                // --- Protocol Fee Calculation --- //
                if (_currentMultiplier > 0) { // Avoid division by zero
                    uint256 interestAmountShares = FullMath.mulDiv(
                        _rentedShares,
                        newMultiplier - _currentMultiplier, // Use cached multiplier
                        _currentMultiplier // Divide by old multiplier
                    );

                    // Get fee percentage only once if needed
                    uint256 protocolFeePercentage = 0;
                    if (protocolFeePercentage == 0) {
                         protocolFeePercentage = _policyMgr.getProtocolFeePercentage(poolId);
                    }

                    if (protocolFeePercentage > 0) {
                        protocolFeeSharesDelta = FullMath.mulDiv(
                            interestAmountShares,
                            protocolFeePercentage,
                            PRECISION // Divide by PRECISION
                        );
                    }
                }
            }
        }

        // Update interest multiplier
        interestMultiplier[poolId] = newMultiplier;

        // Update accumulated fees
        if (protocolFeeSharesDelta > 0) {
            accumulatedFees[poolId] += protocolFeeSharesDelta; // SSTORE only if changed
        }

        // Update last interest accrual time
        lastInterestAccrualTime[poolId] = _currentTime;

        // --- Emit Events --- //
        emit InterestAccrued(
            poolId,
            _currentTime,
            timeElapsed,
            ratePerSecond,
            newMultiplier
        );
        if (protocolFeeSharesDelta > 0) {
            emit ProtocolFeesAccrued(poolId, protocolFeeSharesDelta);
        }
    }

    // =========================================================================
    // Internal Action Handlers (Phase 2 Implementation)
    // =========================================================================

    /**
     * @notice Internal handler for depositing collateral.
     * @param poolId The ID of the pool.
     * @param user The user performing the action.
     * @param key The PoolKey for the pool.
     * @param action The specific batch action details.
     * @param vaultMem The user's vault memory struct (will be modified).
     * @dev Tokens are assumed to have been transferred to this contract already by Margin.sol.
     */
    function _handleDepositCollateral(
        PoolId poolId,
        address user,
        PoolKey calldata key,
        IMarginData.BatchAction calldata action,
        IMarginData.Vault memory vaultMem // Pass memory struct for Phase 3
    ) internal {
        if (action.amount == 0) revert Errors.ZeroAmount();

        uint128 amount128 = action.amount.toUint128(); // Reverts on overflow
        bool isToken0;

        // Determine which token balance to update based on action.asset and PoolKey
        // address(0) asset signifies native currency
        if (key.currency0.isNative()) {
            if (action.asset != address(0)) revert Errors.InvalidAsset();
            isToken0 = true;
        } else if (key.currency1.isNative()) {
            if (action.asset != address(0)) revert Errors.InvalidAsset();
            isToken0 = false;
        } else {
            // Both are ERC20
            address token0Addr = key.currency0.unwrap();
            address token1Addr = key.currency1.unwrap();
            if (action.asset == token0Addr) {
                isToken0 = true;
            } else if (action.asset == token1Addr) {
                isToken0 = false;
            } else {
                revert Errors.InvalidAsset();
            }
        }

        // Update vault balance (add as uint256 then cast back)
        if (isToken0) {
            vaultMem.token0Balance = (uint256(vaultMem.token0Balance) + amount128).toUint128();
        } else {
            vaultMem.token1Balance = (uint256(vaultMem.token1Balance) + amount128).toUint128();
        }

        emit DepositCollateralProcessed(poolId, user, action.asset, action.amount);
    }

    /**
     * @notice Internal handler for withdrawing collateral.
     * @param poolId The ID of the pool.
     * @param user The user performing the action.
     * @param key The PoolKey for the pool.
     * @param action The specific batch action details.
     * @param vaultMem The user's vault memory struct (will be modified).
     * @param recipient The final recipient of the withdrawn tokens.
     */
    function _handleWithdrawCollateral(
        PoolId poolId,
        address user,
        PoolKey calldata key,
        IMarginData.BatchAction calldata action,
        IMarginData.Vault memory vaultMem, // Pass memory struct for Phase 3
        address recipient
    ) internal {
        if (action.amount == 0) revert Errors.ZeroAmount();

        uint128 amount128 = action.amount.toUint128(); // Reverts on overflow
        address tokenAddress; // For ERC20 transfers
        bool isNativeTransfer = false;

        // Determine which token, check balance, and decrement
        address currency0Addr = key.currency0.unwrap();
        address currency1Addr = key.currency1.unwrap();

        if ((key.currency0.isNative() && action.asset == address(0)) || currency0Addr == action.asset) {
            if (vaultMem.token0Balance < amount128) revert Errors.InsufficientBalance(amount128, vaultMem.token0Balance);
            vaultMem.token0Balance -= amount128;
            isNativeTransfer = key.currency0.isNative();
            tokenAddress = currency0Addr; // Will be address(0) if native
        } else if ((key.currency1.isNative() && action.asset == address(0)) || currency1Addr == action.asset) {
            if (vaultMem.token1Balance < amount128) revert Errors.InsufficientBalance(amount128, vaultMem.token1Balance);
            vaultMem.token1Balance -= amount128;
            isNativeTransfer = key.currency1.isNative();
            tokenAddress = currency1Addr; // Will be address(0) if native
        } else {
            revert Errors.InvalidAsset();
        }

        // Perform transfer out
        if (isNativeTransfer) {
            // Call Margin.sol to send ETH. Margin.sol verifies caller is this contract.
            Margin(marginContract).sendETH(recipient, action.amount);
        } else {
            // Transfer ERC20 from this contract (MarginManager)
            _safeTransferOut(tokenAddress, recipient, action.amount);
        }

        emit WithdrawCollateralProcessed(poolId, user, recipient, action.asset, action.amount);
    }

    /**
     * @notice Internal handler for borrowing shares.
     * @param poolId The ID of the pool.
     * @param user The user performing the action.
     * @param key The PoolKey for the pool.
     * @param action The specific batch action details (amount = shares to borrow).
     * @param vaultMem The user's vault memory struct (will be modified).
     * @param recipient The final recipient of the borrowed tokens.
     */
    function _handleBorrow(
        PoolId poolId,
        address user,
        PoolKey calldata key,
        IMarginData.BatchAction calldata action,
        IMarginData.Vault memory vaultMem, // Accepts memory struct
        address recipient,
        uint128 initialTotalShares, // Use cached value
        IInterestRateModel _rateModel // Added Phase 5 (for future use/consistency)
    ) internal {
        if (action.amount == 0) revert Errors.ZeroAmount();
        uint256 sharesToBorrow = action.amount;

        // --- Phase 3: Basic Capacity Check --- //
        // Use cached total shares from start of batch for check
        uint256 currentRented = rentedLiquidity[poolId]; // SLOAD (Needs SLOAD as it can change mid-batch via Repay)
        uint256 newRented = currentRented + sharesToBorrow;

        // Prevent borrowing more shares than exist in the pool (basic sanity check)
        if (newRented > initialTotalShares) {
            revert Errors.MaxPoolUtilizationExceeded(newRented, initialTotalShares); // Use cached value
        }

        // --- Update Debt State --- //
        // Note: Interest accrual (Phase 4) should happen *before* this in executeBatch
        vaultMem.debtShares += sharesToBorrow;
        rentedLiquidity[poolId] = newRented; // Update global rented liquidity (SSTORE)

        // --- Call Liquidity Manager to get tokens --- //
        // The LM removes liquidity equivalent to sharesToBorrow and sends tokens to this contract.
        (uint256 amount0Received, uint256 amount1Received) = 
            FullRangeLiquidityManager(liquidityManager).borrowImpl(poolId, sharesToBorrow, address(this));

        // --- Transfer Tokens Out --- //
        if (amount0Received > 0) {
            if (key.currency0.isNative()) {
                Margin(marginContract).sendETH(recipient, amount0Received);
            } else {
                _safeTransferOut(key.currency0.unwrap(), recipient, amount0Received);
            }
        }
        if (amount1Received > 0) {
            if (key.currency1.isNative()) {
                Margin(marginContract).sendETH(recipient, amount1Received);
            } else {
                _safeTransferOut(key.currency1.unwrap(), recipient, amount1Received);
            }
        }

        // --- Emit Event --- //
        emit BorrowProcessed(poolId, user, recipient, sharesToBorrow, amount0Received, amount1Received);
    }

    /**
     * @notice Internal handler for repaying debt using vault collateral.
     * @inheritdoc IMarginManager
     * @param poolId The ID of the pool.
     * @param user The user performing the action.
     * @param key The PoolKey for the pool.
     * @param action The specific batch action details (amount = shares target to repay).
     * @param vaultMem The user's vault memory struct (will be modified).
     * @param initialReserve0 The initial reserve0 of the pool.
     * @param initialReserve1 The initial reserve1 of the pool.
     * @param initialTotalShares The initial total shares of the pool.
     * @dev Phase 4 only supports repaying using vault balance (FLAG_USE_VAULT_BALANCE_FOR_REPAY assumed or ignored).
     *      Requires MarginManager to have ETH balance if repaying involves native token deposit.
     */
    function _handleRepay(
        PoolId poolId,
        address user,
        PoolKey calldata key,
        IMarginData.BatchAction calldata action,
        IMarginData.Vault memory vaultMem,
        uint256 initialReserve0,
        uint256 initialReserve1,
        uint128 initialTotalShares
    ) internal {
        // Ensure user has debt. Interest already accrued by executeBatch.
        uint256 currentDebtShares = vaultMem.debtShares;
        if (currentDebtShares == 0) revert Errors.NoDebtToRepay();

        uint256 sharesToRepay = action.amount;
        if (sharesToRepay == 0) revert Errors.ZeroAmount();

        // Cap repayment amount to current debt
        if (sharesToRepay > currentDebtShares) {
            sharesToRepay = currentDebtShares;
        }

        // Calculate token amounts needed based on *initial* pool state from start of batch
        (uint256 amount0Needed, uint256 amount1Needed) = 
            MathUtils.computeWithdrawAmounts(initialTotalShares, sharesToRepay, initialReserve0, initialReserve1, false);
        
        if (amount0Needed == 0 && amount1Needed == 0 && sharesToRepay > 0) {
             // Should not happen if reserves/totalShares > 0, but safety check
             revert Errors.InternalError("Repay calc failed");
        }

        // Phase 4 Simplification: Only handle repay from vault balance
        bool useVaultBalance = (action.flags & IMarginData.FLAG_USE_VAULT_BALANCE_FOR_REPAY) > 0;
        // if (!useVaultBalance) revert("Repay from external funds not yet supported"); // Enforce if needed

        // Check vault balance and deduct needed amounts
        uint128 amount0Needed128 = amount0Needed.toUint128();
        uint128 amount1Needed128 = amount1Needed.toUint128();
        if (vaultMem.token0Balance < amount0Needed128) revert Errors.InsufficientBalance(amount0Needed, vaultMem.token0Balance);
        if (vaultMem.token1Balance < amount1Needed128) revert Errors.InsufficientBalance(amount1Needed, vaultMem.token1Balance);
        
        vaultMem.token0Balance -= amount0Needed128;
        vaultMem.token1Balance -= amount1Needed128;

        // --- Approve LM to spend tokens from this contract --- //
        if (amount0Needed > 0 && !key.currency0.isNative()) {
            _safeApprove(key.currency0.unwrap(), liquidityManager, amount0Needed);
        }
        if (amount1Needed > 0 && !key.currency1.isNative()) {
            _safeApprove(key.currency1.unwrap(), liquidityManager, amount1Needed);
        }

        // --- Deposit into Liquidity Manager --- //
        // Handle ETH separately if needed (assuming LM's deposit handles msg.value if one token is native)
        uint256 msgValueForDeposit = 0;
        if (key.currency0.isNative() && amount0Needed > 0) {
            msgValueForDeposit = amount0Needed;
        } else if (key.currency1.isNative() && amount1Needed > 0) {
            msgValueForDeposit = amount1Needed;
        }
        // Call deposit on LM. It will pull ERC20s and use msg.value if needed.
        // This returns the *actual* shares minted, which might differ from target due to state changes.
        // We use the actual shares minted to reduce debt accurately.
        (uint256 actualSharesMinted, /*uint256 actualAmount0Deposited*/, /*uint256 actualAmount1Deposited*/) = 
            FullRangeLiquidityManager(liquidityManager).deposit{value: msgValueForDeposit}(
                PoolIdLibrary.toKey(poolId), // Requires PoolIdLibrary if not available
                amount0Needed,
                amount1Needed,
                0, // minSharesReceiver - not used in repay flow
                address(this) // Recipient of shares is this contract (but they cancel debt)
            );

        // --- Update Debt State --- //
        // Use the *actual* shares minted/repaid, capping at the initial debt calculated
        uint256 actualSharesRepaid = actualSharesMinted > currentDebtShares ? currentDebtShares : actualSharesMinted;
        if (actualSharesRepaid == 0 && sharesToRepay > 0) {
            // If we intended to repay but got 0 shares back (e.g., LM state changed drastically)
            revert Errors.InternalError("Repay deposit yielded zero shares");
        }

        vaultMem.debtShares -= actualSharesRepaid;
        rentedLiquidity[poolId] -= actualSharesRepaid; // Update global rented liquidity (SSTORE)

        // --- Emit Event --- //
        emit RepayProcessed(poolId, user, actualSharesRepaid, amount0Needed, amount1Needed);
    }

    // =========================================================================
    // Internal Helper Functions (Phase 2 Implementation)
    // =========================================================================

    /**
     * @notice Internal helper to safely transfer ERC20 tokens *out* from this contract.
     * @param token The address of the ERC20 token.
     * @param recipient The address to receive the tokens.
     * @param amount The amount of tokens to send.
     */
    function _safeTransferOut(address token, address recipient, uint256 amount) internal {
        if (amount == 0) return; // Don't attempt zero transfers
        // Use safeTransfer; reverts if transfer fails or token contract is invalid.
        SafeTransferLib.safeTransfer(token, recipient, amount);
    }

    /**
     * @notice Internal helper to safely approve ERC20 tokens for spending by the Liquidity Manager.
     * @dev Resets allowance to 0 first to prevent known ERC20 approval issues.
     * @param token The address of the ERC20 token contract.
     * @param spender The address to approve (Liquidity Manager).
     * @param amount The amount of tokens to approve.
     */
    function _safeApprove(address token, address spender, uint256 amount) internal {
        SafeTransferLib.safeApprove(token, spender, 0); // Reset approval first
        SafeTransferLib.safeApprove(token, spender, amount);
    }

    // =========================================================================
    // Governance Functions
    // =========================================================================

    /**
     * @notice Sets the solvency threshold below which liquidations can occur.
     * @inheritdoc IMarginManager
     * @param _threshold The new solvency threshold, scaled by PRECISION (e.g., 98e16 for 98%).
     */
    function setSolvencyThresholdLiquidation(uint256 _threshold) external override onlyGovernance {
        if (_threshold == 0 || _threshold > PRECISION) {
             revert Errors.InvalidParameter("solvencyThresholdLiquidation", _threshold);
        }
        solvencyThresholdLiquidation = _threshold;
    }

    /**
     * @notice Sets the fee charged during liquidations.
     * @inheritdoc IMarginManager
     * @param _fee The new liquidation fee percentage, scaled by PRECISION (e.g., 1e16 for 1%).
     */
    function setLiquidationFee(uint256 _fee) external override onlyGovernance {
        // Liquidation fee can technically be 0, but must be less than 100%
        if (_fee >= PRECISION ) {
             revert Errors.InvalidParameter("liquidationFee", _fee);
        }
        liquidationFee = _fee;
    }

    /**
     * @notice Sets the interest rate model contract address.
     * @inheritdoc IMarginManager
     * @param _interestRateModel The address of the new interest rate model contract.
     */
    function setInterestRateModel(address _interestRateModel) external override onlyGovernance {
        if (_interestRateModel == address(0)) {
            revert Errors.ZeroAddress();
        }
        // Optional: Add a check to ensure the address implements IInterestRateModel?
        // This requires an external call or interface check, skipped for gas/simplicity here.
        interestRateModel = IInterestRateModel(_interestRateModel);
    }

    // =========================================================================
    // Internal/Hook Functions (Called by Margin.sol)
    // =========================================================================

    // =========================================================================
    // Events
    // =========================================================================

    // These events are already defined in IMarginManager
    // Commented out to avoid duplication
    /*
    // Phase 1/2 Events
    event DepositCollateralProcessed(PoolId indexed poolId, address indexed user, address asset, uint256 amount);
    event WithdrawCollateralProcessed(PoolId indexed poolId, address indexed user, address indexed recipient, address asset, uint256 amount);

    // Phase 3 Events
    event BorrowProcessed(PoolId indexed poolId, address indexed user, address indexed recipient, uint256 sharesBorrowed, uint256 amount0Received, uint256 amount1Received);

    // Phase 4 Events
    event RepayProcessed(PoolId indexed poolId, address indexed user, uint256 sharesRepaid, uint256 amount0Provided, uint256 amount1Provided);
    event PoolInterestInitialized(PoolId indexed poolId, uint256 initialMultiplier, uint64 timestamp);
    event SolvencyThresholdLiquidationSet(uint256 oldThreshold, uint256 newThreshold);
    event LiquidationFeeSet(uint256 oldFee, uint256 newFee);
    event InterestRateModelSet(address oldModel, address newModel);
    */

    // Potential Future Events
    // event SwapProcessed(...);
    // event LiquidationProcessed(...);

    // --- Restored Placeholder Functions --- 
    
    function getPendingProtocolInterestTokens(PoolId poolId) 
        external 
        view 
        override(IMarginManager) 
        returns (uint256 amount0, uint256 amount1) 
    {
        // Placeholder implementation
        return (0, 0);
    }
    
    function reinvestProtocolFees(
        PoolId poolId, 
        uint256 amount0ToWithdraw, 
        uint256 amount1ToWithdraw, 
        address recipient
    ) external override(IMarginManager) returns (bool success) {
        // Placeholder implementation
        return true;
    }
    
    function resetAccumulatedFees(PoolId poolId) external override(IMarginManager) returns (uint256 processedShares) {
        // Placeholder implementation
        uint256 prev = accumulatedFees[poolId];
        accumulatedFees[poolId] = 0;
        return prev;
    }
}