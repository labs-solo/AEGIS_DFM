# AEGIS DFM Simulation – Revised Implementation Spec (Phase 2 to Phase 5)

## Phase 2: Dynamic Fee Simulation Implementation

**Overview:** Phase 2 focuses on simulating the AEGIS Dynamic Fee Model over a short horizon, with updated frequency and detailed logging. We simulate price movements and swap events, track fee dynamics (base vs. surge fees), and identify **CAP events** (volatility-induced price caps). The following changes and requirements are incorporated:

### 1. Simulation Timeline and Swap Frequency

* **Swap Interval:** Reduce the time step from hourly to **5-minute intervals**. Each swap now represents a 5-minute block of trading.
* **Daily Swaps:** 288 swaps per day (5 min \* 288 = 24 hours).
* **Simulation Duration:** Simulate a total of **3 full days** per scenario, resulting in **864 sequential swaps** (blocks) per run.
* The simulation loop will iterate 864 times, updating prices and applying the fee model on each step. This provides higher temporal resolution to capture rapid market changes and fee adjustments.

### 2. Price Path Generation and CAP Event Semantics

* **Synthetic Price Data:** Generate a realistic ETH/BTC price path for two distinct volatility scenarios (detailed in section 5 below). Each swap uses a new price observation from this data (fed by an oracle in the simulation).
* **CAP Events:** *Clarification:* **Swaps themselves are not “capped”**. Instead, the **oracle price feed can be truncated** if a price change exceeds a configured **max tick delta**. In other words, if the true market price moves too sharply between observations, the oracle limits the reported change to the maximum allowed delta. This truncation triggers a **CAP event**:

  * **CAP Event Start:** When a price observation is **capped/truncated by the oracle**, mark the start timestamp of a CAP event. The pool’s recorded price is held at the cap (not reflecting the full market jump).
  * **CAP Event Ongoing:** While subsequent swaps continue and the “true” market price remains beyond the cap threshold, the oracle will keep capping each observation. The CAP event is considered ongoing throughout this period. Swaps still execute, but the price input is artificially constrained.
  * **CAP Event End:** When the market volatility subsides such that the next oracle price update does **not** require truncation (i.e. the observed price delta is within the allowed range), the CAP event ends. Record the end timestamp. At this point, the pool’s price feed is no longer being limited by the cap.
* **Effect:** During a CAP event, the pool’s price lags behind the true market price, creating potential arbitrage opportunities but also activating surge fees (see below) to compensate liquidity providers and discourage excessive exploitation.

### 3. Base Fee and Surge Fee Mechanism

* **Base Fee (BaseFeePPM):** The baseline swap fee (in parts-per-million) that applies to all swaps. This fee is dynamic, bounded by configured `minBaseFeePPM` and `maxBaseFeePPM`. The base fee adjusts based on market conditions:

  * In stable periods (no CAP events), the base fee tends to drift downwards toward the minimum, encouraging trading.
  * In high-volatility periods (frequent CAP events), the base fee can increase toward the maximum to capture more fees and protect liquidity.
* **Surge Fee:** An *additional* fee applied on top of the base fee **only during CAP events**. The surge fee is designed to temporarily charge extra fees when volatility is extreme (i.e., when the oracle is capping prices):

  * When a CAP event starts, set a surge fee (e.g., a percentage of swap value or in PPM) to immediately apply to swaps during the CAP event. This represents an elevated fee due to abnormal volatility.
  * **Decay Behavior:** After the CAP event, the surge fee **decays linearly back to 0** over a configured **decay window** (for example, 3600 seconds = 1 hour). This means once volatility subsides and the event ends, the extra fee will gradually diminish to zero, rather than dropping off instantly. If a new CAP event occurs during a decay, the surge fee may be reset/increased again.
  * **Independence:** Notably, **the surge fee’s presence is not identical to CAP event status**. A surge fee might still be partially in effect (decaying) even after a CAP event has ended. Conversely, if a CAP event lasts a long time, the surge fee might remain at its set level (it could even be configured to refresh or step up if the event is prolonged).
