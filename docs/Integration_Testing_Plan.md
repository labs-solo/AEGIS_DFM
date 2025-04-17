# Integration Testing Plan

This plan outlines integration tests to be performed on a forked Unichain environment after deploying the system using the test setup logic defined in `test/integration/ForkSetup.t.sol`. It focuses on verifying the end-to-end behavior and interactions between the different components, skipping isolated unit tests.

**Goal:** Achieve high confidence (>95% branch coverage on critical paths) that the Dynamic Fee and Protocol-Owned Liquidity systems function according to the `Statement_of_Intended_Behavior.md`.

**Environment:** Forked Unichain mainnet environment using Foundry (`forge test --fork-url $UNICHAIN_RPC_URL ...`). The core contracts (`PoolPolicyManager`, `FullRangeLiquidityManager`, `FullRangeDynamicFeeManager`, `Spot` hook, `TruncGeoOracleMulti`) are deployed directly within the test setup (`ForkSetup.t.sol`), not via external deployment scripts.

**Prerequisites:**

1. Foundry installed.
2. Environment variables set (`PRIVATE_KEY`, `UNICHAIN_MAINNET_RPC_URL`, `FORK_BLOCK_NUMBER`).
3. `ForkSetup.t.sol` successfully compiles and its `setUp()` function executes, providing instances of deployed contracts (PoolManager, PolicyManager, LiquidityManager, DynamicFeeManager, Spot hook, Oracle, Test Routers).
4. Test wallet funded with ETH and relevant tokens (WETH, USDC) on the fork (`vm.deal`).

---

## Phase 1: Test Case Design & Rationalization

Here, we outline the necessary tests and justify their inclusion based on the intended behavior.

**A. Deployment & Configuration Verification**

* **Rationale:** Ensure the system is deployed correctly and initial configurations are applied as expected by the scripts. This forms the baseline for all other tests.
* **Tests:**
    1. `test_VerifyContractAddresses`: Check that deployment within `ForkSetup` yields non-zero addresses for all core contracts.
    2. `test_VerifyPoolManagerLinkages`: Confirm `LiquidityManager`, `DynamicFeeManager`, and `Spot` hook reference the correct `PoolManager` address. *(Note: Oracle linkage to PoolManager is not directly testable via standard getters).*
    3. `test_VerifyPolicyManagerLinkages`: Confirm `DynamicFeeManager` and `Spot` hook reference the correct `PoolPolicyManager`.
    4. `test_VerifyLiquidityManagerLinkages`: Confirm `Spot` hook references the correct `LiquidityManager` and `LiquidityManager` has the correct `Spot` hook authorized.
    5. `test_VerifyDynamicFeeManagerLinkages`: Confirm `Spot` hook references the correct `DynamicFeeManager`, and `DynamicFeeManager` references the correct `Spot` hook (`fullRangeAddress()`). *(Note: Oracle linkage within DFM is not directly testable via standard getters).*
    6. `test_VerifyOracleFunctionality`: *(Renamed)* Placeholder test or check integrated into fee calculation tests to ensure the Oracle is being *used* correctly by `DynamicFeeManager`, rather than checking a direct linkage getter.
    7. `test_VerifyInitialPoolSetup`: Confirm the WETH/USDC pool exists in `PoolManager`, is initialized (via `StateLibrary.getSlot0`), and implicitly uses the deployed `Spot` hook address (verified by checking pool existence for the `PoolId` derived from the `PoolKey` containing the hook). Verify correct token addresses (`currency0`, `currency1`).
    8. `test_VerifyInitialPolicySettings`: Read *available* key settings from `PoolPolicyManager` (e.g., `getPoolPOLShare`, `getMinimumTradingFee`, `getTickScalingFactor`, `getDefaultDynamicFee`) and verify they match deployment values from `ForkSetup.sol`. *(Note: Parameters like `maxBaseFeePpm`, `maxTickChange`, bounds, increase/decrease factors, and reinvestment interval lack direct getters and cannot be verified here; their behavior will be tested implicitly later).*

**B. Dynamic Fee Mechanism**

