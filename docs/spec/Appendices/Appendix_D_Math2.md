# Concentrated-Liquidity Borrow-Lend — Complete Math Specification

Uniswap v4 hook with one full-range position; users deposit raw tokens then allocate them into full-, finite-, or limit-order liquidity. Borrowing remains full-range shares only.

⸻

## A. Process Flow

Plain-language summary: think of one vault per user. Deposit raw tokens (step 1); allocate them into full-range, finite-range or 1-tick limit-order liquidity (step 2); borrow only full-range shares (step 3); repay by returning those shares or the equivalent tokens (step 4); and if loan-to-value is too high the engine seizes idle assets (step 5). The full-range block enforces Uniswap’s constant-product $x\,y=K$ so $\sqrt{K}$ becomes the natural collateral / debt unit.

1. **Deposit** – move raw Asset A and/or Asset B into the vault.  
2. **Allocation** – route vault tokens into three liquidity flavours:

   | Allocation | Characteristics |
   | ---------- | --------------- |
   | **FR-shares** | Full-range; spans every price → classic constant-product block |
   | **CR-shares** | Finite range $[\underline{P},\overline{P}]$; behaves like a Uniswap v4 LP |
   | **LO-shares** | Limit-order = single-tick CR-share:<br>Open → acts like a CR-share over a 1-tick band<br>Filled → instantly converts to idle raw tokens and ceases to be “shares” |

3. **Borrow** – only FR-shares can be borrowed.  
4. **Repay** – return idle FR-shares or deposit tokens (hook mints and retires FR-shares).  
5. **Liquidation** – if LTV is too high, idle tokens/shares are seized and burned.

A mandatory full-range block guarantees  

$$
x\,y = K, \qquad \sqrt{K} = \sqrt{x\,y}.
$$

*Derivation.* In a constant-product AMM, any swap or liquidity change adjusts $x$ and $y$ such that the product remains constant. For example, if asset A increases by $\Delta x$ and asset B decreases by $\Delta y$, the pool enforces  

$$
(x + \Delta x)(y - \Delta y) \;=\; x\,y,
$$

so $x\,y = K$ at all times. Solving for a small incoming amount $\Delta x$ yields  

$$
\Delta y \;=\; y \;-\; \frac{x y}{x + \Delta x}
           \;=\; \frac{y\,\Delta x}{x + \Delta x},
$$

demonstrating that the reserves adjust to maintain $x\,y = K$. In a full-range position spanning all prices one may write reserves in terms of Uniswap liquidity $L_{\text{FR}}$ and the current √-price $\sigma=\sqrt{P}$: $x = L_{\text{FR}}/\sigma$ and $y = L_{\text{FR}}\,\sigma$, giving $x\,y = L_{\text{FR}}^{2}$, hence  

$$
L_{\text{FR}} = \sqrt{x y}\,.
$$

so the full-range liquidity **is** $\sqrt{K}$.

*Implementation note.* The full-range pool’s reserves $x$ and $y$ are read directly from the AMM. The constant $K$ need not be stored; swaps preserve $x\,y = K$. The quantity $L_{\text{FR}}=\sqrt{x\,y}$ can be computed on-chain if needed or read from pool state.

⸻

## B. Collateral Types & Uses

Idle raw tokens count 1-for-1 toward solvency. Wrapping them into FR/CR/LO shares doesn’t apply haircuts at this layer; risk differentiation happens later via worst-case ledgers.

| Raw vault asset | Optional allocations                           | Solvency valuation | Extra risk metric |
| --------------- | ---------------------------------------------- | ------------------ | ----------------- |
| Asset A         | idle / mint FR / mint CR / place LO            | 1 : 1 face value   | —                 |
| Asset B         | idem                                           | 1 : 1 face value   | —                 |

⸻

## C. Pool Geometry

* **Full-range block:** reserves $x,y$ already satisfy $L_{\mathrm{FR}}=\sqrt{K}$. Each FR-share is a parcel $x/S_{\mathrm{FRtot}}\,A + y/S_{\mathrm{FRtot}}\,B$.  
* **Finite-range position:** liquidity $L_i$ lives between prices $[a_i^{2},b_i^{2}]$. Shares $S_{\mathrm{CR},i}$ track ownership. A 1-tick limit order is the special case $a_i=b_i$; when filled, liquidity goes to zero and shares auto-burn.

