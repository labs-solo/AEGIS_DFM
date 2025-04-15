# Integration Testing Plan

This plan outlines integration tests to be performed on a forked Unichain environment after deploying the system using the `DeployUnichainV4.s.sol` or `DirectDeploy.s.sol` scripts. It focuses on verifying the end-to-end behavior and interactions between the different components, skipping isolated unit tests.

**Goal:** Achieve high confidence (>95% branch coverage on critical paths) that the Dynamic Fee and Protocol-Owned Liquidity systems function according to the `Statement_of_Intended_Behavior.md`.

**Environment:** Forked Unichain mainnet environment using Foundry (`forge test --fork-url $UNICHAIN_RPC_URL ...`).

**Prerequisites:**
1.  Foundry installed.
2.  Environment variables set (`PRIVATE_KEY`, `UNICHAIN_RPC_URL`).
3.  Deployment scripts (`DeployUnichainV4.s.sol` or `DirectDeploy.s.sol`) successfully run on the fork, providing addresses for deployed contracts (PoolManager, PolicyManager, LiquidityManager, DynamicFeeManager, Spot hook, Oracle, Test Routers).
4.  Test wallet funded with ETH and relevant tokens (WETH, USDC) on the fork (`vm.deal`).

---

## Phase 1: Test Case Design & Rationalization

Here, we outline the necessary tests and justify their inclusion based on the intended behavior.

**A. Deployment & Configuration Verification**
*   **Rationale:** Ensure the system is deployed correctly and initial configurations are applied as expected by the scripts. This forms the baseline for all other tests.
*   **Tests:**
    1.  `test_VerifyContractAddresses`: Check that deployment scripts return non-zero addresses for all core contracts.
    2.  `test_VerifyPoolManagerLinkages`: Confirm `LiquidityManager`, `DynamicFeeManager`, `Spot` hook, and `Oracle` reference the correct `PoolManager` address.
    3.  `test_VerifyPolicyManagerLinkages`: Confirm `DynamicFeeManager` and `Spot` hook reference the correct `PoolPolicyManager`.
    4.  `test_VerifyLiquidityManagerLinkages`: Confirm `Spot` hook references the correct `LiquidityManager` and `LiquidityManager` has the correct `Spot` hook authorized.
    5.  `test_VerifyDynamicFeeManagerLinkages`: Confirm `Spot` hook references the correct `DynamicFeeManager`, and `DynamicFeeManager` references the correct `Spot` hook and `Oracle`.
    6.  `test_VerifyOracleLinkage`: Confirm `DynamicFeeManager` references the correct `Oracle`.
    7.  `test_VerifyInitialPoolSetup`: Confirm the WETH/USDC pool exists in `PoolManager`, is initialized, and uses the deployed `Spot` hook address.
    8.  `test_VerifyInitialPolicySettings`: Read key settings from `PoolPolicyManager` (POL share, min fee, tick scaling, etc.) and verify they match deployment script values.

**B. Dynamic Fee Mechanism**
*   **Rationale:** Verify the core fee calculation logic, including the interaction between base and surge fees, and the application during swaps.
*   **Tests:**
    1.  `test_FeeCalculation_BaseOnly`: With no CAP event active and surge decayed, perform a swap and verify the fee charged matches the `baseFeePpm` reported by `DynamicFeeManager`.
    2.  `test_FeeCalculation_SurgeOnly`: Trigger a CAP event, ensure `baseFeePpm` is temporarily set to 0 (or low), perform a swap immediately, verify fee matches `INITIAL_SURGE_FEE_PPM`.
    3.  `test_FeeCalculation_BaseAndSurge`: Trigger a CAP event, ensure non-zero `baseFeePpm`, perform swap, verify fee matches `baseFeePpm + INITIAL_SURGE_FEE_PPM`.
    4.  `test_FeeCalculation_Cap`: Set base and surge fees such that their sum exceeds `type(uint128).max`. Perform swap, verify fee is capped at `type(uint128).max`.
    5.  `test_FeeApplication`: Perform a swap using `PoolSwapTest`. Trace the call to `Spot.beforeSwap` and verify the `dynamicFee` returned matches the output of `DynamicFeeManager.getCurrentDynamicFee` at that block. Verify the final swap amounts reflect this fee being applied by the `PoolManager`.
    6.  `test_UninitializedPoolFee`: If possible to deploy without initializing a specific pool in `DynamicFeeManager`, attempt swap and verify the `defaultDynamicFee` from `PolicyManager` is used. Then initialize and verify dynamic fee is used.

