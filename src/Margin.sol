// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { Spot, DepositParams, WithdrawParams } from "./Spot.sol";
import { IMargin } from "./interfaces/IMargin.sol";
import { ISpot } from "./interfaces/ISpot.sol";
import { IMarginManager } from "./interfaces/IMarginManager.sol";
import { IMarginData } from "./interfaces/IMarginData.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/src/types/BalanceDelta.sol";
import { ReentrancyGuard } from "solmate/src/utils/ReentrancyGuard.sol";
import { MathUtils } from "./libraries/MathUtils.sol";
import { Errors } from "./errors/Errors.sol";
import { FullRangeLiquidityManager } from "./FullRangeLiquidityManager.sol";
import { IPoolPolicy } from "./interfaces/IPoolPolicy.sol";
import { EnumerableSet } from "v4-core/lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import { FullMath } from "v4-core/src/libraries/FullMath.sol";
import { IInterestRateModel } from "./interfaces/IInterestRateModel.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { PoolTokenIdUtils } from "./utils/PoolTokenIdUtils.sol";
import { SafeTransferLib } from "solmate/src/utils/SafeTransferLib.sol";
import { Currency } from "lib/v4-core/src/types/Currency.sol";
import { CurrencyLibrary } from "lib/v4-core/src/types/Currency.sol";
import { IFeeReinvestmentManager } from "./interfaces/IFeeReinvestmentManager.sol";
import { TransferUtils } from "./utils/TransferUtils.sol";
import "forge-std/console2.sol";

/**
 * @title Margin
 * @notice Foundation for a margin lending system on Uniswap V4 spot liquidity positions
 * @dev Phase 1 establishes the architecture and data structures needed for future phases.
 *      This contract acts as a facade and V4 Hook implementation, delegating core logic and state
 *      to an associated MarginManager contract. It inherits from Spot.sol for base V4 integration
 *      and policy management.
 *      Refactored in v1.8 to separate logic/state into MarginManager.sol.
 */

// Move event inside contract
// event ETHClaimed(address indexed recipient, uint256 amount);