### C.1 Full-range block

| Symbol | Definition |
| ------ | ---------- |
| $(x,y)$ | reserves of A & B in the full-range position |
| $L_{\text{FR}}$ | v4 liquidity (= $\sqrt{K}$) |
| $S_{\text{FRtot}}$ | total FR-shares |

One FR-share represents  

$$
\frac{x}{S_{\text{FRtot}}}\,A \;+\; \frac{y}{S_{\text{FRtot}}}\,B.
$$

### C.2 Finite-range (or limit-order) position $i$

| Symbol | Definition |
| ------ | ---------- |
| $[\underline{P}_i,\overline{P}_i]$ | lower / upper price bound (B per A) |
| $a_i=\sqrt{\underline{P}_i},\;b_i=\sqrt{\overline{P}_i}$ | √-price bounds (LO: $a_i=b_i$) |
| $L_i$ | v4 liquidity contributed |
| $S_{\text{CR},i}$ | shares issued |

Filled LO-shares have $L_i=0$; shares auto-burn, user holds tokens.

⸻

## D. User State

| Field | Unit | Meaning |
| ----- | ---- | ------- |
| `sharesBorrowed` | FR-shares | debt |
| `shareMultiplier` | $1\times10^{18}$ | compounding factor |
| `assetA_Vault`, `assetB_Vault` | tokens | idle (includes filled LOs) |
| `sharesFR_Vault` | FR-shares | minted from own tokens |
| `sharesCR_Vault[i]` | CR-shares | each finite range $i$ |
| `sharesLO_Open[j]` | LO-shares | open single-tick orders |

⸻

## E. Token Equivalents of Idle Shares

### E.1 Full-range shares

$$
\boxed{
x_{S,\mathrm{FR}} = \frac{\text{sharesFRVault}\,x}{S_{\text{FRtot}}},
\qquad
y_{S,\mathrm{FR}} = \frac{\text{sharesFRVault}\,y}{S_{\text{FRtot}}}
}\tag{1}
$$

### E.2 Finite-range share $i$  (spot $P$, $\sigma=\sqrt{P}$)

$$
\boxed{
\Delta A_i =
\begin{cases}
0 & P \ge \overline{P}_i\\
\dfrac{L_i\,(b_i-\sigma)}{\sigma b_i} & a_i \le P \le b_i\\
\dfrac{L_i\,(b_i-a_i)}{a_i b_i} & P \le \underline{P}_i
\end{cases}
}\tag{2}
$$

$$
\boxed{
\Delta B_i =
\begin{cases}
L_i\,(\sigma-a_i) & a_i \le P \le b_i\\
L_i\,(b_i-a_i) & P \ge \overline{P}_i\\
0 & P \le \underline{P}_i
\end{cases}
}\tag{3}
$$

Open LO ($a_i=b_i$) collapses to 1-tick form; filled LO ($L_i=0$) gives $\Delta A_i=\Delta B_i=0$.

Aggregating all CR bands and open LOs:

$$
\boxed{
x_{S,\mathrm{CR}} =
\sum_{i\in\mathrm{CR}}\!\Delta A_i +
\sum_{j\in\mathrm{LO\text{-}open}}\!\Delta A_j
},\qquad
\boxed{
y_{S,\mathrm{CR}} =
\sum_{i\in\mathrm{CR}}\!\Delta B_i +
\sum_{j\in\mathrm{LO\text{-}open}}\!\Delta B_j
}\tag{4}
$$

⸻

## F. Worst-Case Exposure of CR / Open-LO Shares

$$
\boxed{
A^{\max}_i = \frac{L_i\,(b_i-a_i)}{a_i b_i},
\qquad
B^{\max}_i = L_i\,(b_i-a_i)
}\tag{5}
$$

$$
\boxed{
\text{WorstA} = \sum_{i\in(\mathrm{CR}\cup\mathrm{LO_{\text{open}}})} A^{\max}_i,
\qquad
\text{WorstB} = \sum_{i\in(\mathrm{CR}\cup\mathrm{LO_{\text{open}}})} B^{\max}_i
}\tag{6}
$$

⸻

## G. Collateral, Debt & LTV

