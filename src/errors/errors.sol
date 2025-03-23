// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/**
 * @title Errors
 * @notice Defines custom error types for the FullRange system to save gas on revert messages.
 * @dev Each error is declared with an identifier and parameter types (if any). Using revert with custom errors is cheaper than revert with string messages.
 */
library Errors {
    // Access control errors
    error AccessNotAuthorized(address caller);
    error AccessOnlyEmergencyAdmin(address caller);
    error AccessOnlyOwner(address caller);
    error AccessOnlyGovernance(address caller);
    error AccessOnlyPoolManager(address caller);
    error Unauthorized();
    
    // Validation and input errors
    error ValidationDeadlinePassed(uint32 deadline, uint32 timestamp);
    error ValidationZeroAddress(string target);
    error ValidationInvalidInput(string reason);
    error ValidationZeroAmount(string parameter);
    error ZeroAddress();
    error ParameterOutOfRange(uint256 value, uint256 min, uint256 max);
    error DeadlinePassed(uint256 deadline, uint256 timestamp);
    error ZeroAmount();
    error Reentrancy();
    error NotImplemented();
    error InvalidInput();
    error ArrayLengthMismatch();
    error InvalidCallbackSalt();
    error InvalidPolicyImplementationsLength(uint256 length);
    error NotInitialized();
    error ReinvestmentDisabled();
    
    // Math errors
    error DivisionByZero();
    error Overflow(uint256 value, uint256 max);
    error Underflow(uint256 value, uint256 min);
    error NegativeValue(int256 value);
    error IntegerConversionError(uint256 value, uint256 maxAllowed);
    error AmountTooLarge(uint256 provided, uint256 maximum);
    error AmountTooSmall(uint256 provided, uint256 minimum);
    error LiquidityCalculationFailed();
    error PriceCalculationFailed(int24 tick, uint160 sqrtPriceX96);
    error FeeCalculationFailed();
    
    // Hook-specific errors
    error HookInvalidAddress(address hook);
    error HookNotAuthorizedToCreatePool(address sender);
    error HookCallFailed();
    error AddressMismatch(address provided, address expected);
    error NotCalledByPoolManager(address caller);
    error InvalidHookAddress(address hook);
    error NotAuthorizedToCreatePool(address caller);
    error HookInitializationFailed(address hook);
    error ZeroPolicyManagerAddress();
    error ZeroPoolManagerAddress();
    error ZeroFullRangeAddress();
    
    // Pool errors
    error PoolNotInitialized(PoolId poolId);
    error PoolAlreadyExists(PoolId poolId);
    error PoolInvalidParameters(PoolId poolId);
    error TickOutOfRange(int24 tick, int24 minTick, int24 maxTick);
    error UnsupportedTickSpacing(int24 spacing);
    error InvalidFeeOrTickSpacing(uint24 fee, int24 spacing);
    error PoolUnauthorized(PoolId poolId);
    error PoolOperationFailed(PoolId poolId);
    error FeeNotDynamic(uint24 fee);
    error PoolUnsupportedTickSpacing(int24 tickSpacing);
    error PoolInvalidFeeOrTickSpacing(uint24 fee, int24 tickSpacing);
    error PoolTickOutOfRange(int24 tick, int24 minTick, int24 maxTick);
    error PoolInEmergencyState(PoolId poolId);
    error PoolNotFound(PoolId poolId);
    
    // Liquidity errors
    error InsufficientAmount(uint256 requested, uint256 available);
    error SlippageExceeded(uint256 expected, uint256 actual);
    error ZeroShares(address owner);
    error NoTokensToWithdraw();
    error SharesTransferFailed(address from, address to, uint256 amount);
    error InsufficientShares(uint256 requested, uint256 available);
    error InvalidDepositAmounts(uint256 token0Amount, uint256 token1Amount);
    error ExceedsMaxReserve(uint256 requested, uint256 maximum);
    error FeeClaimFailed();
    
    // Fee errors
    error AllocationInvalid(uint256 total);
    error ReinvestmentFailed(PoolId poolId);
    error NotDynamicFee(uint24 fee);
    error OnlyDynamicFee(uint24 fee);
    error FeeOutOfRange(uint24 provided, uint24 minimum, uint24 maximum);
    error InvalidAdjustmentParameters(uint256 increasePct, uint256 decreasePct);
    error AdjustmentFailed(uint8 adjustmentType, int256 deviation);
    error AllocationSumError(uint256 polShare, uint256 fullRangeShare, uint256 lpShare, uint256 total);
    
    // Oracle errors
    error CardinalityCannotBeZero();
    error TargetPredatesOldestObservation(uint32 oldestTimestamp, uint32 targetTimestamp);
    error PositionsMustBeFullRange();
    error OnlyDynamicFeePoolAllowed();
    error InvalidObservation(uint16 index);
    error OracleInitializationFailed();
    error OracleOperationFailed(string operation, string reason);
    
    // Policy errors
    error PolicyNotApproved(address implementation);
    error PolicyFrozen(PoolId poolId);
    error InvalidImplementation(address implementation);
    error ChangeNotQueued(bytes32 changeId);
    error TimelockNotExpired(uint256 timestamp, uint256 required);
    error PoolAlreadyInitialized(PoolId poolId);
    error InterfaceNotSupported(bytes4 interfaceId);
    error InvalidTimelockDelay(uint256 provided, uint256 minimum, uint256 maximum);
    
    // Token and ETH transfer errors
    error TransferFailed(address token, address from, address to, uint256 amount);
    error InsufficientBalance(address token, address account, uint256 required, uint256 available);
    error InsufficientAllowance(address token, address owner, address spender, uint256 required, uint256 available);
    error EthTransferFailed(address recipient, uint256 amount);
    error EthNotAccepted();
    error InsufficientEth(uint256 required, uint256 available);
    error ApprovalFailed(address token, address owner, address spender, uint256 amount);
    error TokenOperationFailed(address token);
    error TokenEthNotAccepted();
    error TokenInsufficientEth(uint256 required, uint256 provided);
    error TokenEthTransferFailed(address to, uint256 amount);
} 