
# Solo Hook System Testing Checklist (Uniswap V4)

This checklist outlines tests for the Solo Hook System, a margin trading protocol integrated with Uniswap V4 via hooks.

## 1. Core Contracts & Libraries (Unit & Fuzz Tests)

### 1.1. `Math` / `TickMath` Libraries
- [ ] **(Unit)** Verify core arithmetic functions (addition, subtraction, multiplication, division) handle edge cases correctly (zero values, maximum values, potential overflows/underflows, rounding precision).
- [ ] **(Unit)** Test functions specific to LTV calculations, share calculations, and interest accrual math under various inputs.
- [ ] **(Unit)** Validate tick-related calculations if custom logic exists beyond standard UniV4 libraries.
- [ ] **(Fuzz)** Fuzz mathematical functions with a wide range of valid and near-invalid inputs to check for unexpected reverts or incorrect results.

### 1.2. `FeeMath` Library / Dynamic Fee Logic
- [ ] **(Unit)** Verify dynamic fee calculation based on utilization inputs (0%, 50%, 100%, >100%).
- [ ] **(Unit)** Verify dynamic fee calculation based on volatility inputs (low, medium, high).
- [ ] **(Unit)** Test fee calculation logic when CAP events are triggered (lower/upper bounds).
- [ ] **(Unit)** Test borrow fee accrual calculations for different time durations and interest rates.
- [ ] **(Unit)** Test spread fee calculations.
- [ ] **(Fuzz)** Fuzz dynamic fee function with diverse utilization and volatility inputs.

### 1.3. `Oracle` (`PriceOracle`/`TwapOracle`)
- [ ] **(Unit)** Verify TWAP calculation against mock pool observations over different time windows.
- [ ] **(Unit)** Test handling of insufficient pool observations or oracle returning stale data (should revert or return error).
- [ ] **(Unit)** Test logic for `maxAbsTickMove` (or similar price deviation caps) against mock price changes.
- [ ] **(Unit)** Test price scaling/normalization logic if applicable.
- [ ] **(Fuzz)** Fuzz `getPrice` with diverse mock pool states (tick, liquidity, observations) and time intervals.
- [ ] **(Scenario/Fork)** Query price against known historical fork states with high volatility.
- [ ] **(Scenario/Fork)** Query price against fork states with low pool liquidity.

### 1.4. `Margin` Contract (Internal Logic)
- [ ] **(Unit)** Test internal accounting updates (`_updatePosition`) for collateral and debt changes.
- [ ] **(Unit)** Test share minting/burning logic during deposits/withdrawals.
- [ ] **(Unit)** Test LTV calculation helper function (`_calculateLTV` or similar).
- [ ] **(Unit)** Test solvency check helper function (`_isSolvent` or similar).
- [ ] **(Fuzz)** Fuzz internal state updates by simulating sequences of manager calls (deposit, withdraw, borrow, repay). Check internal consistency.

### 1.5. `MarginManager` (Core Logic & Validation)
- [ ] **(Unit)** Test access control for governance functions (`setPolicyParam`, `setFeeTo`, `pause`, `unpause`).
- [ ] **(Unit)** Test validation logic for parameters set via governance (e.g., LTV limits, fee rates, liquidation bonuses).
- [ ] **(Unit)** Test basic batch action decoding and routing within `executeBatch` (mocking `Margin` contract interactions).
- [ ] **(Unit)** Test liquidation eligibility checks (`_isLiquidatable`).
- [ ] **(Unit)** Test calculation of liquidation penalties/bonuses.

### 1.6. `SpotLiquidityManager` (Internal Logic)
- [ ] **(Unit)** Test share calculation logic for minting/burning spot LP shares.
- [ ] **(Unit)** Test internal logic for fee compounding or distribution related to spot LP.

### 1.7. `FullRangeLiquidityManager` (Internal Logic)
- [ ] **(Unit)** Test logic for calculating required amounts to mint/burn full-range LP positions based on target value or POL requirements.
- [ ] **(Unit)** Test interaction logic with the UniV4 Pool Manager interface for modifying positions.

