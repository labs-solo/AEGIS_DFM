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
import { IFullRangeLiquidityManager } from "./interfaces/IFullRangeLiquidityManager.sol";
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
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { ERC20 } from "solmate/src/tokens/ERC20.sol";
import { BaseHook } from "v4-periphery/src/utils/BaseHook.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";

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
    uint256 public constant override(IMargin) PRECISION = 1e18;

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
     * @param _liquidityManager The single, multi-pool liquidity manager instance (dependency of Spot)
     * @param _marginManager The address of the deployed MarginManager contract.
     */
    constructor(
        IPoolManager _poolManager,
        IPoolPolicy _policyManager,
        IFullRangeLiquidityManager _liquidityManager,
        address _marginManager
    ) Spot(_poolManager, _policyManager, _liquidityManager) {
        if (_marginManager == address(0)) {
            revert Errors.ZeroAddress();
        }
        marginManager = IMarginManager(_marginManager);
    }

    /**
     * @notice Executes a batch of margin actions (Deposit, Withdraw, Borrow, Repay, Swap) for a specific pool.
     * @param poolId The ID of the pool these actions pertain to.
     * @param actions An array of actions to perform sequentially.
     * @dev This is the primary entry point for user interactions changing vault state.
     *      Handles ETH payment, orchestrates ERC20 transfers in, delegates core logic
     *      to MarginManager, and handles ETH refunds.
     */
    function executeBatch(bytes32 poolId, IMarginData.BatchAction[] calldata actions)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        uint256 numActions = actions.length;
        if (numActions == 0) revert Errors.ZeroAmount();

        // Validate the poolId corresponds to an initialized pool in this hook
        if (!poolData[poolId].initialized) revert Errors.PoolNotInitialized(poolId);

        // Get PoolKey using the provided poolId
        PoolKey memory key = poolKeys[poolId];

        uint256 requiredETH = 0;

        // --- Pre-computation and Token Pulling --- //
        for (uint256 i = 0; i < numActions; ++i) {
            IMarginData.BatchAction calldata action = actions[i];

            // Validate action type and parameters based on poolId's key
            // (Example: Ensure deposit asset matches pool currencies)
            if (action.actionType == IMarginData.ActionType.DepositCollateral) {
                if (action.amount > 0) { // Only process non-zero deposits
                    address token0Addr = Currency.unwrap(key.currency0);
                    address token1Addr = Currency.unwrap(key.currency1);
                    // Use address(0) check for native currency
                    bool isNativeToken0 = key.currency0.isAddressZero();
                    bool isNativeToken1 = key.currency1.isAddressZero();
                    bool isActionAssetNative = (action.asset == address(0));

                    if (isActionAssetNative) {
                         // Native ETH Deposit - must match one of the pool currencies
                         if (!isNativeToken0 && !isNativeToken1) revert Errors.InvalidAsset(); // Pool doesn't use native
                         requiredETH = requiredETH + action.amount; // Use safe math if necessary
                    } else {
                         // ERC20 Deposit - must match one of the pool currencies
                         if (action.asset == token0Addr) {
                             // ERC20 Token0 Deposit - Pull tokens
                             // Ensure token0 is not native
                             if (isNativeToken0) revert Errors.InvalidAsset(); 
                             SafeTransferLib.safeTransferFrom(ERC20(token0Addr), msg.sender, address(marginManager), action.amount);
                         } else if (action.asset == token1Addr) {
                             // ERC20 Token1 Deposit - Pull tokens
                             // Ensure token1 is not native
                             if (isNativeToken1) revert Errors.InvalidAsset(); 
                             SafeTransferLib.safeTransferFrom(ERC20(token1Addr), msg.sender, address(marginManager), action.amount);
                         } else {
                             revert Errors.InvalidAsset(); // Asset doesn't match pool currencies
                         }
                    }
                }
            } else if (action.actionType == IMarginData.ActionType.WithdrawCollateral) {
                 // No token pulling needed for withdrawals, handled by Manager
                 if (action.amount == 0) revert Errors.ZeroAmount(); // Validate withdrawal amount > 0
                 // Further validation (e.g., asset matches pool) can happen in Manager
            } else if (action.actionType == IMarginData.ActionType.Borrow) {
                if (action.amount == 0) revert Errors.ZeroAmount(); // Validate borrow amount > 0
                // Manager handles borrow logic and validation
            } else if (action.actionType == IMarginData.ActionType.Repay) {
                if (action.amount == 0) revert Errors.ZeroAmount(); // Validate repay amount > 0
                // Manager handles repay logic and token transfers
            } else if (action.actionType == IMarginData.ActionType.Swap) {
                // Manager (or swap delegate) handles swap logic and validation
                // Decode SwapRequest data = abi.decode(action.data, (SwapRequest));
                // if (data.amountIn == 0) revert Errors.ZeroAmount();
            } else {
                 revert Errors.ValidationInvalidInput("Unknown action type"); // Use ValidationInvalidInput
            }
        }

        // --- ETH Check --- //
        if (msg.value < requiredETH) {
            revert Errors.InsufficientETH(requiredETH, msg.value);
        }

        // --- Delegate to Manager --- //
        // Pass msg.sender and the specific poolId
        marginManager.executeBatch(msg.sender, PoolId.wrap(poolId), key, actions);

        // --- Refund Excess ETH --- //
        if (msg.value > requiredETH) {
            _safeTransferETH(msg.sender, msg.value - requiredETH);
        }

        // Optional: Emit high-level event
        // emit BatchExecuted(msg.sender, poolId, numActions);
    }

    /**
     * @notice Get vault information
     * @dev Delegates to MarginManager.
     * @inheritdoc IMargin
     */
    function getVault(PoolId poolId, address user) public view override(IMargin) returns (IMarginData.Vault memory) {
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
     * @notice Set up initial pool state when a pool is initialized by PoolManager using this hook.
     * @dev Extends Spot._afterInitialize to call MarginManager to initialize interest state for the specific pool.
     *      Note: Spot._afterInitialize now handles storing the PoolKey and marking the pool as initialized in this hook.
     */
    function _afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal virtual override(Spot) returns (bytes4) {
        // Get the poolId as bytes32 for compatibility with Spot's implementation
        bytes32 _poolId = PoolId.unwrap(key.toId());

        // 1. Call the base Spot implementation first. 
        // This is CRUCIAL because Spot._afterInitialize now performs the core setup 
        // (poolData[poolId].initialized = true, poolKeys[poolId] = key) required by Margin.
        super._afterInitialize(sender, key, sqrtPriceX96, tick);

        // 2. Perform Margin-specific initialization via the Manager
        // Ensure manager address is valid
        if (address(marginManager) == address(0)) {
             revert Errors.NotInitialized("MarginManager");
        }
        try marginManager.initializePoolInterest(key.toId()) {
            // Success, potentially emit Margin-specific event
            // emit MarginPoolInitialized(_poolId);
        } catch (bytes memory reason) {
            // Handle failure if Manager revert - decide if this should revert the whole initialization
            revert Errors.ValidationInvalidInput(string(reason));
        }

        // Return the selector required by the hook interface (usually IHooks.afterInitialize.selector)
        // Since Spot._afterInitialize already returns this, and we don't change the return value, 
        // we can implicitly rely on the return from super or explicitly return it.
        return IHooks.afterInitialize.selector; 
    }

    /**
     * @notice Hook called before adding or removing liquidity.
     * @dev Accrues pool interest via MarginManager before liquidity is modified.
     *      Overrides IHooks function via Spot.
     */
    function beforeModifyLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4) {
        // Basic validation
        if (msg.sender != address(poolManager)) revert Errors.CallerNotPoolManager(msg.sender);

        bytes32 _poolId = PoolId.unwrap(key.toId());
        // Accrue interest for the specific pool via the manager
        try marginManager.accruePoolInterest(PoolId.wrap(_poolId)) {
            // Success
        } catch (bytes memory reason) {
            // Handle failure - should interest accrual failure prevent liquidity modification?
            revert Errors.ValidationInvalidInput(string(reason)); // Use ValidationInvalidInput instead of ManagerCallFailed
        }
        // Return the required selector - use IHooks.beforeAddLiquidity.selector since this is handling both add and remove liquidity
        return IHooks.beforeAddLiquidity.selector;
    }

    /**
     * @notice Hook called after adding liquidity to a pool
     * @dev Overrides internal function from Spot. Currently performs no Margin-specific actions.
     */
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override(Spot) virtual returns (bytes4, BalanceDelta) {
        // Call Spot's implementation first if it has logic we want to preserve
        // super._afterAddLiquidity(sender, key, params, delta, feesAccrued, hookData);
        
        // Get the poolId as bytes32 for compatibility with Spot
        bytes32 _poolId = PoolId.unwrap(key.toId());
        // No Margin-specific logic currently needed here.
        // Placeholder for future logic.

        // Return the selector and delta required by the hook interface
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Hook called after removing liquidity from a pool
     * @dev Overrides internal function from Spot. Calls Spot's fee processing.
     */
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override(Spot) virtual returns (bytes4, BalanceDelta) {
        // 1. Call Spot's implementation first to handle fee processing etc.
        super._afterRemoveLiquidity(sender, key, params, delta, feesAccrued, hookData);

        // Get the poolId as bytes32 for compatibility with Spot
        bytes32 _poolId = PoolId.unwrap(key.toId());
        // No *additional* Margin-specific logic currently needed here.
        // Placeholder for future logic.

        // Return the selector and delta required by the hook interface
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @notice Hook called before a swap.
     * @dev Accrues pool interest via MarginManager and gets dynamic fee from Spot.
     *      Overrides function from Spot.
     */
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override(Spot) returns (bytes4, BeforeSwapDelta, uint24) {
        // Basic validation
        if (msg.sender != address(poolManager)) revert Errors.CallerNotPoolManager(msg.sender);

        bytes32 _poolId = PoolId.unwrap(key.toId());
        
        // 1. Accrue interest for the specific pool via the manager
        try marginManager.accruePoolInterest(PoolId.wrap(_poolId)) {
            // Success
        } catch (bytes memory reason) {
             // Handle failure - should interest accrual failure prevent swaps?
            revert Errors.ValidationInvalidInput(string(reason)); // Use ValidationInvalidInput instead of ManagerCallFailed
        }

        // 2. Call Spot's internal implementation to get the dynamic fee
        // Note: We are overriding the *external* `beforeSwap` from Spot, 
        // so we call Spot's *internal* `_beforeSwap` to get its return values.
        (, BeforeSwapDelta spotDelta, uint24 dynamicFee) = super._beforeSwap(sender, key, params, hookData);

        // Margin hook itself doesn't add a delta or modify the fee from Spot
        return (
            IHooks.beforeSwap.selector,
            spotDelta,
            dynamicFee
        );
    }

    /**
     * @notice Hook called before donating tokens.
     * @dev Accrues pool interest via MarginManager before the donation occurs.
     *      Overrides IHooks function.
     */
    // function beforeDonate(
    //     address sender,
    //     PoolKey calldata key,
    //     uint256 amount0,
    //     uint256 amount1,
    //     bytes calldata hookData
    // ) external override(BaseHook) returns (bytes4) {
    //     // Basic validation
    //     if (msg.sender != address(poolManager)) revert Errors.CallerNotPoolManager(msg.sender);

    //     bytes32 _poolId = key.toId();
    //     // Accrue interest for the specific pool via the manager
    //     try marginManager.accruePoolInterest(_poolId) {
    //         // Success
    //     } catch (bytes memory reason) {
    //          // Handle failure - should interest accrual failure prevent donations?
    //         revert Errors.ManagerCallFailed("accruePoolInterest", reason);
    //     }

    //     // Return the required selector
    //     return IHooks.beforeDonate.selector; 
    // }

    /**
     * @notice Gets the current interest rate per second for a pool from the model.
     * @param poolId The pool ID
     * @return rate The interest rate per second (scaled by PRECISION)
     */
    function getInterestRatePerSecond(PoolId poolId) public view virtual override(IMargin) returns (uint256 rate) {
        // Call the interest rate model's calculateInterestRate function directly
        // using the pool's utilization rate, which we would need to calculate
        IInterestRateModel model = marginManager.interestRateModel();
        if (address(model) == address(0)) {
            return 0; // Return 0 if no model is set
        }
        
        // For a basic implementation, we could return a constant rate
        // Or in a more complete implementation, calculate based on utilization:
        // uint256 utilization = calculateUtilization(poolId);
        // return model.calculateInterestRate(utilization);
        
        // For now, just return a placeholder constant rate until proper implementation
        return PRECISION / 31536000; // ~3.17e-8 per second (1% APR)
    }

    /**
     * @notice Override withdraw function from Spot to prevent direct LM withdrawals
     * @dev Users must use executeBatch with WithdrawCollateral action.
     */
    function withdraw(WithdrawParams calldata params) 
        external 
        view
        override(Spot)
        returns (uint256 amount0, uint256 amount1) 
    {
        revert Errors.ValidationInvalidInput("Use executeBatch with WithdrawCollateral action");
    }

    /**
     * @notice Override deposit function from Spot to prevent direct LM deposits
     * @dev Users must use executeBatch with DepositCollateral action.
     */
    function deposit(DepositParams calldata params)
        external
        override(Spot)
        payable
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        revert Errors.ValidationInvalidInput("Use executeBatch with DepositCollateral action");
    }

    /**
     * @notice Gets the number of users with vaults in a pool
     */
    function getPoolUserCount(PoolId poolId) external view virtual returns (uint256) {
        // This is a stub implementation since marginManager doesn't expose this functionality
        // In a proper implementation, we would delegate to marginManager
        // return marginManager.getPoolUserCount(poolId);
        return 0; // Return 0 as a placeholder until actual implementation
    }

    /**
     * @notice Check if a user has a vault (any balance or debt) in the pool
     */
    function hasVault(PoolId poolId, address user) external view virtual returns (bool) {
        return marginManager.hasVault(poolId, user);
    }

    /**
     * @notice Gets the rented liquidity for a pool
     */
    function getRentedLiquidity(PoolId poolId) external view virtual returns (uint256) {
        return marginManager.rentedLiquidity(poolId);
    }

    /**
     * @notice Gets the interest multiplier for a pool
     */
    function getInterestMultiplier(PoolId poolId) external view virtual returns (uint256) {
        return marginManager.interestMultiplier(poolId);
    }

    /**
     * @notice Gets the last interest accrual time for a pool
     */
    function getLastInterestAccrualTime(PoolId poolId) external view virtual returns (uint64) {
        return marginManager.lastInterestAccrualTime(poolId);
    }

    /**
     * @notice Gets the solvency threshold for liquidation
     */
    function getSolvencyThresholdLiquidation() external view virtual returns (uint256) {
        return marginManager.solvencyThresholdLiquidation();
    }

    /**
     * @notice Gets the liquidation fee
     */
    function getLiquidationFee() external view virtual returns (uint256) {
        return marginManager.liquidationFee();
    }

    /**
     * @notice Gets the interest rate model for a pool
     */
    function getInterestRateModel() external view virtual returns (IInterestRateModel) {
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

    // --- Restored Delegating Functions --- 
    
    // REMOVED isVaultSolvent as it's not in IMarginManager
    // function isVaultSolvent(PoolId poolId, address user) external view override(IMargin) returns (bool) {
    //     return marginManager.isVaultSolvent(poolId, user);
    // }
    
    // REMOVED getVaultLTV as it's not in IMarginManager
    // function getVaultLTV(PoolId poolId, address user) external view override(IMargin) returns (uint256) {
    //     return marginManager.getVaultLTV(poolId, user);
    // }
    
    function getPendingProtocolInterestTokens(PoolId poolId) 
        external 
        view 
        override(IMargin) 
        returns (uint256 amount0, uint256 amount1) 
    {
        return marginManager.getPendingProtocolInterestTokens(poolId);
    }
    
    function accumulatedFees(PoolId poolId) external view override(IMargin) returns (uint256) {
        return marginManager.accumulatedFees(poolId);
    }
    
    function resetAccumulatedFees(PoolId poolId) external override(IMargin) returns (uint256 previousValue) {
        return marginManager.resetAccumulatedFees(poolId);
    }
    
    function reinvestProtocolFees(
        PoolId poolId,
        uint256 amount0ToWithdraw,
        uint256 amount1ToWithdraw,
        address recipient
    ) external override(IMargin) returns (bool success) {
        return marginManager.reinvestProtocolFees(poolId, amount0ToWithdraw, amount1ToWithdraw, recipient);
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

    /**
     * @notice Override `getHookPermissions` to specify which hooks `Margin` uses
     * @dev Overrides Spot's implementation to declare hooks Margin interacts with.
     */
    function getHookPermissions() public pure override(Spot) returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false, 
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @notice Get oracle data for a pool
     * @param poolId The pool ID
     * @return tick The latest recorded tick
     * @return blockNumber The block number when the tick was last updated
     */
    function getOracleData(PoolId poolId) external view virtual override returns (int24 tick, uint32 blockNumber) {
        // Keep it simple: Call the parent class method with the right signature since we are Spot
        return ISpot(address(this)).getOracleData(poolId);
    }

    /**
     * @notice Gets pool info, providing a PoolId interface.
     * @param poolId The pool ID (PoolId type)
     * @return isInitialized Whether the pool is initialized
     * @return reserves Array of pool reserves [reserve0, reserve1]
     * @return totalShares Total shares in the pool
     * @return tokenId Token ID for the pool
     */
    function getPoolInfo(PoolId poolId) external view virtual override returns (
        bool isInitialized,
        uint256[2] memory reserves,
        uint128 totalShares,
        uint256 tokenId
    ) {
        return ISpot(address(this)).getPoolInfo(poolId);
    }

    /**
     * @notice Gets the pool key, providing a PoolId interface.
     * @param poolId The pool ID (PoolId type)
     * @return The pool key if initialized.
     */
    function getPoolKey(PoolId poolId) external view virtual override returns (PoolKey memory) {
        return ISpot(address(this)).getPoolKey(poolId);
    }

    /**
     * @notice Gets reserves and shares, providing a PoolId interface.
     * @param poolId The pool ID (PoolId type)
     * @return reserve0 The reserve amount of token0.
     * @return reserve1 The reserve amount of token1.
     * @return totalShares The total liquidity shares outstanding for the pool from LM.
     */
    function getPoolReservesAndShares(PoolId poolId) external view virtual override returns (uint256 reserve0, uint256 reserve1, uint128 totalShares) {
        return ISpot(address(this)).getPoolReservesAndShares(poolId);
    }

    /**
     * @notice Gets the token ID, providing a PoolId interface.
     * @param poolId The pool ID (PoolId type)
     * @return The ERC1155 token ID representing the pool's LP shares.
     */
    function getPoolTokenId(PoolId poolId) external view virtual override returns (uint256) {
        return ISpot(address(this)).getPoolTokenId(poolId);
    }

    /**
     * @notice Checks pool initialization, providing a PoolId interface.
     * @param poolId The pool ID (PoolId type)
     * @return True if the pool is initialized and managed by this hook instance.
     */
    function isPoolInitialized(PoolId poolId) external view virtual override returns (bool) {
        return ISpot(address(this)).isPoolInitialized(poolId);
    }

    /**
     * @notice Sets emergency state, providing a PoolId interface.
     * @param poolId The pool ID (PoolId type)
     * @param isEmergency The new state
     */
    function setPoolEmergencyState(PoolId poolId, bool isEmergency) external virtual override {
        ISpot(address(this)).setPoolEmergencyState(poolId, isEmergency);
    }
}