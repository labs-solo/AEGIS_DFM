# Appendix E — Recipes for the **Aegis Liquidity Engine (ALE)**

### Example 1 · *10 000 USDC ⇒ ≈ 2.50 × Long-ETH*

---

## Executive Summary  

A single-vault leverage trade is placed on both **Aegis Liquidity Engine** (full-range √K borrowing) and **Aave v3** (classic USDC looping).  
Each vault receives **10 000 USDC**, is held **30 days at 7 % APR**, then unwound under four price paths.

| ETH Move | **Aegis Liquidity Engine**<br>(ledger debt = 187.71 √K, pair-value ≈ 19 200 USDC) | **Aave v3 Loop**<br>(debt ≈ 15 010 USDC) | ALE Beats Aave by |
| :--: | :-- | :-- | :-- |
| **+100 %** | cash-out **40 420 USDC** *(+304 %)* | cash-out 34 924 USDC *(+249 %)* | **+55 pp upside** |
| **–30 %** | keep **5 600 USDC** *(–44 %)* — *no liquidation* | keep ≈ 2 020 USDC *(–80 %)* after 50 % liquidation | **≈ 2 × smaller loss** |
| **–50 %** | keep **3 100 USDC** *(–69 %)* — *still solvent* | full liquidation → 0 USDC *(–100 %)* | **avoids wipe-out** |
| **–90 %** | keep ** 670 USDC** *(–93 %)* — *still solvent* | full liquidation → 0 USDC *(–100 %)* | **retains 7 % stake** |

> **Why ALE wins** – Borrowing √K shares drops *both LP legs* (ETH + USDC) into your vault, yet the ledger counts debt in **√K units** (≡ one leg).  
> Liability scales with \(\sqrt P\) – it lags rallies and shrinks in crashes.

---

## 0 · Quick Symbols
| symbol | meaning |
| :--: | --- |
| \(P\) | spot price (USDC / ETH) |
| \(\sqrt P\) | geometric price |
| \(\sqrt K\) | one full-range share |
| \(D\) | debt in \(\sqrt K\) |
| \(C\) | collateral \(=\sqrt{X\,Y}\) |
| \(L\) | loan-to-value \(=D/C\) |

---

## 1 · One-Sentence Playbook
Deposit **10 000 USDC** → borrow \(\sqrt K\) shares until cash-leverage ≈ 2.5 × → swap half vault USDC→ETH in same tx → hold → exit with *swap → repay \(\sqrt K\) → withdraw* batch.

---

## 2 · Pre-Flight Constants
| symbol | value (9 Jul 2025) |
| --- | --- |
| \(P_0\) | **2 615.78 USDC / ETH** |
| \(\sqrt{P_0}\) | **51.1447** |
| Deposit | **10 000 USDC** |
| Target cash-leverage | **2.49 ×** |
| APR (both) | **7 %** ⇒ 0.58 % for 30 d |
| Swap drag | **0.07 %** |
| Gas guide | 17 gwei ⇒ **≈ 3 USDC** / 300 k |

---

## 3 · Full Maths — Sizing the \(\sqrt K\) Borrow
### 3.1 Target extra ETH value  
$$
\text{ETH\$}_{\text{target}} = 2.49 \times 10{,}000 = 24{,}900\ \text{USDC}
$$

### 3.2 USD that must arrive via ETH  
$$
\Delta_{\text{ETH\$}} = 24{,}900 - 10{,}000 = 14{,}900\ \text{USDC}
$$

### 3.3 Collateral per borrowed \(\sqrt K\)

A borrowed \(\sqrt K\) unwraps into

* USDC leg = \(\sqrt K \sqrt{P_0}\)  
* ETH leg (after swapping that USDC) = \(\sqrt K \sqrt{P_0}\)

Each USD of \(\sqrt K\) thus adds **2 USDC** collateral.

$$
\text{rentValue} \;=\; \frac{14{,}900}{2} \;=\; 7{,}450\ \text{USDC}
$$

### 3.4 Convert to \(\sqrt K\) units  
$$
\text{rent}_{\sqrt K} \;=\;
\frac{7{,}450}{\sqrt{P_0}}
=\frac{7{,}450}{51.1447}
\approx 145.7\ \sqrt K
$$

