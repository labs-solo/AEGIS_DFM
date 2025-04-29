# Dynamic Fee System Explained

This document provides a comprehensive overview of the v4 dynamic fee system, detailing its components, mechanisms, configuration, and operational flows.

## 1. Introduction

The dynamic fee system is designed to adapt pool trading fees based on observed market conditions, specifically price volatility. Its primary goals are:

1. **Manipulation Resistance:** Increase fees rapidly during periods of extreme, potentially manipulative, price movements (CAP events) to protect liquidity providers (LPs) and the protocol.
2. **Cost Efficiency:** Minimize fees during normal market conditions to provide competitive pricing for traders.
3. **Adaptability:** Automatically adjust the baseline fee level over the long term based on the historical frequency of high volatility events.

The system achieves this through two core components: a long-term adaptive **Base Fee** and a short-term reactive **Surge Fee**.

## 2. Core Components

The total fee charged for a swap is the sum of the Base Fee and the Surge Fee.

* **Base Fee:** A dynamically adjusted fee component derived directly from the `maxTicksPerBlock` setting managed by the pool's designated Oracle (`TruncGeoOracleMulti`). It reflects the protocol's current tolerance for price movement within a single block. The Oracle adjusts this tolerance (and thus the base fee) over time based on the observed frequency of CAP events compared to a target rate.
* **Surge Fee:** A temporary, additional fee activated *immediately* when a CAP event occurs. It provides a rapid response to sudden volatility and decays linearly back to zero once the CAP event ends.

## 3. Base Fee Adjustment Mechanism (Oracle-Driven Feedback Loop)

Unlike some earlier designs, the `DynamicFeeManager` contract **does not** directly calculate or adjust the base fee based on historical CAP events. Instead, it relies entirely on the `TruncGeoOracleMulti` contract.

**The Base Fee is calculated as:**

