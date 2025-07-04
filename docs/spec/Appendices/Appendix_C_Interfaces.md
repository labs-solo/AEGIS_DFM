# Appendix — Header‑Only Solidity Interfaces
> v1.1.0 – Typed batching & lean wrappers

## `IVaultManagerCore.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PoolId}  from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @title  IVaultManagerCore
/// @notice Canonical external surface for the AEGIS V2 unified vault.
/// @custom:version 1.1.0
interface IVaultManagerCore {
    /*───────────────────────────  EVENTS  ───────────────────────────*/

    event Deposit(address indexed caller, address indexed asset, uint256 amount, address indexed recipient);
    event Withdraw(address indexed caller, address indexed asset, uint256 amount, address indexed recipient);
    event PoolRegistered(address indexed caller, PoolId indexed poolId, PoolKey poolKey);
    event ReinvestToggled(PoolId indexed poolId, bool enabled);
    event Paused(address indexed caller, uint8 flags);
    event Unpaused(address indexed caller, uint8 flags);
    event Borrow(address indexed borrower, PoolId indexed poolId, uint256 amount);
    event Repay(address indexed payer, PoolId indexed poolId, uint256 amount);
    event InterestAccrued(PoolId indexed poolId, uint256 interest);
    event LPPositionOpened(
        address indexed owner,
        uint256 indexed positionId,
        PoolKey poolKey,
        int24 lowerTick,
        int24 upperTick,
        uint128 liquidity
    );
    event LPPositionClosed(address indexed owner, uint256 indexed positionId, uint128 liquidity);
    event LPFeesCollected(address indexed owner, uint256 indexed positionId, uint256 amount0, uint256 amount1);
    event LimitOrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        PoolKey poolKey,
        bool isBuy,
        uint128 amount,
        uint256 price,
        uint64 expiry
    );
    event LimitOrderCancelled(uint256 indexed orderId);
    event LimitOrderExecuted(uint256 indexed orderId, uint128 fillAmount, uint256 fillPrice);
    event Liquidation(
        address indexed liquidator,
        address indexed borrower,
        PoolId indexed poolId,
        uint256 repaidDebt,
        uint256 seizedCollateral
    );
    event InsuranceFundUpdated(address indexed caller, int256 delta);
    event VaultMetrics(uint256 totalAssets, uint256 totalLiabilities, uint256 totalCollateral);
    event BadDebtCovered(PoolId indexed poolId, uint256 amount);
    event BatchExecuted(address indexed caller, uint256 actions, bool allSucceeded);
    event UserVaultDeposit(PoolId indexed poolId, address indexed user, uint256 amount0, uint256 amount1);
    event UserVaultWithdraw(PoolId indexed poolId, address indexed user, address indexed to, uint256 amount0, uint256 amount1);
    event FeesReinvested(PoolId indexed poolId, uint256 amount0, uint256 amount1, uint256 sharesMinted);

    /*───────────────────────────  ERRORS  ───────────────────────────*/

    error UnauthorizedCaller();
    error ContractPaused(uint8 flags);
    error UnsupportedAction();
    error InsufficientCollateral();
    error NoDebt();
    error OrderNotFound(uint256 orderId);
    error OrderExpired(uint256 orderId);
    error LiquidationNotAllowed();

    /*──────────────────────────  STRUCTS  ───────────────────────────*/

    struct LimitOrder {
        uint256  id;
        address  maker;
        PoolKey  poolKey;
        bool     isBuy;
        uint128  amount;
        uint256  price;
        uint64   expiry;
    }

    /*──────────  CORE MUTATIVE FUNCTIONS  ─────────*/

    function deposit(address asset, uint256 amount, address recipient) external returns (uint256 shares);
    /// @notice Deposit on behalf of another user. Skips interest/oracle logic if caller has no debt.
    function depositFor(address asset, uint256 amt, address onBehalf) external returns (uint256 shares);
    function withdraw(address asset, uint256 shares, address recipient) external returns (uint256 amount);
    /// @notice Redeem shares to a recipient. Skips interest/oracle logic if caller has no debt.
    function redeemTo(address asset, uint256 shares, address to) external returns (uint256 amount);

    function registerPool(PoolKey calldata poolKey) external returns (PoolId poolId);

    function toggleReinvest(PoolId poolId, bool enabled) external;
    function pause(uint8 flags) external;
    function unpause(uint8 flags) external;

    function borrow(PoolId poolId, uint256 amount, address recipient) external;
    function repay(PoolId poolId, uint256 amount, address onBehalfOf) external returns (uint256 remaining);
    function accrueInterest(PoolId poolId) external;
    function setInterestRateModel(PoolId poolId, address model) external;

    function openLPPosition(
        PoolKey calldata poolKey,
        int24 lowerTick,
        int24 upperTick,
        uint128 liquidity,
        address recipient
    ) external returns (uint256 positionId);
    function closeLPPosition(uint256 positionId, address recipient) external;
    function collectLPFees(uint256 positionId, address recipient) external returns (uint256 amount0, uint256 amount1);

    function placeLimitOrder(
        PoolKey calldata poolKey,
        bool isBuy,
        uint128 amount,
        uint256 price,
        uint64 expiry,
        address recipient
    ) external returns (uint256 orderId);
    function cancelLimitOrder(uint256 orderId) external;
    function executeLimitOrder(uint256 orderId, uint128 fillAmount) external;

    function liquidate(
        address borrower,
        PoolId poolId,
        uint256 debtToCover,
        address recipient
    ) external returns (uint256 seizedCollateral);
    function updateInsuranceFund(int256 delta, address recipient) external;
    function coverBadDebt(PoolId poolId, uint256 amount) external;

    /// @deprecated Use {executeBatchTyped} instead.
    function executeBatch(bytes[] calldata actions) external returns (bytes[] memory results);
    function executeBatchTyped(Action[] calldata actions) external returns (bytes[] memory results);

    function depositToVault(PoolId poolId, uint256 amount0, uint256 amount1) external;
    function withdrawFromVault(PoolId poolId, uint256 amount0, uint256 amount1, address recipient) external;

    /*──────────  VIEW FUNCTIONS  ─────────*/

    function getLPPosition(uint256 positionId) external view returns (
        address owner,
        PoolKey poolKey,
        int24 lowerTick,
        int24 upperTick,
        uint128 liquidity
    );
    function getLimitOrder(uint256 orderId) external view returns (LimitOrder memory order);
    function isPausedAll() external view returns (bool);
    function vaultMetrics() external view returns (
        uint256 totalAssets,
        uint256 totalLiabilities,
        uint256 totalCollateral
    );

    /*──────────  GOVERNANCE  ─────────*/

    function setGovernanceTimelock(uint256 newDelay) external;
    function setPauseGuardian(address newGuardian) external;
}
```

---

### `IPoolPolicyManager.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PoolId} from "v4-core/src/types/PoolId.sol";