* **Total Fee per Swap:** Each swap’s fee = base fee + surge fee (if any). During normal periods, total fee = base fee (since surge = 0). During a CAP event, total fee = base fee + current surge fee (which could be at initial high value or a decaying value if towards the end of the event). All fee rates are in PPM (parts per million) of the swap notional, unless otherwise specified.

### 4. Logging Requirements (CAP Events & Fees)

The simulation will produce detailed logs to track events and fees, both for analysis and for verification in tests:

* **CAP Event Log:** Maintain a log of each CAP event with the following details:

  * **Start Timestamp:** Simulation timestamp or block number when the event began.
  * **End Timestamp:** Timestamp/block when the event ended.
  * **Duration:** Computed duration of the event (in seconds or number of 5-min intervals).
    Each CAP event corresponds to a contiguous sequence of capped observations. This log will be written to a CSV file (`cap_event_log.csv`) for easy analysis.
* **Per-Swap Logging:** For each swap (each 5-min interval), record:

  * Timestamp (or day index and interval) of the swap.
  * **CAP Status Flag:** A boolean or indicator if a CAP event is active *during that swap*. (True if the price input was capped on that swap, false if not). This essentially flags the blocks that occur inside a CAP event window.
  * **Base Fee Charged:** The base fee portion charged for that swap (in whatever units, likely PPM or as an absolute amount if notional is known).
  * **Surge Fee Charged:** The surge fee portion charged (if any, else 0 if no CAP or post-decay).
  * **Total Fee:** The sum of base + surge fees for that swap.
  * (Optional) The current BaseFeePPM level at that time, if base fee is dynamically adjusting over time.
    These per-swap details may be written to a log file or kept in memory for aggregation. Storing all swaps in a CSV can aid debugging but also can be large (864 lines per scenario run, which is fine).
* **Daily Aggregation:** At the end of each simulated day (every 288 swaps), aggregate the fees and events:

  * Sum of base fees collected that day.
  * Sum of surge fees collected that day.
  * Total fees (base+surge) collected that day.
  * Number of CAP events that started during that day (CapEventCount).
  * The **BaseFeePPM level** at the end of that day (to see fee trend) – assuming base fee might adjust slowly, this value captures where it landed by day’s end.
  * The date (Day 1, Day 2, Day 3 or actual calendar date if we assign one) for clarity.
    These daily metrics will be written to a CSV report (`fee_and_cap_metrics.csv`) with one line per day. This provides a high-level view of system behavior per day.

### 5. Scenario Design – Low vs. High Volatility

We will run **two distinct scenarios** to test the system under different volatility regimes, using synthetic but realistic price paths for an ETH/BTC market:

* **Scenario A: Low Volatility** – This scenario simulates relatively stable market conditions:

  * Price changes per 5-min interval are small and smooth (e.g., mild random walk with a low standard deviation, perhaps <0.5% swings). The maximum tick delta threshold is rarely hit.
  * CAP events should be **rare or non-existent** here. Perhaps only 0 or 1 short-lived CAP event in the entire 3-day run (if at all).
  * Expectation: The base fee remains at or near **minBaseFeePPM** throughout, since volatility never forces it upward. Surge fees would almost never be applied (approximately 0 total surge fees). This tests the baseline behavior of the system in calm markets.
* **Scenario B: High Volatility** – This scenario simulates a very turbulent market:

  * Price changes are large and frequent. For example, incorporate sudden jumps or drops of several percent within a single 5-minute interval, exceeding the oracle’s max delta cap regularly. The price might surge upward or downward and stay volatile for an extended period.
  * **Frequent CAP events:** Each time a large jump occurs, the oracle caps the change, triggering a CAP event. We ensure some events last multiple intervals (e.g., a sustained price move such that even after one cap, the next interval’s true price is still beyond the cap, continuing the CAP event for several steps). CAP events lasting multiple minutes (several 5-min blocks) should occur multiple times in 3 days.
  * Expectation: The base fee will respond by increasing (eventually reaching **maxBaseFeePPM** if volatility persists) to reflect the heavy usage/volatility. Multiple CAP events will be logged. Significant **surge fees** will be collected during those events, contributing to total fees. This scenario tests the system’s protective fee mechanism under stress.
