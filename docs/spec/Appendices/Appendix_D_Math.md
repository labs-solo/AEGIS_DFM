# Concentrated-Liquidity Borrow-Lend — Complete Math Specification

*Uniswap v4 hook with one full-range position; users deposit raw tokens then allocate them into full-, finite-, or limit-order liquidity. Borrowing remains full-range shares only.*

---

## A. Process Flow

1. **Deposit** – Move raw **Asset A** and/or **Asset B** into the vault.  
2. **Allocation** – Route vault tokens into three liquidity flavours:

   | Allocation | Characteristics |
   |------------|-----------------|
   | **FR-shares** | Full-range; spans every price → classic constant-product block |
   | **CR-shares** | Finite range `$[\underline{P},\overline{P}]$`; behaves like a Uniswap v4 LP |
   | **LO-shares** | Limit-order = single-tick CR-share:<br>**Open** → acts like a CR-share over a 1-tick band<br>**Filled** → instantly converts to idle raw tokens and ceases to be “shares” |

3. **Borrow** – Only FR-shares can be borrowed.  
4. **Repay** – Return idle FR-shares *or* deposit tokens (hook mints and retires FR-shares).  
5. **Liquidation** – If LTV is too high, idle tokens/shares are seized and burned.

A mandatory full-range block guarantees  

$$
x y = K,\qquad \sqrt{K} = \sqrt{x y}.
$$

---

## B. Collateral Types & Uses

| Raw vault asset | Optional allocations                | Solvency valuation  | Extra risk metric |
|-----------------|-------------------------------------|---------------------|-------------------|
| **Asset A**     | idle / mint FR / mint CR / place LO | 1 : 1 face value    | —                 |
| **Asset B**     | idem                                | face value         | —                 |

---

## C. Pool Geometry

### C.1 Full-range block

| Symbol             | Definition                            |
|--------------------|---------------------------------------|
| $(x,y)$            | reserves of A & B in the full-range position |
| $L_{\text{FR}}$    | v4 liquidity (= $\sqrt{K}$)           |
| $S_{\text{FRtot}}$ | total FR-shares                      |

One FR-share represents  

$$
\frac{x}{S_{\text{FRtot}}}A + \frac{y}{S_{\text{FRtot}}}B
$$

### C.2 Finite-range (or limit-order) position *i*

| Symbol                                 | Definition                                       |
|----------------------------------------|--------------------------------------------------|
| $[\underline{P}_i,\overline{P}_i]$     | lower / upper price bound (B per A)              |
| $a_i=\sqrt{\underline{P}_i}, b_i=\sqrt{\overline{P}_i}$ | √-price bounds (LO: $a_i=b_i$)       |
| $L_i$                                  | v4 liquidity contributed                         |
| $S_{\text{CR},i}$                      | shares issued                                    |

Filled LO-shares have $L_i=0$; shares auto-burn, user holds tokens.

---

## D. User State

| Field                   | Unit            | Meaning                     |
|-------------------------|-----------------|-----------------------------|
| `sharesBorrowed`        | FR-shares       | debt                        |
| `shareMultiplier`       | $1\times10^{18}$ | compounding factor          |
| `assetA_Vault`, `assetB_Vault` | tokens  | idle (includes filled LOs)   |
| `sharesFR_Vault`        | FR-shares       | minted from own tokens       |
| `sharesCR_Vault[i]`     | CR-shares       | each finite range *i*        |
| `sharesLO_Open[j]`      | LO-shares       | open single-tick orders      |

---

## E. Token Equivalents of Idle Shares

### E.1 Full-range shares  

$$
\boxed{
x_{S,\mathrm{FR}} = \frac{\text{sharesFRVault}\,x}{S_{\text{FRtot}}},
\qquad
y_{S,\mathrm{FR}} = \frac{\text{sharesFRVault}\,y}{S_{\text{FRtot}}}
}
\tag{1}
$$

### E.2 Finite-range share *i* (spot $P$, $\sigma=\sqrt{P}$)

$$
\boxed{
\Delta A_i =
\begin{cases}
0 & P \ge \overline{P}_i\\
\dfrac{L_i(b_i-\sigma)}{\sigma\,b_i} & a_i \le P \le b_i\\
\dfrac{L_i(b_i-a_i)}{a_i\,b_i} & P \le \underline{P}_i
\end{cases}
}
\tag{2}
$$

$$
\boxed{
\Delta B_i =
\begin{cases}
L_i(\sigma-a_i) & a_i \le P \le b_i\\
L_i(b_i-a_i) & P \ge \overline{P}_i\\
0 & P \le \underline{P}_i
\end{cases}
}
\tag{3}
$$

*Open LO ($a_i=b_i$) collapses to 1-tick form; filled LO ($L_i=0$) gives $\Delta A_i=\Delta B_i=0$.*

