// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/**
 * @title Errors
 * @notice Collection of all custom errors used in the protocol
 */
library Errors {
    // Access control errors
    error AccessDenied();
    error AccessOnlyGovernance(address caller);
    error AccessOnlyPoolManager(address caller);
    error AccessNotAuthorized(address caller);
    error AccessOnlyEmergencyAdmin(address caller);
    error Unauthorized();
    
    // Validation and input errors
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
    error ReinvestmentDisabled();
    error RateLimited();
    error InvalidPoolKey();
    error InvalidPoolId();
    
    // Math errors
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
    error InvalidTick();
    error InvalidRange();
    error InvalidSlippage();
    error InvalidLiquidity();
    error InvalidInput();
    error AmountTooLarge(uint256 amount, uint256 maximum);
    error SlippageExceeded(uint256 required, uint256 actual);
    
    // System errors
    error ZeroAddress();
    error ZeroAmount();
    error ZeroLiquidity();
    error ZeroShares();
    error ZeroPolicyManagerAddress();
    error ZeroPoolManagerAddress();
    error ZeroFullRangeAddress();
    error HookDispatchFailed(bytes4 selector);
    error DelegateCallFailed();
    error EthTransferFailed(address to, uint256 amount);
    error NotImplemented();
    error ContractPaused();
    
    // Pool errors
    error PoolNotInitialized(PoolId poolId);
    error PoolAlreadyInitialized(PoolId poolId);
    error PoolNotFound(PoolId poolId);
    error PoolPaused(PoolId poolId);
    error PoolLocked(PoolId poolId);
    error PoolInvalidState(PoolId poolId);
    error PoolInvalidOperation(PoolId poolId);
    error PoolInvalidParameter(PoolId poolId);
    error PoolUnsupportedFee(uint24 fee);
    error PoolUnsupportedTickSpacing(int24 tickSpacing);
    error PoolInvalidFeeOrTickSpacing(uint24 fee, int24 tickSpacing);
    error PoolTickOutOfRange(int24 tick, int24 minTick, int24 maxTick);
    error PoolInEmergencyState(PoolId poolId);
    error OnlyDynamicFeePoolAllowed();
    
    // Liquidity errors
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
    
    // Policy errors
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
    
    // Hook errors
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
    
    // Token errors
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
    
    // Native ETH errors
    error NonzeroNativeValue();
    error InsufficientETH(uint256 required, uint256 provided);
    error InsufficientContractBalance(uint256 required, uint256 available);
    error ETHTransferFailed(address to, uint256 amount);

    // Oracle errors
    error OracleOperationFailed(string operation, string reason);

    // Fee Reinvestment Manager Errors
    error FeeExtractionFailed(string reason);
    error InvalidPolPercentage(uint256 provided, uint256 min, uint256 max);
    error PoolSpecificPolPercentageNotAllowed();
    error InvalidFeeDistribution(uint256 polShare, uint256 lpShare, uint256 expected);
    error PoolReinvestmentBlocked(PoolId poolId);
    error CollectionIntervalTooShort(uint256 provided, uint256 minimum);
    error CollectionIntervalTooLong(uint256 provided, uint256 maximum);
    error CalculationError(string reason);
    error HookCallbackFailed(string reason);
    error FeesNotAvailable();

    /// @notice Error thrown when the extraction amount exceeds the fee amount
    error ExtractionAmountExceedsFees();
    
    /// @notice Error thrown when the cache is stale
    error CacheStale(uint32 lastUpdate, uint32 currentTime, uint32 maxAge);

    /// @notice Error thrown when direct pool data reading fails
    error FailedToReadPoolData(PoolId poolId);

    error AlreadyInitialized(string component);
} 