* **Price Path Generation:** Use a pseudo-random generator (with a fixed seed for reproducibility in tests) to create price sequences:

  * Possibly utilize a Geometric Brownian Motion model or random walk with configurable volatility. For low vol, use a very low sigma; for high vol, use a high sigma and inject occasional large shock moves.
  * Ensure the starting price is the same for both scenarios (for comparability, e.g., start ETH/BTC at some value like 0.07) and apply different random seeds or parameters to get divergent volatility profiles.
  * The “oracle cap” logic will be applied on top of this raw price path to determine when a CAP event occurs (i.e., compare each interval’s percent change to the max allowed change). If the change exceeds threshold (say threshold = X% or certain ticks), cap it and flag CAP status.

### 6. Metrics Output Files

All important results from the Phase 2 simulation runs will be saved under the `simulation/results/` directory as CSV files for later analysis (and use in Phase 4 dashboard):

* **Daily Fee & CAP Metrics (`results/fee_and_cap_metrics.csv`):** This CSV contains one row per simulated day for the scenario run. Columns:

  * **Date:** The date or day index of the simulation (e.g., Day 1, Day 2, Day 3 or a formatted date if a start date is assumed).
  * **BaseFeePPM:** The base fee (in PPM) in effect at the end of that day. (If base fee didn’t change intra-day, this could just be the constant value. If it adjusts per block, this could be the value after the final swap of the day.)
  * **CapEventCount:** How many CAP events started during that day.
  * **TotalBaseFeeCollected:** Sum of base fees from all swaps that day (in whatever unit, e.g., PPM applied to notional – for relative comparison we can keep it in fee units or convert to an absolute value if we assume a notional trade size).
  * **TotalSurgeFeeCollected:** Sum of surge fees from all swaps that day.
  * **TotalFeeCollected:** Sum of total fees (base + surge) from all swaps that day.
    *Note:* These values are scenario-dependent. We will produce separate CSVs for each scenario run (or include a scenario identifier column if combining data).
* **CAP Event Log (`results/cap_event_log.csv`):** A detailed log of each CAP event during the simulation. Each row represents one CAP event with columns:

  * **StartTimestamp:** Simulation timestamp or block number where the event began (e.g., “Day2 13:35” or a UNIX-like time counter).
  * **EndTimestamp:** When the event ended.
  * **Duration:** Duration of the event (in seconds or number of 5-minute intervals).
  * (Optional) **PeakDelta:** Possibly record how much the true price move was beyond the cap (if available), or an identifier for the event.
    This log helps analyze how long and how often extreme volatility periods occur. It will be useful for verifying that in low-vol scenarios this file is nearly empty, and in high-vol it has multiple entries.

All files should be written in CSV format with headers. Ensure that writing these results does not significantly slow down the simulation (we can accumulate data in memory and write out once at end of day or end of run for efficiency).

### 7. Verification Tests for Phase 2

We implement two automated tests to verify that the simulation meets the expected outcomes for each scenario:

* **Test Low Volatility (`test_base_fee_down.py`):** This test runs the 3-day simulation on the low-volatility scenario. After completion, it asserts that:

  * The final `baseFeePPM` equals the configured `minBaseFeePPM`. In a calm market, the base fee should either remain at minimum or drop to it. This confirms no upward fee pressure.
  * The total surge fees collected over the 3 days is approximately 0. It should be essentially zero since no CAP events should have triggered any meaningful surge fees. (We allow a tiny epsilon in case of any rounding or a single trivial event, but ideally it’s exactly 0 if no CAP ever happened.)
  * Additionally, we expect `CapEventCount` for each day to be 0 in the metrics output, which can be checked as well.
