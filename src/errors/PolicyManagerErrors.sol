// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

/**
 * @title Errors
 * @notice Custom errors used throughout the Spot system
 */
library PolicyManagerErrors {
    // === General errors ===
    error ZeroAddress();
    error UnauthorizedCaller(address caller);
    error ETHRefundFailed();
    error ParameterOutOfRange(uint256 value, uint256 min, uint256 max);
    error AllocationSumError(uint256 pol, uint256 fullRange, uint256 lp, uint256 expected);
    error InvalidFeeRange(uint24 value, uint24 min, uint24 max);

    // === Pool-specific errors ===
    error PoolNotFound(PoolId poolId);
    error PositionNotFound(PoolId poolId);
    error PoolPositionManagerMismatch();
    error InvalidHookAuthorization(address expected, address actual);

    // === Liquidity operations errors ===
    error TooLittleAmount0(uint256 minimum, uint256 actual);
    error TooLittleAmount1(uint256 minimum, uint256 actual);
    error InsufficientETH(uint256 required, uint256 provided);
    error InvalidPrice(uint160 price);
    error InvalidSwapDelta();

    // === Manual fee errors ===
    error ManualFeeNotSet(PoolId poolId);
    error ManualFeeAlreadySet(PoolId poolId);
}