$$
\boxed{C = \sqrt{A_{\text{tot}} B_{\text{tot}}}}\tag{7}
$$

$$
\boxed{D = \dfrac{\text{sharesBorrowed}\times\text{shareMultiplier}}{10^{18}}}\tag{8}
$$

$$
\boxed{
L=
\begin{cases}
0 & D = 0\\
\dfrac{D}{C} & D > 0
\end{cases}
}\tag{9}
$$

⸻

## H. Interest Accrual

$$
\boxed{
U = \frac{\sum D}{L_{\text{FR-balance}}+\sum D},
\qquad
U \le 0.95
}\tag{10}
$$

$$
\boxed{
\Delta M = \text{shareMultiplier}\,r(U)\,\frac{\Delta t}{10^{18}},
\qquad
\text{shareMultiplier} \;\leftarrow\; \text{shareMultiplier} + \Delta M
}\tag{11}
$$

⸻

## I. Borrow / Repay (Full-Range Shares Only)

Borrow $s$ FR-shares:

$$
\boxed{
\Delta x = \frac{s\,x}{S_{\text{FRtot}}},
\qquad
\Delta y = \frac{s\,y}{S_{\text{FRtot}}}
}\tag{12}
$$

⸻

## J. Mint / Burn of CR-shares & Limit Orders

* Mint CR / place LO-open – consume tokens, create $L_i$, issue shares, add $A^{\max}_i,B^{\max}_i$.  
* Burn CR / cancel LO-open – reverse tokens & ledgers.  
* LO fills – shares auto-burn, tokens credited, ledgers shrink.

⸻

## K. Solvency & Liquidation

| LTV $L$ | Response |
| ------- | -------- |
| $L<0.98$ | healthy |
| $0.98\le L<0.99$ | seize $p(L)$ fraction of debt |
| $L\ge0.99$ | up to 100 % seizure |

$$
\begin{aligned}
p(L)=\begin{cases}
0.0025 & L = 0.98\\
0.2 + 0.8\dfrac{L-0.985}{0.005} & 0.985 < L < 0.99\\
1 & L \ge 0.99
\end{cases}
\end{aligned}\tag{13}
$$

⸻

## L. System Worst-Case Guard

$$
\boxed{
\text{NetA} \ge \text{WorstA},
\qquad
\text{NetB} \ge \text{WorstB}
}\tag{14}
$$

⸻

## M. Additional Safeguards

1. Utilisation cap $U\le0.95$.  
2. No negative balances.  
3. Spot–TWAP price deviation bound.  
4. Forced swap ≤ $1/350$ reserves.  
5. Smooth penalty/interest curves — no cliffs.

⸻

## N. Key Mathematical Motifs

* Constant-product core via full-range block.  
* Flexible allocation to FR, CR, or single-tick limit orders.  
* Geometric-mean collateral; debt in $\sqrt{K}$ units; exponential growth via a global multiplier.  
* Worst-case ledgers fence asymmetric risk; shrink on LO fills.  
* Convex liquidation curve & utilisation-driven rates stabilize leverage demand.

⸻

## O. AMM Fundamentals & Constant-Product Proof

In a constant-product AMM the reserves satisfy $x\,y = \text{constant}$. For initial $(x,y)$ and a trade adding $\Delta x$ A and removing $\Delta y$ B,

$$
(x + \Delta x)(y - \Delta y) = x\,y.
$$

Thus $\sqrt{K} = \sqrt{x\,y}$ is invariant.

For a full-range Uniswap position covering $[0,\infty)$ with liquidity $L$ at price $P$ ($\sigma=\sqrt{P}$),

$$
x = \frac{L}{\sigma},\qquad y = L\,\sigma \;\;\Longrightarrow\;\; L = \sqrt{x\,y}.
$$

⸻

## P. Full-Range Borrow / Repay Equations

Borrowing $s$ FR-shares releases  

$$
\Delta x = \frac{s\,x}{S_{\text{FRtot}}},
\qquad
\Delta y = \frac{s\,y}{S_{\text{FRtot}}}.
$$

Repayment is the exact reverse.

⸻

## Q. Swap-Rebalancing Quadratic

