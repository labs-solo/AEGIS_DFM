## A Process & Quality Guidelines

### A1 Process & Documentation

1. **Red‑bar first** – add a failing test that reproduces the bug before any patch; commit it to lock the regression.
2. **Batch unrelated fixes** (Batch 1, Batch 2, …) – never mix concerns in one PR.
3. **Update a Running FAQ** (answered + pending) after every session to preserve tribal knowledge.

### A2 Coverage & Instrumentation

4. **Broad invariant / fuzz coverage** – keep edge‑range checks for min/max ticks, zero liquidity, overflow.
5. **Annotate tricky paths** with NatSpec & inline comments whenever a defect is fixed.
6. **Instrument state transitions** with `emit log_named_…` to shorten future triage.
7. **Parameterise tests** so new inputs automatically exercise past regression surfaces.
8. **Record every “gas win”** in a markdown ledger so optimisations aren’t re‑litigated.
9. **CI guard‑rail** – ≥ 100 % branch coverage on critical invariants; new tests may not delete a previously asserted truth.

## B Testing & CI Guidelines

### B1 Environment & Setup

10. Heavy fork fixtures are isolated from pure‑unit tests.
11. Pool‑manager address in all fixtures is deterministic; prevents `keccak` variance in revert selectors.

### B2 Unit Tests

12. FullRangeLiquidityManager: every deposit must mint > 0 shares.
13. TruncGeoOracleMulti: ring‑buffer cardinality equals 1 right after oracle init (`assertEq(card, 1)`).
14. TruncGeoOracleMulti: oracle tick is capped when an over‑limit value is pushed (`assertTrue(tickWasCapped)`).
15. DynamicFeeManager: base‑fee remains unchanged after redundant `initialize` calls.

### B3 Integration & Deployment

16. Integration: initial surge fee = 0; base fee = policy default.
17. Integration: surge component must reach exactly 0 when the decay window elapses.
18. Fork deployment test: on‑chain hook address must match deterministic salt.

⸻

## C Functional Requirements – Behaviour

### C0 Overall Functional Requirements

19. **Monotone Surge Decay** – surge‑fee may only decline between CAP events.
20. **Base‑fee Step‑limit** – base‑fee moves ≤ `baseFeeStepPpm` per interval.
21. **Hard Tick Cap** – Oracle clamps any tick move > `maxTicksPerBlock`.
22. **Hook Exclusivity** – only the authorised Spot hook may call any write‑path on Oracle or DynamicFeeManager.
23. **Global re‑entrancy gate** – every mutator is `nonReentrant`; Spot also enforces `msg.sender == PoolManager`.
24. **Emergency kill‑switch** – fee adjustments revert while `emergencyState == true`.
25. **Access control** – every externally callable mutator must be protected by `onlyOwner`, `onlyGovernance`, or explicit authorised‑hook check.
26. **State‑change events** – emit an event for every config change (fee splits, cap updates, policy swaps) so off‑chain monitors can diff state.

### FullRangeLiquidityManager.sol

27. Authorised hook address can be set once; a second call reverts.
28. First deposit mints `MIN_LOCKED_SHARES` to `address(0)`; those shares can never be withdrawn.
29. ERC‑6909 is the sole share ledger; `totalSupply` must equal `positionTotalShares` after every state change.
30. Deposit & withdraw revert if realised amounts fall below user‑supplied mins (slippage guard).
31. All external mutators are `nonReentrant`.
32. Invariant: deposit → withdraw round‑trips balances within ± 1 wei.
33. `PoolKey` ordering (`token0 < token1`) is enforced.
34. Re‑balancing is integrated via pre/post‑swap hooks so traders pay the gas.
35. Safe unchecked increment in bounded `for` loops.
36. `Deposit`/`Withdraw` events are emitted after state write.
37. Guard helpers ensure `sqrtPriceLimitX96` never triggers `PriceLimitOutOfBounds`.
38. All view functions are pure/read‑only.

### Spot.sol

39. **Gas‑stipend guard** – external calls are limited to 100 000 gas; reinvest calls are excluded.
40. Transient storage words (`tstore`/`tload`) never overlap (`poolId`, `poolId+1`).
41. `_beforeSwap` rejects negative deltas on “exact‑in” path (`InvalidSwapDelta`).
42. `_afterInitialize` reverts if initial `sqrtPriceX96 == 0` (`InvalidPrice`).
43. Skip reinvest when `feesToReinvest == 0` to save gas.
44. Every Spot callback validates `msg.sender == PoolManager` (Single Trusted Hook).
45. After each swap, the oracle → DFM → Spot fee flow must succeed (bounded by gas‑stipend) or the entire swap reverts.
46. `ensure(deadline)` plus user min‑amount checks propagate to `FullRangeLiquidityManager`.

### DynamicFeeManager.sol

47. `_requireHookAuth` rejects any caller that is not owner, oracle, or authorised hook.
48. `initialize` reverts if `policyManager` or `oracle` is the zero address.
49. A pool may be initialised only once; repeat calls emit `AlreadyInitialized` but change nothing.
50. Oracle address must never be `0x0` (constructor guard).
51. Surge‑fee monotonicity – `surgeFeePPM` decays linearly to 0 over `surgeDecayPeriodSeconds`; it can increase only on CAP events.
52. Base‑fee falls back to `DEFAULT_BASE_FEE_PPM` (0.5 %) when the oracle returns 0 ticks.
53. Fee‑bound invariant: `ticksPerBlock == feePctBps`.
54. Minimum trading fee (`minimumFeeBps`) is governance‑settable but never 0.
55. Pure `previewFee()` helper performs no storage writes.
56. All per‑pool data live in a 256‑bit packed slot; bit‑mask helpers guarantee no field overlap.

### PoolPolicyManager.sol

57. `POL` + FullRange + LP fee splits must sum to 1 000 000 ppm or the tx reverts.
58. `minimumTradingFeePpm` & `feeClaimThresholdPpm` ≤ 100 000 ppm (10 %).
59. Tick‑scaling factor > 0; step size ≤ 100 000 ppm; surge multiplier ≤ 3 000 000 ppm.
60. Surge decay window ∈ \[60 s, 1 day].
61. Protocol‑interest fee ≤ 1 000 000 ppm (100 %).
62. All critical setters revert when given `address(0)`.
63. `setDefaultDynamicFee` bounds new fee to \[1, 50 000] ppm (`FeeTooHigh`).
64. `setPoolPOLShare` rejects values > 1 000 000 ppm.
65. `initializePolicies` must receive exactly 4 implementation addresses.

### TruncGeoOracleMulti.sol

66. `enableOracleForPool` validates and clamps the initial `maxTicksPerBlock` into \[`minCap`, `maxCap`].
67. Cached policy must satisfy: `minCap ≤ maxCap`, `stepPpm ≤ 1e6`, `budgetPpm ≤ 1e6`, `decayWindow > 0`, `updateInterval > 0`.
68. `pushObservationAndCheckCap` callable only by authorised hook.
69. Cardinality never exceeds `PAGE_SIZE = 512` per leaf; ring‑buffer wraps correctly.
70. `maxTicksPerBlock` can move ≤ `stepPpm` every `updateInterval` (Cap Step‑Limit).
71. All mutators inherit `nonReentrant`.
72. Cap‑frequency counter `capFreq` saturates at `CAP_FREQ_MAX` (no `uint64` overflow).
73. Governance may refresh the policy cache only once per block per pool (rate‑limit).
