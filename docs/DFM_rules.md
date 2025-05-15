## A Overall-codebase rules

1. Red-bar first: add a failing test that reproduces the bug before any patch; commit it to lock the regression.
2. Batch unrelated fixes (Batch 1, Batch 2, …); never mix concerns in one PR.
3. Never change core business logic unless a new invariant or fuzz test proves behaviour unchanged.
4. Update a Running FAQ (answered + pending) after every session to preserve tribal knowledge.
5. Maintain broad invariant + fuzz coverage on edge ranges (min/max ticks, zero liquidity, overflow).
6. Annotate tricky paths with NatSpec & inline comments when a defect is fixed.
7. Instrument key state transitions with emit log\_named\_ to shorten future triage.
8. Parameterise tests so new inputs automatically exercise past regression surfaces.
9. Record every “gas win” in a markdown ledger so optimisations aren’t re-litigated.
10. Monotone Surge Decay – surge-fee may only decline between CAP events.
11. Base-fee Step-limit – base-fee moves ≤ baseFeeStepPpm per interval.
12. Hard Tick Cap – Oracle clamps any tick move > maxTicksPerBlock.
13. Hook Exclusivity – only the authorised Spot hook may call any write-path on Oracle or DynamicFeeManager.
14. Gas-stipend guard – external calls made by Spot are limited to 100 000 gas for normal swaps; reinvest calls are excluded.
15. Global re-entrancy gate – every mutator is nonReentrant; Spot also enforces msg.sender == PoolManager.
16. Emergency kill-switch – fee adjustments revert while emergencyState == true.
17. Every externally callable mutator must be protected by onlyOwner, onlyGovernance, or explicit authorised-hook check.
18. Emit an event for every config change (fee splits, cap updates, policy swaps) so off-chain monitors can diff state.
19. CI must keep ≥ 100 % branch coverage on critical invariants; new tests may not delete a previously asserted truth.

⸻

## B Tests / CI rules

20. Heavy fork fixtures are isolated from pure-unit tests.
21. Pool-manager address in all fixtures is deterministic; prevents keccak variance in revert selectors.
22. Unit test FullRangeLiquidityManager: every deposit must mint > 0 shares.
23. After oracle init the ring-buffer cardinality must equal 1 (assertEq(card,1)).
24. Oracle tick is capped when an over-limit value is pushed (assertTrue(tickWasCapped)).
25. DynamicFeeManager base-fee remains unchanged after redundant initialize calls.
26. Integration: initial surge fee = 0; base fee = policy default.
27. Integration: surge component must reach exactly 0 when decay window elapses.
28. Fork deployment test: on-chain hook address must match deterministic salt.

⸻

## C File-specific rules

### FullRangeLiquidityManager.sol

29. Authorised hook address can be set once; a second call reverts.
30. First deposit mints MIN\_LOCKED\_SHARES to address(0); those shares can never be withdrawn.
31. ERC-6909 is the sole share ledger; totalSupply must equal positionTotalShares after every state change.
32. Deposit & withdraw revert if realised amounts fall below user-supplied mins (slippage guard).
33. All external mutators are nonReentrant.
34. Invariant test: deposit → withdraw round-trips balances within ± 1 wei.
35. PoolKey ordering (token0 < token1) is enforced.
36. Re-balancing is integrated via pre/post-swap hooks so traders pay the gas.
37. Safe unchecked increment in bounded for loops.
38. Deposit/Withdraw events are emitted after state write.
39. Guard helpers ensure sqrtPriceLimitX96 never triggers PriceLimitOutOfBounds.
40. All view functions are pure/read-only.

### Spot.sol

41. Transient storage words (tstore/tload) never overlap (poolId, poolId+1).
42. \_beforeSwap rejects negative deltas on “exact-in” path (InvalidSwapDelta).
43. \_afterInitialize reverts if initial sqrtPriceX96 == 0 (InvalidPrice).
44. Skip reinvest when feesToReinvest == 0 to save gas.
45. Every Spot callback validates msg.sender == PoolManager (Single Trusted Hook).
46. After each swap, the oracle → DFM → Spot fee flow must succeed (bounded by gas‑stipend) or the entire swap reverts.
47. ensure(deadline) plus user min-amount checks propagate to FullRangeLiquidityManager.

### DynamicFeeManager.sol

48. \_requireHookAuth rejects any caller that is not owner, oracle, or authorised hook.
49. initialize reverts if policyManager or oracle is the zero address.
50. A pool may be initialized only once; repeat calls emit AlreadyInitialized but change nothing.
51. Oracle address must never be 0x0 (constructor guard).
52. Surge-fee monotonicity – surgeFeePPM decays linearly to 0 over surgeDecayPeriodSeconds; it can increase only on CAP events.
53. Base-fee falls back to DEFAULT\_BASE\_FEE\_PPM (0.5 %) when the oracle returns 0 ticks.
54. Fee bound invariant: ticksPerBlock == feePctBps.
55. Minimum trading fee (minimumFeeBps) is governance‑settable but never 0.
56. Pure previewFee() helper performs no storage writes.
57. All per‑pool data live in a 256‑bit packed slot; bit‑mask helpers guarantee no field overlap.

### PoolPolicyManager.sol

58. POL + FullRange + LP fee splits must sum to 1 000 000 ppm or the tx reverts.
59. minimumTradingFeePpm & feeClaimThresholdPpm ≤ 100 000 ppm (10 %).
60. Tick‑scaling factor must be > 0; step size ≤ 100 000 ppm; surge multiplier ≤ 3 000 000 ppm.
61. Surge decay window must be in \[60 s, 1 day].
62. Protocol‑interest fee ≤ 1 000 000 ppm (100 %).
63. All critical setters revert when given address(0).
64. setDefaultDynamicFee bounds new fee to \[1, 50 000] ppm (FeeTooHigh).
65. setPoolPOLShare rejects values > 1 000 000 ppm.
66. initializePolicies must receive exactly 4 implementation addresses.

### TruncGeoOracleMulti.sol

67. enableOracleForPool validates and clamps the initial maxTicksPerBlock into \[minCap, maxCap].
68. Cached policy must satisfy: minCap ≤ maxCap, stepPpm ≤ 1e6, budgetPpm ≤ 1e6, decayWindow > 0, updateInterval > 0.
69. pushObservationAndCheckCap callable only by authorised hook.
70. Cardinality never exceeds PAGE\_SIZE = 512 per leaf; ring-buffer wraps correctly.
71. maxTicksPerBlock can move ≤ stepPpm every updateInterval (Cap Step-Limit).
72. All mutators inherit nonReentrant.
73. Cap-frequency counter capFreq saturates at CAP\_FREQ\_MAX (no uint64 overflow).
74. Governance may refresh the policy cache only once per block per pool (rate-limit).