### 1.8. `SoloHook` Contract (Hook Logic Isolation)
- [ ] **(Unit)** Test `beforeSwap` logic in isolation: fee calculation input preparation, oracle pre-update checks.
- [ ] **(Unit)** Test `afterSwap` logic in isolation: triggering oracle updates, potentially fee collection logic.
- [ ] **(Unit)** Test `beforeModifyPosition` logic in isolation: POL adjustment checks, interaction permissions.
- [ ] **(Unit)** Test `afterModifyPosition` logic in isolation: state updates post-LP change.
- [ ] **(Unit)** Test `beforeDonate` logic in isolation.
- [ ] **(Unit)** Test `afterDonate` logic in isolation: POL/state updates post-donation.
- [ ] **(Unit)** Test `unlockCallback` security checks: caller validation (`msg.sender == pool`), expected state checks.
- [ ] **(Unit)** Test `unlockCallback` logic: handling different `data` payloads, state cleanup.

## 2. Margin Trading (`MarginManager`, `Margin`) (Integration, Fuzz, Scenario Tests)

### 2.1. `executeBatch` - Core User Actions
- [ ] **(Integration)** Deposit collateral (token0 only): Check `Margin` state, token transfers, event emission.
- [ ] **(Integration)** Deposit collateral (token1 only): Check `Margin` state, token transfers, event emission.
- [ ] **(Integration)** Deposit collateral (both tokens): Check `Margin` state, token transfers, event emission.
- [ ] **(Integration)** Withdraw collateral (below LTV limit): Check `Margin` state, token transfers, LTV update, event emission.
- [ ] **(Integration)** Attempt Withdraw collateral (above LTV limit): Verify revert (`NotSolvent` or similar).
- [ ] **(Integration)** Borrow asset (below LTV limit): Check `Margin` debt, LTV update, event emission.
- [ ] **(Integration)** Attempt Borrow asset (above LTV limit): Verify revert (`NotSolvent` or similar).
- [ ] **(Integration)** Repay partial debt: Check `Margin` debt, LTV update, token transfers, event emission.
- [ ] **(Integration)** Repay full debt: Check `Margin` debt (should be ~0), LTV update, token transfers, event emission.
- [ ] **(Integration)** Swap collateral within margin account: Check `Margin` collateral balances, pool interaction, LTV update, event emission.
- [ ] **(Integration)** Perform multiple actions in one batch (e.g., Deposit + Borrow): Verify combined effect, state consistency, single event (or multiple).
- [ ] **(Integration)** Perform multiple actions in one batch (e.g., Borrow + Swap): Verify correct execution order and state.
- [ ] **(Integration)** Perform multiple actions in one batch (e.g., Repay + Withdraw): Verify correct execution order and state.
- [ ] **(Fuzz)** Fuzz `executeBatch` with randomized valid sequences and amounts for all action types. Check state invariants (LTV, balances) and event emissions.
- [ ] **(Fuzz Stateful)** Simulate a user lifecycle: deposit, borrow, trade, accrue interest, repay, withdraw over multiple blocks/actions. Check invariants throughout.
- [ ] **(Scenario)** `executeBatch` with zero amount for an action (should succeed NOP or revert if invalid).
- [ ] **(Scenario)** `executeBatch` attempting to withdraw/borrow more than available/allowed (should revert).
- [ ] **(Scenario)** `executeBatch` for a new user (should create `Margin` account implicitly).
- [ ] **(Scenario)** `executeBatch` when protocol is paused (should revert).
- [ ] **(Scenario)** `executeBatch` with slippage parameters for swaps.

### 2.2. `liquidate` - Liquidation Actions
- [ ] **(Integration)** Liquidate an account barely exceeding the LTV threshold. Verify state updates, POL deposit, event.
- [ ] **(Integration)** Liquidate an account significantly exceeding the LTV threshold (bad debt). Verify state updates, POL deposit, event.
- [ ] **(Integration)** Verify calculation of seized collateral and repaid debt matches expected values based on liquidation bonus/penalty.
- [ ] **(Integration)** Verify correct interaction with `FullRangeLiquidityManager` to deposit seized collateral as POL.
- [ ] **(Integration)** Verify `LiquidationExecuted` event emitted with correct parameters (liquidator, liquidated user, amounts).
- [ ] **(Scenario)** Attempt liquidation on a solvent account (should revert).
- [ ] **(Scenario)** Partial liquidation scenario (if supported): Verify account remains open but with reduced debt/collateral and updated LTV.
- [ ] **(Scenario/Fork)** Trigger liquidation after significant price movement on a fork. Verify LTV calculation uses updated oracle price.
- [ ] **(Scenario/Fork)** Test liquidation with different collateral/debt compositions.
- [ ] **(Scenario)** Test liquidation when protocol is paused (should revert unless specifically allowed for liquidators).
- [ ] **(Fuzz)** Fuzz `liquidate` calls on accounts set up with various LTVs around the threshold (below, exactly at, just above, far above).

