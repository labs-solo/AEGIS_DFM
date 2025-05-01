📑 Re-scoped Integration-Test Plan

(v2 – aligned with the codebase as of ForkSetup.t.sol & the latest failing‐test report)

⸻

0. Why this revision?
 • The original matrix was written before we consolidated many unit specs into the four big “integration” suites now living in
test/integration/.
 • Several helper APIs that appeared in the first draft (isInCapEvent(), “pendingFee*”, etc.) do not exist (or are now private), while new helpers (DynamicFeeManager.getFeeState, _addLiquidityAsGovernance …) were added.
 • Current red tests show the real pain-points:
 • CAP-driven base-fee bump not detected (test_B2_BaseFee_Increases_With_CAP_Events)
 • POL reinvest flow / pause logic (two InternalReinvestTest failures)
 • Surge decay edge-cases (4 red tests in SurgeFeeDecayIntegration)

The plan below keeps the high-level coverage goals, but maps directly onto today’s files & helpers so we can start greening the suite instead of rewriting half the harness.

⸻

1. File Layout (update)

test/integration/
├── ForkSetup.t.sol                 # shared deploy/utility base (unchanged)
├── DeploymentAndConfig.t.sol       # ✅ already exists
├── DynamicFeeAndPOL.t.sol          # ✅ red/green mix – keep
├── InternalReinvestTest.t.sol      # ✅ red – keep
├── SurgeFeeDecayIntegration.t.sol  # ✅ red – keep
├── LiquidityComparison.t.sol       # ✅ green – keep
└── InvariantLiquiditySettlement.t.sol # ⛔ fixture not implemented yet

We will not create seven new files as in v1 – the existing suites already group the concerns logically.
Instead we retitle some individual tests and add the missing ones inside the same contracts.

⸻

2. Re-mapped Test Objectives & Names

Old Section New concrete test (inside which file / function stub) Notes & rationale
A. Deployment & Config DeploymentAndConfig.t.sol already covers address wiring and policy param sanity.  Add a single holistic check:test_PolicyParametersSnapshot() – emit or assert every getter value (min/max base fee, decay window, POL share, tickScalingFactor…) so that future PRs altering deployment will fail loudly. keeps file focused.
B. Dynamic Fee – base vs surge Already partially covered in DynamicFeeAndPOL.t.sol (test_B1_*etc.)  Add:test_DynamicFee_MatchesHookReturn() – compares fee returned by Spot.beforeSwap (via hook) vs dfm.getFeeState. ensures hook wiring.
C. CAP Lifecycle Rename failing testtest_B2_BaseFee_Increases_With_CAP_Events ➜ test_BaseFee_Increase_OnCap() (same logic).Add lightweight helper in same file:_doCapTriggerSwap() so other tests can reuse. match file naming convention.
D. Base-fee decay Already tested in test_B3_BaseFee_Decreases_When_Caps_Too_Rare.  No rename.
E. POL extraction Covered implicitly by fee accounting; add in DynamicFeeAndPOL.t.sol:test_POLQueue_IncreasesAfterSwap() – inspect liquidityManager.positionTotalShares[poolId] before/after small swap and assert delta matches polSharePpm. There are no pendingFee* vars; shares growth is the observable signal.
F–G. POL reinvest InternalReinvestTest.t.sol already targets this.  Adjust names:test_ReinvestSucceedsAfterBalance ➜ test_POLReinvest_SucceedsWhenUnpaused.test_ReinvestSkippedWhenGlobalPaused stays. clarity & grep-ability.
H. Safety / Pause Already in InternalReinvestTest & SurgeFeeDecayIntegration.  Add one generic check in Surge file:test_RevertOnReentrancy() that tries nested dfm.notifyOracleUpdate.
I. Combined flows LiquidityComparison.t.sol is the combined flow (direct vs FRLM).  Keep as is; ensure variable names use new constants from TestConstants.sol.

⸻

3. Immediate fix-first focus (red tests)

Failing test Likely root-cause & quick harness patch
Base fee did not increase after CAP events Our “large” swap in helper no longer guarantees TickCheck.isCap(...) > 0 after liquidity scaling ×10.  Action: compute required amount from oracle.getMaxTicksPerBlock at runtime instead of hard-coding 35 k USDC.
TRANSFER_FROM_FAILED in _IsolatedDeposit_Initial() lpProvider now needs allowance to LiquidityManager not PoolManager inside isolated helper.  Approve both.
Two InternalReinvestTest reverts Global pause flag default changed to true.  Before calling reinvest, set policyManager.setGlobalPaused(false).
Four Surge decay mismatches New fee math switched from linear to stepwise decay by block.  Update expected surge formula in tests from strict half to initialSurge * (period-left)/period rounded by tickScalingFactor.

(These are code fixes – not part of the plan, but listed so the next dev knows where to attack.)

⸻

4. Drop / defer
 • InvariantLiquiditySettlement.t.sol ⟶ skipped for now; the fixture isn’t implemented and it hides real CI signal.
 • Tests that rely on non-existent public getters (isInCapEvent, pendingFee0) are removed; coverage will come from observable side-effects instead (share minting, events).

⸻

5. Coverage target

We keep the > 95 % branch coverage on:
 • DynamicFeeManager.sol
 • FullRangeLiquidityManager.sol
 • Spot.sol

forge coverage with the updated suites should be wired in CI (--report summary,lcov).

⸻

6. Next steps checklist
 • Patch failing helpers (see §3).
 • Rename tests & update expectEmit topics accordingly.
 • Add the two small new tests described in §2.
 • Re-run forge test -vv; ensure green.
 • Push & let CI publish coverage to PR.

⸻

Made with 🖤 and a lot of vm.roll.