* **Test High Volatility (`test_base_fee_up.py`):** This test runs the 3-day simulation on the high-vol scenario and asserts that:

  * The final `baseFeePPM` equals the configured `maxBaseFeePPM`. Under sustained high volatility, the base fee should ratchet up to its cap, indicating the model responded to continuous CAP events by increasing the baseline fee to maximum.
  * Multiple CAP events occurred over the 3 days. We can assert that the `CapEventCount` in the metrics for at least one of the days (or total events count across days) is greater than 1 (in practice, each day in a high-vol scenario might have several events). The `cap_event_log.csv` should contain multiple entries.
  * A non-zero surge fee was charged overall. Specifically, `TotalSurgeFeeCollected` over 3 days should be > 0 (likely substantial). We might also check that on at least one day, surge fees are > 0 and maybe base fees < total fees to ensure surge component was present.
  * (Optionally, verify that during CAP events the total fee per swap logged was base+surge, and outside events it was base-only. But this is more granular and can be covered by inspecting log outputs if needed.)
* Both tests should also confirm that the CSV output files are produced and contain the expected columns and rows (e.g., 3 rows for 3 days, etc.). The tests use the data to assert correctness of the logic. We will use a fixed random seed for price generation to ensure deterministic behavior for these tests (making the volatility outcomes predictable).

### 8. Performance and CI Considerations

* The simulation and logging code must be efficient to execute, as we will be running it in CI (GitHub Actions) for tests and later phases. The target is to **complete Phase 2 simulation (both scenarios) and all tests within 5 minutes** on the CI runner.
* **Optimizations:** Using 5-minute intervals (864 swaps) is relatively light, but ensure no extremely slow operations:

  * Use vectorized operations or efficient loops for generating price paths.
  * Avoid excessive file I/O inside the swap loop – aggregate in memory and write out at the end of each day or end of run.
  * Limit logging verbosity during the run (e.g., print statements) in CI mode to avoid overhead.
* We will verify that the end-to-end runtime for both test scenarios is well under the limit (likely a few seconds per scenario). If the high-vol scenario involves expensive computations (e.g., iterative solving), consider simplifying the model or using faster approximations to maintain speed.
* **Determinism:** Set random seeds for scenario generation to avoid flakiness in CI tests. This ensures consistent pass/fail outcomes and comparable metrics across runs.
* By meeting these performance constraints, we ensure that as we progress to longer simulations (Phase 4) and additional features, the CI pipeline remains fast and reliable.

## Phase 3: Swap Planner and Dual-Pool Loop Extension

**Overview:** Phase 3 extends the simulation to incorporate a **swap planner** and a **dual-pool trading loop**. This will allow us to simulate interactions between two liquidity pools (or a pool and an external market) and test how the dynamic fee model handles arbitrage and route planning, especially under CAP events. All new logic introduced in Phase 2 (CAP events, surge fees, fee logging) will be maintained and utilized in this phase.

### Dual-Pool Simulation Setup

* **Two Pools:** We introduce a second pool into the simulation environment. For example:

  * **Pool A (AEGIS DFM Pool):** The primary pool with the dynamic fee model (from Phase 2) – featuring adaptive base fee and surge fees on CAP events. (E.g., an ETH/BTC pool using our AEGIS DFM logic.)
  * **Pool B (Reference Pool):** A secondary pool or market for the same asset pair (ETH/BTC) that does **not** use the dynamic fee model. This could represent a standard constant-fee AMM or an oracle for the “true” market price. Pool B might have a fixed fee (say 0.3%) or no fee, and it always reflects the true market price movements without caps.
* **External Price Input:** We will use Pool B or an external price feed as the driver of “true” price. Pool A’s oracle price feed (used in Phase 2) can be derived from this true price but with caps applied. Essentially, Pool B’s price will move freely according to the scenario (as an uncapped reference), while Pool A’s price is subject to the same movements but with the CAP event mechanism limiting its rate of change. This setup naturally creates divergences between Pool A and Pool B during extreme volatility.

### Swap Planner Logic