### 2.3. State Consistency & Events
- [ ] **(Integration)** After every `executeBatch` and `liquidate`, verify internal `Margin` state (collateral, debt, shares) is consistent with external token transfers and calculated changes.
- [ ] **(Integration)** Verify all relevant events (`MarginAction`, `LiquidationExecuted`, `PolicyUpdated`, `FeeCollected`, etc.) are emitted with accurate data corresponding to the actions performed.

## 3. Liquidity Provision (`SpotLiquidityManager`, `FullRangeLiquidityManager`) (Integration, Scenario Tests)

### 3.1. Spot LP (`SpotLiquidityManager`)
- [ ] **(Integration)** Mint spot LP shares: User receives correct share amount, tokens transferred to manager/pool.
- [ ] **(Integration)** Burn spot LP shares: User receives correct underlying token amounts, shares burned, tokens transferred from manager/pool.
- [ ] **(Integration)** Verify interaction with UniV4 Pool Manager for `modifyPosition` calls related to spot LP.
- [ ] **(Scenario/Fork)** Mint/burn spot LP and observe fee compounding effect on share value over time (requires pool activity simulation or fork testing with time warp).
- [ ] **(Scenario)** Mint with zero amount (should revert or NOP).
- [ ] **(Scenario)** Burn more shares than owned (should revert).

### 3.2. Protocol-Owned Liquidity (POL) Management (`FullRangeLiquidityManager`, `MarginManager`, Fee Logic)
- [ ] **(Integration)** Verify `liquidate` action correctly triggers deposit of seized collateral into `FullRangeLiquidityManager`'s position.
- [ ] **(Integration)** Verify fee reinvestment mechanism correctly swaps collected fees (if needed) and deposits proceeds into `FullRangeLiquidityManager`'s position.
- [ ] **(Integration)** Verify `FullRangeLiquidityManager` correctly calls `modifyPosition` on the UniV4 pool to update the POL range.
- [ ] **(Scenario/Fork)** Observe POL value changes over time due to accumulated fees and liquidations on a fork.

## 4. Oracle Integration (`Oracle`, `MarginManager`, `SoloHook`) (Integration, Scenario/Fork Tests)

- [ ] **(Integration)** Verify `MarginManager` calls `Oracle.getPrice` during `executeBatch` solvency checks.
- [ ] **(Integration)** Verify `MarginManager` calls `Oracle.getPrice` during `liquidate` solvency checks and collateral valuation.
- [ ] **(Integration)** Verify `SoloHook`'s `afterSwap` (or relevant hook) triggers oracle state updates correctly.
- [ ] **(Scenario/Fork)** Perform actions (`executeBatch`, `liquidate`) immediately after large swaps on a fork. Verify actions use the updated TWAP price reflecting the swap.
- [ ] **(Scenario/Fork)** Test system behavior when a swap triggers `maxAbsTickMove` (or similar deviation cap). Does the swap revert? Does the oracle use a capped price? Does margin trading halt temporarily?
- [ ] **(Scenario/Fork)** Test oracle behavior if underlying pool has very few observations or hasn't been traded in a while (stale data). Does it revert? Return error?
- [ ] **(Security/Scenario/Fork)** Attempt to manipulate TWAP on a fork via rapid small swaps or flash loan attacks and verify impact on liquidations/borrows.

## 5. Fee Management (Dynamic Fees, Borrow Fees, Collection, Reinvestment) (Integration, Scenario/Fork Tests)

- [ ] **(Integration)** Verify swap fees applied during `executeBatch` swaps match `FeeMath` logic based on current utilization/volatility.
- [ ] **(Integration)** Verify borrow fees accrue correctly in `Margin` contract state over time (requires time warp).
- [ ] **(Integration)** Verify accrued borrow fees are correctly accounted for during repayments and liquidations.
- [ ] **(Integration)** Verify fees are transferred to the designated fee collector address or contract.
- [ ] **(Integration)** Verify the full fee reinvestment cycle: collection -> swap fees to POL asset(s) -> deposit into `FullRangeLiquidityManager`.
- [ ] **(Scenario)** Test fee calculations at boundary conditions (0% utilization, 100% utilization, specific CAP trigger points).
- [ ] **(Scenario/Fork)** Simulate high volume trading and borrowing; verify fee collection and POL growth over an extended period (via time warp).
- [ ] **(Integration)** Verify governance can update fee parameters (`setPolicyParam`) and changes take effect.

