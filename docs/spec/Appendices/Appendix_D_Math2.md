Concentrated-Liquidity Borrow-Lend — Complete Math Specification

Uniswap v4 hook with one full-range position; users deposit raw tokens then allocate them into full-, finite-, or limit-order liquidity. Borrowing remains full-range shares only.

⸻

A. Process Flow

Plain-language summary: Think of one vault per user. Deposit raw tokens (step 1); allocate them into full-range, finite-range or 1-tick limit-order liquidity (step 2); borrow only full-range shares (step 3); repay by returning those shares or the equivalent tokens (step 4); and if loan-to-value is too high the engine seizes idle assets (step 5). The full-range block enforces Uniswap’s constant-product $x,y=K$ so $\sqrt{K}$ becomes the natural collateral / debt unit.
	1.	Deposit – Move raw Asset A and/or Asset B into the vault.
	2.	Allocation – Route vault tokens into three liquidity flavours:

Allocation	Characteristics
FR-shares	Full-range; spans every price → classic constant-product block
CR-shares	Finite range $[\underline{P},\overline{P}]$; behaves like a Uniswap v4 LP
LO-shares	Limit-order = single-tick CR-share: Open → acts like a CR-share over a 1-tick bandFilled → instantly converts to idle raw tokens and ceases to be “shares”

	3.	Borrow – Only FR-shares can be borrowed.
	4.	Repay – Return idle FR-shares or deposit tokens (hook mints and retires FR-shares).
	5.	Liquidation – If LTV is too high, idle tokens/shares are seized and burned.

A mandatory full-range block guarantees

x y = K,\qquad \sqrt{K} = \sqrt{x y}.

Derivation: In a constant-product AMM, any swap or liquidity change adjusts $x$ and $y$ such that the product remains constant. For example, if asset A increases by $\Delta x$ and asset B decreases by $\Delta y$, the pool enforces

(x + \Delta x)(y - \Delta y) = x y,

so that $x y = K$ at all times. Solving this relation for a small incoming amount $\Delta x$ yields

\Delta y = y - \frac{x y}{x + \Delta x} = \frac{y \Delta x}{x + \Delta x},

demonstrating that the reserves adjust to maintain $x y = K$. Taking the square root of the invariant gives $\sqrt{K} = \sqrt{x y}$. In a full-range position spanning all prices, one can also express the reserves in terms of the Uniswap liquidity $L_{\text{FR}}$ and current √-price $\sigma=\sqrt{P}$: $x = L_{\text{FR}}/\sigma$ and $y = L_{\text{FR}}\sigma$. It follows that $x y = L_{\text{FR}}^2$, so

L_{\text{FR}} = \sqrt{x y},

meaning the full-range liquidity is exactly $\sqrt{K}$.

Implementation Note: The full-range pool’s reserves $x$ and $y$ are read directly from the AMM (Uniswap v4 pool). The constant $K$ need not be stored explicitly; any token swap is executed against the pool contract, which automatically preserves $x y = K$. The quantity $L_{\text{FR}}=\sqrt{x y}$ (v4 liquidity) can be computed on-chain if needed (e.g. via Math.sqrt), or obtained from the pool’s internal liquidity state.

⸻

B. Collateral Types & Uses

Plain-language summary: Idle raw tokens count 1-for-1 toward solvency. Wrapping them into FR/CR/LO shares doesn’t apply haircuts at this layer; risk differentiation happens later via worst-case ledgers.

Raw vault asset	Optional allocations	Solvency valuation	Extra risk metric
Asset A	idle / mint FR / mint CR / place LO	1 : 1 face value	—
Asset B	idem	1 : 1 face value	—

⸻

C. Pool Geometry

Plain-language summary:
	•	Full-range block: reserves $x,y$ already satisfy $L_{\mathrm{FR}}=\sqrt{K}$. Each FR-share is a fixed parcel $x/S_{\mathrm{FRtot}},A + y/S_{\mathrm{FRtot}},B$.
	•	Finite-range position: liquidity $L_i$ lives between prices $[a_i^2,b_i^2]$. Shares $S_{\mathrm{CR},i}$ track ownership. A 1-tick limit order is just the special case $a_i=b_i$; when filled, liquidity goes to zero and shares auto-burn.

C.1 Full-range block

Symbol	Definition
$(x,y)$	reserves of A & B in the full-range position
$L_{\text{FR}}$	v4 liquidity (= $\sqrt{K}$)
$S_{\text{FRtot}}$	total FR-shares

One FR-share represents

\frac{x}{S_{\text{FRtot}}}A + \frac{y}{S_{\text{FRtot}}}B

Derivation: The entire full-range position (reserves $x,y$) is split into $S_{\text{FRtot}}$ equal shares. By definition, each share is entitled to an identical fraction $1/S_{\text{FRtot}}$ of the reserves. Multiplying the total $x$ (resp. $y$) by this fraction yields $x/S_{\text{FRtot}}$ units of A (resp. $y/S_{\text{FRtot}}$ units of B) per share, as stated.

Implementation Note: In the vault, a user’s FR-share balance is stored in sharesFR_Vault. The total supply of FR-shares $S_{\text{FRtot}}$ is tracked globally (e.g. by the pool contract or hook). The formula above is used implicitly whenever the vault converts between FR-shares and underlying tokens (e.g. on borrow or repay).

C.2 Finite-range (or limit-order) position i