**C. CAP Event Lifecycle**
*   **Rationale:** Ensure the system correctly detects large price movements (CAP events), activates surge fees appropriately, and handles the decay period.
*   **Tests:**
    1.  `test_CapEventTrigger_LargeSwap`: Perform a swap large enough to exceed the current `maxTickChange`. Verify `TickChangeCapped` event from `DynamicFeeManager`. Verify `isInCapEvent` becomes true. Verify `currentSurgeFeePpm` becomes `INITIAL_SURGE_FEE_PPM`. Verify `SurgeFeeUpdated` event.
    2.  `test_CapEvent_NoTrigger_SmallSwap`: Perform a swap smaller than `maxTickChange`. Verify no `TickChangeCapped` event. Verify `isInCapEvent` remains false (or becomes false if previously true).
    3.  `test_CapEventEnding`: Trigger a CAP event. Advance block. Perform a small swap (no capping). Verify `isInCapEvent` becomes false. Verify `capEventEndTime` is set to the current block timestamp. Verify `SurgeFeeUpdated` event.
    4.  `test_SurgeFeeDecay_MidPoint`: Trigger CAP event, end it, advance time to `SURGE_DECAY_PERIOD_SECONDS / 2`. Call `getCurrentDynamicFee`. Verify surge component is approx `INITIAL_SURGE_FEE_PPM / 2`.
    5.  `test_SurgeFeeDecay_FullPeriod`: Trigger CAP event, end it, advance time past `SURGE_DECAY_PERIOD_SECONDS`. Call `getCurrentDynamicFee`. Verify surge component is 0.
    6.  `test_SurgeFee_DuringCapEvent`: Trigger CAP event. Advance time (less than decay period). Call `getCurrentDynamicFee`. Verify surge component remains `INITIAL_SURGE_FEE_PPM` (as `isInCapEvent` is true).

**D. Base Fee Adjustment**
*   **Rationale:** Verify the long-term feedback loop where the base fee adjusts based on CAP event frequency.
*   **Tests:**
    1.  `test_BaseFee_NoUpdateNeeded`: Call `updateDynamicFeeIfNeeded` shortly after a previous update (less than interval). Verify no `DynamicFeeUpdated` event is emitted and base fee remains unchanged.
    2.  `test_BaseFee_UpdateTrigger`: Advance time past the update interval (e.g., `block.timestamp + 3601`). Call `updateDynamicFeeIfNeeded`. Verify `lastUpdateTimestamp` is updated.
    3.  `test_BaseFee_Increase_FrequentCaps`: Perform several swaps triggering CAP events within an update interval. Advance time past interval. Call `updateDynamicFeeIfNeeded`. Verify `DynamicFeeUpdated` event shows `newBaseFee > oldBaseFee`. Verify increase factor (e.g., ~10%).
    4.  `test_BaseFee_Decrease_NoCaps`: Ensure no CAP events occur for > 1 update interval. Advance time past interval. Call `updateDynamicFeeIfNeeded`. Verify `DynamicFeeUpdated` event shows `newBaseFee < oldBaseFee`. Verify decrease factor (e.g., ~1%).
    5.  `test_BaseFee_LowerBound`: Manually set base fee near minimum via cheat codes (if needed for setup). Ensure no CAPs. Trigger update. Verify new base fee does not go below `minimumTradingFee` from `PolicyManager`.
    6.  `test_BaseFee_UpperBound`: Trigger frequent CAPs. Let base fee increase. Set a low `maxBaseFeePpm` via cheat codes (or policy manager if possible). Trigger update. Verify new base fee does not exceed `maxBaseFeePpm`.