## 6. Uniswap V4 Hook Interactions (`SoloHook`, Pool Interactions) (Integration, Scenario/Fork Tests)

- [ ] **(Integration)** Verify `afterInitialize` hook sets up necessary state during pool deployment (if applicable).
- [ ] **(Integration)** Execute a swap in the hooked pool: Verify `beforeSwap` and `afterSwap` are called, fees applied, oracle updates triggered, state changes occur as expected.
- [ ] **(Integration)** Modify liquidity position in the hooked pool: Verify `beforeModifyPosition` and `afterModifyPosition` are called, POL/spot LP interactions occur correctly.
- [ ] **(Integration)** Donate liquidity to the hooked pool: Verify `beforeDonate` and `afterDonate` are called, POL/state updates occur.
- [ ] **(Integration)** Verify `unlockCallback` is invoked by the pool after an action and executes successfully, handling any required state cleanup or asset accounting.
- [ ] **(Scenario/Fork)** Test hook interactions during complex pool actions (e.g., swaps involving multiple hooks, flash loans if the pool uses them).
- [ ] **(Scenario)** Test hook revert conditions (e.g., oracle deviation cap hit in `beforeSwap` should prevent the swap). Verify atomicity.
- [ ] **(Security/Scenario)** Test for reentrancy vulnerabilities:
    - Can `unlockCallback` be re-entered maliciously?
    - Can hooks trigger external calls that loop back into the protocol unexpectedly?
    - Ensure `lock` mechanism (if used) is effective.

## 7. Governance and Access Control (`MarginManager`, others) (Unit, Integration Tests)

- [ ] **(Unit/Integration)** Verify only the designated owner/admin can call privileged functions (`setPolicyParam`, pause, change fee destination, etc.). Test with non-owner accounts.
- [ ] **(Unit/Integration)** Verify only the designated pauser role (if separate) can pause/unpause.
- [ ] **(Integration)** Pause the protocol: Verify core user actions (`executeBatch`, potentially `liquidate` depending on design) revert. Verify admin functions still work.
- [ ] **(Integration)** Unpause the protocol: Verify normal functionality is restored.
- [ ] **(Integration)** Update a policy parameter (e.g., liquidation threshold): Verify the change is stored and reflected in subsequent actions (e.g., solvency checks use the new threshold).
- [ ] **(Integration)** Verify `PolicyUpdated` (or similar) events are emitted on governance changes.

## 8. System-Wide Invariants (Invariant Tests during Fuzzing/Integration)

- [ ] **(Invariant)** **Asset Conservation:** Total collateral (token0/1) across all `Margin` accounts + `MarginManager` + `SpotLiquidityManager` + `FullRangeLiquidityManager` should consistently match the net external deposits/withdrawals (accounting for fees leaving the system, if any).
- [ ] **(Invariant)** **Debt Consistency:** Total debt recorded across all `Margin` accounts should equal the total amount of the borrowed asset managed by the protocol (e.g., sourced from POL).
- [ ] **(Invariant)** **LP Share Value:** Total underlying assets held by `SpotLiquidityManager` should correspond to the total supply of its LP shares multiplied by the current share price/value.
- [ ] **(Invariant)** **Solvency:** No user `Margin` account should have LTV > Max LTV threshold *after* an `executeBatch` action completes successfully. (It can temporarily exceed during the action or before liquidation).
- [ ] **(Invariant)** **POL Accounting:** The value tracked within `FullRangeLiquidityManager` should correctly reflect accumulated fees and liquidation proceeds deposited into it.
- [ ] **(Invariant)** **Oracle Consistency:** Oracle price should only update based on valid pool interactions or admin overrides (if any). Price should not change without cause.

## 9. Gas Efficiency (Analysis / Scenario Tests)

- [ ] **(Analysis)** Measure gas costs for common user flows: deposit, withdraw, borrow, repay, swap (single and batched).
- [ ] **(Analysis)** Measure gas cost for liquidation.
- [ ] **(Analysis)** Measure gas costs for hook callbacks during typical pool interactions.
- [ ] **(Scenario)** Test gas usage with a large number of margin accounts existing.
- [ ] **(Scenario)** Test gas usage for complex `executeBatch` calls involving multiple actions.

## 10. Upgradeability (If Applicable) (Scenario Tests)

- [ ] **(Scenario)** If using proxies (e.g., UUPS), deploy V1, perform actions, upgrade to V2 (with a compatible change), verify state is preserved, and V2 functions work correctly.
- [ ] **(Scenario)** Test upgrade process failure modes (e.g., trying to upgrade with wrong admin account).