Symbol	Definition
$[\underline{P}_i,\overline{P}_i]$	lower / upper price bound (B per A)
$a_i=\sqrt{\underline{P}_i}, b_i=\sqrt{\overline{P}_i}$	√-price bounds (LO: $a_i=b_i$)
$L_i$	v4 liquidity contributed
$S_{\text{CR},i}$	shares issued

Filled LO-shares have $L_i=0$; shares auto-burn, user holds tokens.

⸻

D. User State

Plain-language summary: Vault fields record raw tokens, each share flavour, borrowed FR-shares, and the global shareMultiplier that meters interest over time.

Field	Unit	Meaning
sharesBorrowed	FR-shares	debt
shareMultiplier	$1\times10^{18}$	compounding factor
assetA_Vault, assetB_Vault	tokens	idle (includes filled LOs)
sharesFR_Vault	FR-shares	minted from own tokens
sharesCR_Vault[i]	CR-shares	each finite range i
sharesLO_Open[j]	LO-shares	open single-tick orders

⸻

E. Token Equivalents of Idle Shares

Plain-language summary: Eq. (1) converts a vault’s FR-shares into current token amounts. Eqs. (2–3) do the same for each CR/LO band; Eq. (4) sums them so the vault’s synthetic token balances are always explicit.

E.1 Full-range shares

\boxed{
x_{S,\mathrm{FR}} = \frac{\text{sharesFRVault} \cdot x}{S_{\text{FRtot}}},
\qquad
y_{S,\mathrm{FR}} = \frac{\text{sharesFRVault} \cdot y}{S_{\text{FRtot}}}
}
\tag{1}

Derivation: If a vault owns sharesFR_Vault FR-shares, that is a fraction sharesFR_Vault / S_FRtot of the full-range pool. Multiplying that fraction by the pool’s current reserves $x$ and $y$ gives the equivalent token amounts attributable to the vault’s FR-shares. This yields $x_{S,\mathrm{FR}} = (\text{sharesFRVault}/S_{\text{FRtot}}) \cdot x$ and similarly for $y_{S,\mathrm{FR}}$, as stated in Eq. (1).

Implementation Note: In code, sharesFR_Vault holds the number of FR-shares in the vault. The total S_FRtot is tracked globally. Whenever the vault needs to compute the token value of its FR-shares (e.g. for solvency checks), it uses a formula equivalent to Eq. (1). (Integer division is used, truncating any fractional token; see rounding rules in Section S.)

E.2 Finite-range share i (spot $P$, $\sigma=\sqrt{P}$)

\boxed{
\Delta A_i =
\begin{cases}
0 & P \ge \overline{P}_i\\
\dfrac{L_i(b_i-\sigma)}{\sigma b_i} & a_i \le P \le b_i\\
\dfrac{L_i(b_i-a_i)}{a_i b_i} & P \le \underline{P}_i
\end{cases}
}
\tag{2}

\boxed{
\Delta B_i =
\begin{cases}
L_i(\sigma-a_i) & a_i \le P \le b_i\\
L_i(b_i-a_i) & P \ge \overline{P}_i\\
0 & P \le \underline{P}_i
\end{cases}
}
\tag{3}

Open LO ($a_i=b_i$) collapses to 1-tick form; filled LO ($L_i=0$) gives $\Delta A_i=\Delta B_i=0$.

Derivation: For a finite range position, the formulas can be derived from Uniswap v3’s liquidity mathematics. If the current price $P$ (with √-price $\sigma=\sqrt{P}$) lies between the bounds [$a_i^2,b_i^2$], the position holds both A and B. The amount of token A not yet converted (held above the current price) is found by integrating liquidity from $P$ up to the upper bound:

\Delta A_i = L_i\Big(\frac{1}{\sigma} - \frac{1}{b_i}\Big) = \frac{L_i(b_i - \sigma)}{\sigma b_i},

which matches the middle case of Eq. (2). At the upper bound $P=\overline{P}_i$ (i.e. $\sigma=b_i$), this $\Delta A_i$ goes to 0, consistent with the first case (all B, no A). At the lower bound $P=\underline{P}_i$ ($\sigma = a_i$), the formula gives $\Delta A_i = L_i(b_i - a_i)/(a_i b_i)$, which is exactly the third case (position entirely in A).

Similarly, the B component comes from liquidity below the current price. When $a_i \le \sigma \le b_i$,

\Delta B_i = L_i(\sigma - a_i),

the amount of B acquired from the lower bound up to price $P$. This yields the middle case of Eq. (3). At $\sigma=a_i$ (price at the lower bound), $\Delta B_i=0$ (third case, all A). At $\sigma=b_i$ (upper bound), $\Delta B_i = L_i(b_i - a_i)$, which matches the second case (position fully in B).

Implementation Note: Each finite-range position $i$ is recorded with its liquidity $L_i$ and price bounds $[a_i,b_i]$. Equations (2) and (3) are used when calculating the token amounts represented by that liquidity at the current price $P$ (for example, to compute a vault’s total assets or to settle a position on fill). On-chain, $a_i$ and $b_i$ may be stored as tick indices or as fixed-point sqrt-price values. The contract uses the same piecewise logic as above to determine $\Delta A_i$ and $\Delta B_i$, rounding down any fractional token results.

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

