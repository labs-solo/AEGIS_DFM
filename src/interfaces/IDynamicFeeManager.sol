// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolPolicyManager} from "./IPoolPolicyManager.sol";
import {TruncGeoOracleMulti} from "../TruncGeoOracleMulti.sol";

/// @title IDynamicFeeManager
/// @notice Interface for a dynamic fee manager that adjusts Uniswap v4 pool fees based on trading activity
/// @dev This contract manages dynamic fee adjustments with surge pricing during high-activity periods.
///      The system works in two phases:
///      1. Base fee calculation from oracle data (tick volatility)
///      2. Surge fee application during capped trading periods with linear decay
///
///      Integration Requirements:
///      - Hook must call initialize() once during pool creation
///      - Hook must call notifyOracleUpdate() on every swap to maintain accurate state
///      - Policy manager must be configured with surge parameters before use
interface IDynamicFeeManager {
    // - - - EVENTS - - -

    /// @notice Emitted when a pool transitions into or out of a capped trading state
    /// @param poolId The pool identifier
    /// @param inCap True if entering capped state, false if exiting
    event CapToggled(PoolId indexed poolId, bool inCap);

    /// @notice Emitted when a pool is successfully initialized for dynamic fee management
    /// @param poolId The pool identifier that was initialized
    event PoolInitialized(PoolId indexed poolId);

    /// @notice Emitted when initialize() is called on an already initialized pool
    /// @dev This is informational and indicates idempotent behavior rather than an error
    /// @param poolId The pool identifier that was already initialized
    event AlreadyInitialized(PoolId indexed poolId);

    /// @notice Emitted when the fee state changes for a pool
    /// @dev The surge fee value reflects the state at emission time and may decay further
    ///      if calculated at a later block timestamp
    /// @param poolId The pool identifier
    /// @param baseFeePpm The new base fee in parts per million (1% = 10,000 PPM)
    /// @param surgeFeePpm The current surge fee in parts per million (0 if no surge active)
    /// @param inCapEvent True if the pool is currently experiencing capped trading
    /// @param timestamp The block timestamp when this state change occurred
    event FeeStateChanged(
        PoolId indexed poolId, uint256 baseFeePpm, uint256 surgeFeePpm, bool inCapEvent, uint40 timestamp
    );

    // - - - EXTERNAL FUNCTIONS - - -

    /// @notice Initializes dynamic fee management for a new pool
    /// @dev Should be called once during pool creation, typically by a factory contract.
    ///      This function is idempotent - calling it multiple times on the same pool
    ///      will emit AlreadyInitialized and return without state changes.
    ///
    ///      Access Control: Only owner or authorized hook
    /// @param poolId The pool identifier to initialize
    /// @param initialTick The current tick at pool creation (used for analytics, not fee calculation)
    function initialize(PoolId poolId, int24 initialTick) external;

    /// @notice Notifies the fee manager of oracle updates and potential tick capping events
    /// @dev This is the core function that must be called on every swap to maintain accurate
    ///      fee state. It handles:
    ///      - Entering capped state when tick movements are restricted
    ///      - Exiting capped state when surge fees decay to zero
    ///      - Emitting appropriate events for state transitions
    ///
    ///      Access Control: Only owner, authorized hook, or oracle contract
    /// @param poolId The pool identifier being updated
    /// @param tickWasCapped True if the tick movement was capped during this swap
    function notifyOracleUpdate(PoolId poolId, bool tickWasCapped) external;

    // - - - VIEW FUNCTIONS - Configuration - - -

    /// @notice Returns the policy manager contract that provides surge fee parameters
    /// @return The policy manager contract interface
    function policyManager() external view returns (IPoolPolicyManager);

    /// @notice Returns the oracle contract that provides tick volatility data
    /// @return The truncated geometric oracle contract interface
    function oracle() external view returns (TruncGeoOracleMulti);

    /// @notice Returns the hook contract authorized to call state-changing functions
    /// @return The address of the authorized hook contract
    function authorizedHook() external view returns (address);

    // - - - VIEW FUNCTIONS - Fee State - - -

    /// @notice Gets the current fee state for a pool
    /// @dev The base fee is calculated from current oracle data (tick volatility).
    ///      The surge fee is calculated with linear decay from the cap start time.
    ///      Total effective fee = baseFee + surgeFee
    /// @param poolId The pool identifier to query
    /// @return baseFee The current base fee in parts per million
    /// @return surgeFee The current surge fee in parts per million (0 if no active surge)
    function getFeeState(PoolId poolId) external view returns (uint256 baseFee, uint256 surgeFee);

    /// @notice Checks if a pool is currently in a capped trading state
    /// @dev A pool enters capped state when tick movements are restricted due to high volatility.
    ///      While capped, surge fees are applied with linear decay over time.
    /// @param poolId The pool identifier to query
    /// @return True if the pool is currently experiencing capped trading conditions
    function isCAPEventActive(PoolId poolId) external view returns (bool);
}