**E. Protocol-Owned Liquidity (POL) Collection & Queuing**
*   **Rationale:** Verify that the correct percentage of fees are identified as POL and correctly accumulated in the `FeeReinvestmentManager`.
*   **Tests:**
    1.  `test_PolExtraction_Swap`: Perform a swap. Check `FeeReinvestmentManager` state (or events if easier). Verify `FeesQueuedForProcessing` event is emitted (if hook calls it). Verify `pendingFee0`/`pendingFee1` increase by `SwapFee * polSharePpm`.
    2.  `test_PolExtraction_LiquidityEvent`: Add/Remove liquidity (if hooks trigger extraction). Verify `pendingFee0`/`pendingFee1` update correctly based on collected fees and `polSharePpm`.
    3.  `test_PolQueuing_MultipleSwaps`: Perform multiple small swaps. Verify `pendingFee0`/`pendingFee1` correctly sum the POL amounts from each swap.
    4.  `test_PolShare_PolicyChange`: Change `polSharePpm` in `PolicyManager`. Perform a swap. Verify the newly queued amount reflects the *new* percentage.

**F. POL Reinvestment Processing & Leftovers**
*   **Rationale:** Verify the triggering logic for reinvestment, the calculation of optimal amounts based on pool ratio, and the handling of leftover tokens.
*   **Tests:**
    1.  `test_ProcessQueuedFees_ManualTrigger`: Queue some fees. Call `processQueuedFees`. Verify `FeesReinvested` event is emitted with calculated `pol0`, `pol1`. Verify `pendingFee0`/`pendingFee1` are reset to 0. Verify `lastSuccessfulReinvestment` timestamp is updated.
    2.  `test_ProcessQueuedFees_NoFees`: Call `processQueuedFees` when `pendingFee0/1` are zero. Verify it returns `false` and emits no `FeesReinvested` event.
    3.  `test_ProcessQueuedFees_WithdrawalTrigger`: Setup: Queue fees. Perform liquidity withdrawal using `PoolModifyLiquidityTest` which should trigger fee processing via hooks/`collectFees`. Verify `FeesReinvested` event and state changes as in manual trigger.
    4.  `test_OptimalReinvestment_MatchingRatio`: Queue fees `fee0`, `fee1` such that `fee0/fee1` matches the current `reserve0/reserve1` ratio. Process fees. Verify `optimal0 == fee0` and `optimal1 == fee1` in the `FeesReinvested` event (or internal calls). Verify `leftoverToken0/1` remain 0.
    5.  `test_OptimalReinvestment_MismatchRatio`: Queue fees `fee0`, `fee1` where the ratio *differs* from `reserve0/reserve1`. Process fees. Verify `optimal0`, `optimal1` match the amounts calculated by `MathUtils.calculateReinvestableFees`. Verify non-zero `leftoverToken0` or `leftoverToken1` are stored correctly.
    6.  `test_LeftoverProcessing`: Create leftovers from a previous test. Queue *zero* new fees. Process fees. Verify the `FeesReinvested` event shows reinvestment based *only* on the previous leftovers. Verify leftovers are cleared or updated correctly.