* **Purpose:** The swap planner simulates a trader or arbitrageur that observes price discrepancies between the two pools and plans swaps to exploit or mitigate these differences. This is effectively modeling arbitrage trades that should occur in a real market when one pool’s price lags behind or deviates from the other.
* **Detection of Arbitrage Opportunity:** At each 5-minute interval (or whenever prices update), the planner checks the price in Pool A vs Pool B:

  * If the price of ETH/BTC in Pool A is lower than in Pool B (e.g., Pool A’s price is capped and hasn’t caught up to a surge in Pool B’s price), an arbitrage opportunity exists to **buy cheap on Pool A and sell high on Pool B**.
  * Conversely, if Pool A’s price is higher than Pool B’s (could happen if Pool A had a delayed drop), one could sell on A and buy on B.
* **Swap Execution:** When an opportunity is detected, the planner will execute a **two-legged swap** (a loop trade):

  1. Swap on Pool A: trade in the direction that moves Pool A’s price toward Pool B’s price. For example, if Pool A is underpriced, buy from Pool A (which will push its price up, helping close the gap). If Pool A is overpriced, sell into Pool A (pushing its price down).
  2. Counter-trade on Pool B: complete the loop by swapping the acquired asset in Pool B back to the original asset. This yields a net profit if the price discrepancy exceeded fees, or breaks even if just aligning prices. Pool B’s large liquidity or external nature means its price might not move significantly from this trade (or we assume infinite liquidity for simplicity).

  * The swap planner needs to decide how much to trade. A simple strategy: trade just enough volume to equalize the prices (or to the point where the profit margin equals zero due to fees). For simulation, we might assume an infinitesimal arbitrage that equalizes instantly, or a fixed trade size and multiple iterations.
  * **Fees Consideration:** The planner accounts for fees on both pools. In Pool A, the fee could include a surge fee if a CAP event is active. In Pool B, use the fixed fee. The planner will only execute the arbitrage if the price difference *minus the total fees* yields a positive profit. This means if a surge fee is very high (during a CAP event), it might deter the arbitrage until the fee decays enough or the price gap widens further.
* **Iterative Loop:** The simulation’s main loop now includes:

  1. Update true price (Pool B) for the new interval.
  2. Update Pool A’s oracle price with cap if needed (potentially start or continue a CAP event).
  3. **Planner checks for arbitrage** and executes swaps as necessary:

     * This may be done in a while-loop until no more profitable arb remains (to simulate arbitrageurs quickly clearing the discrepancy). Or simply one trade per interval if we assume only one opportunity is taken.
     * Each arbitrage trade on Pool A will generate fee revenue (base and possibly surge) and move Pool A’s price closer to Pool B.
  4. Log any trades made (could log the profit, volumes, and fees paid).
  5. Proceed to next interval.
* This framework effectively ties Pool A’s price to Pool B’s price with a realistic delay: during CAP events, Pool A can’t keep up immediately, but the arbitrage trades will gradually push it toward Pool B, paying surge fees in the process. We’ll capture how effective and costly that is.

### Logging and Metrics (Phase 3 Additions)

All logging from Phase 2 (CAP events, fees, daily aggregates) remains in place for Pool A. Additional data to capture in Phase 3:

* **Arbitrage Trade Log:** Log each swap planner action (optional but useful):

  * Timestamp, trade direction (A->B or B->A first), volume traded, profit achieved (after fees), and whether a CAP event was active (meaning a surge fee was paid).
  * This can illustrate how often arbitrage is happening and the cost. It’s especially interesting to see trades during CAP events (surge fee > 0) vs outside.
* **Price Discrepancy Tracking:** (Optional) Log the price of Pool A and Pool B each interval to see the gap and how quickly it closes. This can be analyzed later to evaluate the impact of surge fees on alignment speed.
* **Fee Impact:** We will observe in metrics how much fee Pool A accumulates specifically from these planner swaps. In high volatility, many arbitrage loops might occur, generating significant fee (which is by design to compensate LPs).
* We will keep the same `fee_and_cap_metrics.csv` structure for Pool A’s daily fees (which now include fees from regular and arbitrage swaps alike). We may extend it with additional columns if needed (e.g., total volume arbitraged per day, etc., if desired for analysis).
* No separate metrics file for Pool B since it’s a reference; we assume it has deep liquidity and negligible price impact from trades (or we can track its price if using finite liquidity, but likely not needed for spec).

