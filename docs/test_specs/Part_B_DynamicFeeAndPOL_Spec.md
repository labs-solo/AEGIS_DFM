# Specification: Integration Test Suite Part B - Dynamic Fee & POL Management (`DynamicFeeAndPOL.t.sol`)

## 1. Goal

This integration test suite (`test/integration/DynamicFeeAndPOL.t.sol`) aims to verify the core **behavioral** aspects of the dynamic fee mechanism and Protocol Owned Liquidity (POL) management within the `Spot` hook ecosystem. It builds upon the static deployment and configuration checks performed in Part A (`DeploymentAndConfig.t.sol`).

The primary focus is to ensure that:
* Dynamic fees (base + surge) are calculated and applied correctly during swaps based on oracle price movements and CAP event status.
* Protocol Owned Liquidity (POL) is accurately collected from swap fees according to the configured POL share.
* The `FeeReinvestmentManager` (or equivalent mechanism) correctly queues and reinvests collected POL back into the pool under various conditions.
* Interactions between the `Spot` hook, `FullRangeDynamicFeeManager`, `FullRangeLiquidityManager`, `PoolPolicyManager`, and the Oracle (`TruncGeoOracleMulti`) function as expected during typical operations and edge cases.

These tests correspond to **Section B** of the `docs/Integration_Testing_Plan.md`.

---

## 2. Test Environment Setup (`setUp` in `DynamicFeeAndPOL.t.sol`)

* **Inheritance:** The test contract should inherit from `test/integration/ForkSetup.t.sol` to leverage the deployed contract instances and the forked mainnet environment.
* **Initial State:** The setup begins with the state established by `ForkSetup.t.sol`:
  * All core contracts deployed and linked (`PoolManager`, `PoolPolicyManager`, `FullRangeLiquidityManager`, `FullRangeDynamicFeeManager`, `Spot`, `TruncGeoOracleMulti`, `WETH`, `USDC`).
  * The WETH/USDC pool initialized with the `Spot` hook.
  * Initial policy settings applied (Default Dynamic Fee, POL Share, Tick Scaling Factor, etc.).
  * Oracle initialized with a starting price.
* **Actors:** Define standard actors (e.g., `user1`, `user2`, `lpProvider`, `reinvestor`) with initial token balances (WETH, USDC).
* **Initial Liquidity:** Consider adding some initial LP liquidity (distinct from POL) via the `lpProvider` to facilitate swaps. Use `FullRangeLiquidityManager.deposit`.
* **Approvals:** Ensure necessary ERC20 approvals are granted from actors to the `PoolManager` and potentially the `FullRangeLiquidityManager`.

---

## 3. Test Scenarios & Assertions

This section outlines the specific scenarios to be tested. Each test function should be clearly named (e.g., `test_B1_Swap_AppliesDefaultFee`, `test_B2a_CapEvent_TriggersSurgeFee`).

### B1: Basic Swap Fee Calculation & POL Collection

* **Goal:** Verify that swaps correctly apply the initial default dynamic fee and allocate the appropriate POL share.
* **Scenario:**
  * `user1` performs a small swap (WETH -> USDC) that doesn't significantly move the price or trigger oracle updates/CAP events.
  * Check pool state (`getSlot0`) before and after the swap.
  * Check `user1` token balances before and after.
  * Check POL balance held by the `FeeReinvestmentManager` (or equivalent) before and after.
* **Assertions:**
  * The swap succeeds.
  * The fee deducted from the swap output corresponds to the `PoolPolicyManager.getDefaultDynamicFee()`.
  * The amount of fee token (e.g., WETH if swapping WETH->USDC) collected as POL in the `FeeReinvestmentManager` equals `swap_fee * PoolPolicyManager.getPoolPOLShare() / 1e6`.
  * Appropriate `Swap` and potentially `FeeCollected` events are emitted.

### B2: CAP Event Triggering and Surge Fee Application

* **Goal:** Verify that significant price movements (simulated via oracle manipulation or large swaps) trigger CAP events and apply the surge fee.
* **Scenario:**
  * **B2a (Oracle Manipulation):**
    * Manually update the oracle (`TruncGeoOracleMulti.update`) with a price change exceeding the `maxTickChange` calculated from the current base fee and `tickScalingFactor`.
    * Trigger `FullRangeDynamicFeeManager.updateDynamicFeeIfNeeded` (or perform a swap which triggers it).
    * Check `FullRangeDynamicFeeManager.isPoolInCapEvent()` status.
    * Check `FullRangeDynamicFeeManager.poolStates[poolId].currentSurgeFeePpm`.
    * `user1` performs a swap *after* the CAP event is triggered.
  * **B2b (Large Swap):**
    * `user1` performs a large swap sufficient to move the pool's `tick` beyond the `maxTickChange` threshold relative to the `lastOracleTick` stored in `FullRangeDynamicFeeManager`.
    * Check `FullRangeDynamicFeeManager.isPoolInCapEvent()` status *after* the swap completes (hook callbacks should trigger the update).
    * Check `FullRangeDynamicFeeManager.poolStates[poolId].currentSurgeFeePpm`.
