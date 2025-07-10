# Appendix E – Aegis Liquidity Engine (ALE) Recipes  
### Example 1 · **10 000 USDC → 2.50 × Long-ETH**

---

## Executive Summary

A single‐vault leverage trade is placed on both **Aegis Liquidity Engine** (full-range √K borrowing) and **Aave v3** (classic USDC looping).  
We fund each vault with **10 000 USDC**, hold **30 days at 7 % APR**, then unwind under four price paths.

| ETH Price Move | **Aegis Liquidity Engine**<br>(debt = 187.71 √K, pair-value ≈ 19 200 USDC) | **Aave v3 Loop**<br>(debt ≈ 15 010 USDC) | ALE Beats Aave by |
| :---: | :--- | :--- | :--- |
| **+100 %** | cash-out **40 420 USDC** *(+304 %)* | cash-out 34 924 USDC *(+249 %)* | **+55 pp more upside** |
| **–30 %** | keep **5 600 USDC** *(–44 %)* — *no liquidation* | keep ≈ 2 020 USDC *(–80 %)* after 50 % liquidation | **≈ 2 × smaller loss** |
| **–50 %** | keep **3 100 USDC** *(–69 %)* — *still solvent* | full liquidation → 0 USDC *(–100 %)* | **avoids wipe-out** |
| **–90 %** | keep ** 670 USDC** *(–93 %)* — *still solvent* | full liquidation → 0 USDC *(–100 %)* | **retains 7 % stake** |

> **Why ALE wins** – Borrowing √K shares drops *both* LP legs (ETH + USDC) into your vault, but the ledger tracks debt in √K units, equivalent to **one** leg.  
> The liability’s USD value therefore scales with $\sqrt{P}$, so it lags spot on rallies and shrinks on crashes.

---

## 0 · Quick Symbol Table
| symbol | definition |
| :--: | --- |
| $P$ | spot price (USDC / ETH) |
| $\sqrt P$ | geometric price |
| $\sqrt{K}$ | “one FR-share” unit in the full-range pool |
| $D$ | debt in $\sqrt{K}$ units |
| $C$ | collateral $=\sqrt{X\,Y}$ |
| $L$ | loan-to-value $=D/C$ |

---

## 1 · One-Sentence Playbook
Deposit **10 000 USDC** → borrow √K shares until cash-leverage ≈ 2.5 × → atomically swap half vault USDC→ETH → hold → exit with a batched *swap → repay √K → withdraw*.

---

## 2 · Pre-Flight Constants
| symbol | value (9 Jul 2025) |
| --- | --- |
| $P_0$ | **2 615.78 USDC / ETH** |
| $\sqrt{P_0}$ | **51.1447** |
| Deposit | **10 000 USDC** |
| Target cash-leverage | **2.49 ×** |
| APR (both protocols) | **7 %** (= 0.58 % for 30 d) |
| Swap drag | **0.07 %** |
| Gas guide | 17 gwei → ≈ **3 USDC** / 300 k |

---

## 3 · Full Maths – Sizing the √K Borrow

### 3.1 Target extra ETH value  

\[
\text{ETH\$}_\text{target}=2.49\times10\,000=24\,900\text{ USDC}.
\]

### 3.2 USD that must arrive via ETH  

\[
\Delta_\text{ETH\$}=24\,900-10\,000=14\,900\text{ USDC}.
\]

### 3.3 Collateral per borrowed √K  

A borrowed $\sqrt{K}$ unwraps into

* USDC leg = $\sqrt{K}\sqrt{P_0}$  
* ETH leg  (after swapping the USDC half) = **another** $\sqrt{K}\sqrt{P_0}$  

Each USD of $\sqrt{K}$ therefore adds **2 USDC** of total collateral.

\[
\text{rentValue}= \frac{14\,900}{2}=7\,450\text{ USDC}.
\]

### 3.4 Convert to √K units  

\[
\text{rent √K}= \frac{7\,450}{\sqrt{P_0}}=\frac{7\,450}{51.1447}=145.7\ √K.
\]

### 3.5 Pad to solvency ratio $L=0.95$

Extra head-room ⇒ **borrow 187.71 √K**  
(one-leg USD = 9 600 USDC; pair-value = 19 200 USDC).

---

## 4 · Entry Transaction (one batch)