### Adjustments for CAP and Fees in Planner

* The presence of CAP events and surge fees directly influences the planner’s behavior. We ensure the planner logic is aware of:

  * **Current Surge Fee Level:** If Pool A is in a CAP event, any swap on Pool A pays the extra fee. The planner factors this into the profit calculation. For instance, if the surge fee is very high (cutting deep into profit), the planner might choose not to trade the full discrepancy or wait (we could model this as the planner taking smaller bites if profit is thin).
  * **Multi-interval Effects:** If a CAP event persists, the planner might come back every interval to continue arbitraging as the price cap slowly moves or as surge fee decays, until prices equalize or the CAP event ends.
  * Essentially, the dynamic fee model will throttle the rate of arbitrage: a high surge fee means only a large price gap yields profit, so some discrepancy can remain until the fee decays.
* We will verify that the planner indeed stops trading when surge fee eliminates profit, and resumes when either price gap widens or fee decays. This emergent behavior will confirm the model’s effectiveness.

### Testing & Validation (Phase 3)

We will add tests or assertions to ensure Phase 3’s dual-pool system behaves correctly:

* After a volatility event in Pool B that triggers a CAP in Pool A, verify that Pool A’s price does eventually track back to Pool B’s price by the end of the event (arbitrage closes the gap).
* Ensure that during a sustained CAP event, multiple arbitrage swaps occur and that fees collected by Pool A during that period are significant (and surge fee is indeed charged on those swaps).
* Verify no arbitrage trade occurs when there’s no price discrepancy (planner should not do pointless trades).
* The outcomes (like final baseFeePPM) in extreme scenarios should still align with expectations: e.g., if Phase 3 high-vol scenario is similar to Phase 2, baseFee should still reach max, etc. The introduction of the planner shouldn’t break the fee logic – rather, it should just generate the trades that pay those fees.
* We will reuse the seeded randomness for price in Pool B and have deterministic planner behavior for test reproducibility. If needed, we might fix an arbitrage trade size for consistency.

**Note:** Phase 3 sets the stage for analyzing the economic outcomes (profits vs fees) which will be explored in Phase 4. At the implementation level, Phase 3 introduces the complexity of simulating two pools and an agent, but should still run within reasonable time since each interval’s operations are straightforward.

## Phase 4: Metrics Dashboard and 6-Week Simulation Run

**Overview:** In Phase 4, we perform a longer-term simulation to observe the dynamic fee model over an extended period (e.g., 6 weeks), and we develop a **metrics dashboard** to visualize and interpret the results. We incorporate the new CAP event and fee-tracking logic into our analysis. The goal is to validate the stability of the model over time and present the data in an accessible format.

### Extended 6-Week Simulation

* **Duration:** Run the simulation for **6 weeks (42 days)** of virtual time at 5-minute swap intervals. This results in 42 \* 288 = **12,096 swaps** per scenario. We may choose to run both low-vol and high-vol scenarios for 6 weeks each, or a combined scenario that includes varying volatility phases:

  * One approach is to simulate a **realistic volatility schedule**: mostly low volatility days with a few high-volatility days interspersed (to mimic real market behavior). This would test how the base fee rises during the volatile periods and falls back during calm periods. For example, weeks 2 and 5 could have high-volatility events, the rest relatively calm.
  * Alternatively, run two separate 6-week simulations: one consistently low-vol, one consistently high-vol, to see the long-term extremes of each regime.
* **Data Collection:** As in Phase 2/3, log all swaps, CAP events, and daily aggregates. Over 42 days, we will have a much larger `fee_and_cap_metrics.csv` (42 rows per run) and a comprehensive `cap_event_log.csv`. Ensure the logging is done efficiently (writing once per day, etc., to handle the length).
* **Performance:** 12k swaps is still manageable; however, we will ensure that running the full 6-week simulation and generating the dashboard stays within CI limits if we automate it. If needed, we might limit the dashboard generation to local runs or sample the data for CI. (However, given 12k steps, it should be fine to run in a few seconds or tens of seconds, plus time for plotting.)

