## Sprint 1 – Full-Range Liquidity Skeleton

### **Developer FAQ**

> **Scope of Sprint 1:**
> *Proxy scaffold • immutable storage slots 0-24 • pool registration & locked-shares guard*
> *Deposit / Withdraw for **full-range** liquidity*
> *Pause-guardian wiring & events*
> *(No borrowing, no interest, no tests until P5)*

---

### 1. **What on-chain state do I create in Sprint 1?**

| Slot    | Variable (packed)                                     | Purpose                                                                                                           | Source / Spec ID  |
| ------- | ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ----------------- |
| `0`     | `pauseFlags:uint96` <br>`owner,address`               | Global bit-map (bit 0 = PAUSE\_ALL, 1 = DEPOSITS, 2 = WITHDRAWALS, …)                                             | App B §Storage    |
| `1`-`6` | Oracle, PoolManager, PolicyMgr, PositionMgr, SpotHook | External modules (addresses fixed by governance)                                                                  | App A diagrams    |
| `7`     | `PoolId -> ShareInfo` mapping                         | Holds `totalShares`, `lockedShares`, `lastReinvestTime`, `shareIndex` *(index added but **zero** until Sprint 2)* | Storage Table B-2 |
| `8`     | `PoolId -> pendingFees`                               | (token0, token1) counters **only increment** in S1                                                                | INV-2.3/2.4       |
| `9`     | `User -> Vault` mapping                               | `shareBalance`, `token0Idle`, `token1Idle` *(NFT & debt fields reserved)*                                         | Table B-3         |

> **Append-only rule:** slots 19-24 are hard-gaps from V1; do **not** reuse them.

---

### 2. **How do deposits mint shares?**

1. Read current full-range reserves `(x,y)` from PoolManager.
2. Compute *shares* that keep proportional ownership:

$$
\text{shares} = 
\min\!\Bigl(
\frac{\text{amt0}\,S_{\text{tot}}}{x},
\frac{\text{amt1}\,S_{\text{tot}}}{y}
\Bigr)
\tag{★}
$$

3. `totalShares += shares; user.shareBalance += shares`
4. If `totalShares` was **0** → set `lockedShares = shares` (immutable thereafter).
5. Transfer `amt0/amt1` from `msg.sender` (must be **SpotHook**) and call `PoolManager.addLiquidity`.

Edge-cases → revert:

| Condition                          | Error                |
| ---------------------------------- | -------------------- |
| both `amt0 + amt1 == 0`            | `ZeroDeposit`        |
| caller ≠ `authorizedHook`          | `UnauthorizedCaller` |
| `pauseFlags & PAUSE_DEPOSITS != 0` | `ContractPaused`     |

---

### 3. **How do withdrawals burn shares?**

1. Check `shares ≤ user.shareBalance` else `InsufficientShares`.
2. Pro-rata token amounts:
   $\Delta x = \tfrac{shares}{S_{\text{tot}}}x,\; \Delta y = \tfrac{shares}{S_{\text{tot}}}y$
3. `totalShares -= shares; user.shareBalance -= shares`
4. **Invariant**: `totalShares ≥ lockedShares` after burn (INV-2.1).
5. Call `PoolManager.removeLiquidity`, transfer tokens to `to`.

Slippage protection: caller passes `min0/min1`; if tokens < min → `SlippageFailure`.

---

### 4. **Do shares change when liquidity is lent out later?**

No.  Sprint 1 shares are a **percentage claim** on whatever sits inside the
full-range position *plus* its outstanding IOUs (future loans).
When Sprint 2 adds borrowing:

* Borrower **mints new shares** equal to the slice they extract.
* Those shares enter the **debt ledger** (`borrowShares`) and are not owned by any LP.
* Existing LP balances stay constant; their NAV per share is preserved by double-entry bookkeeping (see §7).

---

### 5. **Why not burn depositor shares on borrow?**

Burning depositor shares would silently dilute user ownership.
Instead the engine follows “**mint-then-remove-tokens**”:

| Action         | Share supply                                                   | Pool tokens      | Result for LPs                            |
| -------------- | -------------------------------------------------------------- | ---------------- | ----------------------------------------- |
| Borrow *s*     | `S_tot += s` *(to borrower)*                                   | `x,y -= Δx,Δy`   | Per-share NAV unchanged (IOU compensates) |
| Repay *(1+ϵ)s* | Borrower burns debt-shares; vault receives tokens `Δx,Δy(1+ϵ)` | NAV ↑ (interest) | LPs gain value                            |