* **Assertions (for both B2a & B2b):**
  * `FullRangeDynamicFeeManager.isPoolInCapEvent(poolId)` returns `true` after the triggering action.
  * `FullRangeDynamicFeeManager.poolStates[poolId].currentSurgeFeePpm` is set to `INITIAL_SURGE_FEE_PPM`.
  * The fee applied to the subsequent swap (in B2a) or the large swap itself (in B2b) equals `baseFee + INITIAL_SURGE_FEE_PPM`.
  * POL collected reflects the *total* fee (base + surge).
  * `CapEventStateChanged(poolId, true)` and `SurgeFeeUpdated` events are emitted.
  * `TickChangeCapped` event might be emitted depending on oracle update timing.

### B3: Surge Fee Decay

* **Goal:** Verify that the surge fee component decays linearly over `SURGE_DECAY_PERIOD_SECONDS` after a CAP event ends.
* **Scenario:**
  * Trigger a CAP event (as in B2).
  * Simulate the end of the CAP event: Update the oracle back to a stable price and trigger an update.
  * Verify `isPoolInCapEvent` becomes `false`.
  * Warp time forward using `vm.warp()` by `SURGE_DECAY_PERIOD_SECONDS / 2`.
  * `user1` performs a swap and record the total fee paid.
  * Warp time forward past the complete decay period.
  * `user2` performs a swap and record the total fee paid.
* **Assertions:**
  * Instead of trying to test the internal `_calculateCurrentDecayedSurgeFee` function directly, observe:
    * `getCurrentDynamicFee()` returns a value approximately equal to `baseFee + (INITIAL_SURGE_FEE_PPM / 2)` at half decay time.
    * The actual fee charged during the swap at half decay matches this value.
    * After full decay, `getCurrentDynamicFee()` equals just the `baseFee`.
  * Use event emissions to validate state transitions (e.g., `CapEventStateChanged`, `SurgeFeeUpdated`).

### B4: Base Fee Dynamics

* **Goal:** Verify how the base fee component behaves over time.
* **Scenario:**
  * From code review, the base fee adjustment is primarily time-based with a 1-hour update interval.
  * Test should:
    * Perform an initial swap to establish base fee.
    * Warp time forward past the 1-hour update interval (3600 seconds).
    * Trigger a fee update via swap or direct call to `updateDynamicFeeIfNeeded`.
    * Examine if the base fee changed according to any adjustment logic.
* **Assertions:**
  * If base fee is designed to be static (as appears in current implementation), verify it remains unchanged.
  * If base fee implements adjustment logic, verify it follows the expected algorithm (likely based on time and possibly market conditions).
  * Verify minimum trading fee boundary is respected.

### B5: POL Reinvestment

* **Goal:** Verify that collected POL fees are correctly queued and reinvested by the `FeeReinvestmentManager` (or equivalent POL handling mechanism).
* **Scenario:**
  * Perform several swaps (as in B1, B2, B3) to accumulate POL in both WETH and USDC within the `FeeReinvestmentManager`.
  * Check the POL balances held by the manager for the specific `poolId`.
  * Authorize a `reinvestor` address using `PoolPolicyManager.setAuthorizedReinvestor`.
  * As the `reinvestor`, call the reinvestment function (e.g., `FeeReinvestmentManager.reinvest(poolId)`).
  * Check POL balances in the manager *after* reinvestment.
  * Check the `poolTotalShares` and `lockedLiquidity` (if applicable) in `FullRangeLiquidityManager` before and after reinvestment.
  * Check the underlying liquidity (`getPositionData`) in the `PoolManager` before and after.
* **Assertions:**
  * The POL token balances within the `FeeReinvestmentManager` for the `poolId` decrease significantly (ideally to near zero, respecting dust thresholds) after reinvestment.
  * The `poolTotalShares[poolId]` in `FullRangeLiquidityManager` increases.
  * The actual liquidity (`getPositionData`) in the `PoolManager` increases.
  * The `reinvestor` call succeeds.
  * Relevant events like `LiquidityAdded`, `PoolStateUpdated` (from `FullRangeLiquidityManager`), and potentially specific `Reinvestment` events from the `FeeReinvestmentManager` are emitted.
  * Verify reinvestment fails if called by an unauthorized address.
  * Verify reinvestment handles edge cases like zero POL balance or insufficient balance for minimum deposit.