### Metrics Dashboard Development

* **Purpose:** The dashboard will compile the simulation outputs into meaningful visuals and summaries, highlighting the dynamic fee model’s behavior, especially focusing on CAP events and fee collection over time.
* **Implementation:** We will likely use a Jupyter Notebook or a Python script (possibly with libraries like Matplotlib or Plotly) to create the dashboard. This dashboard will not be a live web service but rather a generated report (e.g., an HTML or PDF, or just the notebook to view).
* **Key Visualizations and Analyses:**

  * **Price and CAP Events Timeline:** Plot the price of Pool A vs Pool B over the 6-week period (or a representative subset) and mark periods where CAP events were active. This could be a line chart with shaded regions indicating CAP events. It will show how the pool’s price deviates and recovers.
  * **Base Fee and Surge Fee Over Time:** Plot the baseFeePPM value over time (it may step up during volatile periods and possibly step down during calm periods if such logic exists) and the surge fee level. We expect to see base fee at min most of the time in calm scenario, and spiking to max in sustained volatility. The surge fee will spike during each CAP event then decay – we can visualize one example CAP event’s surge fee decay curve.
  * **Daily Fees Collected:** Use the `fee_and_cap_metrics.csv` to plot bar charts of daily fees:

    * Base vs Surge fees per day (stacked bar or side-by-side) to see how on high-vol days the surge component towers, whereas on calm days only base fees (tiny if volume low) are collected.
    * Total fees per day and highlight which days had CAP events (likely correlating with higher fees).
    * Possibly cumulative fees over weeks to show overall revenue.
  * **CAP Event Stats:** Analyze the `cap_event_log.csv`:

    * Calculate distribution of CAP event durations (histogram of how long events last).
    * Number of CAP events per week.
    * Perhaps the percentage of time the system was in a CAP event state each week.
    * This gives a sense of how often the circuit-breaker mechanism kicks in and for how long.
  * **Arbitrage/Swap Planner Outcome:** If Phase 3’s dual-pool system is active in this run, we could also visualize:

    * The price difference between pools vs time.
    * The cumulative profit made by the arbitrageur vs cumulative fees paid (this could show that most of the profit is essentially transferred to LPs via fees in high vol).
    * However, this level of detail might be beyond what’s asked; focus primarily on fees and CAP.
* **Dashboard Format:** The notebook will clearly section these analyses, using titles and captions. We will ensure plots have legends and labels (especially distinguishing base fee vs surge fee, etc.). If possible, interactive elements (like toggling scenario or zooming) could be included using Plotly, but static images are acceptable for documentation purposes.
* **Comparing Scenarios:** If we run both low-vol and high-vol 6-week scenarios, the dashboard will compare them side by side:

  * e.g., two subplots for base fee over time in each scenario, or two bars for fees per day for low vs high volatility, showing dramatic differences.
  * This reinforces how the dynamic model behaves in extremes.
* We’ll include textual analysis in the dashboard, noting observations (e.g., “On Days 10-12 a sustained CAP event caused the base fee to max out at 10000 PPM and surge fees contributed 80% of fees collected on those days.”).

### Ensuring Consistency with New Logic

Throughout the dashboard and extended run, all the new Phase 2/3 logic is accounted for:

* CAP events are identified exactly as per the semantics clarified (and the code for it is the same).
* Surge fee application and decay are exactly as implemented, so the visualization of a surge decay will confirm it works (e.g., seeing a triangular decay shape in fee per swap).
* BaseFee adjustments up to max/down to min are captured and clearly shown.
* The documentation (legends, captions) will use the same terminology (CAP event, base fee, surge fee) as the spec to avoid confusion.

## Phase 5: CI Polishing and Documentation Completion

**Overview:** Phase 5 is the final polish phase, focused on making sure continuous integration (CI) runs smoothly within time and that all documentation is up-to-date and comprehensive. We integrate all changes from Phases 2-4 into the project documentation and ensure long-term maintainability.