**G. POL Reinvestment Execution**
*   **Rationale:** Verify the actual interaction with the `FullRangeLiquidityManager` and the `PoolManager` to add liquidity using the calculated optimal amounts.
*   **Tests:**
    1.  `test_ReinvestmentExecution_Success`: Trigger `processQueuedFees` with non-zero optimal amounts. Verify `TokenSafetyWrapper.safeApprove` is called for `LiquidityManager`. Verify `FullRangeLiquidityManager.reinvestFees` is called with correct amounts. Verify `ProtocolFeesReinvested` event from `LiquidityManager`. Verify `PoolManager.modifyLiquidity` is called via `unlockCallback` with correct params (negative delta, full range ticks). Verify LP token balance of `LiquidityManager` increases. Verify pool reserves increase.
    2.  `test_ReinvestmentExecution_ZeroAmount`: Trigger `processQueuedFees` resulting in zero optimal amounts (e.g., tiny initial fees). Verify `LiquidityManager.reinvestFees` is not called or reverts appropriately if called with zero.
    3.  `test_ReinvestmentExecution_LiquidityManagerRevert`: Cause `LiquidityManager.reinvestFees` to revert (e.g., manually revoke approval mid-flight if possible, or force internal revert). Verify `FeeReinvestmentManager._executePolReinvestment` returns `false`. Verify approvals are revoked (`safeRevokeApproval`). Verify pending fees are *not* cleared and leftovers are *not* updated (state should revert to before the attempt).

**H. Safety and Edge Cases**
*   **Rationale:** Test security mechanisms like pausing and reentrancy guards, as well as behavior under edge conditions.
*   **Tests:**
    1.  `test_Reentrancy_ProcessQueuedFees`: Attempt a reentrant call to `processQueuedFees`. Verify it reverts due to the `nonReentrant` modifier.
    2.  `test_GlobalPause_POL`: Set global reinvestment pause via `PolicyManager`. Attempt `processQueuedFees`. Verify it reverts or fails gracefully (check implementation). Unpause and verify processing works.
    3.  `test_PoolPause_POL`: Pause a specific pool via `PolicyManager`. Attempt `processQueuedFees` for that pool. Verify revert/fail. Attempt for *another* pool, verify it works. Unpause the specific pool and verify processing works.
    4.  `test_DynamicFee_Pause`: (If pausing exists for dynamic fees) Test pausing/unpausing dynamic fee updates or application.
    5.  `test_ZeroSwap`: Attempt a swap with amount 0. Verify it behaves reasonably (likely reverts in PoolManager or hook).
    6.  `test_VeryLargeSwap`: Attempt a swap exceeding pool liquidity. Verify expected V4 PoolManager revert behavior.
    7.  `test_MinimumCollectionInterval`: (Requires knowing where interval is checked) Queue fees. Attempt processing *before* interval passes, verify no-op/revert. Advance time past interval, verify processing works.

**I. Combined Flows**
*   **Rationale:** Test scenarios where both systems interact within the same transaction or sequence.
*   **Tests:**
    1.  `test_Swap_DynamicFee_And_PolExtraction`: Perform a single swap. Verify the dynamic fee is calculated correctly based on current base/surge/CAP state *AND* verify the correct POL share of the *applied* fee is queued in `FeeReinvestmentManager`.
    2.  `test_FrequentSwaps_FeeIncrease_And_PolAccumulation`: Perform multiple swaps that trigger CAP events and increase the base fee over time. Concurrently, verify that POL fees are accumulating correctly based on the *changing* dynamic fees being charged. Finally, process the accumulated POL.

---

## Phase 2: Final Test Plan Structure (Forge Tests)

Based on the rationalization, the integration tests will be structured into the following Foundry test files:

```
test/integration/
├── ForkSetup.t.sol             # Base contract for fork setup, deployments, initial state
├── DeploymentAndConfig.t.sol   # Tests from Section A
├── DynamicFeeMechanism.t.sol   # Tests from Section B
├── CapEventLifecycle.t.sol     # Tests from Section C
├── BaseFeeAdjustment.t.sol     # Tests from Section D
├── PolCollectionQueueing.t.sol # Tests from Section E
├── PolReinvestment.t.sol       # Tests from Sections F & G (Processing, Leftovers, Execution)
├── SafetyAndEdgeCases.t.sol    # Tests from Section H
└── CombinedFlows.t.sol         # Tests from Section I
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