### B6: Interaction with Minimum Trading Fee

* **Goal:** Ensure the calculated dynamic fee never drops below the `minimumTradingFeePpm` set in the `PoolPolicyManager`.
* **Scenario:**
  * (Requires base fee logic that could potentially decrease the fee) If applicable, manipulate conditions (e.g., time warp, oracle stability) such that the calculated `baseFeePpm` (assuming zero surge fee) would theoretically be *below* `minimumTradingFeePpm`.
  * Perform a swap.
* **Assertions:**
  * The fee applied to the swap is exactly `minimumTradingFeePpm`, not the lower calculated value.

### B7: Fee Update Rate Limiting

* **Goal:** Verify the `MIN_UPDATE_INTERVAL` rate limiting on `triggerFeeUpdate`.
* **Scenario:**
  * Call `FullRangeDynamicFeeManager.triggerFeeUpdate` successfully.
  * Immediately attempt to call it again.
  * Warp time forward by less than `MIN_UPDATE_INTERVAL` and attempt to call again.
  * Warp time forward by exactly `MIN_UPDATE_INTERVAL` and call again.
* **Assertions:**
  * The first call succeeds.
  * The second immediate call reverts with `Errors.RateLimited()`.
  * The third call (after short warp) reverts with `Errors.RateLimited()`.
  * The fourth call (after full interval warp) succeeds.

### B8: Oracle Integration and Price Movement Tracking

* **Goal:** Verify that the dynamic fee system correctly interacts with the oracle for price tracking and CAP event detection.
* **Scenario:**
  * **B8a: Oracle Data Propagation**
    * Perform a swap that moves the price slightly but not enough to trigger a CAP event.
    * Check that `FullRangeDynamicFeeManager.getOracleData()` correctly reflects the oracle state after the swap.
    * Verify the `lastOracleTick` and `lastOracleUpdateBlock` in `poolStates` are updated.
    
  * **B8b: Oracle Thresholds**
    * Use the `setThresholds` function to adjust `blockUpdateThreshold` and `tickDiffThreshold`.
    * Perform swaps that are just below and just above these thresholds.
    * Verify that oracle updates and potential CAP event triggers respect these thresholds.
    
  * **B8c: Oracle Access Pattern**
    * Verify the Reverse Authorization Model is working correctly:
      * The `FullRangeDynamicFeeManager` pulls data from the oracle when needed.
      * The `onlyFullRange` modifier correctly restricts access for sensitive functions.
* **Assertions:**
  * Oracle data is correctly propagated to the fee manager.
  * Oracle updates respect the configured thresholds.
  * The fee system correctly reacts to oracle-reported price changes.
  * `OracleUpdated` events are emitted with correct parameters.

### B9: Pool-Specific POL Shares

* **Goal:** Verify that pool-specific POL share percentages work correctly when enabled.
* **Scenario:**
  * Using the owner account, call `PoolPolicyManager.setPoolSpecificPOLSharingEnabled(true)`.
  * Set a specific POL share for the test pool: `setPoolPOLShare(poolId, customSharePpm)`.
  * Perform a swap and verify POL collection.
  * Disable pool-specific sharing and perform another swap.
* **Assertions:**
  * When pool-specific sharing is enabled, POL is collected according to the custom share percentage.
  * When disabled, POL reverts to using the global setting.
  * `getPoolPOLShare()` returns the correct value in both scenarios.

---

## 4. Potential Edge Cases & Considerations

* **Zero Swaps:** Ensure fee calculations handle scenarios with no prior swaps or updates.
* **Dust Amounts:** How are extremely small fee amounts or POL amounts handled during collection and reinvestment?
* **Reentrancy:** While `nonReentrant` guards exist, consider if complex interactions (especially during reinvestment involving `unlock`) could create vectors.
* **Gas Limits:** Are there scenarios (e.g., complex swaps triggering multiple updates) that could approach gas limits? (Less critical for integration, more for optimization).
* **Oracle Failure/Staleness:** How does the system behave if the oracle data becomes unavailable or stale? (May require more complex setup/mocking).
* **Integer Precision:** Verify calculations involving PPM, shares, and token amounts maintain sufficient precision.

---

## 5. Non-Goals for this Test Suite

* Testing the *absolute correctness* of the Oracle's price feed (assumed correct for these tests).
* Exhaustive testing of the `