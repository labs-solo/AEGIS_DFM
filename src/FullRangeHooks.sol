// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title FullRangeHooks
 * @notice Encapsulates callback logic for deposits and withdrawals in a Uniswap V4 environment.
 *         Verifies salt, identifies deposit vs. withdrawal by sign of liquidityDelta.
 *
 * Phase 4 Requirements:
 *  • Salt check => must match keccak256("FullRangeHook")
 *  • Distinguish deposit vs. withdrawal => liquidityDelta > 0 vs. < 0
 *  • Achieve 90%+ coverage in FullRangeHooksTest.
 */

import {ISpot, CallbackData, ModifyLiquidityParams} from "./interfaces/ISpot.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Errors} from "./errors/Errors.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/**
 * @dev Minimal contract handling the callback data. 
 *      We assume an external caller (like FullRange or a manager) calls handleCallback(...)
 *      to finalize or check the deposit/withdraw operation.
 */
contract FullRangeHooks {
    /// @dev salt constant for verifying callback
    bytes32 public constant FULL_RANGE_SALT = keccak256("FullRangeHook");

    /// @dev Events for enhanced visibility of callback operations
    event DepositCallbackProcessed(address sender, int256 liquidityDelta);
    event WithdrawCallbackProcessed(address sender, int256 liquidityDelta);

    /**
     * @notice Decodes callback data, verifies salt, identifies deposit/withdraw
     * @param data The abi-encoded CallbackData
     * @return result The serialized BalanceDelta or other final data
     */
    function handleCallback(bytes calldata data) external returns (bytes memory result) {
        // 1. decode
        CallbackData memory cd = abi.decode(data, (CallbackData));

        // 2. check salt
        if (cd.params.salt != FULL_RANGE_SALT) {
            revert Errors.ValidationInvalidInput("InvalidCallbackSalt");
        }

        // 3. deposit vs. withdrawal identification
        if (cd.params.liquidityDelta > 0) {
            // deposit finalize or additional logic
            emit DepositCallbackProcessed(cd.sender, cd.params.liquidityDelta);
            // For demonstration, we simply return a "deposit" label in result
            return abi.encode(BalanceDelta.wrap(0), "depositCallback");
        } else if (cd.params.liquidityDelta < 0) {
            // withdrawal finalize or additional logic
            emit WithdrawCallbackProcessed(cd.sender, cd.params.liquidityDelta);
            return abi.encode(BalanceDelta.wrap(0), "withdrawCallback");
        } else {
            // zero liquidityDelta => no-op or revert, up to design
            revert Errors.ValidationZeroAmount("liquidityDelta");
        }
    }
} 