Mathematically:

$$
\text{NAV/share} = \frac{ x+y + \text{PV(loans)} }{ S_{\text{tot}} }
$$

remains constant through a borrow/repay cycle.

---

### 6. **What events must I emit in Sprint 1?**

| Event                                               | When                          | Fields       |
| --------------------------------------------------- | ----------------------------- | ------------ |
| `PoolRegistered(poolId, key)`                       | first deposit into a new pool | —            |
| `Deposit(user, poolId, shares, amt0, amt1)`         | each successful deposit       | —            |
| `Withdraw(user, poolId, shares, amt0, amt1)`        | each successful withdraw      | —            |
| `Paused(caller, flags)` / `Unpaused(caller, flags)` | pause toggles                 | flags bitmap |

All events use Solidity `indexed` fields for high-volume filters.

---

### 7. **Walk-through example (numbers)**

| Moment                                             | Reserves (A,B) | **S\_tot**         | Alice shares | Bob shares | Alice NAV/share |
| -------------------------------------------------- | -------------- | ------------------ | ------------ | ---------- | --------------- |
| First deposit 1 000 A+1 000 B                      | 1 000/1 000    | 1 000              | 1 000        | —          | 1 A+1 B         |
| Bob borrows 200 shares *(in Sprint 2)*             | 800/800        | **1 200** *(+200)* | 1 000        | 200 (debt) | 1 A+1 B         |
| Bob repays 220 A+220 B                             | 1 020/1 020    | 1 000 *(burn 200)* | 1 000        | 0          | 1.02 A+1.02 B   |
| Keeper reinvests extra 20 A+20 B → mints 19 shares | 1 040/1 040    | 1 019              | 1 000        | 0          | 1.02 A+1.02 B   |

*Take-away:* LP balances never move; interest shows up as higher redeem-value per share.

---

### 8. **Invariant checklist for Sprint 1 code**

| ID                                                               | Enforcement point                                               |
| ---------------------------------------------------------------- | --------------------------------------------------------------- |
| **INV-2.1** Locked shares never withdrawn                        | `withdraw()` `require(totalShares - shares ≥ lockedShares)`     |
| **INV-2.2** LockedShares immutable                               | set once in `registerPool`; no setter thereafter                |
| **INV-2.3 / 2.4** Fee counters only ↑ and reset to 0 on reinvest | counters updated only by SpotHook (+) and `reinvestFees()` (→0) |
| **INV-2.6** Authorized hook only                                 | `require(msg.sender == authorizedHook)` in `deposit/withdraw`   |
| **INV-2.7** Pause halts risky ops                                | `whenNotPaused(flags)` on every external mutator                |

Unit + invariant tests for these fire in **Sprint 1 • Phase 5**.

---

### 9. **Dev checklist**

* [ ] Respect exact slot order from Appendix B — run `forge inspect` diff.
* [ ] All storage structs have explicit gap fields (`uint256[50] __gap;`).
* [ ] `deposit()` & `withdraw()` covered by `nonReentrant` (OpenZeppelin guard).
* [ ] Use `SafeERC20` for token transfers.
* [ ] Revert strings match spec (`"UnauthorizedCaller"`, `"InsufficientShares"`, …).
* [ ] Emit events **after** all state changes.
* [ ] Gas target: deposit ≈ 80 k, withdraw ≈ 85 k on cold storage (check Foundry snapshot).

---

### 10. **Future hooks you can stub now**

| Hook / Flag                     | Needed later in… | Stub behaviour in Sprint 1  |
| ------------------------------- | ---------------- | --------------------------- |
| `shareIndex` (interest)         | Sprint 2-P1      | add field, default = 1e18   |
| `reinvestEnabled`               | Sprint 2-P4      | mapping<bool>, default true |
| `BatchEngine.executeBatchTyped` | Sprint 5         | empty body returning `true` |
| `totalBorrowShares`             | Sprint 2         | declare var, keep = 0       |

---

**If anything is still unclear ping this thread before coding phase starts. Happy building!**
