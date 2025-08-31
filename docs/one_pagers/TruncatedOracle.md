# TruncatedOracle - One-Pager

## 1. Purpose & Context

* **What it does** - Records `(tick, liquidity)` observations each block and serves time-weighted price queries (`observe`, `observeSingle`).
* **Where it lives** - Called exclusively by the pool's *Hook* on swap / mint events.
* **Who calls it**:
  * Write-path: Hook -> `write`
  * Read-path: DEX fee logic, TWAP helpers, external contracts -> `observe*`.

### Key Features
* **Tick Movement Capping** - Prevents oracle manipulation by limiting maximum tick movement between observations
* **Ring Buffer Storage** - Efficient 65535-slot circular array with auto-growing cardinality (max 1024)
* **Time-Weighted Queries** - Supports TWAP calculations with binary search over historical data
* **Gas Optimized** - Packed 256-bit observations, early returns, and efficient storage layout

## 2. Trust & Threat Model

| Actor | Trust Level | Possible Abuse / Mitigation |
|-------|-------------|------------------------------|
| **Hook / Pool** | Must provide monotonic timestamps & hard-capped `tick`s. | |
| **Block producer** | Can reorder txs but cannot forge timestamp gaps ≥ 900 s (EVM rule). | |
| **User / LP** | Only indirect influence via trades; cannot call oracle directly. | |
| **L1 re-org** | Out of scope; handled by canonical-chain finality. | |

## 3. Storage Layout - 1 slot / observation

| Bits | Field | Type | Notes |
|------|-------|------|-------|
| 0-31 | `blockTimestamp` | uint32 | wraps every ≈ 136 years |
| 32-55 | `prevTick` | int24 | capped ±9126 by hook |
| 56-111 | `tickCumulative` | int56 | monotone sum |
| 112-271 | `secondsPerLiquidityCumulativeX128` | uint160 | Q128.128 fixed-point |
| 272-279 | `initialized` | bool | branch hint |

**Ring variables (slot 2)** - `index:uint16`, `cardinality:uint16`, `cardinalityNext:uint16`

## 4. External API

| Function | Gas (happy) | Reverts | Comment |
|----------|-------------|---------|---------|
| `initialize(uint32 time, int24 tick)` | ~5k | - | one-time setup |
| `write(uint32 ts, int24 tick, uint128 liq, uint24 maxTicks)` | ~25k (no cap) | `OracleCardinalityCannotBeZero` | inserts / rotates |
| `grow(uint16 current, uint16 next)` | O(next-current) | - | allocates buffer |
| `observe(uint32 nowTs, uint32[] calldata secondsAgos, …)` | O(n log c) | `TargetPredatesOldestObservation` | binary search |
| `observeSingle(uint32 nowTs, uint32 secondsAgo, …)` | O(log c) | same | thin wrapper |

## 5. Oracle Invariants

| ID | Property (holds after every write) | Why it matters |
|----|-----------------------------------|----------------|
| **I1** | `cardinality ≥ 1` | prevents division-by-zero & empty reads |
| **I2** | `index < cardinality` | always points to a valid slot |
| **I3** | `initialized == true` for slot at `index` | the latest observation is usable |
| **I4** | `obs[i].blockTimestamp` strictly increases modulo 2³² | ensures time monotonicity even across wrap |
| **I5** | `tickCumulative` is non-decreasing | required for TWAP maths (`Δcum / Δt`) |
| **I6** | `secondsPerLiquidityCumulativeX128` is non-decreasing | same as I5 for liquidity-weighted metrics |
| **I7** | `abs(prevTick - tick) ≤ 9126` (enforced pre-oracle) | bounds all arithmetic to 48-bit range |
| **I8** | For `cardinality == 1`, any query with `target < only.blockTimestamp` **reverts** | avoids phantom interpolation before first observation |
| **I9** | `transform` early-returns when `delta == 0` | gas & correctness (no double-count) |
| **I10** | `observe*` never panics (overflow/underflow) for valid inputs | API guarantee for integrators |