Derivation: Equation (4) simply sums the contributions of all finite-range and open LO positions in the vault. The total A-equivalent from all such positions is $x_{S,\mathrm{CR}}$, computed by summing each band’s $\Delta A_i$ (Eq. (2)). Likewise, $y_{S,\mathrm{CR}}$ adds up all $\Delta B_i$. These totals represent the net tokens currently “inside” the vault’s CR and open-LO shares.

Implementation Note: The engine computes $x_{S,\mathrm{CR}}$ and $y_{S,\mathrm{CR}}$ on the fly when needed (e.g. during collateral calculation or position updates). It iterates over each active CR position and open LO to accumulate $\Delta A_i$ and $\Delta B_i$. There are no dedicated storage variables for $x_{S,\mathrm{CR}}$ or $y_{S,\mathrm{CR}}$ – they are derived from the per-position data using formulas (2–4).

⸻

F. Worst-Case Exposure of CR / Open-LO Shares

Plain-language summary: Eq. (5) computes the maximum single-token exposure for each band; Eq. (6) aggregates them into WorstA/WorstB so the protocol always knows how many tokens it might suddenly owe.

\boxed{
A^{\max}_i = \frac{L_i(b_i-a_i)}{a_i b_i},
\qquad
B^{\max}_i = L_i(b_i-a_i)
}
\tag{5}

Derivation: $A^{\max}_i$ and $B^{\max}_i$ represent the worst-case token amounts for position $i$. If price falls to the lower bound (or below), position $i$ will be entirely in asset A, yielding

A^{\max}_i = \frac{L_i(b_i - a_i)}{a_i b_i},

which is exactly the third-case expression from Eq. (2). Similarly, if price rises to or above the upper bound, the position converts fully to B, giving

B^{\max}_i = L_i(b_i - a_i),

the second-case expression from Eq. (3). These formulas define the maximum amount of token A or token B that $i$ could require if the market moves adversely. (They are attained when the position is completely in one token.)

Implementation Note: Whenever a new CR position is minted or an LO is opened, the contract computes $A^{\max}_i$ and $B^{\max}_i$ for that position and adds them to global ledgers WorstA and WorstB. Conversely, burning a position or a filled LO removes its contribution. Thus WorstA/WorstB always reflect the sum of all active positions’ worst-case liabilities.

\boxed{\text{WorstA} = \sum_{i \in (\mathrm{CR}\cup \mathrm{LO_{\text{open}}})} A^{\max}_i,
\qquad
\text{WorstB} = \sum_{i \in (\mathrm{CR}\cup \mathrm{LO_{\text{open}}})} B^{\max}_i}
\tag{6}

Derivation: WorstA (resp. WorstB) is obtained by summing the $A^{\max}$ (resp. $B^{\max}$) values for every active CR or open-LO position. In other words, the protocol assumes each position simultaneously hits its worst-case (all A or all B) to determine how many tokens it might owe in total. Equation (6) performs this sum across all positions.

Implementation Note: WorstA and WorstB are stored as global variables that update whenever the underlying positions change (see above). These represent the total tokens the system would owe if all positions flipped entirely to asset A or entirely to asset B, respectively.

⸻

G. Collateral, Debt & LTV

Plain-language summary:
	1.	Eq. (7) converts total tokens into geometric-mean collateral $C$.
	2.	Eq. (8) expresses debt in $\sqrt{K}$ units via the global multiplier.
	3.	Eq. (9) gives LTV $L=D/C$ (or zero when no debt).

\boxed{C = \sqrt{A_{\text{tot}} B_{\text{tot}}}}
\tag{7}

Derivation: To measure a vault’s total collateral from two assets, a geometric mean is used. Given the total amounts $A_{\text{tot}}$ and $B_{\text{tot}}$ (summing idle tokens and all shares’ equivalents as in Eq. (4)), the collateral is defined as

C = \sqrt{A_{\text{tot}} B_{\text{tot}}}\,. 

This choice reflects the constant-product principle: if the vault’s assets were all placed in a full-range pool, $C$ would equal the pool’s liquidity (since $L=\sqrt{x y}$). Intuitively, $C$ increases symmetrically when both $A_{\text{tot}}$ and $B_{\text{tot}}$ grow, and remains unchanged if value is just shuffled between A and B.

Implementation Note: The contract computes $A_{\text{tot}}$ and $B_{\text{tot}}$ by summing the vault’s idle token balances and the token equivalents of all its FR/CR/LO shares (using Eqs. (1–4)). It then calculates $C = \sqrt{A_{\text{tot}} B_{\text{tot}}}$. Because $C$ is used as a divisor (in LTV), minor rounding is not critical; however, the implementation typically floors $C$ (i.e. slight underestimation) to be safe.

\boxed{D = \dfrac{\text{sharesBorrowed} \times \text{shareMultiplier}}{10^{18}}}
\tag{8}

Derivation: The raw debt is tracked as sharesBorrowed (the number of FR-shares borrowed). However, as time passes, interest accrues globally via shareMultiplier. Initially shareMultiplier = 10^{18} (a 1.0× scale factor). As interest accumulates, shareMultiplier grows, effectively increasing the debt owed for each borrowed share. Thus, the effective debt $D$ (in units of FR-share or $\sqrt{K}$ collateral units) is given by the product of sharesBorrowed and shareMultiplier (scaled down by $10^{18}$ to account for the multiplier’s fixed-point encoding). This yields Eq. (8).

