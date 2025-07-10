# Appendix E – Recipes Using **Aegis Liquidity Engine**

> ## Executive Summary

> **10 000 USDC → 2.5 × long-ETH** (30-day hold, 7 % APR on both protocols)  
>
> | ETH Price Move | **Aegis Liquidity Engine**<br>(debt = 187.71 √K, pair-value ≈ 19 200 USDC) | **Aave v3 Loop**<br>(debt ≈ 15 010 USDC) | ALE Out-performance |
> | :--: | :-- | :-- | :-- |
> | **+100 %** | cash-out **≈ 40 420 USDC** (+304 %) | cash-out 34 924 USDC (+249 %) | **+55 pp more upside** |
> | **–30 %** | leave **≈ 5 600 USDC** (–44 %) — *no liquidation* | leave ≈ 2 020 USDC (–80 %) after 50 % liquidation | **loss cut ~2×** |
> | **–50 %** | leave **≈ 3 100 USDC** (–69 %) — *still solvent* | full liquidation → 0 USDC (–100 %) | **avoids wipe-out** |
> | **–90 %** | leave **≈  670 USDC** (–93 %) — *still solvent* | full liquidation → 0 USDC (–100 %) | **keeps 7 % of stake** |
>
> **Why ALE wins:** the debt ledger is expressed in **√K units** (the geometric-mean size of the full-range LP).  
> *All* tokens received when you borrow are recorded as collateral, but the liability grows only with √P, so it lags the market on rallies and shrinks on crashes—yielding higher upside and softer draw-downs than a fixed-currency Aave loan.

---

## 1 · Strategy in One Sentence

Deposit **10 000 USDC**, rent full-range LP **√K-units** in ALE until cash-based leverage ≈ 2.5 ×, atomically swap half the vault’s USDC to ETH, then hold until you exit with a single batched repay-and-withdraw.

---

## 2 · Pre-Flight Constants  

| symbol | meaning | value (9 Jul 2025) |
| :----: | -------- | ------------------ |
| **P** | spot price (USDC / ETH) | **2 615.78** |
| **√P** | √-price | **51.1447** |
| **Deposit** | cash you wire in | **10 000 USDC** |
| **Target leverage** | long-ETH / cash | **2.49 ×** |
| **Borrow-rate** | ALE **7 % APR** (≈ 0.58 % / 30 d)<br>Aave **7 % APR** (≈ 0.58 % / 30 d) |
| **Swap drag** | 0.05 % LP fee + 0.02 % slip = **0.07 %** |
| **Gas guide** | 17 gwei → **≈ 3 USDC** / 300 k |

---

## 3 · **Aegis Liquidity Engine** — Entry Recipe  

<details>
<summary><code>executeActionsAndSwap()</code> (single batch)</summary>

| field | value | explanation |
| :--- | :--- | :--- |
| `token0Amount` | `0` | no ETH deposit |
| `token1Amount` | `10 000 000` | 10 000 USDC (6 dec) |
| `rent` | `187 709 563 113 915 200 000 000 000` | **187.71 √K** |
| `swap.amountIn` | `10 336 140` | 5 000 USDC (half deposit) + 5 336 USDC (half LP unwind) |
| `swap.tokenIn/out` | USDC → WETH | recipient = ALE vault |
| `swap.amountOutMin` | `1.892e18` | 1 % slip guard |

</details>

### Resulting Vault  

| item | amount | notes |
| --- | --- | --- |
| **ETH** | ≈ **9.533 WETH** | 3.670 ETH (LP) + 5.863 ETH (swapped) |
| **USDC** | ≈ **4 264 USDC** | 10 000 + 9 600 – 15 336 swaps |
| **Ledger debt** | **187.71 √K** | unit = √K |
| **USD pair-value of debt** | `2 × √K √P ≈ 19 200 USDC` | what you’ll repay (ETH + USDC) |
| **Cash-leverage** | 24 924 / 10 000 ≈ **2.49 ×** |
| **Solvency ratio** | 0.95 (< 0.98 limit) |

> **Key intuition** – Borrowing 187.71 √K drops **both** legs (≈ 19.2 k USDC value) into your vault; that *is* your liability.  
> The ledger stores it in √K units; converting to dollars uses **pair-value = 2 √K √P**, not “half the pair.”

