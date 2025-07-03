# Spot.sol - One-Pager

Central swap hook, fee router & reinvest brain

## 1. Purpose & Context

* **What** - Acts as the hub that glues together the oracle-driven fee engine, the full-range liquidity vault, and Uniswap V4 pools. It intercepts every swap to apply dynamic fees, streams protocol fees into the vault, and exposes simple deposit / withdraw UX.
* **Where** - Deployed as the hooks address inside each pool's `PoolKey`; called by the V4 PoolManager on every liquidity or swap action.
* **Who**:
  * **Write-path** - `deposit`, `withdraw`, `setPoolEmergencyState`, `pokeReinvest`, hook callbacks from PoolManager.
  * **Read-path** - Dashboards (`getPoolInfo`, `getOracleData`), routers (fee quote via `beforeSwapReturnDelta`).

## 2. Trust & Threat Model

| Actor | Trust | Abuse → Mitigation |
|-------|-------|--------------------|
| Governance owner/DAO | High | Mis-set reinvest params → `onlyGovernance` gate + multisig recommended |
| Authorised LiquidityManager | Med | Rogue liquidity moves → address immutable & one-time set |
| DynamicFeeManager | Med | Returns 0 fee → fallback to base fee; oracle bounded |
| Random EOA | None | All mutators gated; swaps go through PoolManager only |

## 3. Key Storage Layout

| Category | Variable(s) | Default / Range |
|----------|------------|-----------------|
| Core refs | `policyManager`, `liquidityManager`, `truncGeoOracle`, `feeManager` (immutables) | Set at deploy |
| Pool registry | `poolKeys[pid]`, `poolData[pid]` (bool init, bool emergency, uint64 lastSwapTs) | Zero |
| Reinvest cfg | `reinvestCfg[pid]` (minToken0, minToken1, last, cooldown) | Zeroed |
| Global flag | `reinvestmentPaused` | false |

## 4. External API (happy-path)

```solidity
function deposit(DepositParams p)
    external payable nonReentrant ensure(p.deadline)
    returns (uint256 shares, uint256 a0, uint256 a1);  // swaps ETH if native

function withdraw(WithdrawParams p)
    external nonReentrant ensure(p.deadline)
    returns (uint256 a0, uint256 a1);

function pokeReinvest(PoolId id) external nonReentrant;        // anyone – triggers fee reinvest
function setReinvestmentPaused(bool paused) external onlyGov;

function setPoolEmergencyState(PoolId id, bool emergency)      // onlyGov; halts deposits/swaps
    external;

function getPoolInfo(PoolId id) external view
    returns (bool init, uint256[2] memory reserves, uint128 shares, uint256 tokenId);
```

Gas: deposit ≈ 240 k, withdraw ≈ 200 k.

## 5. Events Cheat-Sheet

* `Deposit` / `Withdraw` → user I/O accounting.
* `ReinvestmentSuccess` / `ReinvestSkipped` → fee-to-POL telemetry.
* `PoolEmergencyStateChanged` & `ReinvestmentPauseToggled` → ops alerts.
* `OracleInitialized` / `PolicyInitializationFailed` → pool bootstrap status.

## 6. Critical Invariants & Reverts

1. **Pool must be initialised** - every user action checks `poolData.initialized`.
2. **Emergency halt** - deposits & swaps revert if `emergencyState` active.
3. **Single trusted hook** - Spot validates `msg.sender == poolManager` on every hook call.
4. **Fee flow integrity** - after each swap, oracle → feeManager → Spot reinvest, all bounded by gas-stipend.
5. **Slippage & deadlines** - `ensure(deadline)` and min-amount checks propagate to LM.

## 7. Governance / Upgrade Flow

1. Deploy Spot with addresses of DynamicFeeManager, FullRangeLiquidityManager, TruncGeoOracleMulti, PoolPolicyManager.
2. Pool deployer sets Spot as hooks, triggering `afterInitialize` bootstrap.
3. Governor adjusts `reinvestCfg` or toggles `reinvestmentPaused`/`emergencyState` as needed.
4. Contract is non-upgradeable; new version requires fresh deploy + pool migration.

## 8. Dev & Ops Tips

* Unit tests: fuzz `_afterSwap` with capped/uncapped ticks to ensure fee propagation.
* Monitoring: track `ReinvestSkipped` reasons for tuning thresholds & cooldowns.
* Gas: `GAS_STIPEND` (100 k) caps external-call grief; adjust only with profiling.
* Docs: See sibling one-pagers for deep dives:
  * DynamicFeeManager → one-pager
  * FullRangeLiquidityManager → one-pager
  * TruncGeoOracleMulti → one-pager
  * PoolPolicyManager → one-pager

## 9. Security Considerations

| Risk | Mitigation |
|------|------------|
| Oracle or feeManager revert → swap stuck | Wrapped in gas-stipend call; failure just disables surge fee this block |
| Reinvest sandwich attack | Threshold + cooldown + max full-range liquidity minimise MEV capture |
| PoolManager re-entrancy | `ReentrancyGuard` on all mutators; callbacks validate sender |
| Deprecated setter abuse | Deprecated functions always revert + emit deprecation event |

