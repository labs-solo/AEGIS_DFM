// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { Currency } from "v4-core/src/types/Currency.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { PoolId } from "v4-core/src/types/PoolId.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { SafeCast } from "v4-core/src/libraries/SafeCast.sol";
import { FullMath } from "v4-core/src/libraries/FullMath.sol"; // Might be needed later
import { IMarginData } from "./IMarginData.sol";
import { IInterestRateModel } from "./IInterestRateModel.sol";
import { IPoolPolicy } from "./IPoolPolicy.sol";
import { Errors } from "../errors/Errors.sol";

/**
 * @title Margin Manager Interface
 * @notice Defines the external functions for managing margin accounts,
 *         interest accrual, and core protocol parameters.
 */
interface IMarginManager {
    // --- Events ---
    event DepositCollateralProcessed(PoolId indexed poolId, address indexed user, address asset, uint256 amount);
    event WithdrawCollateralProcessed(PoolId indexed poolId, address indexed user, address indexed recipient, address asset, uint256 amount);
    event BorrowProcessed(PoolId indexed poolId, address indexed user, address indexed recipient, uint256 sharesBorrowed, uint256 amount0Received, uint256 amount1Received);
    event RepayProcessed(PoolId indexed poolId, address indexed user, uint256 sharesRepaid, uint256 amount0Used, uint256 amount1Used);
    event InterestAccrued(PoolId indexed poolId, uint64 timestamp, uint256 timeElapsed, uint256 interestRatePerSecond, uint256 newInterestMultiplier);
    event ProtocolFeesAccrued(PoolId indexed poolId, uint256 feeSharesDelta);
    event SolvencyThresholdLiquidationSet(uint256 oldThreshold, uint256 newThreshold);
    event LiquidationFeeSet(uint256 oldFee, uint256 newFee);
    event InterestRateModelSet(address oldModel, address newModel);
    event PoolInterestInitialized(PoolId indexed poolId, uint256 initialMultiplier, uint64 timestamp);

    // --- Constants and State Variables (as external views) ---
    function PRECISION() external view returns (uint256);
    function vaults(PoolId poolId, address user) external view returns (IMarginData.Vault memory);
    function rentedLiquidity(PoolId poolId) external view returns (uint256);
    function interestMultiplier(PoolId poolId) external view returns (uint256);
    function lastInterestAccrualTime(PoolId poolId) external view returns (uint64);
    function marginContract() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function liquidityManager() external view returns (address);
    function solvencyThresholdLiquidation() external view returns (uint256);
    function liquidationFee() external view returns (uint256);
    function accumulatedFees(PoolId poolId) external view returns (uint256);
    function governance() external view returns (address);
    function interestRateModel() external view returns (IInterestRateModel);
    function hasVault(PoolId poolId, address user) external view returns (bool);

    // --- State Modifying Functions ---
    function executeBatch(address user, PoolId poolId, PoolKey calldata key, IMarginData.BatchAction[] calldata actions) external;
    function accruePoolInterest(PoolId poolId) external;
    function initializePoolInterest(PoolId poolId) external;

    // --- Governance Functions ---
    function setSolvencyThresholdLiquidation(uint256 _threshold) external;
    function setLiquidationFee(uint256 _fee) external;
    function setInterestRateModel(address _model) external;
    
    // --- Phase 4 Interest Fee Functions ---
    function getPendingProtocolInterestTokens(PoolId poolId) external view returns (uint256 amount0, uint256 amount1);
    function reinvestProtocolFees(PoolId poolId, uint256 amount0ToWithdraw, uint256 amount1ToWithdraw, address recipient) external returns (bool success);
    function resetAccumulatedFees(PoolId poolId) external returns (uint256 processedShares);
}