Suppose a vault has $A_{\text{tot}}$ of A, $B_{\text{tot}}$ of B, debt $D$, and current LTV $L=D/\sqrt{A_{\text{tot}}B_{\text{tot}}}$.  
Swap $\Delta$ A for B at price $P$ to reach target $L_{\text{target}}$.

After the swap:

$$
C' = \sqrt{(A_{\text{tot}}-\Delta)\,(B_{\text{tot}}+P\,\Delta)},
\qquad
L_{\text{target}} = \frac{D}{C'}.
$$

Squaring and simplifying yields  

$$
\begin{aligned}
&(P\,L_{\text{target}}^{2})\,\Delta^{2}\\
&\quad-\bigl[L_{\text{target}}^{2}(A_{\text{tot}}P - B_{\text{tot}})\bigr] \, \Delta\\
&\quad-\bigl[L_{\text{target}}^{2}A_{\text{tot}}B_{\text{tot}} - D^{2}\bigr] = 0
\end{aligned}
$$

Hence

$$
\Delta =
\frac{
A_{\text{tot}}P - B_{\text{tot}}
\;\pm\;
\sqrt{
  L_{\text{target}}^{2}(A_{\text{tot}}P + B_{\text{tot}})^{2}
  {}- 4\,P\,D^{2}
}
}{
2\,P\,L_{\text{target}}
}.
$$

*(Choose the root that is non-negative and feasible for the vault.)*

⸻

## R. Interest-Multiplier Math

Continuous form:

$$
\frac{d}{dt}\,\text{shareMultiplier} = r(U)\,\text{shareMultiplier},
\qquad
\text{shareMultiplier}(t)=
\text{shareMultiplier}(0)\,
\exp\!\Bigl(\,\int_{0}^{t} r\bigl(U(\tau)\bigr)\,d\tau\Bigr).
$$

Discrete implementation uses Eq. (11).

⸻

## S. Exact Rounding Rules

1. **Debt (Eq. 8)** – round **up**:  

   $$
   D = \Bigl\lceil
         \frac{\text{sharesBorrowed}\times\text{shareMultiplier}}
              {10^{18}}
       \Bigr\rceil.
   $$

2. **Borrow outflow (Eq. 12)** – $\Delta x,\Delta y$ each **floored** to whole tokens.  
3. **Interest increment (Eq. 11)** – integer division by $10^{18}$ (error ≤ 1 unit).  
4. **Liquidation seize (Eq. 13)** – shares seized **ceiled** to avoid under-liquidation.  
5. **Worst-case ledger (Eq. 5)** – each $A^{\max}_i,B^{\max}_i$ **ceiled** to whole tokens.

Errors are ≤ 1 unit in every case.

⸻

## T. On-Chain Invariants

1. Utilisation cap $U\le0.95$.  
2. No negative balances.  
3. Spot–TWAP deviation bound.  
4. Forced swap ≤ $1/350$ reserves.  
5. Worst-case reserves: $\text{NetA}\ge\text{WorstA}$, $\text{NetB}\ge\text{WorstB}$.  
6. Smooth, cliff-free curves for $r(U)$ and $p(L)$.

⸻

### Appendix A. Analytics

#### Slippage Approximation

For input $\delta x\ll x$,

$$
\begin{aligned}
\delta y &= \frac{y\,\delta x}{x + \delta x}
           \;\approx\;
 y\!\left(\frac{\delta x}{x}
  {}- \Bigl(\tfrac{\delta x}{x}\Bigr)^{2}
  {}+ \Bigl(\tfrac{\delta x}{x}\Bigr)^{3}
  {}- \dots\right)
\end{aligned}\tag{16}
$$

#### LTV Sensitivity to Price

$$
\begin{aligned}
\frac{\partial L}{\partial P}
  &= -\,\frac{D}{2\,C^{3}}\,
    \Bigl(
      B_{\text{tot}}\,\frac{dA_{\text{tot}}}{dP}
      + A_{\text{tot}}\,\frac{dB_{\text{tot}}}{dP}
    \Bigr)
\end{aligned}\tag{17}
$$

#### Utilisation vs. APR

Per-second rate $r(U)$ ⇢ annual percentage rate:

$$
\begin{aligned}
\text{APR}(U)
  &= \bigl(e^{\,r(U)\times 31\,536\,000} - 1\bigr)\times 100\%
\end{aligned}\tag{18}
$$
