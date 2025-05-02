# TruncatedOracle – One-Pager

## 1. Purpose & Context

* **What it does** – records `(tick, liquidity)` observations each block and serves time-weighted price queries (`observe`, `observeSingle`).  
* **Where it lives** – called exclusively by the pool’s *Hook* on swap / mint events.  
* **Who calls it** –  
  * write-path: hook → `write`  
  * read-path: DEX fee logic, TWAP helpers, external contracts → `observe*`.

## 2. Trust & Threat Model

| Actor              | Trust Level | Possible Abuse / Mitigation |
|--------------------|-------------|------------------------------|
| **Hook / Pool**    | Must provide monotonic timestamps & hard-capped `tick`s. |
| **Block producer** | Can reorder txs but cannot forge timestamp gaps ≥ 900 s (EVM rule). |
| **User / LP**      | Only indirect influence via trades; cannot call oracle directly. |
| **L1 re-org**      | Out of scope; handled by canonical-chain finality. |

## 3. Storage Layout – 1 slot / observation

| Bits | Field                       | Type   | Notes |
|------|-----------------------------|--------|-------|
| 0-31 | `blockTimestamp`            | uint32 | wraps every ≈ 136 years |
|32-55 | `prevTick`                  |  int24 | capped ±9126 by hook |
|56-103| `tickCumulative`            |  int48 | monotone sum |
|104-247|`secondsPerLiquidityCumX128`| uint144| Q128.128 fixed-point |
|248   | `initialized`               |  bool  | branch hint |

**Ring variables (slot 2)** – `index:uint16`, `cardinality:uint16`, `cardNext:uint16`

## 4. External API

| Function | Gas (happy) | Reverts | Comment |
|----------|-------------|---------|---------|
| `write(uint32 ts, int24 tick, uint128 liq)` | ~25 k (no cap) | `OracleCardinalityCannotBeZero` | inserts / rotates |
| `grow(uint16 newSize)`                     | O(newSize) | – | allocates buffer |
| `observe(uint32 nowTs, uint32[] calldata secondsAgos, …)` | O(n log c) | `TargetPredatesOldestObservation` | binary search |
| `observeSingle(uint32 nowTs, uint32 secondsAgo, …)` | O(log c) | same | thin wrapper |

---

## 6. Oracle Invariants

| ID | Property (holds after every write) | Why it matters |
|----|------------------------------------|----------------|
| **I1** | `cardinality ≥ 1` | prevents division-by-zero & empty reads |
| **I2** | `index < cardinality` | always points to a valid slot |
| **I3** | `initialized == true` for slot at `index` | the latest observation is usable |
| **I4** | `obs[i].blockTimestamp` strictly increases modulo 2³² | ensures time monotonicity even across wrap |
| **I5** | `tickCumulative` is non-decreasing | required for TWAP maths (`Δcum / Δt`) |
| **I6** | `secondsPerLiquidityCumX128` is non-decreasing | same as I5 for liquidity-weighted metrics |
| **I7** | `abs(prevTick − tick) ≤ 9126` (enforced pre-oracle) | bounds all arithmetic to 48-bit range |
| **I8** | For `cardinality == 1`, any query with `target < only.blockTimestamp` **reverts** | avoids phantom interpolation before first observation |
| **I9** | `transform` early-returns when `delta == 0` | gas & correctness (no double-count) |
| **I10**| `observe*` never panics (overflow/underflow) for valid inputs | API guarantee for integrators |