### Continuous Integration (Performance and Reliability)

* **Runtime Checks:** Re-verify that the entire test suite (including new Phase 2 tests and any Phase 3 specific tests) and if applicable the generation of the Phase 4 results complete in **< 5 minutes** on GitHub Actions. We will monitor the CI logs and optimize if necessary:

  * If the 6-week simulation or dashboard generation is too slow for CI, we might not run the full 42-day simulation on every commit. Instead, possibly run a smaller subset for CI (like 3-day tests as in Phase 2) and reserve the 6-week run for manual or scheduled execution. Alternatively, ensure that plotting in Phase 4 doesn’t consume too much time (e.g., limit resolution of plots).
  * Optimize any heavy computations identified in Phase 4 (for instance, large data handling or plotting could be heavy; use efficient libraries or downsample data for plotting).
* **Deterministic Tests:** Ensure that all tests consistently pass. Use fixed random seeds for any stochastic components (already noted). We should check that even with the dual-pool arbitrage, the outcome is deterministic or bounded so tests can assert outcomes reliably (or else structure tests to check qualitative outcomes, not exact numbers).
* **Error Handling:** Make sure the simulation code gracefully handles any edge cases (e.g., no division by zero if volumes are zero, no negative fees, etc.) so that CI doesn’t hit unexpected exceptions. Add any needed assertions or fallbacks.

### Documentation Updates

* **Spec Documentation:** This implementation spec (Phase 2-5) will be finalized and included in the repository (likely in a README or docs folder). We ensure it reflects all final decisions and matches the implemented code behavior. All the new terms (CAP event, surge fee, BaseFeePPM, etc.) are clearly defined (as we’ve done above) and any formulas or configurations are documented.
* **Code Comments and Docstrings:** Go through the code in `simulation/` and any new modules from Phase 3 (e.g., planner logic) to add or update docstrings, comments, and explanations. Each function related to CAP events or fee calculation should have a clear description. Configuration constants (min/max fee, cap thresholds, decay time) should be explained either in code or in a config file with comments.
* **User Guide / README:** Update the main README (or create one if not present) to describe how to run the simulation, what scenarios are available, and how to interpret the output:

  * Explain how to execute the Phase 2 simulation (perhaps via a CLI or script) and that it will produce CSV results in `/results/`.
  * Explain how to run the Phase 4 dashboard notebook or script to see the analysis (and possibly provide sample graphs or an output snapshot).
  * Include instructions for running tests (e.g., via `pytest`) for verification.
  * Summarize the dynamic fee model in simple terms for new readers (possibly reusing some content from this spec).
* **Visualization and Results in Docs:** If possible, include a few key plots or tables from Phase 4 in the documentation to illustrate what the model does. For example, embed a chart of base fee vs time or daily fees from the 6-week run in the README or an attached report. This serves as both a validation and an executive summary for stakeholders.
* **Changelog:** Document the changes introduced in each phase (especially Phase 2 changes 1–8) in a CHANGELOG or clearly in the spec, so that reviewers can see what has been modified from earlier versions (the bullet list we addressed can be converted into a summary of improvements).
* **Ensure Completeness:** Double-check that every deliverable item from all phases is accounted for:

  * Phase 2 deliverables: implemented and documented (yes, covered above).
  * Phase 3: dual-pool and planner described and coded, with any outputs or tests noted.
  * Phase 4: the 6-week run results available and the dashboard script/notebook provided.
  * Phase 5: tests passing, docs updated, no loose ends (like unused code or outdated comments).
* Possibly have a colleague or the CI run a documentation linter or markdown link check if available, to ensure all references in docs are correct.

### Final CI Pass and Review

* Run the full CI pipeline one more time after documentation is updated to ensure nothing in docs or added files causes CI issues (for instance, if we generate images for docs, ensure path issues are resolved or skip in CI).
* After passing CI, the project is considered complete for Phase 5, with a polished state: robust simulation code, thorough logging and metrics, validated tests, and a rich set of documentation and analytical results demonstrating the AEGIS DFM behavior under various conditions.