Implementation Note: Equation (8) is implemented exactly as written: e.g. debtD = sharesBorrowed * shareMultiplier / 1e18. The division is integer division (Solidity truncates), meaning $D$ is rounded down by at most 1 wei (see Section S for rounding bounds). In practice, this negligible difference is inconsequential to LTV calculations.

\boxed{
L =
\begin{cases}
0 & D=0\\
\dfrac{D}{C} & D>0
\end{cases}
}
\tag{9}

Derivation: Loan-to-Value ratio $L$ is defined as debt divided by collateral. If the vault has no debt ($D=0$), $L$ is defined to be 0. Otherwise, $L = D/C$ as given in Eq. (9). This ratio increases if debt grows or collateral shrinks, and vice versa.

Implementation Note: The LTV calculation in code mirrors Eq. (9). If debtD is zero, LTV is set to 0 (avoiding division by zero). Otherwise, the contract divides debtD by the latest computed $C$. The result (a fixed-point fraction) is typically compared against thresholds (e.g. 0.98) to determine health or trigger liquidations.

⸻

H. Interest Accrual

Plain-language summary: Utilisation $U$ (Eq. 10) measures how much FR liquidity is lent out. The multiplier bumps by $\Delta M$ (Eq. 11) at a rate $r(U)$; everyone’s debt scales automatically.

\boxed{
U = \frac{\sum D}{L_{\text{FR-balance}} + \sum D},
\qquad U \le 0.95
}
\tag{10}

Derivation: The utilisation $U$ is defined as the fraction of full-range liquidity that is currently lent out. The numerator $\sum D$ is the total outstanding debt (in $\sqrt{K}$ units, i.e. sum of all borrowers’ $D$). The denominator is the sum of that debt plus the remaining unborrowed liquidity $L_{\text{FR-balance}}$ in the full-range pool. Thus $U = \frac{\text{lent}}{\text{lent + available}}$. A utilisation cap of 95% ($U \le 0.95$) is imposed to ensure at least 5% of FR liquidity is always free (this guards against extreme interest spikes or pool depletion).

Implementation Note: In code, L_FR_balance is derived from the pool’s current reserves and total liquidity (or equivalently, initial $L_{\text{FR}}$ minus borrowed liquidity). The quantity $\sum D$ (total debt) is tracked across all vaults. Before allowing a new borrow, the contract computes the prospective $U$ and reverts if it would exceed 0.95. The cap prevents nearly full utilisation, which could lead to runaway interest or zero liquidity for swaps.

\boxed{
\Delta M = \text{shareMultiplier} \cdot r(U) \cdot \tfrac{\Delta t}{10^{18}},
\qquad
\text{shareMultiplier} \leftarrow \text{shareMultiplier} + \Delta M
}
\tag{11}

Derivation: The global interest factor shareMultiplier accrues continuously based on utilisation. In a continuous model, one would write the differential equation $\frac{dM}{dt} = r(U),M$, whose solution is exponential growth $M(t) = M(0)e^{r(U)t}$. The implementation simulates this by discrete steps: for a small time interval $\Delta t$, it increases the multiplier by

\Delta M = M \cdot r(U) \cdot \Delta t,

which is Eq. (11) (here $M$ denotes the current shareMultiplier). The division by $10^{18}$ in $\Delta M$ converts the fixed-point rate to the proper scale. All outstanding debts $D$ scale up proportionally when shareMultiplier increases, so interest is applied evenly to all borrowers.

Implementation Note: The contract typically updates shareMultiplier in each block or upon certain actions. It computes $\Delta M$ using the current $r(U)$ (from a predefined utilisation-rate curve) and the elapsed time $\Delta t$ (in seconds, scaled by $10^{18}$). After adding $\Delta M$ to shareMultiplier, it may also take a protocol fee (a fraction $f$ of $\Delta M$, applied to $\sum D$). The continuous compounding approximation is very accurate for small $\Delta t$, and the utilisation cap ensures $r(U)$ remains bounded.

⸻

I. Borrow / Repay (Full-Range Shares Only)

Plain-language summary: Eq. (12) shows the exact token amounts behind $s$ borrowed FR-shares; repayment is simply the reverse transfer or share return.

Borrow $s$ FR-shares

\boxed{
\Delta x = \tfrac{s \cdot x}{S_{\text{FRtot}}},
\qquad
\Delta y = \tfrac{s \cdot y}{S_{\text{FRtot}}}
}
\tag{12}

Derivation: When a vault borrows $s$ full-range shares, it is removing $s/S_{\text{FRtot}}$ of the full-range liquidity. As derived in Section C.1, each share corresponds to $\frac{x}{S_{\text{FRtot}}}$ of asset A and $\frac{y}{S_{\text{FRtot}}}$ of asset B. Therefore, borrowing $s$ shares releases

\Delta x = \frac{s}{S_{\text{FRtot}}} \cdot x,

and

\Delta y = \frac{s}{S_{\text{FRtot}}} \cdot y.

This is exactly what Eq. (12) expresses. Conversely, to repay $s$ FR-shares, the vault must return the same amounts $\Delta x,\Delta y$ (either by transferring in those tokens, or by directly returning $s$ FR-shares which the hook then retires).

Implementation Note: In the hook implementation, borrowing $s$ FR-shares involves minting $s$ new FR-shares to the borrower and sending out $\Delta x$ of asset A and $\Delta y$ of asset B from the pool. The vault’s sharesBorrowed increases by $s$. To repay, the user either returns $s$ FR-shares (which are burned, reducing sharesBorrowed), or supplies the $\Delta x,\Delta y$ tokens back into the pool (in which case the hook mints and burns $s$ shares internally to cancel out the debt).

