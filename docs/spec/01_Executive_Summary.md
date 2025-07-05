# 1. Executive Summary

**AEGIS V2's killer feature is one-call composability: the ability to combine liquidity provision, borrowing, leveraged trading, and price-triggered orders in a single atomic transaction — all enforced by share-based accounting and pool-isolated vaults.** It is a holistic liquidity engine for Uniswap V4 that lets any participant (LP, market-maker, structured-product desk, or trader) bundle deposits, loans, swaps, LP-NFT operations, and on-chain limit orders with deterministic execution.  It integrates Uniswap's liquidity provision, fee management, lending, advanced LP positions (including on-chain limit orders), and liquidations into one unified Vault architecture.

In today's DeFi landscape, complex strategies typically require multiple protocols and transactions. AEGIS closes this gap: its unified vaults and atomic batch engine ensure that intricate multi-leg workflows execute under one roof.  All collateral-increasing steps (deposits, repays) are applied *before* any collateral-consuming steps (withdraws, borrows), so either the entire batch succeeds or it reverts.  For example, combining a deposit and a borrow in one batch consumes materially less gas than executing those actions separately.  Even 10–12 mixed actions (deposits, swaps, LP ops, etc.) fit within typical block gas limits.  In practice, AEGIS supports up to 14 actions per batch (the current cap) with only a small per-action overhead.  These efficiencies mean users can perform sophisticated strategies at predictable, affordable costs.

As a result, AEGIS delivers a prime-brokerage–like experience on-chain.  In one click, users can deploy capital, hedge exposure, or trade with built-in risk controls — instead of juggling multiple apps.  This unlocks powerful outcomes (see Appendix A for architecture).

**Key Numbers:**

* **Max Batch Actions:** 14 per transaction (bounded by Uniswap hook gas limit).
* **Predictable Gas Efficiency:** Batching actions cuts gas relative to separate transactions.
* **Liquidation Penalty:** \~10% bonus to liquidators on under-collateralized positions.
* **LP Collateral:** Full-range and narrow-range (limit-order) positions both count as collateral (100% factor for full LP).
* **Vault Isolation:** Each pool's vault is siloed under VaultManagerCore, so failures cannot cascade between pools.
* **Deterministic Solvency:** Share-denominated accounting (√a×b) keeps collateral and debt in lock-step, minimizing oracle reliance and preventing price-drift liquidations.

**One-Call Wins:**

| **Who**            | **Pain**                                                                                 | **AEGIS Super-Power**                                                                    | **Outcome**                                                                     |
| ------------------ | ---------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| **Active Traders** | Juggle many transactions (borrow, swap, exit) with high gas and front-run risk.          | Unified margin vault per pool + atomic batch trades with on-chain stop-loss/take-profit. | CEX-like on-chain trading: fast leveraged positions, no partial failure.        |
| **LPs & MMs**      | Suffer impermanent loss with no on-chain hedge; rely on off-chain bots for limit orders. | Share-based lending + native one-tick LP limit orders.                                   | Hedged liquidity provision and tight on-chain markets (two-sided quoting).      |
| **DAO Treasuries** | Manage funds across many protocols manually; inefficient yield and risk management.      | One unified vault for deposits, yield, borrowing, and hedges.                            | Maximal capital efficiency: bulk treasury moves and hedges in one call.         |
| **Builders**       | Piece together multiple contracts to build new products; slow development.               | Modular batch API and vault hooks for composition.                                       | Rapid product launches: complex strategies codable via one-call "lego" actions. |
