# Concentrated-Liquidity Borrow-Lend — Complete Math Specification

*Uniswap v4 hook with one full-range position; users deposit raw tokens then allocate them into full-, finite-, or limit-order liquidity. Borrowing remains full-range shares only.*

---

## A. Process Flow

1. **Deposit** – A user moves raw **Asset A** and/or **Asset B** into their vault.  
2. **Allocation** – Vault tokens can be routed into three liquidity flavours:

   | Allocation | Characteristics |
   |------------|-----------------|
   | **FR-shares** | Full-range; spans every price → classic constant-product block |
   | **CR-shares** | Finite range `$[\underline{P},\overline{P}]$`; behaves like a Uniswap v4 LP |
   | **LO-shares** | Limit-order = single-tick CR-share:<br>**Open** → acts like a CR-share over a 1-tick band<br>**Filled** → instantly converts to idle raw tokens and ceases to be “shares” |

   Tokens exit the vault and the vault now records the new shares (or, for a filled limit order, extra tokens).  
3. **Borrow** – Only **FR-shares** can be borrowed.  
4. **Repay** – Debt is repaid  
   * by returning idle **FR-shares**, or  
   * by depositing vault tokens, which the hook converts into new **FR-shares** and immediately retires.  
5. **Liquidation** – If a vault’s LTV breaches limits, the engine seizes idle tokens and/or idle shares, burning seized shares to extract tokens.  
   * open **LO-shares** → burned as shares  
   * filled **LO-shares** → already idle tokens  

A mandatory full-range block guarantees the global pool always satisfies  

```latex
$$x\,y = K,\qquad \sqrt{K} = \sqrt{x\,y}.$$


⸻

B. Collateral Types & Uses

Raw vault asset	Optional allocations	Solvency valuation	Extra risk metric
Asset A	idle / mint FR / mint CR / place LO	1 : 1 face value	—
Asset B	idem	face value	—

	•	Shares receive no haircut because they can be burned in one transaction to regain raw tokens that directly repay debt.
	•	CR-shares and open LO-shares carry asymmetric tail risk; the protocol tracks a worst-case single-asset ledger (§ F).

⸻

C. Pool Geometry

C.1 Full-range block

Symbol	Definition
$(x,y)$	reserves of A & B in the full-range position
$L_{\text{FR}}$	v4 liquidity (= $\sqrt{K}$)
$S_{\text{FR_tot}}$	total FR-shares

One FR-share represents

$$\frac{x}{S_{\text{FR\_tot}}}\,A \;+\; \frac{y}{S_{\text{FR\_tot}}}\,B$$


⸻

C.2 Finite-range (or limit-order) position i

Symbol	Definition
$[\underline{P}_i,\overline{P}_i]$	lower / upper price bound (B per A)
$a_i=\sqrt{\underline{P}_i},; b_i=\sqrt{\overline{P}_i}$	√-price bounds (for LO: $a_i=b_i$)
$L_i$	v4 liquidity contributed
$S_{\text{CR},i}$	shares issued

Filled LO-shares have $L_i=0$; the shares are burned and the user just holds tokens.

⸻

D. User State

Field	Unit	Meaning
sharesBorrowed	FR-shares	debt
shareMultiplier	$1\times10^{18}$	compounding factor
assetA_Vault, assetB_Vault	tokens	idle (includes tokens from filled LOs)
sharesFR_Vault	FR-shares	minted from own tokens
sharesCR_Vault[i]	CR-shares	each finite range i
sharesLO_Open[j]	LO-shares	single-tick orders not yet filled

(Filled LO-shares no longer exist — they are replaced by idle tokens.)

⸻

E. Token Equivalents of Idle Shares

E.1 Full-range shares

$begin:math:display$
\\boxed{
x_{S,\\mathrm{FR}} = \\tfrac{\\text{sharesFR\\_Vault}\\,x}{S_{\\text{FR\\_tot}}},
\\qquad
y_{S,\\mathrm{FR}} = \\tfrac{\\text{sharesFR\\_Vault}\\,y}{S_{\\text{FR\\_tot}}}}
\\tag{1}
$end:math:display$

E.2 Finite-range share i (spot price $P$, $\sigma=\sqrt{P}$)

$begin:math:display$
\\boxed{
\\Delta A_i =
\\begin{cases}
0 & P \\ge \\overline{P}_i\\\\
\\dfrac{L_i(b_i-\\sigma)}{\\sigma\\,b_i} & a_i \\le P \\le b_i\\\\
\\dfrac{L_i(b_i-a_i)}{a_i\\,b_i} & P \\le \\underline{P}_i
\\end{cases}}
\\tag{2}
$end:math:display$

$begin:math:display$
\\boxed{
\\Delta B_i =
\\begin{cases}
L_i(\\sigma-a_i) & a_i \\le P \\le b_i\\\\
L_i(b_i-a_i) & P \\ge \\overline{P}_i\\\\
0 & P \\le \\underline{P}_i
\\end{cases}}
\\tag{3}
$end:math:display$

	•	For an open limit order ($a_i=b_i$) the two cases collapse to the 1-tick formulas.
	•	For a filled limit order $L_i=0$, so $\Delta A_i=\Delta B_i=0$; the tokens are already idle.

$begin:math:display$
\\boxed{
x_{S,\\mathrm{CR}} =
\\sum_{i\\in\\mathrm{CR}}\\!\\Delta A_i +
\\sum_{j\\in\\mathrm{LO\\text{-}open}}\\!\\Delta A_j},
\\qquad
\\boxed{
y_{S,\\mathrm{CR}} =
\\sum_{i\\in\\mathrm{CR}}\\!\\Delta B_i +
\\sum_{j\\in\\mathrm{LO\\text{-}open}}\\!\\Delta B_j}
\\tag{4}
$end:math:display$