* **Rationale:** Verify the core fee calculation logic, including the interaction between base and surge fees, and the application during swaps.
* **Tests:**
    1. `test_FeeCalculation_BaseOnly`: With no CAP event active and surge decayed, perform a swap and verify the fee charged matches the base fee component returned by `DynamicFeeManager.getCurrentDynamicFee` (or inferred if combined fee is returned).
    2. `test_FeeCalculation_SurgeOnly`: Trigger a CAP event, ensure `baseFeePpm` component is temporarily zero (or near zero), perform a swap immediately, verify fee matches `FullRangeDynamicFeeManager.INITIAL_SURGE_FEE_PPM`. *(Verify constant name/visibility).*
    3. `test_FeeCalculation_BaseAndSurge`: Trigger a CAP event, ensure non-zero `baseFeePpm` component, perform swap, verify total fee matches `baseFeePpm + INITIAL_SURGE_FEE_PPM`.
    4. `test_FeeCalculation_Cap`: Set base and surge fees such that their sum exceeds `type(uint128).max`. Perform swap, verify fee is capped at `type(uint128).max`.
    5. `test_FeeApplication`: Perform a swap using `PoolSwapTest`. Trace the call to `Spot.beforeSwap` and verify the `dynamicFee` returned matches the output of `DynamicFeeManager.getCurrentDynamicFee` at that block. Verify the final swap amounts reflect this fee being applied by the `PoolManager`.
    6. `test_UninitializedPoolFee`: *(Potentially infeasible)* Attempt swap on a *different*, uninitialized pool (if setup allows easy creation) and verify `defaultDynamicFee` from `PolicyManager` is used. Initialize it in `DynamicFeeManager` and verify its specific dynamic fee is then used. *(Note: The primary WETH/USDC pool is always initialized in ForkSetup, making this test difficult for that specific pool).*

**C. CAP Event Lifecycle**

* **Rationale:** Ensure the system correctly detects large price movements (CAP events), activates surge fees appropriately, and handles the decay period.
* **Tests:**
    1. `test_CapEventTrigger_LargeSwap`: Perform a swap large enough to exceed the current `maxTickChange` (calculated based on current fee/policy, as direct getter is unavailable). Verify `TickChangeCapped` event from `DynamicFeeManager`. Verify `isInCapEvent` becomes true. Verify `currentSurgeFeePpm` becomes `INITIAL_SURGE_FEE_PPM`. Verify `SurgeFeeUpdated` event.
    2. `test_CapEvent_NoTrigger_SmallSwap`: Perform a swap smaller than `maxTickChange`. Verify no `TickChangeCapped` event. Verify `isInCapEvent` remains false (or becomes false if previously true).
    3. `test_CapEventEnding`: Trigger a CAP event. Advance block. Perform a small swap (no capping). Verify `isInCapEvent` becomes false. Verify `capEventEndTime` is set to the current block timestamp. Verify `SurgeFeeUpdated` event.
    4. `test_SurgeFeeDecay_MidPoint`: Trigger CAP event, end it, advance time to `SURGE_DECAY_PERIOD_SECONDS / 2`. Call `getCurrentDynamicFee`. Verify surge component is approx `INITIAL_SURGE_FEE_PPM / 2`. *(Verify constant SURGE_DECAY_PERIOD_SECONDS exists/is accessible).*
    5. `test_SurgeFeeDecay_FullPeriod`: Trigger CAP event, end it, advance time past `SURGE_DECAY_PERIOD_SECONDS`. Call `getCurrentDynamicFee`. Verify surge component is 0.
    6. `test_SurgeFee_DuringCapEvent`: Trigger CAP event. Advance time (less than decay period). Call `getCurrentDynamicFee`. Verify surge component remains `INITIAL_SURGE_FEE_PPM` (as `isInCapEvent` is true).

**D. Base Fee Adjustment**

