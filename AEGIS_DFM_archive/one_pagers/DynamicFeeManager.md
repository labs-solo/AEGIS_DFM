# DynamicFeeManager - One-Pager

Real-time base + surge fee engine for V4 pools

## 1. Purpose & Context

* **What** - Computes a base fee from the pool's max-tick oracle and layers an auto-decaying surge fee when a tick-cap (CAP) event fires, returning the sum on demand.
* **Where** - Deployed next to the Full-Range Hook; the hook pushes oracle updates, while strategy contracts read fees before quoting trades.
* **Who**:
  * **Write-path** - `initialize`, `notifyOracleUpdate`, `setAuthorizedHook` – owner or the authorised hook only.
  * **Read-path** - `getFeeState`, `isCAPEventActive`, `baseFeeFromCap` – routers, off-chain indexers, dashboards.

## 2. Trust & Threat Model

| Actor | Trust | Possible Abuse → Mitigation |
|-------|-------|----------------------------|
| Owner (EOA / DAO) | High | Sets bad hook → guarded by non-zero check & mutable only via `setAuthorizedHook`. |
| Authorised Hook | Medium | Spam `notifyOracleUpdate` → single-slot packing keeps gas flat; surge auto-decays. |
| Oracle (TruncGeoOracleMulti) | Medium | Lies about maxTicksPerBlock → bounded by downstream risk limits. |
| PolicyManager | Medium | Mis-sets decay / multiplier → values read-only; callers can sanity-check. |
| External EOA | None | All mutating paths gated by owner or hook modifiers. |

## 3. Key Storage Layout

| Category | Variable(s) | Default / Range |
|----------|------------|-----------------|
| Globals | `policyManager`, `oracle`, `authorizedHook` (immutables) | Non-zero at deploy |
| Per-pool packed slot `_s[id]` | `freq` (96b), `freqL` (40b), `capStart` (40b), `lastFee` (32b), `inCap` (1b) | All zero until initialize |
| Const | `DEFAULT_BASE_FEE_PPM` = 5 000 ppm | 0.5 % |

## 4. External API (happy-path)

```solidity
function initialize(PoolId id, int24 tick) external;          // owner|hook – one-time setup
function notifyOracleUpdate(PoolId id, bool capped) external; // hook – updates fees, emits event
function getFeeState(PoolId id)
        external view returns (uint256 baseFee, uint256 surgeFee);
function isCAPEventActive(PoolId id) external view returns (bool);
function setAuthorizedHook(address newHook) external;         // owner – rotates hook key
```

Gas: `notifyOracleUpdate` ≈ 40 k (no CAP) / 46 k (CAP & emit).

## 5. Events Cheat-Sheet

| Event | Fired on | Why it matters |
|-------|----------|----------------|
| `PoolInitialized` | `initialize` | Marks fee engine live for pool. |
| `AlreadyInitialized` | `initialize` 2nd call | Signals idempotence. |
| `FeeStateChanged` | `notifyOracleUpdate` | Off-chain feeds watch base + surge moves. |

## 6. Critical Invariants & Reverts

1. **Single initialisation** - `_s[id] == 0` enforced; repeat calls emit warning only.
2. **Hook exclusivity** - `_requireHookAuth()` on every oracle callback.
3. **Oracle presence** - all fee math guards `address(oracle) != 0`.
4. **Surge fee monotone-decay** - linear decay to zero over `policyManager.getSurgeDecayPeriodSeconds()`.
5. **Packed-slot safety** - setters/masks keep writes within 256 bits to avoid clobber.

## 7. Governance / Upgrade Flow

1. Deploy new PolicyManager with updated decay/multiplier parameters.
2. If hook logic changes, call `setAuthorizedHook(newHook)` (owner only).
3. Contract itself is non-upgradeable; migrate by deploying a fresh manager & pointing the hook to it.

## 8. Dev & Ops Tips

* Unit tests: fuzz `notifyOracleUpdate` with `capped=true/false` and variable `block.timestamp`.
* Gas: packed slot ensures one SSTORE per update.
* Telemetry: index `FeeStateChanged` for a live fee chart.
* Constants: tweak `DEFAULT_BASE_FEE_PPM` only in constructor fork to keep storage layout intact.

## 9. Security Considerations

| Risk | Mitigation |
|------|------------|
| Oracle mis-reports leading to 0 fee | Falls back to `DEFAULT_BASE_FEE_PPM`. |
| Hook key stolen | Owner can rotate via `setAuthorizedHook`; recommend timelock-protected multisig. |
| DoS via endless CAP events | Surge auto-decays; fee calc O(1) regardless of volume. |
| State corruption from bit packing | `_P` library masks every setter; extensive unit tests cover edge widths. |
