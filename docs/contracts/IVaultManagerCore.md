> v1.2.1-rc3

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PoolId}  from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/*//////////////////////////////////////////////////////////////////////////
                                 TYPE ALIASES
//////////////////////////////////////////////////////////////////////////*/

/// @notice Vault share type returned by {deposit} and consumed by {withdraw}.
type LPShare is uint128;

/*//////////////////////////////////////////////////////////////////////////
                                    INTERFACE
//////////////////////////////////////////////////////////////////////////*/

/// @title IVaultManagerCore
/// @notice Canonical surface for the AEGIS V2 unified vault (Phases 1 → 7 + Batch)
/// @custom:version 1.2.1-rc3
interface IVaultManagerCore {
    /*==============================  EVENTS  ==============================*/

    /// @phase1 Emitted when assets enter the vault.
    event Deposit(address indexed caller, address indexed asset, uint256 amount, address indexed recipient);

    /// @phase1 Emitted when assets leave the vault.
    event Withdraw(address indexed caller, address indexed asset, uint256 amount, address indexed recipient);

    /// @phase1 Pool registered with the vault.
    event PoolRegistered(address indexed caller, PoolId indexed poolId, PoolKey poolKey);

    /// @phase2 Set whether auto‑reinvest is enabled for a pool.
    event ReinvestToggled(PoolId indexed poolId, bool enabled);

    /// @phase2 Contract or subsystem paused.
    event Paused(address indexed caller, uint8 flags);

    /// @phase2 Contract or subsystem un‑paused.
    event Unpaused(address indexed caller, uint8 flags);

    /// @phase3 Debt created.
    event Borrow(address indexed borrower, PoolId indexed poolId, uint256 amount);

    /// @phase3 Debt repaid.
    event Repay(address indexed payer, PoolId indexed poolId, uint256 amount);

    /// @phase3 Interest accrued.
    event InterestAccrued(PoolId indexed poolId, uint256 interest);

    /// @phase4 LP position opened.
    event LPPositionOpened(
        address indexed owner,
        uint256 indexed positionId,
        PoolKey poolKey,
        int24 lowerTick,
        int24 upperTick,
        uint128 liquidity
    );

    /// @phase4 LP position closed.
    event LPPositionClosed(address indexed owner, uint256 indexed positionId, uint128 liquidity);

    /// @phase4 Fees collected from Uniswap V4 position.
    event LPFeesCollected(address indexed owner, uint256 indexed positionId, uint256 amount0, uint256 amount1);