⸻

J. Mint / Burn of CR-shares & Limit Orders

Plain-language summary: Minting CR/LO shares consumes idle tokens and enlarges WorstA/WorstB; burning or an LO fill does the opposite.
	•	Mint CR / place LO-open – consume tokens, create $L_i$, issue shares, add $A^{\max}_i,B^{\max}_i$.
	•	Burn CR / cancel LO-open – reverse tokens & ledgers.
	•	LO fills – shares auto-burn, tokens credited, ledgers shrink.

⸻

K. Solvency & Liquidation

Plain-language summary: The table defines actions by LTV bands. Eq. (13) gives a smooth, convex seizure fraction $p(L)$ so liquidations begin gently and ramp to 100% as $L \to 1$.

LTV $L$	Response
$L<0.98$	healthy
$0.98\le L<0.99$	seize $p(L)$ fraction of debt
$L\ge0.99$	up to 100 % seizure

p(L)=\begin{cases}
0.0025 & \text{if } L = 0.98\\
0.2 + 0.8\dfrac{L-0.985}{0.005} & \text{if } 0.985 < L < 0.99\\
1 & \text{if } L \ge 0.99
\end{cases}
\tag{13}

Derivation: The liquidation penalty function $p(L)$ is defined piecewise to smoothly increase from a very small value to 100% as LTV approaches 1. At $L=0.98$, $p(L)=0.0025$ (0.25% of the debt is seized). For $0.985 < L < 0.99$, $p(L)$ rises linearly from 20% to 100% over that narrow range. In particular, at $L=0.985$, the formula gives $p(0.985)=0.2$ (20% seize), and at $L=0.99$ it gives $p(0.99)=1$ (100% seize). For $L \ge 0.99$, the maximum 100% of debt is seized (full liquidation). This piecewise convex shape ensures liquidations start gently (only a tiny fraction at $L=0.98$) and rapidly escalate as LTV nears 1.

Implementation Note: The contract implements $p(L)$ according to the cases in Eq. (13). In practice, if a vault’s LTV enters the $0.98$–$0.99$ band, the engine seizes a fraction $p(L)$ of its debt (and equivalent collateral) to bring LTV down. Because $p(L)$ is continuous on $(0.985,0.99)$ and capped at 100%, liquidations avoid sudden jumps and never exceed the debt amount.

⸻

L. System Worst-Case Guard

Plain-language summary: Eq. (14) asserts the system’s on-chain reserves (NetA/NetB) always cover the WorstA/WorstB ledgers — even after any state change.

\boxed{\text{NetA} \ge \text{WorstA}, \qquad \text{NetB} \ge \text{WorstB}}
\tag{14}

Derivation: “Net” reserves refers to all tokens the system currently holds (pool reserves plus idle vault balances plus the current token value of all CR/LO shares). The WorstA/B ledgers (from Eq. (6)) represent the maximum tokens the system could owe if all positions shift to one asset. Therefore, to remain solvent after any hypothetical extreme move, the system must maintain

\text{NetA} \ge \text{WorstA}, \quad \text{NetB} \ge \text{WorstB}\,. 

This inequality (Eq. (14)) is enforced after every operation to guarantee that, even in the worst case, there are enough reserves to cover all positions.

Implementation Note: On-chain, NetA and NetB are not explicitly stored as single variables. Instead, whenever an action is about to complete (e.g. a borrow, swap, or share mint/burn), the contract computes the latest NetA/NetB and WorstA/WorstB and checks that both inequalities in Eq. (14) hold. If not, the transaction reverts. This ensures that no state change can push the system into a potentially insolvent position.

⸻

M. Additional Safeguards

Plain-language summary: Caps utilisation at 95%, blocks negative balances, enforces price sanity, limits forced swaps to 0.29% of reserves, and uses smooth curves everywhere to avoid cliffs.
	1.	Utilisation cap $U\le 0.95$.
	2.	No negative balances.
	3.	Spot–TWAP price deviation bound.
	4.	Forced swap ≤ $1/350$ reserves.
	5.	Smooth penalty/interest curves — no cliffs.

⸻

N. Key Mathematical Motifs

Plain-language summary: Constant-product backbone, composable liquidity, geometric-mean collateral, single global interest multiplier, worst-case ledgers, and convex liquidation/rate curves together create a stable yet flexible lending-LP engine.
	•	Constant-product core via full-range block.
	•	Flexible allocation to FR, CR, or single-tick limit orders.
	•	Geometric-mean collateral; debt in $\sqrt{K}$ units; exponential growth via global multiplier.
	•	Worst-case ledgers fence asymmetric risk; shrink on LO fills.
	•	Convex liquidation curve & utilisation-driven rates stabilize leverage demand.

O. AMM Fundamentals & Constant-Product Proof

(This section provides additional background and proofs for the AMM model underlying full-range liquidity.)

Proof of constant-product invariant: In a constant-product AMM, the reserves $x$ and $y$ are always adjusted so that $x,y = \text{constant}$. Given initial reserves $(x,y)$, any trade that adds $\Delta x$ of asset A and removes $\Delta y$ of asset B will satisfy

(x + \Delta x)(y - \Delta y) = x y,