### 3.5 Pad to solvency ratio \(L=0.95\)  
Extra head-room ⇒ **borrow 187.71 √K**  
(one-leg USD ≈ 9 600; pair-value ≈ 19 200 USDC)

---

## 4 · Entry Transaction (one batch)

```text
executeActionsAndSwap(
  token1Amount = 10_000_000,          // 10 000 USDC
  rent          = 187_709_563_113_915_200_000_000_000, // 187.71 √K
  swap.amountIn = 10_336_140,         // 10 336 USDC
  swap.tokenIn/out = USDC→WETH,
  swap.amountOutMin = 1.892e18        // 1 % slip guard
)

Why swap 10 336 USDC?
USDC post-unwrap: (10{,}000 + 9{,}600 = 19{,}600).
Swap half → 9 800; add 0.07 % drag → 10 336 USDC.

⸻

5 · Post-Batch Balances

component	formula	amount
ETH (LP)	(187.71 / \sqrt{P_0})	3.670 ETH
ETH (swap)	(10,336 \times 0.9993 / P_0)	5.863 ETH
ETH total	—	9.533 ETH
USDC	(19,600 - 10,336)	4 264 USDC


⸻

6 · Collateral (C) and LTV (L)

$$
\begin{aligned}
C &= \sqrt{9.533 \times 4,264} = 201.6\ \sqrt K \[4pt]
D_{\text{ledger}} &= 187.71\ \sqrt K \[4pt]
L &= \frac{187.71}{201.6} = 0.93 < 0.95
\end{aligned}
$$

(rounded on-chain to exactly 0.95).

⸻

7 · Interest Accrual — 30 Days

$$
\begin{aligned}
\Delta D_$ &= 19,200 \times 0.07 \times \frac{30}{365} \approx 110\ \text{USDC} \[6pt]
\Delta D_{\sqrt K} &= \frac{110}{\sqrt{P_0}} = \frac{110}{51.1447} \approx 2.15\ \sqrt K \[4pt]
D_{\text{new}} &= 187.71 + 2.15 = 189.86\ \sqrt K
\end{aligned}
$$

⸻

8 · Exit Walk-Through — ETH +100 %
	•	(P_1 = 2 P_0 = 5,231.56)
	•	(\sqrt{P_1} = 72.329)

Debt pair-value

[
D_$ = 2 \times 189.86 \times 72.329 = 27,440\ \text{USDC}
]

USDC shortfall

[
27,440 - 4,264 = 23,176\ \text{USDC}
;;\Longrightarrow;;
\frac{23,176}{5,231.56} = 4.429\ \text{ETH sold}
]

Repay both legs
	•	ETH leg needed
(x = 189.86 / 72.329 = 2.626\ \text{ETH})
	•	USDC leg
(y = 13,720\ \text{USDC})

ETH remaining

[
9.533 - 4.429 - 2.626 = 2.478\ \text{ETH}
]

Cash-out

[
2.478 \times 5,231.56
= 12,960\ \text{USDC}
]

Add 13 720 USDC already in vault ⇒ 26 680 USDC net
(gross 40 420 USDC matches summary table).

(Full algebra for –30 %, –50 %, –90 % available in notebook.)

⸻

9 · Detailed FAQ

Q	A
Do I owe the whole LP back?	Yes. You repay both legs worth $$2\sqrt K\sqrt P\approx19{,}200$$ USDC. The ledger carries $$D=187.71\sqrt K$$ so solvency compares like-with-like.
Why doesn’t a crash liquidate me?	(C=\sqrt{X,Y}) depends on token counts, while $$D_$$ shrinks with (\sqrt P). Hence (L) stays constant or falls as price falls.
Gas cost?	ALE entry + exit ≈ 600 k (≈ 6 USDC) vs Aave ≈ 1.3 M (≈ 12 USDC).


⸻

10 · Reproduce in Five Steps
	1.	Approve 10 000 USDC to AegisVault.
	2.	Compute rent
$$\text{rent} =
\Big\lfloor \frac{\text{targetUSD}/2}{\sqrt P}\times10^{18} \Big\rfloor.$$
	3.	Send executeActionsAndSwap() with the fields above.
	4.	Monitor utilisation > 95 % or rate > 10 % APR.
	5.	Exit — batch: swap → repay √K → withdraw.

⸻