* **Rationale:** Verify the long-term feedback loop where the base fee adjusts based on CAP event frequency.
* **Tests:**
    1. `test_BaseFee_NoUpdateNeeded`: Call `updateDynamicFeeIfNeeded` shortly after a previous update (less than interval). Verify no `DynamicFeeUpdated` event is emitted and base fee remains unchanged.
    2. `test_BaseFee_UpdateTrigger`: Advance time past the update interval (e.g., `block.timestamp + 3601`). Call `updateDynamicFeeIfNeeded`. Verify `lastUpdateTimestamp` is updated.
    3. `test_BaseFee_Increase_FrequentCaps`: Perform several swaps triggering CAP events within an update interval. Advance time past interval. Call `updateDynamicFeeIfNeeded`. Verify `DynamicFeeUpdated` event shows `newBaseFee > oldBaseFee`. Verify increase factor (e.g., ~10%).
    4. `test_BaseFee_Decrease_NoCaps`: Ensure no CAP events occur for > 1 update interval. Advance time past interval. Call `updateDynamicFeeIfNeeded`. Verify `DynamicFeeUpdated` event shows `newBaseFee < oldBaseFee`. Verify decrease factor (e.g., ~1%).
    5. `test_BaseFee_LowerBound`: Manually set base fee near minimum via cheat codes (if needed for setup). Ensure no CAPs. Trigger update. Verify new base fee does not go below `minimumTradingFee` from `PolicyManager`.
    6. `test_BaseFee_UpperBound`: Trigger frequent CAPs. Let base fee increase. Attempt to trigger update. Verify the base fee does not exceed an expected maximum value *(Note: Cannot directly compare to `maxBaseFeePpm` from `PolicyManager` due to missing getter. Test may need to verify fee stops increasing or compare against a hardcoded expected max).* Check if `PoolPolicyManager` allows setting `maxBaseFeePpm` post-deployment via governance for more direct testing.

**E. Protocol-Owned Liquidity (POL) Collection & Queuing (within `FullRangeLiquidityManager`)**

* **Rationale:** Verify that the correct percentage of fees are identified as POL and correctly accumulated within the `FullRangeLiquidityManager`.
* **Tests:** *(Verify function/event/state variable names against FullRangeLiquidityManager.sol)*
    1. `test_PolExtraction_Swap`: Perform a swap. Check `FullRangeLiquidityManager` state (e.g., `pendingFee0`/`pendingFee1` if available) or events (e.g., `FeesQueuedForProcessing` if emitted by hook/LM). Verify amounts increase by `SwapFee * polSharePpm`.
    2. `test_PolExtraction_LiquidityEvent`: Add/Remove liquidity (if hooks trigger extraction). Verify `pendingFee0`/`pendingFee1` update correctly based on collected fees and `polSharePpm`.
    3. `test_PolQueuing_MultipleSwaps`: Perform multiple small swaps. Verify `pendingFee0`/`pendingFee1` correctly sum the POL amounts from each swap.
    4. `test_PolShare_PolicyChange`: Change `polSharePpm` in `PolicyManager`. Perform a swap. Verify the newly queued amount reflects the *new* percentage.

**F. POL Reinvestment Processing & Leftovers (within `FullRangeLiquidityManager`)**

* **Rationale:** Verify the triggering logic for reinvestment (e.g., `processQueuedFees` if it exists), the calculation of optimal amounts based on pool ratio, and the handling of leftover tokens within `FullRangeLiquidityManager`.
* **Tests:** *(Verify function/event/state variable names against FullRangeLiquidityManager.sol)*
    1. `test_ProcessQueuedFees_ManualTrigger`: Queue some fees. Call the appropriate processing function on `FullRangeLiquidityManager` (e.g., `processQueuedFees`). Verify relevant events (e.g., `FeesReinvested`) are emitted with calculated `pol0`, `pol1`. Verify pending fees are reset. Verify timestamp (e.g., `lastSuccessfulReinvestment`) is updated.
    2. `test_ProcessQueuedFees_NoFees`: Call processing function when pending fees are zero. Verify expected behavior (e.g., returns false, no events).
    3. `test_ProcessQueuedFees_WithdrawalTrigger`: Setup: Queue fees. Perform liquidity withdrawal using `PoolModifyLiquidityTest`. Verify if `Spot.afterRemoveLiquidity` triggers fee processing in `FullRangeLiquidityManager`. Check for expected events and state changes.
    4. `test_OptimalReinvestment_MatchingRatio`: Queue fees matching pool ratio. Process fees. Verify optimal amounts match queued amounts and leftovers are zero.
    5. `test_OptimalReinvestment_MismatchRatio`: Queue fees mismatching pool ratio. Process fees. Verify optimal amounts match expected calculation (e.g., `MathUtils.calculateReinvestableFees` logic). Verify non-zero leftovers are stored correctly (check state variables like `leftoverToken0`/`leftoverToken1` if available).
    6. `test_LeftoverProcessing`: Create leftovers. Queue *zero* new fees. Process fees. Verify reinvestment occurs based *only* on leftovers. Verify leftovers are cleared/updated.

