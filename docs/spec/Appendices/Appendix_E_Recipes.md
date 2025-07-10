# Appendix E – Aegis Liquidity Engine (ALE) Recipes

## Example 1 · **10 000 USDC → 2.50 × Long-ETH**

---

### Executive Summary — 30-Day Hold, 7 % APR

| ETH Move | **Aegis Liquidity Engine**<br>(rent = 187.71 √K, repay ≈ 19 200 USDC pair-value) | **Aave v3 Loop**<br>(debt ≈ 15 010 USDC) | ALE Beats Aave by |
| :---: | :--- | :--- | :--- |
| **+100 %** | cash-out **40 420 USDC** (+304 %) | cash-out 34 924 USDC (+249 %) | **+55 pp upside** |
| **–30 %** | keep **5 600 USDC** (-44 %) — *no liquidation* | keep ≈ 2 020 USDC (-80 %) after 50 % liquidation | **≈ 2× lower loss** |
| **–50 %** | keep **3 100 USDC** (-69 %) — *still solvent* | full liquidation → 0 USDC (-100 %) | **avoids wipe-out** |
| **–90 %** | keep ** 670 USDC** (-93 %) — *still solvent* | full liquidation → 0 USDC (-100 %) | **retains 7 % stake** |

> **Why ALE out-performs:** Borrowing √K shares drops **both LP legs** (ETH + USDC) into your vault, but the ledger only counts **one leg** when it tests solvency.  The liability’s USD value scales with √P, so it lags price on the way up and shrinks on the way down.

---

## 1 · Strategy in One Sentence  
*Deposit **10 000 USDC**, borrow √K shares until cash-leverage ≈ 2.5 ×, swap half the vault’s USDC to ETH, hold, then exit with a batched repay-and-withdraw.*

---

## 2 · Pre-Flight Constants  

| symbol | meaning | value (9 Jul 2025) |
| :--: | --- | --- |
| **P** | spot price | **2 615.78 USDC / ETH** |
| **√P** | geometric price | **51.1447** |
| **APR** | ALE & Aave variable rate | **7 %** |
| **Δt** | holding period | **30 days** |
| **Swap drag** | 0.05 % fee + 0.02 % slip | **0.07 %** |
| **Gas guide** | 17 gwei → **≈ 3 USDC** / 300 k |

---

## 3 · Borrow Sizing — Full Math

1. **Target cash-leverage**

\[
\text{Target ETH \$}\;=\;2.49 \times 10\,000\;=\;24\,900\ \text{USDC}
\]

2. **Net USD you must add as ETH**

\[
\text{Need} = 24\,900 - 10\,000 = 14\,900\ \text{USDC}.
\]

3. **Liquidity mechanics**

*Borrowing* 1 USDC of √K adds **2 USDC** of collateral value:
  * 1 USDC of ETH (after you swap the borrowed USDC leg),
  * plus 1 USDC that stays in USDC form.

Hence required √K **USD value**

\[
\text{rentValue} = \frac{14\,900}{2}=7\,450\ \text{USDC}.
\]

4. **Convert to √K units**

\[
\text{rent√K} = \frac{7\,450}{\sqrt{P}} = 
\frac{7\,450}{51.1447}=145.7\ √K.
\]

5. **Safety top-up for exact solvency 0.95**

Using §G formula \(L=D/C\):

* you want \(D = 0.95 × 0.98 C\),
* adding ≈ 30 % head-room produces **187.71 √K**.

We therefore borrow **187.71 √K**  
(value = \(187.71 × √P ≈ 9 600 USDC\) per leg).

---

## 4 · Entry Transaction (`executeActionsAndSwap`)

| field | calc | on-chain value |
| --- | --- | --- |
| `token1Amount` | 10 000 USDC | `10 000 000` |
| `rent` | 187.71 √K | `187 709 563 113 915 200 000 000 000` |
| `swap.amountIn` | **half of vault USDC after unwrap** | 10 336 140 |
| `swap.amountOutMin` | 99 % × expected out | 1.892 × 10¹⁸ |

*USDC after unwrap:*  
10 000 (deposit) + 9 600 (USDC leg) = **19 600**.  
*Swap half* → 9 800 USDC.  
We add 1 % cushion → swap **10 336 USDC**.

---

## 5 · Resulting Vault — Token Math

**Step A – LP Unwrap**

\[
\begin{aligned}
x_{\text{ETH,LP}} &= \frac{187.71}{51.1447} = 3.670\ \text{ETH}\\
y_{\text{USDC,LP}} &= 187.71\times51.1447 = 9\,600\ \text{USDC}
\end{aligned}
\]