contract Margin is ReentrancyGuard, Spot, IMargin {
    /// @inheritdoc IMargin
    /// @notice Precision constant (1e18).
    uint256 public constant override PRECISION = 1e18;

    // Define event here
    event ETHClaimed(address indexed recipient, uint256 amount);

    using PoolIdLibrary for PoolKey;
    using EnumerableSet for EnumerableSet.AddressSet;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using FullMath for uint256;

    /**
     * @notice The address of the core logic and state contract. Immutable.
     * @dev Set during deployment, links this facade to the MarginManager.
     */
    IMarginManager public immutable marginManager;

    /**
     * @notice Tracks pending ETH payments for failed transfers
     * @dev Stores amounts of ETH that failed to be sent, allowing users to claim later.
     */
    mapping(address => uint256) public pendingETHPayments;

    /**
     * @notice Constructor
     * @param _poolManager The Uniswap V4 pool manager
     * @param _policyManager The policy manager (handles governance, passed to Spot)
     * @param _liquidityManager The liquidity manager (dependency of Spot, passed to Spot)
     * @param _marginManager The address of the deployed MarginManager contract.
     * @param _poolId The PoolId for this specific Margin instance.
     */
    constructor(
        IPoolManager _poolManager,
        IPoolPolicy _policyManager,
        FullRangeLiquidityManager _liquidityManager,
        address _marginManager,
        PoolId _poolId
    ) Spot(_poolManager, _policyManager, _liquidityManager, _poolId) {
        if (_marginManager == address(0)) {
            revert Errors.ZeroAddress();
        }
        marginManager = IMarginManager(_marginManager);
    }

    /**
     * @notice Executes a batch of margin actions (Deposit, Withdraw, Borrow, Repay, Swap).
     * @inheritdoc IMargin
     * @param actions An array of actions to perform sequentially.
     * @dev This is the primary entry point for user interactions changing vault state.
     *      Handles ETH payment, orchestrates ERC20 transfers in, delegates core logic
     *      to MarginManager, and handles ETH refunds.
     *      Implementation deferred to Phase 2.
     */
    function executeBatch(IMarginData.BatchAction[] calldata actions)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        uint256 numActions = actions.length;
        if (numActions == 0) revert Errors.ZeroAmount();

        // Access state variable instead of calling function
        PoolId thisPoolId = poolId;
        PoolKey memory key = getPoolKey(thisPoolId);

        uint256 requiredETH = 0;

        // --- Pre-computation and Token Pulling --- //
        for (uint256 i = 0; i < numActions; ++i) {
            IMarginData.BatchAction calldata action = actions[i];

            if (action.actionType == IMarginData.ActionType.DepositCollateral) {
                if (action.amount > 0) { // Only process non-zero deposits
                    address token0Addr = key.currency0.unwrap();
                    address token1Addr = key.currency1.unwrap();
                    bool isNativeToken0 = key.currency0.isNative();
                    bool isNativeToken1 = key.currency1.isNative();

                    if ((isNativeToken0 && action.asset == address(0)) || (isNativeToken1 && action.asset == address(0)) ) {
                         // Native ETH Deposit
                         requiredETH += action.amount;
                    } else if (!isNativeToken0 && action.asset == token0Addr) {
                         // ERC20 Token0 Deposit - Pull tokens
                         SafeTransferLib.safeTransferFrom(token0Addr, msg.sender, address(marginManager), action.amount);
                    } else if (!isNativeToken1 && action.asset == token1Addr) {
                         // ERC20 Token1 Deposit - Pull tokens
                         SafeTransferLib.safeTransferFrom(token1Addr, msg.sender, address(marginManager), action.amount);
                    } else {
                         revert Errors.InvalidAsset(); // Asset doesn't match pool or native currency designation
                    }
                }
            } else if (action.actionType == IMarginData.ActionType.WithdrawCollateral) {
                 // No token pulling needed for withdrawals, handled by Manager
                 if (action.amount == 0) revert Errors.ZeroAmount(); // Validate withdrawal amount > 0
            } else {
                 // Defer other actions (Borrow, Repay, Swap) - do nothing here in Phase 2
                 // Validation for these actions will happen inside MarginManager in later phases.
            }
        }

        // --- ETH Check --- //
        if (msg.value < requiredETH) {
            revert Errors.InsufficientETH(requiredETH, msg.value);
        }

        // --- Delegate to Manager --- //
        // Ensure manager address is valid before calling
        if (address(marginManager) == address(0)) {
            revert Errors.ZeroAddress(); // Or a more specific error
        }
        marginManager.executeBatch(msg.sender, thisPoolId, key, actions);

        // --- Refund Excess ETH --- //
        if (msg.value > requiredETH) {
            _safeTransferETH(msg.sender, msg.value - requiredETH); // Use internal function
        }

        // Optional: Emit high-level event
        // emit BatchExecuted(msg.sender, thisPoolId, numActions);
    }

    /**
     * @notice Get vault information
     * @dev Delegates to MarginManager.
     * @inheritdoc IMargin
     */
    function getVault(PoolId poolId, address user) external view returns (IMarginData.Vault memory) {
        return marginManager.vaults(poolId, user);
    }

    /**
     * @notice Set the contract pause state
     * @dev Assumes pause state is managed by Spot/PolicyManager.
     */
    function setPaused(bool _paused) external onlyGovernance {
        revert("Margin: Pause control via Policy Manager TBD");
    }

    /**
     * @notice Sets the solvency threshold by delegating to MarginManager.
     * @dev Requires onlyGovernance modifier (inherited).
     */
    function setSolvencyThresholdLiquidation(uint256 _threshold) external onlyGovernance {
        marginManager.setSolvencyThresholdLiquidation(_threshold);
    }
    function setLiquidationFee(uint256 _fee) external onlyGovernance {
        marginManager.setLiquidationFee(_fee);
    }
    function setInterestRateModel(address _interestRateModel) external onlyGovernance {
        marginManager.setInterestRateModel(_interestRateModel);
    }

    /**
     * @notice Only allow when contract is not paused
     */
    modifier whenNotPaused() {
        // TODO: Implement actual pause check, possibly via PolicyManager
        _;
    }

    /**
     * @notice Set up initial pool state when a pool is initialized
     * @dev Extends Spot._afterPoolInitialized to call MarginManager to initialize interest state.
     */
    function _afterPoolInitialized(
        PoolId _poolId, // Use parameter name consistently
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal override {
        Spot._afterPoolInitialized(_poolId, key, sqrtPriceX96, tick);

        // Manager handles interest initialization
        if (address(marginManager) != address(0)) {
             marginManager.initializePoolInterest(_poolId);
        }
        // Remove direct state modification - Manager owns this state
        // interestMultiplier[poolId] = PRECISION;
        // lastInterestAccrualTime[poolId] = block.timestamp;
    }

    /**
     * @notice Hook called before adding or removing liquidity.
     * @dev Accrues pool interest before liquidity is modified.
     */
    function beforeModifyLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        marginManager.accruePoolInterest(key.toId());
        return Margin.beforeModifyLiquidity.selector;
    }

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
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();

        return (bytes4(0), BalanceDeltaLibrary.ZERO_DELTA);
    }

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
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();

        return (bytes4(0), BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Hook called before a swap.
     * @dev Accrues pool interest before the swap occurs.
     */
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        marginManager.accruePoolInterest(key.toId());
        return Margin.beforeSwap.selector;
    }

    /**
     * @notice Hook called before donating tokens.
     * @dev Accrues pool interest before the donation occurs.
     */
    function beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external override returns (bytes4) {
        marginManager.accruePoolInterest(key.toId());
        return Margin.beforeDonate.selector;
    }

    /**
     * @notice Gets the current interest rate per second for a pool from the model.
     * @param poolId The pool ID
     * @return rate The interest rate per second (scaled by PRECISION)
     */
    function getInterestRatePerSecond(PoolId poolId) public view override returns (uint256 rate) {
        revert("Margin: Logic moved to MarginManager");
    }

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
        revert("Margin: Use executeBatch for collateral operations.");
    }

    /**
     * @notice Implements ISpot deposit function
     * @dev This implementation may be called by other contracts
     * @inheritdoc ISpot
     */
    function deposit(DepositParams calldata params)
        external
        override(Spot)
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        revert("Margin: Use executeBatch for collateral operations.");
    }

    /**
     * @notice Gets the number of users with vaults in a pool
     */
    function getPoolUserCount(PoolId poolId) external view returns (uint256) {
        revert("Margin: Logic moved to MarginManager");
    }

    /**
     * @notice Check if a user has a vault (any balance or debt) in the pool
     */
    function hasVault(PoolId poolId, address user) external view returns (bool) {
        revert("Margin: Logic moved to MarginManager");
    }

    /**
     * @notice Gets the rented liquidity for a pool
     */
    function getRentedLiquidity(PoolId poolId) external view returns (uint256) {
        return marginManager.rentedLiquidity(poolId);
    }

    /**
     * @notice Gets the interest multiplier for a pool
     */
    function getInterestMultiplier(PoolId poolId) external view returns (uint256) {
        return marginManager.interestMultiplier(poolId);
    }

    /**
     * @notice Gets the last interest accrual time for a pool
     */
    function getLastInterestAccrualTime(PoolId poolId) external view returns (uint64) {
        return marginManager.lastInterestAccrualTime(poolId);
    }

    /**
     * @notice Gets the solvency threshold for liquidation
     */
    function getSolvencyThresholdLiquidation() external view returns (uint256) {
        return marginManager.solvencyThresholdLiquidation();
    }

    /**
     * @notice Gets the liquidation fee
     */
    function getLiquidationFee() external view returns (uint256) {
        return marginManager.liquidationFee();
    }

    /**
     * @notice Gets the interest rate model for a pool
     */
    function getInterestRateModel() external view returns (IInterestRateModel) {
        return marginManager.interestRateModel();
    }

    /**
     * @notice Sends ETH to a recipient, intended to be called only by the MarginManager.
     * @dev Relies on _safeTransferETH for actual transfer and pending payment handling.
     * @param recipient The address to receive ETH.
     * @param amount The amount of ETH to send.
     */
    function sendETH(address recipient, uint256 amount) external {
        if (msg.sender != address(marginManager)) {
            revert Errors.AccessNotAuthorized(msg.sender);
        }
        _safeTransferETH(recipient, amount); // Use internal function
    }

    /**
     * @notice Claims pending ETH payments for the caller.
     * @dev Allows users to retrieve ETH that failed to be transferred previously.
     */
    function claimETH() external nonReentrant {
        uint256 amount = pendingETHPayments[msg.sender];
        if (amount == 0) return;
        pendingETHPayments[msg.sender] = 0;
        _safeTransferETH(msg.sender, amount); // Use internal function
        emit ETHClaimed(msg.sender, amount); // Emit the event
    }

    // --- Internal Helper Functions ---

    /**
     * @notice Safely transfers ETH, storing failed transfers in pendingETHPayments.
     * @param to The recipient address.
     * @param amount The amount of ETH to send.
     */
    function _safeTransferETH(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, ) = to.call{value: amount}("");
        if (!success) {
            // Transfer failed, store for later claim
            pendingETHPayments[to] += amount;
            // Optional: Emit an event for failed transfer?
            // emit ETHTransferFailed(to, amount);
        }
    }
} 