interface IPoolPolicyManager {
    /*──── Collateral‑type constants ────*/
    uint8 constant POSITION_TYPE_FULL_RANGE_SHARE = 0;
    uint8 constant POSITION_TYPE_TOKEN0_CLAIM     = 1;
    uint8 constant POSITION_TYPE_TOKEN1_CLAIM     = 2;
    uint8 constant POSITION_TYPE_CUSTOM_LP        = 3;

    /*──── Fee‑treasury settings ────*/
    function treasury() external view returns (address);
    function setTreasury(address newTreasury) external;

    /*──── Collateral factors ────*/
    function getCollateralFactors(PoolId poolId, uint8 positionType)
        external view returns (uint16 initFactorBps, uint16 maintFactorBps);

    function setCollateralFactors(
        PoolId poolId,
        uint8 positionType,
        uint16 initFactorBps,
        uint16 maintFactorBps
    ) external;

    function getDefaultCollateralFactors(uint8 positionType)
        external view returns (uint16 initFactorBps, uint16 maintFactorBps);

    function setDefaultCollateralFactors(
        uint8 positionType,
        uint16 initFactorBps,
        uint16 maintFactorBps
    ) external;

    /*──── Events ────*/
    event CollateralFactorUpdated(
        PoolId indexed poolId,
        uint8 positionType,
        uint16 initFactorBps,
        uint16 maintFactorBps
    );
}
```

---

### `IInterestRateModel.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PoolId} from "v4-core/src/types/PoolId.sol";

interface IInterestRateModel {
    function ratePerSecond(PoolId poolId) external view returns (uint256);
    function getParameters() external view returns (
        uint256 baseRate,
        uint256 multiplier,
        uint256 jumpMultiplier,
        uint256 kink
    );
}
```

---

### `IGovernanceTimelock.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IGovernanceTimelock {
    /*──── Events ────*/
    event ChangeQueued(bytes32 indexed id, bytes32 indexed param, uint256 value, uint256 eta);
    event ChangeExecuted(bytes32 indexed id);
    event ChangeCanceled(bytes32 indexed id);

    /*──── Errors ────*/
    error TimelockNotElapsed(bytes32 id);
    error DuplicateChangeId(bytes32 id);

    /*──── Actions ────*/
    function queueChange(bytes32 id, address target, bytes calldata data, bytes32 param, uint256 value) external;
    function executeChange(bytes32 id) external;
    function cancelChange(bytes32 id) external;

    /*──── Views ────*/
    function minDelay() external view returns (uint256);
    function getEta(bytes32 id) external view returns (uint256);
    function isQueued(bytes32 id) external view returns (bool);
}
```

---

### `IVaultMetricsLens.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IVaultMetricsLens {
    function getVaultHealth(address account) external view
        returns (uint256 collateralUSD, uint256 debtUSD, uint16 healthFactorBps);

    function getPoolUtilisation(bytes32 poolId) external view returns (uint16 utilisationBps);

    function getPOLSummary(bytes32 poolId) external view
        returns (uint256 polShares, uint16 polSharePctBps, uint256 polValueUSD);
}
```
