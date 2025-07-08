# Concentrated-Liquidity Borrow-Lend — Complete Math Specification
*Uniswap v4 hook with one full-range position; users deposit raw tokens then allocate them into full-, finite-, or limit-order liquidity. Borrowing remains full-range shares only.*

---

## A. Process Flow

1. **Deposit** – Move raw **Asset A** and/or **Asset B** into the vault.  
2. **Allocation** – Route vault tokens into three liquidity flavours:

   | Allocation | Characteristics |
   |------------|-----------------|
   | **FR-shares** | Full-range; spans every price → constant-product block |
   | **CR-shares** | Finite range `$[\underline{P},\overline{P}]$`; behaves like a Uniswap v4 LP |
   | **LO-shares** | Limit-order = single-tick CR-share:<br>• **Open** → acts like a CR-share over a 1-tick band<br>• **Filled** → instantly converts to idle raw tokens |

3. **Borrow** – Only FR-shares can be borrowed.  
4. **Repay** – Return idle FR-shares *or* deposit tokens (hook mints FR-shares and retires them).  
5. **Liquidate** – If LTV ≥ threshold, idle tokens/shares are seized and burned.

A mandatory full-range block guarantees  

```latex
$$x\,y = K,\qquad \sqrt{K} = \sqrt{x\,y}$$


⸻

B. Collateral Types & Uses

Raw vault asset	Optional allocations	Solvency valuation	Extra risk metric
Asset A	idle / mint FR / mint CR / place LO	face value 1 : 1	—
Asset B	ditto	face value	—


⸻

C. Pool Geometry

C.1 Full-range block

Symbol	Definition
$(x,y)$	reserves of A & B in the full-range position
$L_{\text{FR}}$	v4 liquidity (= $\sqrt{K}$)
$S_{\text{FR,tot}}$	total FR-shares

One FR-share represents

$$\frac{x}{S_{\text{FR,tot}}}\,A + \frac{y}{S_{\text{FR,tot}}}\,B$$

C.2 Finite-range (or limit-order) position i

Symbol	Definition
$[\underline{P}_i,\overline{P}_i]$	lower / upper price bound (B per A)
$a_i=\sqrt{\underline{P}_i},; b_i=\sqrt{\overline{P}_i}$	√-price bounds (LO: $a_i=b_i$)
$L_i$	v4 liquidity contributed
$S_{\text{CR},i}$	shares issued

Filled LO-shares have $L_i=0$ (shares burn, user holds tokens).

⸻

D. User State

Field	Unit	Meaning
sharesBorrowed	FR-shares	debt
shareMultiplier	$1\times10^{18}$	compounding factor
assetA_Vault, assetB_Vault	tokens	idle (includes filled LOs)
sharesFR_Vault	FR-shares	minted from own tokens
sharesCR_Vault[i]	CR-shares	each finite range i
sharesLO_Open[j]	LO-shares	open single-tick orders


⸻

E. Token Equivalents of Idle Shares

E.1 Full-range shares

\[
\boxed{
x_{S,\mathrm{FR}} = \frac{\text{sharesFR\_Vault}\,x}{S_{\text{FR,tot}}},
\qquad
y_{S,\mathrm{FR}} = \frac{\text{sharesFR\_Vault}\,y}{S_{\text{FR,tot}}}}
\tag{1}
\]

E.2 Finite-range share i (spot $P$, $\sigma=\sqrt{P}$)

$begin:math:display$
\\boxed{
\\Delta A_i =
\\begin{cases}
0 & P\\ge\\overline{P}_i\\\\[4pt]
\\dfrac{L_i(b_i-\\sigma)}{\\sigma\\,b_i} & a_i\\le P\\le b_i\\\\[4pt]
\\dfrac{L_i(b_i-a_i)}{a_i\\,b_i} & P \\le \\underline{P}_i
\\end{cases}}
\\tag{2}
$end:math:display$

$begin:math:display$
\\boxed{
\\Delta B_i =
\\begin{cases}
L_i(\\sigma-a_i) & a_i\\le P\\le b_i\\\\[4pt]
L_i(b_i-a_i) & P\\ge\\overline{P}_i\\\\[4pt]
0 & P\\le\\underline{P}_i
\\end{cases}}
\\tag{3}
$end:math:display$

Open LO ($a_i=b_i$) collapses to 1-tick form; filled LO ($L_i=0$) gives $\Delta A_i=\Delta B_i=0$.

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


⸻

F. Worst-Case Exposure of CR / Open-LO Shares

$begin:math:display$
\\boxed{
A^{\\max}_i = \\frac{L_i(b_i-a_i)}{a_i\\,b_i},
\\qquad
B^{\\max}_i = L_i(b_i-a_i)}
\\tag{5}
$end:math:display$

$begin:math:display$
\\boxed{
\\text{WorstA} = \\sum_{\\mathrm{CR+LO\\text{-}open}} A^{\\max}_i,
\\qquad
\\text{WorstB} = \\sum_{\\mathrm{CR+LO\\text{-}open}} B^{\\max}_i}
\\tag{6}
$end:math:display$


⸻

G. Collateral, Debt & LTV

$begin:math:display$
A_{\\text{tot}} = \\text{assetA\\_Vault}+x_{S,\\mathrm{FR}}+x_{S,\\mathrm{CR}},
\\qquad
B_{\\text{tot}} = \\text{assetB\\_Vault}+y_{S,\\mathrm{FR}}+y_{S,\\mathrm{CR}}
$end:math:display$

$begin:math:display$
\\boxed{C = \\sqrt{A_{\\text{tot}}\\,B_{\\text{tot}}}}
\\tag{7}
\\qquad
\\boxed{D = \\tfrac{\\text{sharesBorrowed}\\,\\text{shareMultiplier}}{10^{18}}}
\\tag{8}
$end:math:display$

$begin:math:display$
\\boxed{
L=
\\begin{cases}
0 & D=0\\\\
\\dfrac{D}{C} & D>0
\\end{cases}}
\\tag{9}
$end:math:display$


⸻

H. Interest Accrual

$begin:math:display$
\\boxed{
U=\\frac{\\sum D}{L_{\\text{FR,balance}}+\\sum D},
\\qquad U\\le0.95}
\\tag{10}
$end:math:display$

$begin:math:display$
\\boxed{
\\Delta M=\\text{shareMultiplier}\\,r(U)\\,\\tfrac{\\Delta t}{10^{18}},
\\qquad
\\text{shareMultiplier}\\leftarrow\\text{shareMultiplier}+\\Delta M}
\\tag{11}
$end:math:display$

Protocol fee = $f,\Delta M,\sum D / 10^{18}$.