ensuring the product remains $K = x y$. Solving for the outgoing amount gives

\Delta y = \frac{y \Delta x}{x + \Delta x}\,,

which shows how the marginal price increases as more A is added (slippage). Because $x y = K$ is invariant, we also have $\sqrt{K} = \sqrt{x y}$ constant throughout.

Full-range liquidity as $\sqrt{K}$: Consider a full-range Uniswap position covering prices $[0,\infty)$. Let $L$ be its liquidity (Uniswap’s internal measure) and let the current price be $P$ (with $\sigma=\sqrt{P}$). It is known that the amounts of A and B in such a position are

x = \frac{L}{\sigma}, \qquad y = L\,\sigma\,.

From this one immediately finds $x,y = L^2$, or $L = \sqrt{x y}$. In other words, the liquidity $L$ of a full-range position equals $\sqrt{K}$. This justifies treating $\sqrt{K}$ (which we’ve denoted as $L_{\text{FR}}$) as the “collateral unit” or base amount of one full-range share.

P. Full-Range Borrow/Repay Equations

(This section re-derives the borrow/repay formula and connects it to the contract state variables.)

Recall from Eq. (12) that borrowing $s$ FR-shares releases

\Delta x = \frac{s x}{S_{\text{FRtot}}}, \qquad \Delta y = \frac{s y}{S_{\text{FRtot}}}\,. 

This result was obtained by noting that each FR-share represents $x/S_{\text{FRtot}}$ A and $y/S_{\text{FRtot}}$ B (Section C.1), so $s$ shares correspond to that fraction of the pool’s reserves.

When repaying $s$ FR-shares, the process is reversed: the borrower returns either the $s$ shares themselves or the equivalent $\Delta x$ and $\Delta y$ tokens. In the latter case, the hook uses the incoming tokens to mint $s$ new FR-shares and immediately burn them to cancel out the debt.

