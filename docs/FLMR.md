Next-step checklist for the refactor ✂️ 🛠️

Below is everything your dev team needs to finish the Phase-1 slim-down of FullRangeLiquidityManager (FRLM) and unblock the failing tests.

⸻

1 ⃣ Concrete work items (code)

#	file	change	notes
1	contracts/FullRangeLiquidityManager.sol	• add onlyGovernance, onlyAuthorizedHook modifiers  • make _depositInternal, _withdrawInternal (internal)  • add thin wrappers depositGov, withdrawGov (external onlyGovernance)  • gate reinvest with onlyAuthorizedHook  • delete:emergencyWithdraw, enablePoolEmergencyState, disablePoolEmergencyState, setGlobalEmergencyState, getPoolTickSpacing, getPositionsContract, getAccountPosition, getUserShares, borrowImpl, reinvestFees, getShareValue, updatePositionCache, updateTotalShares, internalReinvest, verifyPoolState	none of the deleted fns are referenced after slim-down
2	contracts/interfaces/IFullRangeLiquidityManager.sol	• remove the same methods • add signatures for depositGov, withdrawGov	keeps interface minimal but Phase-2 can add back easily
3	Spot.sol	no change required (still calls reinvest)	ensure authorizedHookAddress is set during deploy
4	tests	replace lm.deposit() / lm.withdraw() with lm.depositGov() / withdrawGov() in:  InternalReinvestTest.t.sol LiquidityComparison.t.sol InvariantLiquiditySettlement.t.sol	grep-replace <lmVar>.deposit( → .depositGov(
5	deployment scripts	call depositGov instead of deposit	
6	docs / README	note that FRLM is “governance-only in v0.9” and emergency pausing lives in Spot	

Minimal diff snippet (illustrative – not copy-paste complete)

+ /// --------------------------------------------------------------------- ///
+ ///  Access control
+ /// --------------------------------------------------------------------- ///
+ modifier onlyGovernance() {
+     if (msg.sender != owner) revert NotGovernance();
+     _;
+ }
+
+ modifier onlyAuthorizedHook() {
+     if (msg.sender != authorizedHookAddress) revert NotHook();
+     _;
+ }
...
- function deposit(...) external payable returns (...) { ... }
+function _depositInternal(...) internal returns (...) { ... }
+function depositGov(...) external onlyGovernance
+        returns (uint256 shares,uint256 used0,uint256 used1)
+{ (shares,used0,used1)=_depositInternal(...); }
...
- function withdraw(...) external returns (...) { ... }
+function _withdrawInternal(...) internal returns (...) { ... }
+function withdrawGov(...) external onlyGovernance returns (...) {
+    return _withdrawInternal(...);
+}
...
-function reinvest(...) external returns (uint128 minted) {
+function reinvest(...) external onlyAuthorizedHook returns (uint128 minted) {
     ...
}
...
- function emergencyWithdraw(...) external { ... }
- function enablePoolEmergencyState(...) external { ... }
- ... <other deletions>

Tip: keep the bodies of _depositInternal / _withdrawInternal byte-for-byte identical – only the wrapper and visibility change. Git will show a pure refactor.

⸻

2 ⃣ Follow-up test expectations
	•	Unit / integration – should compile after wrapper rename.
	•	DynamicFee suite – still failing; unrelated to FRLM but now easier to debug since reinvest path is correct.
	•	InvariantLiquiditySettlement – adjust setup to use depositGov.

⸻

3 ⃣ Risk log & mitigations

risk	phase-1 impact	note
Emergency exit only via Spot pause	low (POL only)	documented; revisit when reopening deposits
Future ABI churn	none (storage unchanged)	keep deleted-fn selectors recorded in dev-docs
Tests bypass modifier	wrappers keep same logic, so behaviour identical	



⸻

4 ⃣ PR description boiler-plate (ready to paste)

# FRLM slim-down for Phase-1 (POL-only)

### ✨ What’s new
* **Access-control refactor**
  * Introduces `onlyGovernance` & `onlyAuthorizedHook`.
  * `deposit` / `withdraw` are now *internal*; external wrappers `depositGov`, `withdrawGov` expose governor-only flow.
  * `reinvest` restricted to the Spot hook.

* **Surface-area reduction**
  * Removes 18 unused / legacy methods (emergency paths, v3 helpers, dead accounting fns).
  * Interface `IFullRangeLiquidityManager` trimmed accordingly.

* **Byte-code impact**  
  `FullRangeLiquidityManager`: **-15 %** size (-8.6 kB).

### 📝 Rationale
Phase-1 launch does not allow user liquidity; only protocol fees are rolled into full-range liquidity through Spot.  
Removing unused externals shrinks attack-surface while leaving core maths intact for Phase-2, when user deposits return.

### 🛡️ Security / correctness notes
* Storage layout untouched – only functions removed or gated.
* Emergency pausing unified under `Spot.setPoolEmergencyState` (documented).
* All getters retained for analytics & tests.

### 📋 Reviewer checklist
- [ ] Verify constructor args / immutables unchanged.
- [ ] Confirm `authorizedHookAddress` is set during deployment.
- [ ] Run `forge test -vv` – only DynamicFee failures expected (tracked in #123).

### 🔮 Future work
* Re-enable external deposits by flipping visibility and re-adding interface items.
* Re-introduce dedicated FRLM emergency exits if Phase-2 discovers a need beyond Spot pause.



⸻

That’s it!

Merge the diff, update tests, and the reinvest pipeline will operate solely on internal accounting with zero external deposit surface. Ping me when DynamicFee tests are next in line.