# TruncGeoOracleMulti - One-Pager

Adaptive tick-cap oracle safeguarding Uniswap V4 pools

## 1. Purpose & Context

* **What** - Maintains a rolling tick-history and enforces a geometrically truncated "max-ticks-per-block" cap that auto-tunes to pool volatility.
* **Where** - Lives beside the Spot (FullRange) Hook; the Hook invokes it every swap, governance touches it only for setup/tuning.
* **Who**:
  * **Write-path** - Spot Hook (`pushObservationAndCheckCap`), governance (`enableOracleForPool`, `refreshPolicyCache`, `setAutoTunePaused`).
  * **Read-path** - Off-chain indexers & tests (`getLatestObservation`, `getMaxTicksPerBlock`, `isOracleEnabled`).

## 2. Trust & Threat Model

| Actor | Trust | Abuse → Mitigation |
|-------|-------|-------------------|
| Governance owner | High | Mis-sets caps → `PolicyValidator.validate()` enforces bounds |
| PoolManager (hook) | Med | Swap spam → `maxTicksPerBlock` cap + `nonReentrant` |
| Liquidity provider | Low | Price manipulation → oracle truncates excess ticks |
| Random EOA / bot | None | All mutating funcs are `onlyOwner` or hook-gated |
| Miner / block-prod. | None | Time skew limited; oracle stamps `block.timestamp` internally |

## 3. Key Storage Layout

| Category | Variable(s) | Default / Range |
|----------|------------|-----------------|
| Ring buffer | `_pages[id][pageIdx]` (512 obs/page) · `states[id]` | Empty |
| Adaptive cap | `maxTicksPerBlock[id]` | uint24 1 – 500 bps |
| Policy cache | `_policy[id]` (minCap, maxCap, stepPpm, budgetPpm, decayWindow, updateInterval) | All zero until validated |
| Auto-tune flags | `_autoTunePaused[id]` bool, `_lastMaxTickUpdate[id]` uint32 | false, 0 |
| Constants | `PAGE_SIZE`, `ONE_DAY_PPM`, `CAP_FREQ_MAX`, `EV_THRESHOLD` | Compile-time |

## 4. External API (happy-path)

```solidity
function enableOracleForPool(PoolKey key) external;           // owner – seeds history & policy
function pushObservationAndCheckCap(PoolId pid, bool zfO)
        external nonReentrant returns (bool capped);          // hook – ~42 k gas; +6 k if capped
function refreshPolicyCache(PoolId pid) external;             // owner – syncs _policy from IPoolPolicy
function setAutoTunePaused(PoolId pid, bool paused) external; // owner – toggle auto-tune
function getLatestObservation(PoolId pid)
        external view returns (int24 tick, uint32 ts);        // view – cheap (≤ 400 gas)
```

## 5. Events Cheat-Sheet

| Event | Fired on | Why it matters |
|-------|----------|----------------|
| `OracleConfigured` | `enableOracleForPool` | Confirms hook/oracle linkage |
| `PolicyCacheRefreshed` | `refreshPolicyCache` | Signals new policy params |
| `MaxTicksPerBlockUpdated` | Auto-tune step | Off-chain risk models listen |
| `TickCapParamChanged` | Upstream policy contract edit | Auditable config change |
| `AutoTunePaused` | Governance pause/unpause | Incident response flag |

## 6. Critical Invariants & Reverts

1. **Policy sanity** - `PolicyValidator.validate()` rejects zero/illogical caps.
2. **Hook exclusivity** - `pushObservationAndCheckCap` reverts unless `msg.sender == hook`.
3. **Ring bounds** - `states.cardinalityNext ≤ PAGE_SIZE` enforced by TruncatedOracle.
4. **Cap step-limit** - `maxTicksPerBlock` moves ≤ stepPpm per updateInterval.
5. **Re-entrancy** - All mutating paths use `nonReentrant`.

## 7. Governance / Upgrade Flow

1. Deploy new `IPoolPolicy` contract with fresh params.
2. Call `refreshPolicyCache(pid)` – caches & validates.
3. Leave auto-tune on for normal ops; pause via `setAutoTunePaused` during incidents.
4. Contract is non-upgradeable; future versions require redeploy + hook pointer update.

## 8. Dev & Ops Tips

* Fuzz `pushObservationAndCheckCap` ±maxTicksPerBlock to cover cap-hit branch.
* Keep `PAGE_SIZE` a power-of-two for cheap modulo masking.
* Index `MaxTicksPerBlockUpdated` to plot real-time volatility.
* Use `CAP_FREQ_MAX` to bound autotune gas in extreme markets.

## 9. Security Considerations

| Risk | Mitigation |
|------|------------|
| Oracle DoS via swap flood | Hard cap on autotune frequency (`CAP_FREQ_MAX`) + ring mask overflow-safe |
| Governance key compromise | Recommend timelock/multisig; invalid caps revert in validator |
| Tick precision overflow/underflow | SafeCast on every cast to int24 |
| Cross-chain replay | Storage keyed by PoolId; foreign chain IDs map to disjoint slots |