**G. POL Reinvestment Execution (within `FullRangeLiquidityManager`)**

* **Rationale:** Verify the actual interaction of `FullRangeLiquidityManager` with the `PoolManager` to add liquidity using the calculated optimal amounts.
* **Tests:** *(Verify function/event/state variable names against FullRangeLiquidityManager.sol and interactions)*
    1. `test_ReinvestmentExecution_Success`: Trigger fee processing with non-zero optimal amounts. Verify necessary approvals (e.g., `TokenSafetyWrapper.safeApprove` usage). Verify `FullRangeLiquidityManager` calls `PoolManager.modifyLiquidity` (likely via `unlockCallback`) with correct params (negative delta, full range ticks). Verify relevant events (e.g., `ProtocolFeesReinvested` from LM if exists). Verify LP token balance of LM increases. Verify pool reserves increase.
    2. `test_ReinvestmentExecution_ZeroAmount`: Trigger processing resulting in zero optimal amounts. Verify no `modifyLiquidity` call occurs or handles zero amounts gracefully.
    3. `test_ReinvestmentExecution_LiquidityManagerRevert`: Cause `modifyLiquidity` call within LM to revert. Verify the POL processing state reverts correctly (pending fees/leftovers not cleared, approvals potentially revoked).

**H. Safety and Edge Cases**

* **Rationale:** Test security mechanisms like pausing and reentrancy guards, as well as behavior under edge conditions.
* **Tests:**
    1. `test_Reentrancy_ProcessQueuedFees`: Attempt a reentrant call to the POL processing function in `FullRangeLiquidityManager`. Verify revert if `nonReentrant` modifier is present.
    2. `test_GlobalPause_POL`: Check if `PoolPolicyManager` has a global reinvestment pause function. If yes, set pause. Attempt POL processing. Verify revert/fail. Unpause and verify success.
    3. `test_PoolPause_POL`: Check if `PoolPolicyManager` allows pausing reinvestment for specific pools. If yes, test pausing/unpausing effects on POL processing for that pool vs others.
    4. `test_DynamicFee_Pause`: Check if `PoolPolicyManager` or `FullRangeDynamicFeeManager` implement pausing for dynamic fee updates or application. If yes, test accordingly.
    5. `test_ZeroSwap`: Attempt a swap with amount 0. Verify it behaves reasonably (likely reverts in PoolManager or hook).
    6. `test_VeryLargeSwap`: Attempt a swap exceeding pool liquidity. Verify expected V4 PoolManager revert behavior.
    7. `test_MinimumCollectionInterval`: Check if `FullRangeLiquidityManager`'s processing logic enforces a minimum interval (related to `minReinvestmentInterval` policy). If yes, test attempting to process before and after interval expiry. *(Note: Requires confirming existence of this check and interval value, as getter was missing).*

**I. Combined Flows**

* **Rationale:** Test scenarios where both systems interact within the same transaction or sequence.
* **Tests:**
    1. `test_Swap_DynamicFee_And_PolExtraction`: Perform a single swap. Verify the dynamic fee is calculated correctly based on current base/surge/CAP state *AND* verify the correct POL share of the *applied* fee is queued in `FullRangeLiquidityManager` (check state/events).
    2. `test_FrequentSwaps_FeeIncrease_And_PolAccumulation`: Perform multiple swaps that trigger CAP events and increase the base fee over time. Concurrently, verify that POL fees are accumulating correctly based on the *changing* dynamic fees being charged. Finally, process the accumulated POL.