$$
\boxed{
x_{S,\mathrm{CR}} =
\sum_{i\in\mathrm{CR}}\Delta A_i +
\sum_{j\in\mathrm{LO\text{-}open}}\Delta A_j
},
\qquad
\boxed{
y_{S,\mathrm{CR}} =
\sum_{i\in\mathrm{CR}}\Delta B_i +
\sum_{j\in\mathrm{LO\text{-}open}}\Delta B_j
}
\tag{4}
$$

---

## F. Worst-Case Exposure of CR / Open-LO Shares

$$
\boxed{
A^{\max}_i = \frac{L_i(b_i-a_i)}{a_i\,b_i},
\qquad
B^{\max}_i = L_i(b_i-a_i)
}
\tag{5}
$$

$$
\boxed{\mathrm{WorstA} = \sum_{i \in (\mathrm{CR}\cup \mathrm{LO_{open}})} A^{\max}_i}
$$

$$
\boxed{\mathrm{WorstB} = \sum_{i \in (\mathrm{CR}\cup \mathrm{LO_{open}})} B^{\max}_i}
$$

---

## G. Collateral, Debt & LTV

$$
A_{\text{tot}} = \text{assetAVault} + x_{S,\mathrm{FR}} + x_{S,\mathrm{CR}},
\qquad
B_{\text{tot}} = \text{assetBVault} + y_{S,\mathrm{FR}} + y_{S,\mathrm{CR}}
$$

$$
\boxed{C = \sqrt{A_{\text{tot}}\,B_{\text{tot}}}}
\tag{7}
$$

$$
\boxed{D = \dfrac{\text{sharesBorrowed}\,\text{shareMultiplier}}{10^{18}}}
\tag{8}
$$

$$
\boxed{
L =
\begin{cases}
0 & D=0\\
\dfrac{D}{C} & D>0
\end{cases}
}
\tag{9}
$$

---

## H. Interest Accrual

$$
\boxed{
U = \frac{\sum D}{L_{\text{FR,balance}} + \sum D},
\qquad U \le 0.95
}
\tag{10}
$$

$$
\boxed{
\Delta M = \text{shareMultiplier}\,r(U)\,\tfrac{\Delta t}{10^{18}},
\qquad
\text{shareMultiplier} \leftarrow \text{shareMultiplier} + \Delta M
}
\tag{11}
$$

Protocol fee = $f\,\Delta M\,\sum D / 10^{18}$.

---

## I. Borrow / Repay (Full-Range Shares Only)

Borrow *s* FR-shares  

$$
\boxed{
\Delta x = \tfrac{s\,x}{S_{\text{FRtot}}},
\qquad
\Delta y = \tfrac{s\,y}{S_{\text{FRtot}}}
}
\tag{12}
$$

Repay *s* FR-shares by returning shares or depositing tokens ($\Delta x,\Delta y$).

---

## J. Mint / Burn of CR-shares & Limit Orders

* **Mint CR / place LO-open** – consume tokens, create $L_i$, issue shares, add $A^{\max}_i,B^{\max}_i$.  
* **Burn CR / cancel LO-open** – reverse tokens & ledgers.  
* **LO fills** – shares auto-burn, tokens credited, ledgers shrink.

---

## K. Solvency & Liquidation

| LTV $L$    | Response                      |
|------------|-------------------------------|
| $L<0.98$   | healthy                       |
| $0.98\le L<0.99$ | seize $p(L)$ fraction of debt |
| $L\ge0.99$ | up to 100 % seizure            |

\[
 p(L) =
 \begin{cases}
 0.0025 & \text{if } L = 0.98\\[4pt]
 0.2 + 0.8\dfrac{L-0.985}{0.005} & \text{if } 0.985 < L < 0.99\\[4pt]
 1 & \text{if } L \ge 0.99
 \end{cases}
 \tag{13}
\]

---

## L. System Worst-Case Guard

$$
\boxed{\text{NetA} \ge \text{WorstA}, \qquad \text{NetB} \ge \text{WorstB}}
\tag{14}
$$

NetA/B = on-chain reserves + idle tokens + current value of CR and open LO shares.

---

## M. Additional Safeguards

1. Utilisation cap $U\le0.95$.  
2. No negative balances.  
3. Spot–TWAP price deviation bound.  
4. Forced swap ≤ $1/350$ reserves.  
5. Smooth penalty curves — no cliffs.

---

## N. Key Mathematical Motifs

* Constant-product core via full-range block.  
* Flexible allocation to FR, CR, or single-tick limit orders.  
* Geometric-mean collateral; debt in $\sqrt{K}$ units; exponential growth via global multiplier.  
* Worst-case ledgers fence asymmetric risk; shrink on LO fills.  
* Convex liquidation curve & utilisation-driven rates stabilize leverage demand.
