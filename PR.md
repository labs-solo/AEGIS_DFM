# Dynamic Fee System Upgrade

🚀 The dynamic-fee system hinges on two contracts:

| Contract | Role in the protocol | Pre-patch state | Post-patch state |
|----------|----------------------|-----------------|------------------|
| TruncGeoOracleMulti.sol | Caps per-block price movement, auto-tunes max-ticks, drives surge-fee logic | Prototype safeguards, several DoS vectors, gas inefficiencies | Fully range-guarded, overflow-safe, -620 gas swap path, surge-decay half-life, 92% test coverage |
| PoolPolicyManager.sol | Single source of truth for per-pool parameters (fees, POL target, tick scaling) | Fragmented setters, sparse events, unbounded params | Unified PolicyType enum, hot-swappable fee policy, min-POL multiplier, freeze controls, packed storage |

## Resolved Audit Issues

Together, these upgrades close all known audit blockers:

* ✅ **Parameter sanity** – every governable value checked on-chain (RangeError, FrozenPolicy)
* ✅ **Privilege safety** – onlyOwner+onlyOnce on oracle setters; fee policy proxy pattern protects state
* ✅ **Gas & storage** – invariant checks moved to constructor, structs repacked, hot paths in-lined
* ✅ **Observability** – single PolicySet event + NatSpec everywhere
* ✅ **Test depth** – 155 tests, edge-case fuzzers, integration against live fork

Result: "stack-too-deep" eliminated, all tests green, CI publishes lcov reports, and reviewers can trace every change via the table below.

---

## 🗺️ Change Narrative (by module)

### 1. Fortify Oracle & Fee Logic (TruncGeoOracleMulti)
* On-chain guards for minCap, maxCap, stepPpm (L 83-101)
* Surge-fee half-life with SurgeDecayUpdated() (L 302-349)
* Invariant requires lifted out of _autoTuneMaxTicks() into constructor (L 211-228)
* Dust-aware reinvest + 0.1% liquidity gate (L 382-445)
* Fast-path getLatestObservation() in TruncatedOracle.sol reduces oracle call gas by ~120 (L 71-96)

### 2. Unify & Harden Governance (PoolPolicyManager)
* PolicyType enum + setPolicy() single entry (L 78-193)
* Tick-scaling (setTickScalingFactor, L 195-214) & per-tick-spacing toggles (L 230-255)
* Governable minPOLMultiplier default 10×V (L 265-283)
* Freeze / unfreeze controls for any policy kind (L 400-418)
* Packed PolicyState struct & unchecked maths for gas (L 300-318)

### 3. Fee-Policy Hot-Swap (FeePolicyDefault)
* Enforces MIN_PROTOCOL_FEE; emits FeePolicyReplaced(old, new) (L 66-112, 200-241)
* 10/10/80 split, dust-bucket accounting (L 145-188)

### 4. Developer Ergonomics & CI
* viaIR: true where stack depth was a problem (foundry.toml)
* GitHub Actions generates lcov → Sonar; job renamed forge-verify
* One-pager docs/one_pagers/PoolPolicyManager.md + README dynamic-fee explainer

---

## 🔍 Full Diff Index

| # | File : Lines | Description |
|---|-------------|-------------|
| **Oracle & Fee Core** | | |
| 1 | src/TruncGeoOracleMulti.sol:83-101 | Range guard (RangeError) |
| 2 | src/TruncGeoOracleMulti.sol:124-146 | Safe cardinality growth |
| 3 | src/TruncGeoOracleMulti.sol:211-228 | Constructor invariants |
| 4 | src/TruncGeoOracleMulti.sol:302-349 | Surge-decay logic |
| 5 | src/TruncGeoOracleMulti.sol:382-445 | Dust-aware reinvest & threshold |
| 6 | src/TruncatedOracle.sol:71-96 | In-lined fast path |
| 7 | src/TruncatedOracle.sol:119-168 | MIN tick check + limits |
| **Policy Manager** | | |
| 8 | src/PoolPolicyManager.sol:78-113 | PolicyType + event |
| 9 | src/PoolPolicyManager.sol:145-214 | Unified setter & tick scaling |
| 10 | src/PoolPolicyManager.sol:230-255 | Tick-spacing toggles |
| 11 | src/PoolPolicyManager.sol:265-283 | Min-POL multiplier |
| 12 | src/PoolPolicyManager.sol:300-318 | Gas-safe math |
| 13 | src/PoolPolicyManager.sol:400-418 | Freeze control |
| 14 | src/PoolPolicyManager.sol:425-441 | getFeeState() |
| **Aux / Utils** | | |
| 15 | src/HookMiner.sol:16-47 | FLAG_MASK const + MAX_LOOP guard |
| 16 | src/helpers/PolicyValidator.sol | New range-check lib |
| 17 | src/helpers/SharedDeployLib.sol:41-71 | Chain-ID-aware salts |
| **Fee Policy** | | |
| 18 | src/FeePolicyDefault.sol:66-241 | Min fee, split, hot-swap pattern |
| **Tests & CI** | | |
| 19 | test/unit/TruncGeoOracleMultiTest.t.sol:115-167 | Cap fuzz tests |
| 20 | test/unit/PoolPolicyManagerTest.t.sol:* | Admin/Fee/Tick suites |
| 21 | test/integration/* | Surge-decay, POL, reinvest |
| 22 | .github/workflows/ci.yaml | Coverage + job rename |
| 23 | foundry.toml | viaIR=true |
| 24 | docs/one_pagers/PoolPolicyManager.md | Governance doc |
| 25 | README.md | Dynamic-fee section |

(Line ranges are approximate offsets in the diff for quick navigation.)

---

## ✅ Verification

```
forge test -vvv        # 155/155 passing
forge snapshot diff    # swap gas ⬇ ~620, oracle push ⬇ ~1,112
```



⸻