---

## Phase 2: Final Test Plan Structure (Forge Tests)

Based on the rationalization, the integration tests will be structured into the following Foundry test files:

```
test/integration/
├── ForkSetup.t.sol                   # Base contract for fork setup, deployments, initial state
├── DeploymentAndConfig.t.sol         # Tests from Section A
├── DynamicFeeMechanism.t.sol         # Tests from Section B
├── CapEventLifecycle.t.sol           # Tests from Section C
├── BaseFeeAdjustment.t.sol           # Tests from Section D
├── PolCollectionAndReinvest.t.sol    # Tests from Sections E, F, G (Logic within FullRangeLiquidityManager)
├── SafetyAndEdgeCases.t.sol          # Tests from Section H
└── CombinedFlows.t.sol               # Tests from Section I
```

**Example Test Structure (within `CapEventLifecycle.t.sol`):**

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../ForkSetup.t.sol"; // Inherits setup, contract instances, helpers
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

contract CapEventLifecycleTest is ForkSetup {

    // Test Purpose: Verify CAP event is triggered by a large swap exceeding maxTickChange.
    // Rationale: Ensures the core detection mechanism for high volatility/manipulation works.
    function test_CapEventTrigger_LargeSwap() public {
        // --- Preconditions ---
        // Ensure pool is initialized in DynamicFeeManager (done in setup)
        // Ensure base fee is non-trivial, get current maxTickChange (helper function needed)
        // Calculate swap amount large enough to cause tick movement > maxTickChange

        int256 swapAmountToken0 = int256(100 ether); // Example: Adjust based on actual price/liquidity
        bool zeroForOne = true; // Swapping token0 for token1

        // Get state before
        (, PoolState memory stateBefore) = dynamicFeeManager.getPoolState(poolId);
        assertFalse(stateBefore.isInCapEvent, "Test precondition: Should not be in CAP event initially");

        // --- Actions ---
        // Perform the large swap using the test router
        vm.startPrank(testUser);
        deal(token0, testUser, uint256(-swapAmountToken0)); // Give user token0
        approve(token0, address(swapRouter), uint256(-swapAmountToken0));

        // Expect events from DynamicFeeManager
        vm.expectEmit(true, true, true, true, address(dynamicFeeManager));
        emit TickChangeCapped(poolId, /*actualTickChange*/, /*cappedTickChange*/); // Values are dynamic
        vm.expectEmit(true, true, true, true, address(dynamicFeeManager));
        emit CapEventStateChanged(poolId, true); // Entering CAP event
        vm.expectEmit(true, true, true, true, address(dynamicFeeManager));
        emit SurgeFeeUpdated(poolId, dynamicFeeManager.INITIAL_SURGE_FEE_PPM(), true); // Surge activated

        swapRouter.swap(key, zeroForOne, swapAmountToken0, sqrtPriceLimitX96(zeroForOne));
        vm.stopPrank();

        // --- Expected Behavior ---
        // Check DynamicFeeManager state *after* the swap
        (, PoolState memory stateAfter) = dynamicFeeManager.getPoolState(poolId);
        assertTrue(stateAfter.isInCapEvent, "isInCapEvent should be true after large swap");
        assertEq(stateAfter.currentSurgeFeePpm, dynamicFeeManager.INITIAL_SURGE_FEE_PPM(), "Surge fee should be set to initial value");
        assertEq(stateAfter.capEventEndTime, 0, "capEventEndTime should be reset"); // Reset when entering event

        // Could also check oracle state if relevant interfaces allow
    }

    // --- Other tests from Section C would follow ---

     function test_CapEventEnding() public { /* ... */ }
     function test_SurgeFeeDecay_MidPoint() public { /* ... */ }
     // ... etc ...

     // --- Helper functions ---
     function sqrtPriceLimitX96(bool zeroForOne) internal pure returns (uint160) {
         // Calculate appropriate price limits for swaps
         // ... implementation ...
     }

     function calculateMaxTickChange() internal view returns (int24) {
        // Helper to get current maxTickChange based on current fee & policy
        // ... implementation ...
     }
}
```