Implementation Note: In the contract, sharesBorrowed tracks the current borrowed share count for the vault. When a vault borrows, sharesBorrowed increases by $s$ and the pool transfers out $\Delta x,\Delta y$. On repayment, sharesBorrowed decreases by $s$, and the vault either loses $s$ FR-shares (returned to pool) or sends in $\Delta x,\Delta y` which the hook converts to $s$ shares (burning them and replenishing the pool reserves).

Q. Swap-Rebalancing Quadratic

(This section derives the quadratic equation for the asset swap needed to reach a target LTV, with an illustrative example.)

Suppose a vault has $A_{\text{tot}}$ of asset A and $B_{\text{tot}}$ of asset B (including idle and share-derived amounts), debt $D$, and current LTV $L = D/\sqrt{A_{\text{tot}} B_{\text{tot}}}$. We want to rebalance the vault by swapping some amount of one asset for the other, in order to achieve a new target LTV $L_{\text{target}}$.

Assume we swap out an amount $\Delta$ of asset A for asset B at the current price $P$ (B per A). After this swap, $A_{\text{tot}}$ decreases to $A_{\text{tot}}’ = A_{\text{tot}} - \Delta$ and $B_{\text{tot}}$ increases to $B_{\text{tot}}’ = B_{\text{tot}} + P,\Delta$. The new collateral will be

C’ = \sqrt{(A_{\text{tot}} - \Delta)(B_{\text{tot}} + P\,\Delta)}\,.

We require the new LTV $L’ = D/C’$ to equal the target, i.e. $L_{\text{target}} = D/C’$. Squaring both sides and clearing denominators yields a quadratic equation in $\Delta$:

L_{\text{target}}^2\,(A_{\text{tot}} - \Delta)\,(B_{\text{tot}} + P\,\Delta) = D^2\,.

Expanding and simplifying, this equation can be written in standard form as

(P L_{\text{target}}^2)\,\Delta^2 - \Big[L_{\text{target}}^2\,(A_{\text{tot}} P - B_{\text{tot}})\Big]\,\Delta - \Big[L_{\text{target}}^2 A_{\text{tot}} B_{\text{tot}} - D^2\Big] = 0\,.

Solving the quadratic for $\Delta$ gives:

\Delta = \frac{(A_{\text{tot}} P - B_{\text{tot}}) \pm \sqrt{\,L_{\text{target}}^2 (A_{\text{tot}} P + B_{\text{tot}})^2 - 4\,P\,D^2\,}}{2\,P\,L_{\text{target}}}\,. \tag{15}

In general, this yields two solutions, but only one will be a valid, nonnegative amount within the vault’s means. For example, if the vault currently holds much more A than B, the appropriate solution will be the smaller $\Delta$ (selling a relatively small portion of A for B). The other (larger) root would correspond to swapping so much A that the vault overshoots into being B-heavy, which is not the intended rebalancing route.

Example: A vault has $A_{\text{tot}}=150$ A, $B_{\text{tot}}=50$ B (at $P=1$ B/A), and debt $D=75$ (so initial $L \approx 0.866$). Suppose the target LTV is $0.80$. Plugging into the quadratic formula (15) gives two roots: $\Delta \approx 15.2$ or $\Delta \approx 84.8$. The feasible solution is $\Delta \approx 15.2$ A. Indeed, selling $\sim15.2$ A for B leaves $A_{\text{tot}}’=134.8$, $B_{\text{tot}}’=65.2$, and

C’ = \sqrt{134.8 \times 65.2} \approx 83.5\,,

yielding $L’ = 75/83.5 \approx 0.898$ (slightly below 0.90 after accounting for rounding). By contrast, the larger root (84.8 A) is not applicable because the vault doesn’t even have that much spare A (and it would overshoot to $L’\approx0.80$ only after swapping an extreme amount). In practice, the engine would choose the minimal swap that achieves or slightly exceeds the target LTV.

Implementation Note: The quadratic equation above can be solved in the contract to determine how much of one asset to swap for the other during vault rebalancing (for example, in an automated deleveraging or refinancing scenario). However, due to gas and complexity concerns, protocol implementations often approximate or iterate toward the solution rather than solving it exactly on-chain. Additionally, any on-chain rebalancing swap is limited in size (see Safeguard M.4): at most 0.29% of reserves per operation, to minimize price impact. Large rebalances can be done via multiple small swaps if needed.

R. Interest-Multiplier Math

(This section elaborates on how continuous interest translates into the discrete updates of shareMultiplier.)

Let $r(U)$ be the annualized borrowing rate as a function of utilisation (in fraction per second). In continuous time, the debt multiplier would satisfy

\frac{d}{dt}\,\text{shareMultiplier} = r(U)\,\text{shareMultiplier}\,,

with solution $\text{shareMultiplier}(t) = \text{shareMultiplier}(0),\exp!\Big(\int_0^t r\big(U(\tau)\big),d\tau\Big)$. Because the utilisation $U$ may change over time, the exponent integrates the rate curve over the path. The implementation, however, updates the multiplier in discrete increments per Eq. (11): each step $\Delta t$ applies a factor of $(1 + r(U)\Delta t)$.

For small $\Delta t$, the discrete compounding closely approximates the continuous solution. For example, if $U$ remains constant, after one year the multiplier grows by $\approx e^{r(U)\times 1 \text{yr}} - 1$. The utilisation-based rate $r(U)$ is typically an increasing convex function (e.g. low when $U$ is small and growing steeply as $U\to0.95$). This means interest accrues slowly when plenty of liquidity is available, and speeds up as utilisation approaches the cap.

Implementation Note: The contract defines a curve for $r(U)$ (for instance, it could start at a base rate at $U=0$ and ramp up sharply near $U=0.95$). Each time interest is accrued (e.g. once per block), the current utilisation is computed and plugged into $r(U)$ to determine the per-second rate. The shareMultiplier is then scaled up by $(1 + r(U)\Delta t)$. Optionally, a portion of the increment ($f$ percent) is diverted as protocol fee. Because $U$ is capped at 0.95, $r(U)$ remains bounded and the discrete updates remain stable.

S. Exact Rounding Rules

(This section lists the rounding conventions (floor/ceil) used in on-chain calculations, and proves the error in each case is at most 1 unit.)
	1.	Debt computation (Eq. 8): When converting sharesBorrowed * shareMultiplier into the debt $D$, the contract rounds up to avoid underestimating debt. In practice,

D = \frac{\text{sharesBorrowed} \times \text{shareMultiplier} + 10^{18} - 1}{10^{18}}\,,

which is the ceiling of the exact fraction. This ensures the recorded debt is at least the true value (at most 1 wei higher).

	2.	Borrow token outflow (Eq. 12): The amounts $\Delta x,\Delta y$ that a borrower receives are each floored to the nearest whole token unit. (The pool does not dispense fractional token units.) The borrower thus gets at most the exact proportional share, with any remainder (<1 unit) left in the pool. This conservative rounding means $x y$ might increase slightly after a borrow (since a tiny fraction of reserves wasn’t taken), but by less than 1 unit of each token.
	3.	Interest increment (Eq. 11): The interest update $\Delta M$ is calculated with integer division by $10^{18}$ (since $r(U)$ is scaled). This truncation means $\Delta M$ is up to $1$ (in multiplier units) smaller than the exact real value. Since the multiplier is scaled by $10^{18}$, an error of 1 in $\Delta M$ corresponds to a relative error of $10^{-18}$ per update — utterly negligible.
	4.	Liquidation seize fraction (Eq. 13): When determining the number of shares to seize for a given $p(L)$, the contract rounds up to ensure it seizes enough. For example, if $p(L)=0.25$ and the vault owes 7 shares, it computes sharesToSeize = \lceil 0.25 \times 7 \rceil = 2 shares. This may be up to 1 share more than the exact fraction, but never less (avoiding under-liquidation).
	5.	Worst-case ledger (Eq. 5): The values $A^{\max}_i$ and $B^{\max}_i$ for each position are each rounded up to the nearest whole token unit when added to the WorstA/WorstB ledgers. This slight overestimation (each by <1 token) ensures the WorstA/WorstB ledgers are not understated. Even if many positions are open, the cumulative worst-case ledgers overcount actual needs by at most the number of positions (typically small relative to total reserves).

Implementation Note: The use of ceilings in debt and liquidation calculations makes the system a tad conservative (overestimating debt or seized shares by at most 1 unit), which is a deliberate safety margin. Floors in output calculations ensure the protocol never gives out more tokens than it should. Overall, these rounding guards bound any numerical errors to within 1 base unit of the respective quantity, which is negligible in practice.

T. On-Chain Invariants

(This section formalizes the key require() conditions maintained by the contract, with a brief rationale for each.)
	1.	Utilisation cap: $U \le 0.95$. (No more than 95% of full-range liquidity may be lent out at any time, leaving a 5% buffer.)
	2.	No negative balances: $\text{assetA_Vault} \ge 0, \quad \text{assetB_Vault} \ge 0$, etc. (Token and share balances are never allowed to go negative, ensuring conservation of value.)
	3.	Price sanity bound: $|P_{\text{spot}} - P_{\text{TWAP}}| \le \varepsilon,P_{\text{TWAP}}$. (The current price must be within $\varepsilon$ of the time-weighted average price; prevents using an aberrant spot price for valuations.)
	4.	Limited forced swap: $\Delta x \le \frac{x}{350}$ and $\Delta y \le \frac{y}{350}$. (Any protocol-forced swap can involve at most ~0.29% of the pool’s reserves, limiting slippage and market impact.)
	5.	Worst-case reserve coverage: $\text{NetA} \ge \text{WorstA}, \quad \text{NetB} \ge \text{WorstB}$. (The system’s net reserves must always cover the worst-case total obligations of all positions — see Eq. (14).)
	6.	Smooth curves, no cliffs: (All rate and penalty functions — e.g. $r(U)$ and $p(L)$ — are chosen to be continuous and gradually varying, avoiding sudden jumps that could destabilize the protocol.)

NatSpec: Each invariant above corresponds to a require() check or design condition in the implementation. For example, before executing a borrow, the contract includes require(U <= 950000000000000000) (if $U$ is scaled by $1e18$) to enforce invariant 1. Invariant 5 is checked by the system-wide solvency condition (Eq. (14)), and invariant 6 is ensured by the functional forms of $p(L)$ and $r(U)$ (no step changes). These conditions guarantee the protocol operates within safe bounds at all times.

Appendix A. Analytics

Slippage Approximation

Even though the swap formula is exact, it can be insightful to expand it for small trades. Starting from the constant-product swap result for an input $\delta x$:

\delta y = \frac{y\,\delta x}{\,x + \delta x\,}\,,

we can perform a series expansion assuming $\delta x \ll x$. Using $\frac{1}{1+u} \approx 1 - u + u^2 - u^3 + \dots$, we get:

\delta y \approx y \Big(\frac{\delta x}{x} - \Big(\frac{\delta x}{x}\Big)^2 + \Big(\frac{\delta x}{x}\Big)^3 - \cdots\Big)\,. \tag{16}

The first term $y,\frac{\delta x}{x}$ corresponds to a trade at the initial price (no slippage). The higher-order terms show how output is reduced as trade size increases (slippage grows roughly with the square of trade fraction for small trades). Typically, the cubic and higher terms are very small unless $\delta x/x$ is not negligible.

LTV Sensitivity to Price

The vault’s LTV will change if the price of A relative to B moves, because the values of $A_{\text{tot}}$ and $B_{\text{tot}}$ (and hence $C=\sqrt{A_{\text{tot}} B_{\text{tot}}}$) shift. We can gauge this by differentiating $L = D/\sqrt{A_{\text{tot}} B_{\text{tot}}}$ with respect to price $P$ (treating debt $D$ as constant in the short term). Using $C=\sqrt{A_{\text{tot}}B_{\text{tot}}}$, one finds:

\frac{\partial L}{\partial P} = -\,\frac{D}{2\,C^3}\Big(B_{\text{tot}}\,\frac{dA_{\text{tot}}}{dP} + A_{\text{tot}}\,\frac{dB_{\text{tot}}}{dP}\Big)\,. \tag{17}

The sign of this derivative depends on the vault’s asset composition. If the vault holds relatively more of asset A, then $dA_{\text{tot}}/dP \approx 0$ (A count is stable) while $dB_{\text{tot}}/dP < 0$ (B portion falls as price rises), making the term in parentheses negative — so $\partial L/\partial P$ is negative (LTV improves when A’s price increases). Conversely, if the vault is B-heavy, a price increase (A up, B down in value) will cause $A_{\text{tot}}$ to rise a bit and $B_{\text{tot}}$ to drop significantly, yielding a positive $\partial L/\partial P$ (LTV worsens). In essence, the LTV moves in the opposite direction of the value of whichever asset dominates the collateral.

Utilisation vs. APR

Because interest accrues continuously, we can convert the rate $r(U)$ into an annual percentage rate (APR). If $r(U)$ is expressed as a per-second rate (fraction of principal per second), then the effective yearly growth factor is $\exp(r(U) \times 31536000)$ (seconds in a year). Thus, the APR corresponding to utilisation $U$ is:

\text{APR}(U) = \Big(e^{\,r(U)\times 31536000} - 1\Big)\times 100\%\,.
\tag{18}

For small rates, this is approximately $r(U)\times 31536000 \times 100%$. For example, if $U=50%$ yields $r(U) \approx 1.0\times10^{-9}$ (per second), the annualized rate is about $0.000000001 \times 3.15\times10^7 \approx 0.0315$, i.e. ~3.15% APR. As $U$ approaches the cap (0.95), $r(U)$ would be much larger, resulting in a high APR — a deliberate design to incentivize repayments or new deposits when utilisation is very high.

Implementation Note: The protocol can be configured with a specific interest rate model $r(U)$ (e.g. a curve that starts at a base rate and grows steeply after $U$ passes some threshold). To visualize or test parameter choices, one can plot APR vs. $U$ using the formula above. The cap at $U=0.95$ ensures the APR is finite (albeit potentially very high) even at maximum utilisation.