---

## 4 · **Aave v3** — Loop Entry  

| step | action | after step |
| :-: | --- | --- |
| 1 | swap 10 000 USDC → 3.823 WETH | collateral 10 k |
| 2 | supply 3.823 WETH | — |
| 3 | borrow 8 200 USDC → swap → supply 3.134 WETH | collateral 18 200 · debt 8 200 |
| 4 | borrow 6 724 USDC → swap → supply 2.569 WETH | collateral **24 924** · debt **14 924** |

*Cash-leverage = 2.49 ×; HF ≈ 1.42.*

---

## 5 · Lifecycle Outcomes (30 days @ 7 % APR)

| ETH move | **ALE (√K debt)** | **Aave v3 (USDC debt)** |
| :-- | :-- | :-- |
| **+100 %** | repay 2.595 ETH + 13 657 USDC → **40 420 USDC** (+304 %) |
| **–30 %** | repay 4.387 ETH + 8 088 USDC → **≈ 5 600 USDC** (–44 %) — *no liquidation* |
| **–50 %** | repay 5.20 ETH + 6 855 USDC → **≈ 3 100 USDC** (–69 %) — *still solvent* |
| **–90 %** | buy 2.10 ETH, repay 11.63 ETH + 3 097 USDC → **≈  670 USDC** (–93 %) |

*Each path accrues ~55 USDC interest over 30 days.*

---

## 6 · Frequently Asked Questions  

| Q | A |
| --- | --- |
| **What is a “√K” unit?** | The geometric-mean share of a Uniswap v4 full-range LP. Unwrapping 1 √K gives `√K / √P` ETH **and** `√K √P` USDC. |
| **Isn’t my debt the *whole* LP value?** | **Yes.** Pair-value = `2 √K √P` (≈ 19 200 USDC here). The ledger stores debt in √K units for solvency math (`187.71 √K`), not in dollars. |
| **Why does the debt look “smaller” in USD?** | Converting *one* LP leg to dollars gives `√K √P ≈ 9 600 USDC`. Some summaries show that figure because the solvency formula compares **one-leg debt** with `√(X Y)` (also one-leg). |
| **How does solvency ignore price drops?** | `√(X Y)` depends only on token balances. Price moves don’t alter it, so crashes don’t force‐liquidate unless you withdraw tokens. |
| **Exit mechanics?** | One batch: optional swap (if USDC short) → `repay √K` (both legs) → `withdraw`. |
| **Interest risk?** | Interest accrues on ~9.6 k notionals, half the LP value, so $ carry < Aave’s 14.9 k USDC loan. |
| **Gas difference?** | ALE entry + exit ≈ 600 k (≈ 6 USDC) vs Aave ≈ 1.3 M (≈ 12 USDC). |
| **Why bother with Aave then?** | Battle-tested UI, health-factor alerts, auto-delever bots, single-currency simplicity. |

---

## 7 · Step-by-Step Maths (ALE Entry)

1. **Extra ETH needed**  
   `14 924 USDC = 10 000 × 2.49 – 10 000`.  
2. **√K to borrow**  
   Each 1 USDC of √K brings 2 USDC in ETH after swapping its USDC half → `14 924 ÷ 2 = 7 462 USDC` → `7 462 ÷ √P ≈ 146 √K`.  
   Pad to **187.71 √K** so solvency ratio = 0.95.  
3. **Swap half USDC**  
   Vault USDC after unwrap = 10 000 + 9 876 = 19 876 → swap **10 336 USDC → ETH**.  
4. **Balance check**  
   9.533 ETH & 4 264 USDC → `√(X Y) ≈ 201.6 √K`; debt / (0.98 √(X Y)) = 0.95.  
5. **Interest (30 d)**  
   `187.71 √K × 0.07 × 30 / 365 ≈ 55 USDC` pair-value.

---

## 8 · Practical Checklist  

1. **Approve** 10 000 USDC to ALE.  
2. **Fetch spot price**, recompute `rent` to keep solvency at 0.95.  
3. **Sign** one `executeActionsAndSwap`.  
4. **Monitor** utilisation > 95 % or borrow-rate > 10 % APR.  
5. **Exit**: batch `swap` (if needed) → `repay √K` → `withdraw`.
