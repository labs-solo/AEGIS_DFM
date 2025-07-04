# AEGIS V2 Unified Vault — Executive Summary

> Version `vFinalSpec‑draft` – 2025‑07‑02

---

## Mission Statement & Scope

AEGIS V2 is a **holistic liquidity engine** for Uniswap V4 that lets any participant—liquidity provider, market‑maker, structured‑product desk, or directional trader—compose deposits, loans, swaps, LP‑NFT operations and price‑triggered orders **in a single atomic call** while enjoying pool‑level risk isolation and deterministic execution.
It extends the original AEGIS Dynamic Fee Manager (DFM) codebase without breaking any of its hooks or fee logic.

---

## Unprecedented Capabilities

* **Per‑User, Per‑Pool Vaults** – each wallet has its own segregated position and debt ledger for every pool, capping blast radius to a single pair while a **single `VaultManagerCore`** contract orchestrates all vaults network‑wide.
* **Instant Portfolio Workflows** – `executeBatch` bundles up to 14 actions (e.g., add liquidity → borrow → hedge → place limit order) into one transaction, guaranteeing that collateral‑adding steps run before collateral‑reducing steps.
* **Share‑Based Lending** – pool‑wide interest index updates in O(1); borrowers repay a deterministic share amount rather than variable principal, simplifying structured‑product payoff design.
* **On‑Chain Limit Orders** – zero‑range LP‑NFTs act as maker orders with deterministic settlement, enabling tight‑spread market‑making strategies impossible in legacy AMMs.
* **Automated Liquidations with Risk Reserve** – a protocol‑owned liquidity (POL) reserve grows from liquidation penalties and a slice of net fees **on a pool‑by‑pool basis** and serves as the ultimate bad‑debt absorber.
* **Granular Governance & Observability** – two‑step timelock, pause bitmap per action family, and a gas‑free metrics lens for real‑time dashboards.
* **Code‑Level Backward Compatibility** – every public function and storage slot from the AEGIS DFM code remains intact; V2 is a pure superset.
* **Dual‑API Guarantee** – all single-action calls map 1:1 to batch operations. Typed batch (`executeBatchTyped`) supersedes legacy bytes variant from v1.1 onward.

These features let LPs farm fees while retaining instant liquidity, let market‑makers quote two‑sided markets inside one block, empower desks to launch delta‑neutral structured notes with a single call, and allow traders to move from cash to leverage to hedged exposure without leaving the chain.

---

## High‑Level Architecture

| Layer              | Component                    | Role                                                                                    |
| ------------------ | ---------------------------- | --------------------------------------------------------------------------------------- |
| **Core State**     | **VaultManagerCore (proxy)** | Holds all balances, borrow indices & pause flags; exposes single‑action and batch APIs. |
| **Swaps & LP Ops** | **Spot Hook**                | Mints/collects Uniswap V4 LP‑NFTs, pipes fees back to the vault.                        |
| **Dynamic Fees**   | **DFM**                      | Adjusts swap fee/Δ according to pool volatility.                                        |
| **Rates**          | **FRLM**                     | Jump‑rate model returns `ratePerSecond` per pool.                                       |
| **Pricing**        | **TruncGeoOracleMulti**      | Time‑weighted tick → on‑chain price.                                                    |
| **Policy**         | **PolicyManager**            | Per‑pool LTV caps, liquidation penalties, whitelist gates.                              |
| **Gov**            | **GovernanceTimelock**       | 48 h delay on upgrades or parameter bumps.                                              |
| **Observability**  | **VaultMetricsLens**         | Read‑only contract for UI/APIs.                                                         |

**Call flow:** Uniswap PoolManager ↔ **Spot Hook** ↔ **VaultManagerCore**; modul­ar contracts (oracle, DFM, FRLM, Policy) feed parameters—no circular writes.

---

## Governance & Licensing

* **License:** Business Source License 1.1 → automatic GPL‑3.0+ re‑license on **2029‑05‑01**.
* **Roles:** `GOV` (timelock executor), `KEEPER` (interest, liquidations), `RELAYER` (optional limit‑order trigger).

---

## Forward‑Compatibility

* New collateral types, rate models, or action codes plug in without state migration.
* Dispatcher reserves IDs `0x0B–0x0E`; unknown codes revert.
* Per‑pool parameter structs are upgradeable via timelock, no contract redeploy required.