    /// @phase5 New on‑chain limit order.
    event LimitOrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        PoolKey poolKey,
        bool isBuy,
        uint128 amount,
        uint256 price,
        uint64 expiry
    );

    /// @phase5 Limit order cancelled by maker or governance.
    event LimitOrderCancelled(uint256 indexed orderId);

    /// @phase5 Limit order (partially) executed by keeper.
    event LimitOrderExecuted(uint256 indexed orderId, uint128 fillAmount, uint256 fillPrice);

    /// @phase6 Position liquidated.
    event Liquidation(
        address indexed liquidator,
        address indexed borrower,
        PoolId indexed poolId,
        uint256 repaidDebt,
        uint256 seizedCollateral
    );

    /// @phase6 Insurance fund deposited or withdrawn.
    event InsuranceFundUpdated(address indexed caller, int256 delta);

    /// @phase7 Vault‑wide metrics snapshot.
    event VaultMetrics(uint256 totalAssets, uint256 totalLiabilities, uint256 totalCollateral);

    /// @phase7 Bad debt covered using insurance/POL.
    event BadDebtCovered(PoolId indexed poolId, uint256 amount);

    /// @batch All‑in‑one batch executed.
    event BatchExecuted(address indexed caller, uint256 actions, bool allSucceeded);

    /*==============================  ERRORS  ==============================*/

    /// @notice Caller lacks the required role/authority.
    error UnauthorizedCaller();

    /// @notice Call rejected because the contract or target module is paused.
    error ContractPaused(uint8 flags);

    /// @notice Action not supported for the supplied parameters.
    error UnsupportedAction();

    /// @phase3 Occurs when attempting to borrow beyond collateral limits.
    error InsufficientCollateral();

    /// @phase3 Returned by {repay} when no debt exists.
    error NoDebt();

    /// @phase5 Limit‑order not found.
    error OrderNotFound(uint256 orderId);

    /// @phase5 Cannot execute order after expiry.
    error OrderExpired(uint256 orderId);

    /// @phase6 Liquidation not allowed (healthy position).
    error LiquidationNotAllowed();

    /*===========================  STRUCTS / ENUMS  ========================*/

    /// @phase5 Off‑chain friendly definition of a limit order.
    struct LimitOrder {
        uint256  id;
        address  maker;
        PoolKey  poolKey;
        bool     isBuy;
        uint128  amount;
        uint256  price;
        uint64   expiry;
    }

    /*========================  CORE MUTATIVE FUNCTIONS  ===================*/

    /// @phase1 Deposit ERC‑20 assets into the vault in exchange for shares.
    /// @return shares Minted vault shares.
    function deposit(address asset, uint256 amount, address recipient) external returns (uint256 shares);

    /// @notice Deposit assets for another user without triggering interest/oracle updates when caller has no debt.
    function depositFor(address asset, uint256 amt, address onBehalf) external returns (uint256 shares);

    /// @phase1 Withdraw ERC‑20 assets by redeeming vault shares.
    /// @return amount Amount of underlying assets returned.
    function withdraw(address asset, uint256 shares, address recipient) external returns (uint256 amount);

    /// @notice Redeem shares to a recipient. Skips oracle and interest logic when caller has no debt.
    function redeemTo(address asset, uint256 shares, address to) external returns (uint256 amount);

    /// @phase1 Register a supported Uniswap V4 pool.
    function registerPool(PoolKey calldata poolKey) external returns (PoolId poolId);

    /// @phase2 Toggle auto‑reinvestment of protocol fees for a specific pool.
    function toggleReinvest(PoolId poolId, bool enabled) external;

    /// @phase2 Pause one or more functional areas (bitmask).
    function pause(uint8 flags) external;

    /// @phase2 Resume one or more functional areas (bitmask).
    function unpause(uint8 flags) external;

    /// @phase3 Borrow assets against on‑chain collateral.
    function borrow(PoolId poolId, uint256 amount, address recipient) external;

    /// @phase3 Repay outstanding debt.
    /// @return remaining Debt remaining after repayment.
    function repay(PoolId poolId, uint256 amount, address onBehalfOf) external returns (uint256 remaining);

    /// @phase3 Accrue linear/compound interest on a given pool’s debt.
    function accrueInterest(PoolId poolId) external;

    /// @phase3 Governance hook to update pool‑level interest‑rate model.
    function setInterestRateModel(PoolId poolId, address irm) external;

    /// @phase4 Mint a concentrated‑liquidity position.
    /// @return positionId Identifier of the newly created position.
    function openLPPosition(
        PoolKey calldata poolKey,
        int24 lowerTick,
        int24 upperTick,
        uint128 liquidity,
        address recipient
    ) external returns (uint256 positionId);

    /// @phase4 Burn an existing concentrated‑liquidity position.
    function closeLPPosition(uint256 positionId, address recipient) external;

    /// @phase4 Collect accrued AMM fees for a position.
    function collectLPFees(uint256 positionId, address recipient)
        external
        returns (uint256 amount0, uint256 amount1);

    /// @phase5 Create a new on‑chain limit order.
    /// @return orderId Identifier of the created order.
    function placeLimitOrder(
        PoolKey calldata poolKey,
        bool isBuy,
        uint128 amount,
        uint256 price,
        uint64 expiry,
        address recipient
    ) external returns (uint256 orderId);

    /// @phase5 Cancel an active limit order.
    function cancelLimitOrder(uint256 orderId) external;

    /// @phase5 Execute (part of) an existing limit order.
    function executeLimitOrder(uint256 orderId, uint128 fillAmount) external;

    /// @phase6 Liquidate an under‑collateralised borrower.
    /// @return seizedCollateral Amount of collateral transferred to liquidator.
    function liquidate(
        address borrower,
        PoolId poolId,
        uint256 debtToCover,
        address recipient
    ) external returns (uint256 seizedCollateral);

    /// @phase6 Deposit or withdraw from the insurance/POL fund. Positive `delta` deposits, negative withdraws.
    function updateInsuranceFund(int256 delta, address recipient) external;

    /// @phase7 Cover bad debt for a specific pool using the insurance fund.
    function coverBadDebt(PoolId poolId, uint256 amount) external;

    /// @batch Execute a bundle of encoded vault actions **atomically**.
    /// @dev MUST revert if any sub‑call fails (`allSucceeded == false`).
    /// @deprecated Use {executeBatchTyped} instead.
    function executeBatch(bytes[] calldata actions) external returns (bytes[] memory results);

    function executeBatchTyped(Action[] calldata actions) external returns (bytes[] memory results);

    /*===========================  VIEW‑ONLY HELPERS  ======================*/

    /// @phase4 Return full metadata for an LP position.
    function getLPPosition(uint256 positionId)
        external
        view
        returns (
            address owner,
            PoolKey poolKey,
            int24 lowerTick,
            int24 upperTick,
            uint128 liquidity
        );

    /// @phase5 Return limit‑order details.
    function getLimitOrder(uint256 orderId) external view returns (LimitOrder memory order);

    /// @phase7 Vault‑wide pause state.
    function isPausedAll() external view returns (bool);

    /// @phase7 Aggregate vault metrics (TVL, debt, collateral).
    function vaultMetrics()
        external
        view
        returns (
            uint256 totalAssets,
            uint256 totalLiabilities,
            uint256 totalCollateral
        );

    /*=====================  OWNER / GOVERNANCE FUNCTIONS  =================*/

    /// @phase7 Update delay before queued governance actions may be executed.
    function setGovernanceTimelock(uint256 newDelay) external;

    /// @phase7 Appoint a new pause guardian.
    function setPauseGuardian(address newGuardian) external;
}
```
