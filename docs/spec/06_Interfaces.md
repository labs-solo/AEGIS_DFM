# 6 External Interfaces & ABIs

> v1.2.1-rc3

## 6.1 Design Principles

| Goal                         | Approach                                                                                                                                                                                                  |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Stability**                | All ABIs are **append‑only**. Every function, event, and error published since the first public release is still present with the same 4‑byte selector.                                                   |
| **Forward‑compatibility**    | New behaviour must appear as _additional_ signatures or in new interfaces. Existing selectors and storage layouts are never modified or removed.                                                          |
| **Gas efficiency & clarity** | • Solidity 0.8.24, custom errors, 32‑byte selectors.<br>• Only the minimal set of public/external functions is exposed.<br>• No external dependencies beyond Uniswap v4 core types (`PoolId`, `PoolKey`). |
| **Auditability**             | Events and errors are declared directly in the interfaces so off‑chain tooling can decode them reliably.                                                                                                  |
| **No surprises**             | Selector‑collision CI and `solc --abi` compile checks are part of the release pipeline.                                                                                                                   |

## 6.2 Canonical Interface Set

| Interface file                | Core purpose (one‑liner)                                                                                                 |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| **`IVaultManagerCore.sol`**   | Unified user/keeper entry‑point: deposits, withdrawals, lending, LP‑NFTs, limit orders, liquidations, batching, metrics. |
| **`IPoolPolicyManager.sol`**  | Governance module for collateral factors, fee destinations, risk caps.                                                   |
| **`IInterestRateModel.sol`**  | Plug‑in curve supplying per‑second borrow rates to the vault.                                                            |
| **`IGovernanceTimelock.sol`** | Delay‑buffer that queues and executes privileged parameter changes.                                                      |
| **`IVaultMetricsLens.sol`**   | Gas‑cheap read‑only aggregation: vault health, utilisation, POL summaries.                                               |

_(The Uniswap v4 “Spot” hook is an internal per‑pool contract and therefore not included in this public bundle.)_

## 6.3 Recent Additions

- **Vault metrics & health:** `VaultMetrics` event and `vaultMetrics()` getter.
- **Insurance & debt recovery:** `coverBadDebt()`, `BadDebtCovered` event.
- **Governance controls:** Timelock interface (`queueChange`, `executeChange`, `cancelChange`) plus `setGovernanceTimelock()` and `setPauseGuardian()` on the vault.
- **Observability:** `IVaultMetricsLens` contract for front‑ends and monitors.

These items are already present in the interface code below—no migrations are required.

```solidity
/// @title IVaultManagerCore
/// @custom:version 1.2.1-rc3
interface IVaultManagerCore {
    function deposit(address asset, uint256 amount, address recipient) external returns (uint256 shares);
    function depositFor(address asset, uint256 amt, address onBehalf) external returns (uint256 shares);
    function withdraw(address asset, uint256 shares, address recipient) external returns (uint256 amount);
    function redeemTo(address asset, uint256 shares, address to) external returns (uint256 amount);
    function borrow(PoolId poolId, uint256 amount, address recipient) external;
    function repay(PoolId poolId, uint256 amount, address onBehalfOf) external returns (uint256 remaining);
    /// @batch Emitted for each sub-action
    event ActionExecuted(uint256 idx, uint8 code, bool success);
    function executeBatch(bytes[] calldata actions) external returns (bytes[] memory results); /// @deprecated
    function executeBatchTyped(Action[] calldata actions) external returns (bytes[] memory results);
    /// @noBatch – rejected by Selector Guard (T8)
    function liquidate(address borrower, PoolId poolId, uint256 debtToCover, address recipient) external returns (uint256 seizedCollateral);
    /// @noBatch – rejected by Selector Guard (T8)
    function coverBadDebt(PoolId poolId, uint256 amount) external;
}
```