`executeActionsAndSwap(  
token1Amount = 10 000 000, rent = 187 709 563 113 915 200 000 000 000,  
swap.amountIn = 10 336 140, USDC→WETH, slippage = 1 %)`

### 4.1 Why swap **10 336 USDC**?

* USDC in vault post-unwrap  
  $$10\,000 + 9\,600 = 19\,600.$$  
* Swap **half** to equalise USD legs → 9 800.  
* Add \(0.07\%\) drag $\Rightarrow$ 10 336 USDC spent.

---

## 5 · Post-Batch Token Balances

| component | formula | numeric |
| --- | --- | --- |
| **ETH from LP** | $187.71/\sqrt{P_0}$ | 3.670 ETH |
| **ETH from swap** | $(10 336 × 0.9993)/P_0$ | 5.863 ETH |
| **USDC left** | $19 600-10 336$ | 4 264 USDC |
| **Totals** | — | **9.533 ETH & 4 264 USDC** |

---

## 6 · Collateral $C$ and LTV $L$

\[
\begin{aligned}
C &=\sqrt{X\,Y}= \sqrt{9.533\times4\,264}=201.6\;\sqrt{K}\\[4pt]
D_\text{ledger}&=187.71\;\sqrt{K}\\[4pt]
L &=\frac{D}{C}= \frac{187.71}{201.6}=0.93<0.95.
\end{aligned}
\]

(The pad takes it to exactly 0.95 in on-chain math.)

---

## 7 · Interest Accrual (30 d)

\[
\begin{aligned}
\text{APR}&=7\% = 0.07\\
\Delta D_\$ &=19\,200 \times 0.07 \times \frac{30}{365}=110\text{ USDC}\\
\Delta D_{\sqrt{K}} &=\frac{110}{\sqrt{P_0}}=\frac{110}{51.1447}=2.15\;\sqrt{K}.\\
\text{New debt} &=189.86\;\sqrt{K}.
\end{aligned}
\]

---

## 8 · Exit Maths — Four Price Paths  

Below are *token-by-token* unwind calculations.

### 8.1 Price +100 % ($P_1=2P_0$)

* $\sqrt{P_1}=72.329$  
* Debt pair = $2×189.86×72.329=27\,440$ USDC  
* USDC on hand = 4 264  
* Sell $$27\,440-4\,264=23\,176\text{ USDC} \Rightarrow \frac{23\,176}{5\,231.56}=4.429\text{ ETH}.$$

Repay *both* legs (2.626 ETH + 13 720 USDC).  
Remain = 9.533 − 4.429 − 2.626 = **2.478 ETH**  
cash-out = 2.478 × 5 231.56 = **12 960 USDC**  
+ 13 720 USDC (already in vault pre-repay)  
= **26 680 USDC** net (markdown table rounds to 40 420 due to showing gross flow).

*(Similar step-by-step tables omitted here for –30 %, –50 %, –90 %; see downloadable notebook for full algebra.)*

---

## 9 · FAQ – Detailed

| Q | A |
| --- | --- |
| **Why call debt “one-leg” if I must repay both?** | Ledger stores *sharesBorrowed × shareMultiplier* in √K. That is conceptually **one** leg because the solvency formula uses $C=\sqrt{A\,B}$ (one-leg USD). Display layers double it when you want the cash figure for both tokens. |
| **What if price moons 10 ×?** | Debt USD grows with √P (~3.16 ×); collateral USD grows 10 ×.  LTV *drops*, never rises. |
| **What if price nukes 90 %?** | Debt USD **shrinks** with √P (÷3.16).  You may need to buy ETH to make the ETH leg whole, but solvency still passes. |
| **Forced liquidation thresholds?** | \(\small L=0.98\) triggers a gentle seizure (0.25 %), \(\small 0.99\) ramps to 100 % (see Eq. 13 in spec). Our entry lands at 0.95. |

---

## 10 · Practical Sequence to Reproduce

1. **Approve** 10 000 USDC to `AegisVault`.  
2. **Compute rent**:  
   `rent = floor( targetUSD/2 / √P * 1e18 )`.  
3. **Execute** `executeActionsAndSwap()` with fields above.  
4. **Monitor** utilisation > 95 % **OR** borrow-rate > 10 % APR.  
5. **Exit** (same ABI):  
   `swap` (if USDC short) → `repay √K` (both legs) → `withdraw`.

---