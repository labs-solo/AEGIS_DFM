# ERC-4626 FAQ for AEGIS V2

| # | Question | Quick answer | Where to look in the spec |
|---|---|---|---|
| 1 | Why do we care about ERC-4626 at all? | It's the de-facto "yield-vault" interface that wallets (e.g. Rabby, Rainbow), routers (1inch, CowSwap) and analytics sites (DeFi Llama, Zapper) already whitelist. Supporting it turns AEGIS pools into first-class citizens with virtually zero bespoke integration work. | GTM segment matrix → Integrator persona; KPI: Connected Wallets (Phase-1) |
| 2 | Which strategy did we choose? | Single "share-wrapper" vault that custodies ordinary AEGIS LP shares (§6.2.7 draft). Core contracts stay untouched; the wrapper is a thin ERC-4626 shell that calls V0 depositFullRange / V1 withdrawFullRange. | §6 Interfaces • §5.7 Batch Engine • INV-2.5 Share-price ≥ prior |
| 3 | Does this break any safety invariant? | No. The wrapper interacts only through existing batch actions, so every invariant in §8 (e.g. INV-3.3 Global Solvency, INV-2.6 Hook-Only Access) continues to hold. | §8 Invariants |
| 4 | Will users see two vault tokens per pool? | No. Unlike the dual-adapter approach, the share-wrapper creates one ERC-4626 token per pool, avoiding UX fragmentation. | Design decision memo 2025-07-07 |
| 5 | Why might APR widgets show "0 %" sometimes? | Share price is monotonic (never falls), so during periods of 100 % utilisation it can pause. Yield is still accruing but isn't realised until fees are harvested. Dashboards should combine totalFeeGrowth from VaultMetricsLens with utilisation() to display effective APY. | INV-2.5, Lens docs |
| 6 | What extra gas does the wrapper add? | ~12–18 k gas per action: one ERC-20 transfer plus wrapper logic. Reads (previewDeposit) are almost free. | Wrapper audit notes |
| 7 | Can I still borrow against wrapped shares? | Yes. The wrapper merely holds the underlying LP shares; users can unwrap any time, then call borrowing actions (V3 borrowShares). No change to collateral flow. | §5 Functional Spec – Borrowing |
| 8 | When will this ship? | Roadmap Phase 1 – "Integrator On-Ramp", Q3 2025. Tagged release v1.3.0 after the current ABI freeze (v1.2.1-rc3). | Roadmap timelines (GTM doc) |
| 9 | What SDK helpers are planned? | wrapper.depositWithPermit() to bundle approval + deposit, wrapper.previewYield() (optional extension) and sdk.canDeposit(poolId) to guard against high utilisation reverts. | SDK changelog draft |
| 10 | How do I list the vault on my dashboard? | Use the wrapper's ERC-20 address, call standard 4626 views (asset(), totalAssets(), convertToShares()); for accurate APR, also read utilisation() and pendingFees() from VaultMetricsLens. | §6.2.7 interface stub | 
| 11 | Why only full-range borrowing? | Debt is denominated in FR-shares so collateral math stays invariant. | §5.3 Borrowing |
| 12 | What happens when my limit order fills? | The LO shares burn and the received tokens remain in your vault. | §5.5 Position-Based Limit Orders |
