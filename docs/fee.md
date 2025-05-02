# Dynamic Fee System Explained

This document is a single-source of truth for the v4 dynamic-fee design.

⸻

1. Introduction

The dynamic-fee system adapts swap fees to market conditions.
 • Capitalize on Volatility – spike fees when price moves too fast.
 • Cost efficiency – keep fees low when markets are quiet.
 • Self-tuning – learn from CAP-event frequency to find equilibrium.

The total fee is:

totalFeePPM = baseFeePPM + surgeFeePPM

PPM means parts per million (10 000 ppm ~ 1 %).

⸻

## Core Components

Component Contract Time-scale Purpose
Base Fee TruncGeoOracleMulti days → weeks Long-term equilibrium based on CAP-event frequency
Surge Fee DynamicFeeManager seconds → minutes Instant bump during each CAP event, linear decay

⸻

## Base Fee Adjustment Mechanism (Oracle-Driven Feedback Loop)

The Oracle stores maxTicksPerBlock (MTB).
The fee manager converts it to a base fee:

baseFeePPM = MTB × 100

How MTB moves

1. CAP counted – every capped swap increments an internal budget counter.
2. Budget decays – counter leaks linearly over
capBudgetDecayWindow seconds.
3. Target comparison – if caps / day diverge from
targetCapsPerDay by ±15 %, MTB nudges (rate-limited by
baseFeeStepPpm and baseFeeUpdateIntervalSeconds).
4. Limits – never below minBaseFeePpm ÷ 100 ticks, never above
maxBaseFeePpm ÷ 100 ticks.

⸻

## Surge Fee Mechanism (Managed by DynamicFeeManager)

Trigger – notifyOracleUpdate(poolId, tickWasCapped) from the hook.
 • If tickWasCapped == true
 • inCap ← true
 • capStart ← now
 • surge0 = baseFee × surgeMultiplierPpm ÷ 1 000 000
 • If tickWasCapped == false
 • inCap flips to false only when
surge(now) == 0.
 • Decay

dt = now − capStart
if dt ≥ decayPeriod → surge = 0
else                → surge = surge0 × (decayPeriod − dt) ÷ decayPeriod

 • Re-cap during decay – resets capStart and surge to full; no compounding
above surge0.

⸻

## Total Fee Calculation

totalFeePPM = baseFeePPM + surgeFeePPM

The hook calls getFeeState(poolId) to obtain (base, surge) and
adds them.

⸻

## Fee Application During Swaps

 1. beforeSwap – hook asks DFM for current fee.
 2. PoolManager – uses that fee when calculating amounts.
 3. afterSwap – hook reports swap to Oracle.
 4. Oracle – decides whether the tick was capped.
 5. DFM – updates surge state via notifyOracleUpdate.

⸻

## Configuration Parameters (PoolPolicyManager)

Name Default Scope Consumed by
defaultTargetCapsPerDay 4 global Oracle
defaultCapBudgetDecayWindow 180 days global Oracle
defaultMinBaseFeePpm 100 global Oracle
defaultMaxBaseFeePpm 30 000 global Oracle
defaultSurgeDecayPeriodSeconds 3 600 s global DFM
_defaultSurgeFeeMultiplierPpm 3 000 000 global DFM
baseFeeStepPpm 20 000 per-pool Oracle
baseFeeUpdateIntervalSeconds 86 400 s per-pool Oracle

Pool-specific overrides exist for every parameter.

⸻

## Detailed Flows

Flow 1: Swap Without a CAP Event

 1. Hook gets fee (surge = 0).
 2. Oracle records uncapped tick.
 3. DFM receives tickWasCapped = false, makes no change.

Flow 2: Swap That Starts a CAP Event

 1. Oracle caps tick → returns true.
 2. DFM sets inCap = true, starts surge.
 3. Fee for next swap = base + surge.

Flow 3: Swap During an Ongoing CAP Event

Same as Flow 2, but inCap already true – timer is refreshed.

Flow 4: Swap That Ends a CAP Event

 1. Oracle returns false.
 2. DFM keeps surge but sets inCap = false.
 3. Surge now decays linearly.

Flow 5: Surge Fee Passive Decay

No swaps required; any later read of getFeeState reflects the lower surge.

Flow 6: Oracle-Driven Base Fee Rebalance

During any update, Oracle may increase or decrease MTB subject to
baseFeeStepPpm and baseFeeUpdateIntervalSeconds.

⸻

## FAQ

1. How is base fee computed? maxTicksPerBlock × 100.
2. Does surge depend on previous base fee? Yes, it multiplies the base fee
at the moment the cap starts.
3. Can base fee move while surge is decaying? Yes; surge decays
independently.
4. When does inCap clear? On the first notifyOracleUpdate(..., false)
after surge has fully decayed.
5. What if caps keep coming? Each one restarts the timer; surge never
exceeds its single-cap maximum.
6. What prevents abrupt base-fee jumps? A per-pool step·ppm cap and a
minimum interval in seconds.
7. Is the system deterministic? Yes; all state is pure on-chain and based
solely on block.timestamp and oracle outputs.

⸻

## Tests Implemented

Group Purpose Key Assertions
B1 – Default fee Verify quiet-market fee path Surge = 0, base = MTB×100
B2 – Fee bumps CAP triggers full surge surge = base × multiplier
B3 – Fee decay Base drops when caps are rare Base fee falls but not below min
Surge Decay Linear drop to zero 10 %, 50 %, 100 % checkpoints
Re-cap No surge compounding Second cap resets surge to max
POL share Fee splits honour params Fees routed

All tests run under Foundry; they warp time (vm.warp) and bump blocks
(vm.roll) to exercise decay logic.
A failing test indicates a breach of the intended invariant and stops the
suite.