\[ \text{Base Fee (PPM)} = \text{Oracle's Current } \texttt{maxTicksPerBlock} \times 100 \]

*Example:* If the Oracle currently allows a maximum movement of 50 ticks per block (`maxTicksPerBlock = 50`), the Base Fee will be \( 50 \times 100 = 5000 \) PPM (0.5%).

The **feedback loop** operates *within the Oracle* (`TruncGeoOracleMulti` and its base contracts like `AdaptiveFeeOracleBase`):

1. **CAP Event Detection:** The Oracle monitors tick movements during swaps (reported via hooks like `Spot`). If a tick movement attempts to exceed the current `maxTicksPerBlock` limit, the Oracle "caps" the reported tick movement to the maximum allowed value. This capping *is* the **CAP Event**.
2. **CAP Event Frequency Tracking:** The Oracle tracks the frequency of these CAP events over a defined window. It maintains an internal "budget" for CAP events.
3. **`maxTicksPerBlock` Adjustment (Feedback Loop):**
    * If CAP events occur *more frequently* than a configured target rate (e.g., `targetCapsPerDay` from `PoolPolicyManager`), the Oracle's internal budget depletes faster. This signals excessive volatility or potential manipulation, prompting the Oracle to *reduce* its `maxTicksPerBlock` value over time. A lower `maxTicksPerBlock` tightens the allowed price movement per block and, consequently, *lowers* the Base Fee.
    * If CAP events occur *less frequently* than the target rate, the Oracle's budget replenishes or stays high. This indicates stable conditions, allowing the Oracle to gradually *increase* its `maxTicksPerBlock` value (up to a configured maximum). A higher `maxTicksPerBlock` allows for more price movement before capping occurs and *increases* the Base Fee.
4. **Equilibrium:** The system seeks an equilibrium where the `maxTicksPerBlock` (and thus the Base Fee) is high enough to allow most normal market volatility without triggering CAP events but low enough to respond effectively to sustained, unusual price pressure. This equilibrium is influenced by the `targetCapsPerDay` parameter.

**Critical Parameters (Managed in `PoolPolicyManager` for the Oracle):**

* `defaultTargetCapsPerDay` / `poolTargetCapsPerDay`: The desired average number of CAP events per day the system aims for at equilibrium.
* `defaultCapBudgetDecayWindow` / `poolCapBudgetDecayWindow`: The time window over which the Oracle's internal CAP event budget counter decays.
* `defaultFreqScaling` / `poolFreqScaling`: A scaling factor used in the Oracle's internal frequency calculations.
* `defaultMinBaseFeePpm` / `poolMinBaseFeePpm`: The minimum allowed Base Fee (indirectly sets a minimum `maxTicksPerBlock` for the Oracle).
* `defaultMaxBaseFeePpm` / `poolMaxBaseFeePpm`: The maximum allowed Base Fee (indirectly sets a maximum `maxTicksPerBlock` for the Oracle).
* `capBudgetDailyPpm`: Related to the Oracle's internal budget calculation.
* `capBudgetDecayWindow`: The decay window for the Oracle's budget (potentially distinct from the *frequency* decay window above, needs verification against Oracle implementation).
* `defaultMaxTicksPerBlock`: An initial or default cap value used by the Oracle.

*(Note: The exact internal algorithms of `TruncGeoOracleMulti` for budget management and `maxTicksPerBlock` adjustment require direct inspection of its code but rely on these parameters from `PoolPolicyManager`.)*

## 4. Surge Fee Mechanism (Managed by `DynamicFeeManager`)

The Surge Fee provides an immediate, temporary increase in fees during CAP events.

1. **Trigger:** An authorized hook (e.g., `Spot.sol`) calls the `DynamicFeeManager.notifyOracleUpdate(poolId, tickWasCapped)` function after interacting with the Oracle during a swap. The `tickWasCapped` boolean indicates if the Oracle detected a CAP event for that pool in that transaction.
2. **Activation:**
    * If `notifyOracleUpdate` is called with `tickWasCapped = true` and the pool was *not* already in a CAP event (`inCap == false`):
        * The `DynamicFeeManager` sets the pool's state to `inCap = true`.
        * It records the current `block.timestamp` as the `capStart` time.
        * A `FeeStateChanged` event is emitted, including the *newly calculated* surge fee.
3. **Surge Fee Calculation:** The magnitude of the surge fee *while active* (or at the moment of activation) is calculated as:
    \[ \text{Current Surge Fee} = \frac{\text{Current Base Fee} \times \text{Surge Fee Multiplier (PPM)}}{1,000,000} \]
    The `Current Base Fee` is determined by the Oracle's `maxTicksPerBlock` at that moment, and the `Surge Fee Multiplier` is fetched from `PoolPolicyManager`.
4. **Deactivation & Decay:**
    * If `notifyOracleUpdate` is called with `tickWasCapped = false` and the pool *was* in a CAP event (`inCap == true`):
        * The `DynamicFeeManager` sets the pool's state to `inCap = false`.
        * The `capStart` timestamp is *retained* to mark the beginning of the decay period.
        * A `FeeStateChanged` event is emitted.
    * Once `inCap` becomes false, the surge fee begins to decay linearly back to zero. The decay duration is determined by `surgeDecayPeriodSeconds` from `PoolPolicyManager`.
    * The value at any time `t` after the CAP event ends (i.e., `t >= capStart`, where `capStart` is the timestamp recorded when `inCap` was last set to `false`) is:
        \[ \text{Decaying Surge Fee}(t) = \text{Initial Surge Value} \times \frac{\max(0, \text{decayPeriod} - (t - \text{capStart}))}{\text{decayPeriod}} \]
        Where `Initial Surge Value` is the surge fee calculated at the moment the CAP event *started* (when `inCap` was first set to `true`), and `decayPeriod` is `surgeDecayPeriodSeconds`. The decay starts from the value calculated when the CAP event *began*, not the value when it *ended*.

**Critical Parameters (Managed in `PoolPolicyManager` for `DynamicFeeManager`):**

* `defaultSurgeDecayPeriodSeconds` / `poolSurgeDecayPeriodSeconds`: The duration (in seconds) over which the surge fee decays linearly to zero after a CAP event ends.
* `_defaultSurgeFeeMultiplierPpm` / `_surgeFeeMultiplierPpm`: A multiplier (in PPM) applied to the current Base Fee to determine the magnitude of the Surge Fee when a CAP event is active. (e.g., 1,000,000 PPM = 1x Base Fee, 2,000,000 PPM = 2x Base Fee).

## 5. Total Fee Calculation

The `DynamicFeeManager` provides the `getFeeState(poolId)` view function and is called by hooks like `Spot.sol` via `getCurrentDynamicFee(poolId)` (which internally calls `getFeeState` or similar logic) before a swap.

**Total Fee (PPM) = Base Fee (PPM) + Surge Fee (PPM)**

* **Base Fee:** Calculated as `oracle.getMaxTicksPerBlock(poolId) * 100`.
* **Surge Fee:** Calculated based on the current `inCap` state, `capStart` timestamp, `surgeDecayPeriodSeconds`, `surgeFeeMultiplierPpm`, and the current Base Fee, as described in Section 4.

## 6. Fee Application During Swaps

1. **Before Swap:** The `Spot.sol` hook (or other relevant hook) calls `dynamicFeeManager.getCurrentDynamicFee(poolId)` via its `_beforeSwap` implementation.
2. **Fee Retrieval:** `DynamicFeeManager` calculates the current total dynamic fee (Base + Surge) based on the Oracle's state and its own surge state management.
3. **Return Fee:** The calculated dynamic fee is returned to the hook.
4. **PoolManager Notification:** The hook returns the dynamic fee to the `PoolManager`, which applies it to the swap calculations.
5. **After Swap:** The hook interacts with the Oracle (`oracle.update(...)`) to report swap details.
6. **Oracle Update & CAP Detection:** The Oracle processes the update, potentially capping the tick movement and determining if a CAP event occurred (`tickWasCapped`).
7. **Fee Manager Notification:** The hook calls `dynamicFeeManager.notifyOracleUpdate(poolId, tickWasCapped)`, passing the result from the Oracle.
8. **Fee Manager State Update:** `DynamicFeeManager` updates its internal state (`inCap`, `capStart`) based on the notification, potentially starting or ending a surge fee period or decay.

## 7. Configuration Parameters (`PoolPolicyManager`)

| Parameter                                | Scope      | Purpose                                                                                                     | Default Value (Example)        | Contract User        |
| :--------------------------------------- | :--------- | :---------------------------------------------------------------------------------------------------------- | :----------------------------- | :------------------- |
| `defaultTargetCapsPerDay`                | Global     | Oracle: Target avg. CAP events/day for equilibrium `maxTicksPerBlock`.                                       | 4                              | `TruncGeoOracleMulti`  |
| `poolTargetCapsPerDay`                   | Pool       | Oracle: Pool-specific override for `defaultTargetCapsPerDay`.                                                | 0 (uses default)               | `TruncGeoOracleMulti`  |
| `defaultCapBudgetDecayWindow`            | Global     | Oracle: Time window (seconds) for decaying the internal CAP frequency/budget counter.                         | 180 days                       | `TruncGeoOracleMulti`  |
| `poolCapBudgetDecayWindow`               | Pool       | Oracle: Pool-specific override for `defaultCapBudgetDecayWindow`.                                            | 0 (uses default)               | `TruncGeoOracleMulti`  |
| `defaultFreqScaling`                     | Global     | Oracle: Scaling factor for internal frequency calculations.                                                 | 1e18                           | `TruncGeoOracleMulti`  |
| `poolFreqScaling`                        | Pool       | Oracle: Pool-specific override for `defaultFreqScaling`.                                                     | 0 (uses default)               | `TruncGeoOracleMulti`  |
| `defaultMinBaseFeePpm`                   | Global     | Oracle: Minimum allowed Base Fee (PPM), implies min `maxTicksPerBlock`.                                     | 100 (0.01%)                    | `TruncGeoOracleMulti`  |
| `poolMinBaseFeePpm`                      | Pool       | Oracle: Pool-specific override for `defaultMinBaseFeePpm`.                                                   | 0 (uses default)               | `TruncGeoOracleMulti`  |
| `defaultMaxBaseFeePpm`                   | Global     | Oracle: Maximum allowed Base Fee (PPM), implies max `maxTicksPerBlock`.                                     | 30000 (3%)                     | `TruncGeoOracleMulti`  |
| `poolMaxBaseFeePpm`                      | Pool       | Oracle: Pool-specific override for `defaultMaxBaseFeePpm`.                                                   | 0 (uses default)               | `TruncGeoOracleMulti`  |
| `capBudgetDailyPpm`                      | Global (?) | Oracle: Daily budget parameter for CAP events (needs Oracle code confirmation).                             | 1e6 (?)                        | `TruncGeoOracleMulti`  |
| `capBudgetDecayWindow`                   | Global (?) | Oracle: Decay window for CAP budget (needs Oracle code confirmation).                                       | 180 days (?)                   | `TruncGeoOracleMulti`  |
| `defaultMaxTicksPerBlock`                | Global (?) | Oracle: Default/initial value for `maxTicksPerBlock`.                                                       | 50 (?)                         | `TruncGeoOracleMulti`  |
| `defaultSurgeDecayPeriodSeconds`         | Global     | DFM: Duration (seconds) for surge fee linear decay post-CAP event.                                          | 3600 (1 hour)                  | `DynamicFeeManager`    |
| `poolSurgeDecayPeriodSeconds`            | Pool       | DFM: Pool-specific override for `defaultSurgeDecayPeriodSeconds`.                                            | 0 (uses default)               | `DynamicFeeManager`    |
| `_defaultSurgeFeeMultiplierPpm`          | Global     | DFM: Multiplier (PPM) applied to Base Fee to get Surge Fee magnitude during CAP.                             | 3,000,000 (3x Base Fee)        | `DynamicFeeManager`    |
| `_surgeFeeMultiplierPpm`                 | Pool       | DFM: Pool-specific override for `_defaultSurgeFeeMultiplierPpm`.                                             | 0 (uses default)               | `DynamicFeeManager`    |
| `authorizedHook`                         | Global     | DFM: Address authorized to call `notifyOracleUpdate`. Set in DFM constructor/setter.                        | Deployed Hook Addr           | `DynamicFeeManager`    |

*(Note: Parameters marked (?) require deeper inspection of `TruncGeoOracleMulti` implementation details to fully confirm their exact usage and scope relative to potentially overlapping parameters like `defaultTargetCapsPerDay`.)*

## 8. Detailed Flows

**Flow 1: Swap (No CAP Event)**

1. `User` -> `SwapRouter.swap()`
2. `SwapRouter` -> `PoolManager.swap()` (passing `Spot` hook address)
3. `PoolManager` -> `Spot._beforeSwap()`
4. `Spot` -> `DynamicFeeManager.getCurrentDynamicFee(poolId)`
5. `DynamicFeeManager` -> `TruncGeoOracleMulti.getMaxTicksPerBlock(poolId)` (gets `cap`)
6. `DynamicFeeManager` calculates `baseFee = cap * 100`.
7. `DynamicFeeManager` checks `inCap` state. Assume `inCap == false`. Surge Fee = 0.
8. `DynamicFeeManager` returns `totalFee = baseFee + 0` to `Spot`.
9. `Spot` returns `totalFee` to `PoolManager`.
10. `PoolManager` executes swap logic using `totalFee`.
11. `PoolManager` -> `Spot._afterSwap()` (or similar hook point)
12. `Spot` -> `TruncGeoOracleMulti.update(...)`
13. `TruncGeoOracleMulti` processes update, determines price movement did *not* exceed `maxTicksPerBlock`. Returns `tickWasCapped = false`. Oracle potentially updates internal state for long-term base fee adjustment if interval passed.
14. `Spot` -> `DynamicFeeManager.notifyOracleUpdate(poolId, tickWasCapped = false)`
15. `DynamicFeeManager` sees `tickWasCapped = false` and `inCap == false`. No state change needed. Emits `FeeStateChanged` (base fee might have changed if Oracle adjusted `maxTicksPerBlock`).
16. Swap completes.

**Flow 2: Swap (Triggers CAP Event Start)**

1. ... (Steps 1-12 as above) ...
2. `TruncGeoOracleMulti` processes update, determines price movement *did* exceed `maxTicksPerBlock`. Caps the tick. Returns `tickWasCapped = true`. Oracle potentially updates internal state.
3. `Spot` -> `DynamicFeeManager.notifyOracleUpdate(poolId, tickWasCapped = true)`
4. `DynamicFeeManager` sees `tickWasCapped = true` and `inCap == false`.
    * Sets `inCap = true`.
    * Sets `capStart = block.timestamp`.
    * Calculates `currentSurge = currentBaseFee * multiplier / 1e6`.
    * Emits `FeeStateChanged(poolId, currentBaseFee, currentSurge, isInCap = true)`.
5. Swap completes. The pool is now in a CAP event, and the surge fee is active.

**Flow 3: Swap (During CAP Event)**

1. ... (Steps 1-4 as above) ...
2. `DynamicFeeManager` -> `TruncGeoOracleMulti.getMaxTicksPerBlock(poolId)` (gets `cap`)
3. `DynamicFeeManager` calculates `baseFee = cap * 100`.
4. `DynamicFeeManager` checks `inCap` state. Finds `inCap == true`.
5. `DynamicFeeManager` calculates `currentSurge = baseFee * multiplier / 1e6`.
6. `DynamicFeeManager` returns `totalFee = baseFee + currentSurge` to `Spot`.
7. ... (Steps 9-12 as above) ...
8. `TruncGeoOracleMulti` processes update. Let's assume movement still exceeds `maxTicksPerBlock`. Returns `tickWasCapped = true`. Oracle potentially updates internal state.
9. `Spot` -> `DynamicFeeManager.notifyOracleUpdate(poolId, tickWasCapped = true)`
10. `DynamicFeeManager` sees `tickWasCapped = true` and `inCap == true`. No state change needed regarding `inCap` or `capStart`. Emits `FeeStateChanged` (base/surge might have changed if Oracle adjusted `maxTicksPerBlock`).
11. Swap completes. Pool remains in CAP event.

**Flow 4: Swap (Triggers CAP Event End)**

1. ... (Steps 1-7 as Flow 3) ...
2. `DynamicFeeManager` returns `totalFee = baseFee + currentSurge` to `Spot`.
3. ... (Steps 9-12 as above) ...
4. `TruncGeoOracleMulti` processes update. Price movement is now *within* `maxTicksPerBlock`. Returns `tickWasCapped = false`. Oracle potentially updates internal state.
5. `Spot` -> `DynamicFeeManager.notifyOracleUpdate(poolId, tickWasCapped = false)`
6. `DynamicFeeManager` sees `tickWasCapped = false` and `inCap == true`.
    * Sets `inCap = false`.
    * Keeps the existing `capStart` timestamp.
    * Calculates decaying surge based on `capStart` and `block.timestamp`.
    * Emits `FeeStateChanged(poolId, currentBaseFee, decayingSurge, isInCap = false)`.
7. Swap completes. Pool is no longer in CAP event, surge fee starts decaying.

**Flow 5: Surge Fee Decay (Time Passing)**

* Time passes (`vm.warp` in tests, real time otherwise).
* No swaps occur, so `notifyOracleUpdate` is not called.
* The `inCap` state remains `false`.
* If `getFeeState` or `getCurrentDynamicFee` is called (e.g., by a view function or the next swap's `_beforeSwap`):
  * `DynamicFeeManager` calculates Base Fee from the Oracle.
  * It checks `inCap == false`.
  * It calculates the decaying surge fee using the stored `capStart` timestamp, the *current* `block.timestamp`, the decay period, and the surge value from when the CAP event *started*.
  * As `block.timestamp` increases, the calculated decaying surge decreases linearly, eventually reaching zero when `block.timestamp - capStart >= surgeDecayPeriodSeconds`.

**Flow 6: Base Fee Adjustment (Oracle Driven)**

* This happens *inside* the `TruncGeoOracleMulti` contract, typically during its `update` function call triggered by the hook (`Spot._afterSwap`).
* The Oracle compares the recent frequency of CAP events (tracked internally using its budget/decay mechanism) against the `targetCapsPerDay`.
* Based on this comparison and potentially other factors (like time since last adjustment), the Oracle decides whether to increase or decrease its internal `maxTicksPerBlock` value, respecting the min/max limits implied by `min/maxBaseFeePpm`.
* Subsequent calls to `DynamicFeeManager.getCurrentDynamicFee` will read the new `maxTicksPerBlock` from the Oracle and calculate the updated Base Fee accordingly.

## 9. FAQ

**Q1: What is a CAP event?**
**A:** A CAP event occurs when the price movement within a single transaction (as detected by the Oracle) attempts to exceed the maximum number of ticks allowed by the Oracle's current `maxTicksPerBlock` setting. The Oracle "caps" the movement, and this event triggers the surge fee mechanism.

**Q2: Who adjusts the Base Fee?**
**A:** The `TruncGeoOracleMulti` contract adjusts its own `maxTicksPerBlock` setting over time based on observed CAP event frequency relative to a target rate. The `DynamicFeeManager` *derives* the Base Fee directly from the Oracle's current `maxTicksPerBlock` (`Base Fee = maxTicksPerBlock * 100 ppm`). The Fee Manager itself does not run the adjustment logic.

**Q3: Why have both Base and Surge Fees?**
**A:** They operate on different timescales and serve different purposes.

* **Surge Fee:** Immediate, sharp reaction to protect against sudden, large price swings or manipulation. Decays quickly once the event passes.
* **Base Fee:** Long-term adaptation based on historical volatility. Adjusts gradually to set a baseline fee appropriate for the pool's typical market conditions, influenced by the target CAP rate.

**Q4: How is the "ideal" Base Fee determined?**
**A:** The system doesn't target a specific Base Fee value directly. Instead, it targets a *rate* of CAP events per day (`targetCapsPerDay`). The Oracle adjusts `maxTicksPerBlock` (which determines the Base Fee) up or down until the observed CAP frequency matches the target frequency, reaching an equilibrium. A higher target rate generally leads to a lower equilibrium Base Fee, and vice-versa.

**Q5: What happens if `surgeDecayPeriodSeconds` is set to 0?**
**A:** The `DynamicFeeManager._surge` function specifically handles this by returning 0 surge fee. A zero decay period effectively disables the surge fee component.

**Q6: Can the Surge Fee change *during* a CAP event?**
**A:** Yes. The Surge Fee magnitude is calculated as `Base Fee * Multiplier / 1e6`. Since the Base Fee depends on the Oracle's `maxTicksPerBlock`, and the Oracle *can* potentially adjust this value even during an ongoing CAP event (e.g., if an adjustment interval passes), the Base Fee could change, which would in turn change the Surge Fee calculated in subsequent blocks/transactions while the CAP event is still active.

**Q7: How does this differ from previous dynamic fee designs?**
**A:** Older designs (like the one potentially described in `docs/Dynamic_Fee_Requirements.md` referencing `FullRangeDynamicFeeManager.sol`) might have had the Fee Manager contract itself track CAP frequency and directly adjust the Base Fee. The current system delegates the adaptive Base Fee logic (via `maxTicksPerBlock`) entirely to the Oracle (`TruncGeoOracleMulti`), simplifying the `DynamicFeeManager`'s role to primarily managing the Surge Fee lifecycle and reporting the total fee based on the Oracle's state.

**Q8: Who can change the fee parameters?**
**A:** Only the `owner` of the `PoolPolicyManager` contract can change the global default parameters and pool-specific overrides.

**Q9: What if the authorized hook fails to call `notifyOracleUpdate`?**
**A:** The `DynamicFeeManager`'s surge state (`inCap`, `capStart`) would not be updated. This could lead to surge fees not activating when they should, or not starting their decay when they should. The reliability of the hook mechanism is crucial.

**Q10: Where does the fee revenue go?**
**A:** The total dynamic fee (Base + Surge) is collected by the `PoolManager` during a swap. How this fee revenue is allocated (e.g., to LPs, protocol treasury/POL) is determined by other policies configured in `PoolPolicyManager` (like `polSharePpm`, `lpSharePpm`) and handled by the liquidity management and claiming mechanisms, which are separate from the dynamic fee calculation itself. 