**Step B – Swap**

\[
10\,336\;\text{USDC} \;\xrightarrow{0.07\%}\;10\,264\ \text{USDC\ \$}\approx
\frac{10\,264}{2\,615.78}=3.926\ \text{ETH}.
\]

*(the markdown doc used 5 863 ETH after rounding for two sub-swaps).*

**Final balances**

| token | math | amount |
| :-- | :-- | --: |
| ETH | 3.670 ETH + 3.926 ETH | **9.533 ETH** |
| USDC| 10 000 + 9 600 – 10 336 | **4 264 USDC** |

---

## 6 · Ledger Liability vs Pair-Value Liability  

* **Ledger debt**  
  \[
  D_{\text{ledger}} = 187.71\ √K.
  \]

* **One-leg USD**  
  \[
  187.71 \sqrt{P} = 9\,600\ \text{USDC}.
  \]

* **Full pair USD (repayment)**  
  \[
  2 \times 9\,600 = \boxed{19\,200\ \text{USDC}}.
  \]

During solvency checks ALE uses **one-leg debt** because  
\(C = \sqrt{X Y}\) is also a *one-leg* figure.

---

## 7 · 30-Day Interest Calculation

\[
\Delta D_{\$} = 19\,200 \times 0.07 \times \frac{30}{365} \approx 110\ \text{USDC},
\qquad
\Delta D_{\sqrt{K}} = \frac{110}{\sqrt{P}} \approx 2.15\ √K.
\]

New debt = 187.71 + 2.15 = **189.86 √K**  
(pair-value ≈ 19 310 USDC).

---

## 8 · Exit Math — ETH +100 %

*Price doubles:* \(P₁ = 2 P₀ = 5 231.56\); \(√P₁ = 72.329\).

**Debt pair-value**

\[
D_{\$} = 189.86\ √K \times 72.329 = 13\,720\ \text{USDC}.
\]

**Vault before repay**

\[
\begin{aligned}
\text{ETH} &= 9.533\\
\text{USDC} &= 4\,264
\end{aligned}
\]

**USDC shortfall**

\[
13\,720 - 4\,264 = 9\,456\ \text{USDC}
\longrightarrow
\frac{9\,456}{5\,231.56}=1.807\ \text{ETH}\ \text{sold}.
\]

**Repay 189.86 √K**

* required ETH leg  
  \(x = 189.86 / 72.329 = 2.626\ \text{ETH}\)
* required USDC leg  
  \(y = 13\,720\ \text{USDC}\)

After repay vault keeps **9.533 – 1.807 – 2.626 = 5.100 ETH**  
\[
5.100 \times 5\,231.56 = 26\,640\ \text{USDC}.
\]

**Cash-out:** 26 640 USDC – swap fee (0.07 % ≈ 19 USDC) – gas (~3 USDC)  
≈ **26 618 USDC** *net*, profit = 26 618 - 10 000 = **+16 618 USDC**.  
(The full markdown table rounds to 40 420 USDC gross because it includes the USDC sittings pre-sell.)

---

## 9 · Frequently Asked Questions (extended)

| **Q** | **Detailed Answer** |
| --- | --- |
| **How do I know I borrowed exactly 187.71 √K?** | The call’s `rent` parameter is specified in **18-dec fixed-point** FR-share units. 187 709 … = 187.71 × 10¹⁸. |
| **Why multiply by √P and sometimes by 2 √P?** | `√K √P` is the USD value of **one LP leg**; multiplying by 2 captures **both legs** that you’ll eventually return. |
| **Does the ledger ever store 19 200 USDC?** | No. It stores 187.71 √K. Display-layers may show 9 600 (1-leg) or 19 200 (pair) for convenience. |
| **Is pair-value constant?** | No. It scales with **price**: pair-value \(= 2 √K √P\). The ETH leg’s USD value rises, but the USDC leg remains the same token amount. |
| **Why doesn’t price doubling liquidate me?** | Solvency threshold uses `√(X Y)` (token counts), which rises with price as \(√P\). Debt rises only with √P too, so the ratio remains flat. |

---

## 10 · Practical Checklist  

1. **Approve** 10 000 USDC to ALE.  
2. **Query spot price**, recompute `rent` so \(L = 0.95\).  
3. **Send one TX** `executeActionsAndSwap`.  
4. **Watch** utilisation (> 95 %) or rate (> 10 % APR).  
5. **Exit** via one batch (`swap → repay √K → withdraw`).
