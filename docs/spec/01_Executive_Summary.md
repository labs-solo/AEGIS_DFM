# 1. Executive Summary

**AEGIS V2 is a holistic liquidity engine for Uniswap V4** that allows any participant—liquidity provider, market-maker, structured-product desk, or trader—to compose deposits, loans, swaps, LP-NFT operations, and price-triggered orders **in a single atomic transaction** while enjoying pool-level risk isolation and deterministic execution. It integrates Uniswap's liquidity provision, fee management, collateralised lending, advanced LP positions (including on-chain limit orders), and automated liquidations into one unified **Vault** architecture.

Each user's assets and debts are isolated in a per-pool vault (capping the blast radius to a single pair) even as a single global `VaultManagerCore` coordinates all pools network-wide. A robust batch engine bundles up to fourteen actions (e.g. *add liquidity → borrow → swap to hedge → place limit order*) in one go, guaranteeing that collateral-increasing steps execute before collateral-reducing steps. This design lets users safely execute complex DeFi workflows that would otherwise require multiple protocols and transactions.

AEGIS V2 also introduces share-based lending, whereby liquidity-provider shares serve as direct collateral and borrowers repay a fixed share amount (not an unpredictable token amount). Because each share's value tracks \(\sqrt{a\times b}\), collateral ratios stay meaningful at every tick, and a global borrow index updates every loan in \(O(1)\) gas. Zero-range (one-tick) liquidity positions double as deterministic limit orders, unlocking tight-spread automated-market-making strategies previously impossible in legacy AMMs.

At a high level, AEGIS V2 centres on an upgradeable **VaultManagerCore** that interfaces with Uniswap v4 pools via a specialised **Spot Hook**, supported by modular components for dynamic fees, interest rates, pricing oracles, and risk policy. All user operations flow through a stateless batch router into the VaultManager, which mints/burns Uniswap LP tokens and enforces margin rules and liquidations in real time. This layered design ensures no pool can contaminate another's solvency, and new collateral types or actions can be added without disruptive migrations. *(See Appendix A for an architecture diagram and component overview.)*

---

## One-Transaction Strategies Enabled

* **Liquidity Providers (LPs):** Earn Uniswap trading fees on deposited assets *while retaining instant liquidity* by borrowing against or withdrawing from positions on demand.
* **Market Makers:** Quote tight, two-sided markets within a single block using on-chain limit orders to deploy both bid and ask liquidity with minimal exposure.
* **Structured-Product Desks:** Launch delta-neutral yield strategies or other structured products with a single call, bundling swaps, liquidity provision, and hedges atomically.
* **Leveraged Traders:** Move from a spot position to a leveraged long or short—and even add a hedge—**entirely on-chain**, all in one unified margin transaction (no CeFi or multi-protocol hopping).

---

### Key Metrics at a Glance

* **Max Batch Actions:** 14 per transaction (bounded by Uniswap hook gas limit).
* **Predictable Gas Efficiency:** Batching actions cuts gas relative to separate transactions.
* **Liquidation Penalty:** ~10 % bonus to liquidators on under-collateralised positions.
* **LP Collateral:** Full-range and narrow-range (limit-order) positions both count as collateral (100 % factor for full-range LP).
* **Vault Isolation:** Each pool's vault is siloed under `VaultManagerCore`, so failures cannot cascade between pools.
* **Deterministic Solvency:** Share-denominated accounting (√a×b) keeps collateral and debt in lock-step, minimising oracle reliance and preventing price-drift liquidations.
