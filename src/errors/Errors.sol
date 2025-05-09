// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/**
 * @title Errors
 * @notice Collection of all custom errors used in the protocol
 */
library Errors {
    // --- Access Control ---
    error AccessDenied();
    error AccessOnlyGovernance(address caller);
    error AccessOnlyPoolManager(address caller);
    error AccessNotAuthorized(address caller);
    error AccessOnlyEmergencyAdmin(address caller);
    error Unauthorized();
    error CallerNotPoolManager(address caller);
    error CallerNotMarginContract();
    error AccessOnlyOwner(address caller);
    error UnauthorizedCaller(address caller);
    error GovernanceNotInitialized();
    error HookAddressAlreadySet();
    error InvalidHookAddress();
    error ZeroDestination();

    // --- Validation & Input ---
    error ValidationDeadlinePassed(uint32 deadline, uint32 blockTime);
    error ValidationZeroAddress(string target);
    error ValidationInvalidInput(string reason);
    error ValidationZeroAmount(string parameter);
    error ValidationInvalidLength(string parameter);
    error ValidationInvalidAddress(address target);
    error ValidationInvalidRange(string parameter);
    error ValidationInvalidFee(uint24 fee);
    error ValidationInvalidTickSpacing(int24 tickSpacing);
    error ValidationInvalidTick(int24 tick);
    error ValidationInvalidSlippage(uint256 slippage);
    error ParameterOutOfRange(uint256 value, uint256 min, uint256 max);
    error DeadlinePassed(uint32 deadline, uint32 blockTime);
    error ArrayLengthMismatch();
    error InvalidCallbackSalt();
    error InvalidPolicyImplementationsLength(uint256 length);
    error NotInitialized(string component);
    error AlreadyInitialized(string component);
    error ReinvestmentDisabled();
    error RateLimited();
    error InvalidPoolKey();
    error InvalidPoolId();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroLiquidity();
    error ZeroShares();
    error ZeroPolicyManagerAddress();
    error ZeroPoolManagerAddress();
    error ZeroFullRangeAddress();
    error InvalidCallbackType(uint8 callbackType);
    error InvalidTickRange();
    error InvalidParameter(string parameterName, uint256 value);
    error ExpiryTooSoon(uint256 expiry, uint256 requiredTime);
    error ExpiryTooFar(uint256 expiry, uint256 requiredTime);

    // --- Math & Calculation ---
    error DivisionByZero();
    error Overflow();
    error Underflow();
    error InvalidCalculation();
    error InvalidConversion();
    error InvalidRatio();
    error InvalidAmount();
    error InvalidShare();
    error InvalidPercentage();
    error InvalidFee();
    error InvalidPrice(uint160 sqrtPriceX96);
    error InvalidLiquidity();
    error InvalidInput();
    error AmountTooLarge(uint256 amount, uint256 maximum);
    error SlippageExceeded(uint256 required, uint256 actual);
    error CalculationError(string reason);
    error MathOverflow();
    error MathUnderflow();

    // --- System & State ---
    error HookDispatchFailed(bytes4 selector);
    error DelegateCallFailed();
    error NotImplemented();
    error ContractPaused();
    error InternalError(string message);
    error InconsistentState(string reason);

    // --- Pool State & Operations ---
    error PoolNotInitialized(bytes32 poolId);
    error PoolAlreadyInitialized(bytes32 poolId);
    error PoolNotFound(bytes32 poolId);
    error PoolPaused(bytes32 poolId);
    error PoolLocked(bytes32 poolId);
    error PoolInvalidState(bytes32 poolId);
    error PoolInvalidOperation(bytes32 poolId);
    error PoolInvalidParameter(bytes32 poolId);
    error PoolUnsupportedFee(uint24 fee);
    error PoolUnsupportedTickSpacing(int24 tickSpacing);
    error PoolInvalidFeeOrTickSpacing(uint24 fee, int24 tickSpacing);
    error PoolTickOutOfRange(int24 tick, int24 minTick, int24 maxTick);
    error PoolInEmergencyState(bytes32 poolId);
    error PoolInvalidStateTransition(bytes32 poolId, string currentState, string targetState);
    error OnlyDynamicFeePoolAllowed();
    error FailedToReadPoolData(PoolId poolId);
    error PoolKeyAlreadyStored(bytes32 poolId);

    // --- Liquidity & Shares ---
    error InsufficientAmount(uint256 requested, uint256 available);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error InsufficientShares(uint256 requested, uint256 available);
    error InsufficientBalance(uint256 requested, uint256 available);
    error InsufficientAllowance(uint256 requested, uint256 available);
    error LiquidityOverflow();
    error LiquidityUnderflow();
    error LiquidityLocked();
    error LiquidityRangeTooWide();
    error LiquidityRangeTooNarrow();
    error LiquidityAlreadyExists();
    error LiquidityDoesNotExist();
    error LiquidityNotAvailable();
    error DepositTooSmall();
    error InitialDepositTooSmall(uint256 minAmount, uint256 actualAmount);
    error WithdrawAmountTooSmall();

    // --- Policy ---
    error PolicyNotFound();
    error PolicyAlreadyExists();
    error PolicyInvalidState();
    error PolicyInvalidParameter();
    error PolicyInvalidOperation();
    error PolicyUnauthorized();
    error PolicyLocked();
    error PolicyExpired();
    error PolicyNotActive();
    error PolicyNotImplemented();
    error AllocationSumError(uint256 polShare, uint256 fullRangeShare, uint256 lpShare, uint256 expected);

    // --- Hooks ---
    error HookNotFound();
    error HookAlreadyExists();
    error HookInvalidState();
    error HookInvalidParameter();
    error HookInvalidOperation();
    error HookUnauthorized();
    error HookLocked();
    error HookExpired();
    error HookNotActive();
    error HookNotImplemented();
    error HookInvalidAddress(address hook);
    error HookOnlyInitialization();
    error HookOnlyModifyLiquidity();
    error HookOnlySwap();
    error HookOnlyDonate();
    error HookNotSet();

    // --- Token & ETH Transfers ---
    error TokenNotFound();
    error TokenAlreadyExists();
    error TokenInvalidState();
    error TokenInvalidParameter();
    error TokenInvalidOperation();
    error TokenUnauthorized();
    error TokenLocked();
    error TokenExpired();
    error TokenNotActive();
    error TokenNotImplemented();
    error TokenTransferFailed();
    error TokenApprovalFailed();
    error TokenEthNotAccepted();
    error TokenInsufficientEth(uint256 required, uint256 provided);
    error TokenEthTransferFailed(address to, uint256 amount);
    error NonzeroNativeValue();
    error InsufficientETH(uint256 required, uint256 provided);
    error InsufficientContractBalance(uint256 required, uint256 available);
    error ETHTransferFailed(address to, uint256 amount);
    error TransferFailed();
    error TransferFromFailed();
    error InsufficientReserves();

    // --- Oracle ---
    error OracleOperationFailed(string operation, string reason);
    error OracleNotInitialized(PoolId poolId);
    error OracleUpdateFailed(PoolId poolId, string reason);
    error OraclePriceInvalid(uint160 sqrtPriceX96);
    error OracleTickInvalid(int24 tick);
    error OracleCapExceeded(PoolId poolId, int24 tick, int24 maxMove);

    // --- Fee Reinvestment ---
    error FeeExtractionFailed(string reason);
    error InvalidPolPercentage(uint256 provided, uint256 min, uint256 max);
    error PoolSpecificPolPercentageNotAllowed();
    error InvalidFeeDistribution(uint256 polShare, uint256 lpShare, uint256 expected);
    error PoolReinvestmentBlocked(PoolId poolId);
    error CollectionIntervalTooShort(uint256 provided, uint256 minimum);
    error CollectionIntervalTooLong(uint256 provided, uint256 maximum);
    error HookCallbackFailed(string reason);
    error FeesNotAvailable();
    error ExtractionAmountExceedsFees();
    error CacheStale(uint32 lastUpdate, uint32 currentTime, uint32 maxAge);
    error FeeReinvestNotAuthorized(address caller);
    error CannotWithdrawProtocolFees();
    error ReinvestmentAmountTooSmall(uint256 amount0, uint256 amount1);
    error ReinvestmentCooldownNotMet(uint64 lastReinvest, uint64 cooldown);
    error ReinvestmentThresholdNotMet(uint256 balance0, uint256 balance1, uint256 min0, uint256 min1);

    // --- Margin & Vault ---
    error WithdrawalWouldMakeVaultInsolvent();
    error NoDebtToRepay();
    error DepositFailed();
    error InsufficientCollateral(uint256 debt, uint256 collateral, uint256 threshold);
    error PoolUtilizationTooHigh();
    error InsufficientPhysicalShares(uint256 requested, uint256 available);
    error InterestModelNotSet();
    error MarginContractNotSet();
    error RepayAmountExceedsDebt(uint256 sharesToRepay, uint256 currentDebtShares);
    error DepositForRepayFailed();
    error InvalidAsset();
    error MaxPoolUtilizationExceeded(uint256 currentUtilization, uint256 maxUtilization);

    // --- Liquidation ---
    error NotLiquidatable(uint256 currentRatio, uint256 threshold);
    error LiquidationTooSmall(uint256 requestedAmount, uint256 minimumAmount);
    error InvalidLiquidationParams();
}
