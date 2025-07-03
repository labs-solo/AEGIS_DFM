# Workflows.md — Single‑Action Flow Primitives

This document defines the **canonical, reusable primitives** for every single‑action vault flow in AEGIS V2 through Phase‑3.  
Each primitive is entirely self‑contained so it can be imported verbatim by the Batch‑Engine specification and by the invariant proofs.

---

## 1  Front‑Matter Table

| Action ID | Name                    | Category            | Risk Effect     | Used In Batch? |
|-----------|-------------------------|---------------------|-----------------|----------------|
| **V0**    | Deposit                | Asset Flow          | risk‑reducing   | **Yes**        |
| **V1**    | Withdraw               | Asset Flow          | risk‑increasing | **Yes**        |
| **V2**    | Borrow                 | Lending             | risk‑increasing | **Yes**        |
| **V3**    | Repay                  | Lending             | risk‑reducing   | **Yes**        |
| **V4**    | Reinvest               | Compounding         | neutral         | **Yes**        |
| **V5**    | Open LP‑NFT            | Liquidity Position  | risk‑increasing | **Yes**        |
| **V6**    | Close LP‑NFT           | Liquidity Position  | risk‑reducing   | **Yes**        |
| **V7**    | Collect Fees           | Revenue             | neutral         | **Yes**        |
| **V8**    | Place Limit Order      | Order Book          | neutral         | **Yes**        |
| **V9**    | Cancel Limit Order     | Order Book          | neutral         | **Yes**        |
| **V10**   | Execute Limit Order    | Order Book          | neutral         | **Yes**        |
| **V11**   | Liquidate             | Risk Management     | risk‑reducing   | **Yes**        |
| **V12**   | Swap                  | Asset Exchange      | neutral         | **Yes**        |

---

## 2  Action Specification Blocks

> **Notation**:  
> • `CF_init` / `CF_maint` = collateral‑factor at initialisation / maintenance  
> • `shareIndex / borrowIndex` = global price accumulators (18‑dec)  
> • “cold” vs “warm” gas figures come from `gas_p3.md`; ±5 % variance allowed on EVM upgrades.

---

### V0  Deposit
*(unchanged — see previous version)*

*(…* *All blocks V1 → V11 are identical to the previous delivery and therefore omitted here for brevity.*)*

---

### V12  Swap

**Canonical Signature**  
`_swap(address assetIn, uint256 amountIn, address assetOut, uint256 minAmountOut, bytes calldata swapPath, address to)`

**Pre‑Conditions**

* P‑1 `amountIn > 0` and `assetIn != assetOut`.  
* P‑2 Both `assetIn` and `assetOut` are enabled collateral assets.  
* P‑3 Caller’s vault balance in `assetIn` ≥ `amountIn`.  
* P‑4 `Vault !paused`.  
* P‑5 Resulting **LTV** after the swap ≤ `CF_maint`.

**Execution Steps**

1. **Burn shares of `assetIn`** equal to `amountIn * 1e18 / shareIndex(assetIn)` from caller. (≈ 9 000 gas warm).  
2. **Perform swap** through the configured router using `swapPath`, verifying that the router returns `amountOut ≥ minAmountOut`. (variable gas, ≈ 75 k cold).  
3. **Mint shares of `assetOut`** to `to` equal to `amountOut * 1e18 / shareIndex(assetOut)`. (≈ 9 000 gas warm).  
4. Emit `Swap(msg.sender, assetIn, amountIn, assetOut, amountOut, to)`.

**Post‑Conditions & Invariants**

* I‑1  `INV‑01 “totalShares == ΣuserShares”` holds for every asset pool.  
* I‑2  `INV‑02 “LTV(user) ≤ CF_maint”` holds.  

**Events Emitted**

* `Swap(address indexed caller, address assetIn, uint256 amountIn, address assetOut, uint256 amountOut, address to)` — warm.

**Error Paths**

| Code                       | Trigger                                            | Notes |
|----------------------------|----------------------------------------------------|-------|
| `InvalidAmount()`          | `amountIn == 0` or `assetIn == assetOut`           | p‑1   |
| `AssetDisabled()`          | either asset not enabled                           | p‑2   |
| `InsufficientShares()`     | caller balance < required shares                   | p‑3   |
| `VaultPaused()`            | global pause                                       | p‑4   |
| `MinOutNotMet()`           | router returned `amountOut < minAmountOut`         | step 2 |
| `CollateralViolation()`    | LTV would exceed `CF_maint` after swap             | p‑5   |

---

## 3  Shared Glossary & Notation

* **CF_init / CF_maint** — initial vs maintenance collateral factor (18‑dec fixed‑point).  
* **shareIndex / borrowIndex** — cumulative indices that translate between assets and shares.  
* **LTV(user)** = Σ(debtValue) / Σ(collateralValue) for user, in base currency.  
* **warm / cold SLOAD** — first slot access in a transaction is “cold” (≈ 2 100 gas surcharge).  
* **bonus** — liquidation incentive percentage (default 5 %).  
* **pid** — pool ID for liquidity positions.  
* **pairKey** — keccak(token0, token1, feeTier).  
* **swapPath** — ABI‑encoded path understood by the DEX router.  

---

## 4  Deterministic Ordering Rules (Stub)

* **Risk Sorting** — The Batch Engine *must* execute all **risk‑reducing** actions (_Repay_, _Deposit_, _Liquidate_, _Close LP‑NFT_) **before** any **risk‑increasing** actions (_Borrow_, _Withdraw_, _Open LP‑NFT_). Neutral actions—including _Swap_—may be freely interleaved.  
* **Temporal Sorting** — When multiple actions share the same `Risk Effect`, they are ordered by ascending `Action ID` to guarantee determinism across clients.

---
