# PoolPolicyManager.sol – One-Pager 

PoolPolicyManager is **AEGIS' all-in-one policy registry** for every Uniswap V4 pool the protocol touches.  
It *replaces* four separate managers (fee, tick-scaling, vtier, and POL) and adds phase-4 "interest-fee" logic, surge-fee rules, and per-pool overrides.

---

## 1.  What does it do?

| Domain | Role |
|--------|------|
| **Fee policy** | Splits every swap fee into **POL ▸ Full-Range Incentive ▸ LP** slices, enforces min-fee / claim-threshold, and computes the **minimum POL reserve** needed ( *liquidity × dynamicFee × multiplier* ). |
| **Tick scaling & vtier** | Keeps a whitelist of supported tick-spacings and validates `(fee, spacing)` pairs; dynamic-fee pools bypass the fee tier map. |
| **Dynamic base-fee "step-engine"** | Stores per-pool step-size & update-interval; governs how fast the base-fee moves when cap-events deviate from target. |
| **Surge fee** | Adds a temporary multiplier after large trades; decay & multiplier are globally defaulted but override-able per pool. |
| **Phase-4 admin** | Globally sets *protocol-interest* fee-% and fee-collector, and whitelists **authorized reinvestor bots**. |
| **Budget feedback** | Exposes daily cap-event budget & linear decay; governs when the base-fee ramps up/down. |

Everything is **read by hooks or off-chain agents**; the contract itself never calls external systems.

---

## 2.  Key Storage Layout

| Category | Variable(s) | Default / Range |
|----------|-------------|-----------------|
| **Fee splits** | `polSharePpm`, `fullRangeSharePpm`, `lpSharePpm` | 100 000 / 0 / 900 000 (ppm) |
| **POL multiplier** | `defaultPolMultiplier`, `poolPolMultipliers[pid]` | 10× (global) |
| **Step engine** | `_baseFeeStepPpm[pid]`, `_baseFeeUpdateIntervalSecs[pid]` | 20 000 ppm & 1 day |
| **Surge** | `_surgeFeeMultiplierPpm[pid]`, `poolSurgeDecayPeriodSeconds[pid]` | 3 000 000 ppm (300 %) & 3 600 s |
| **Tick scaling** | `tickScalingFactor` | 1 (may not be 0) |
| **Tick spacing map** | `supportedTickSpacings[spacing]` | seeded with 1 & 10 |
| **Interest fee** | `protocolInterestFeePercentagePpm` | 50 000 ppm (5 %) |
| **Reinvestors** | `authorizedReinvestors[addr]` | mapping(bool) |

> **Per-pool overrides always win; missing keys fall back to global defaults.**

---

## 3.  External API (happy-path)

```solidity
// Governance setters
setFeeConfig(polPpm, frPpm, lpPpm, minFeePpm, claimPpm, polMult);
setPoolPOLShare(pid, sharePpm);              // paired with setPoolSpecificPOLSharingEnabled()
setBaseFeeParams(pid, stepPpm, interval);    // step-engine
setSurgeDecayPeriodSeconds(pid, secs);
setSurgeFeeMultiplierPpm(pid, ppm);
setTickScalingFactor(int24 newFactor);
updateSupportedTickSpacing(uint24 spacing, bool);
batchUpdateAllowedTickSpacings(uint24[] spacings, bool[] flags);
setProtocolFeePercentage(uint256 pct1e18);
setFeeCollector(address collector);
setAuthorizedReinvestor(address bot, bool ok);
initializePolicies(pid, gov, impls[4]);      // wires hook sub-policies

Readers / hooks mainly call:

getFeeAllocations(pid) → (pol, fullRange, lp);
getMinimumPOLTarget(pid, totalLiq, dynamicFeePpm);
isValidVtier(fee, spacing) → bool;
getBaseFeeStepPpm(pid);   getBaseFeeUpdateIntervalSeconds(pid);
getSurgeFeeMultiplierPpm(pid);  getSurgeDecaySeconds(pid);
getFreqScaling(pid); getTargetCapsPerDay(pid); ...



⸻

4.  Events Cheat-Sheet

Event Fired on
FeeConfigChanged any global fee-split update
PoolPOLShareChanged, POLShareSet per-pool POL % tweaks
BaseFeeParamsSet step-engine override
TickSpacingSupportChanged single / batch tick-spacing toggles
PoolInitialized hook callback (oracle stripped out)
ProtocolInterestFeePercentageChanged, FeeCollectorChanged phase-4 admin
**`PolicySet`:** Emitted by nearly *all* configuration setters (both global defaults and per-pool overrides) indicating a change related to a specific `PolicyType`. The `implementation` field often encodes the new value (e.g., as `address(uint160(value))`) for non-address settings.



⸻

5.  Critical Invariants & Reverts
 1. Fee-split sum must equal 1 000 000 ppm else AllocationSumError.
 2. minimumTradingFeePpm & feeClaimThresholdPpm ≤ 100 000 ppm (10 %).
 3. Tick-scaling factor > 0.
 4. Step size ≤ 100 000 ppm; surge multiplier ≤ 3 000 000 ppm; surge decay ∈ [60 s, 1 day].
 5. Protocol interest fee percentage PPM must be `<= 1_000_000` (100%).
 6. `poolSpecificPolShare` allowed only when the feature flag is true.
 7. `parameter==address(0)` guarded by `ZeroAddress()`.

Foundry suite (**56 tests**) enforces every branch & revert (see gas table in CI).

⸻

6.  Governance / Upgrade Flow

Initial deployment seeds tick-spacings and defaults.
DAO calls:
 1. setFeeConfig to publish official split.
 2. setProtocolFeePercentage & setFeeCollector to turn on interest-fee waterfall.
 3. For a new pool launch:
 • add spacing if novel (updateSupportedTickSpacing),
 • setBaseFeeParams / surge overrides if liquidity profile needs custom aggressiveness.

Sub-policies (hooks, oracles) are hot-pluggable via initializePolicies.

⸻

7.  Dev & Ops Tips
 • Per-pool overrides are sparse storage – call the getter first; if it returns 0 you're reading the global default.
 • To simulate a swap-driven fee update in tests, just write to step params; no need to simulate trades.
 • Event PolicySet is emitted for every setter → index by (poolId, policyType) to rebuild full config off-chain.

⸻

8.  Security Considerations

Risk Mitigation
Mis-configured fee split drains LP yield AllocationSumError & unit tests
Rogue owner changes interest fee to 100 % DAO multisig-controlled `onlyOwner` *and* explicit `<= 1_000_000` PPM check in the setter.
Tick-scaling mis-set to 0 (division by zero downstream) explicit >0 range check
Integer overflow in POL target calc fits in 256-bit math, divided by 1e12



⸻

Bottom-line: PoolPolicyManager is the protocol's single-source of configurable truth – lightweight, upgrade-friendly, and thoroughly unit-tested (**56/56 green**). Put simply, if a pool's economics or fee cadence change, the tweak lands here.