# FullRangeLiquidityManager - One-Pager

Pooled full-range LP vault with ERC-6909 shares

## 1. Purpose & Context

* **What** - Aggregates user or protocol capital into a single full-range Uniswap V4 position per pool, minting fungible ERC-6909 shares that track proportional ownership.
* **Where** - Sits between a Spot hook (authorised contract) and the V4 PoolManager; uses unlockCallback to add/remove liquidity atomically.
* **Who**:
  * **Write-path** - Owner / governance (`deposit`, `withdraw`, `reinvest`), authorised hook (`storePoolKey`, fee reinvest).
  * **Read-path** - Routers & UIs (`poolKeys`, `getPoolReserves`, `getAccountPosition`, `getShares`).

## 2. Trust & Threat Model

| Actor | Trust | Abuse → Mitigation |
|-------|-------|-------------------|
| Governance (owner / DAO) | High | Mis-set hook → callable only once; all ops gated by `onlyGovernance`. |
| Authorised Hook | Med | Malicious liquidity moves → restricted to preset poolIDs via `onlyHook`. |
| PoolManager | Med | Re-entrancy on callback → contract is `ReentrancyGuard`. |
| Liquidity provider (POL) | Low | Deposit/withdraw griefing → strict slippage & share maths. |
| Random EOA / bot | None | No public mutators; all paths gated. |

## 3. Key Storage Layout

| Category | Variable(s) | Default / Range |
|----------|------------|-----------------|
| Core refs | `manager`, `policyManager`, `positions` (immutable) | Set at deploy |
| Pool registry | `_poolKeys[poolId]` | Empty → not initialised |
| Share tracking | `positionTotalShares[poolId]` uint128 | 0 – 2²⁷-1 |
| Seed lock | `lockedShares[poolId]` uint128 | `MIN_LOCKED_SHARES` |
| Authority | `authorizedHookAddress_` | Once-set, non-zero |

## 4. External API (happy-path)

```solidity
function setAuthorizedHookAddress(address hook) external onlyOwner;        // one-time
function storePoolKey(PoolId id, PoolKey key)      external onlyHook;      // afterInitialize
function deposit(PoolId id, uint256 a0, uint256 a1,
                 uint256 min0, uint256 min1, address to)
        external nonReentrant onlyGovernance
        returns (uint256 shares, uint256 used0, uint256 used1);
function withdraw(PoolId id, uint256 burn,
                  uint256 min0, uint256 min1, address to)
        external nonReentrant onlyGovernance
        returns (uint256 out0, uint256 out1);
function reinvest(PoolId id, uint256 use0, uint256 use1, uint128 liq)
        external payable nonReentrant returns (uint128 sharesMinted); // protocol fees
```

Gas guide: deposit ~ 210 k; withdraw ~ 180 k (median).

## 5. Events Cheat-Sheet

| Event | Fired on | Why |
|-------|----------|-----|
| `PoolKeyStored` | pool registration | Links PoolId ↔ PoolKey. |
| `AuthorizedHookAddressSet` | hook set | Immutable authority anchor. |
| `LiquidityAdded` / `Removed` | deposit & withdraw | Off-chain share & PnL accounting. |
| `Reinvested` | fee reinvest | Shows protocol-owned-liquidity (POL) growth. |
| `PoolStateUpdated` | every mutator | Emits new total shares for monitoring. |

## 6. Critical Invariants & Reverts

1. **One-time hook set** - `authorizedHookAddress_` can't be overwritten.
2. **Seed liquidity lock** - first deposit mints `MIN_LOCKED_SHARES` to address(0); never withdrawable.
3. **Share accounting** - `positionTotalShares` = ∑ ERC-6909 supply; checked every state change.
4. **Slippage control** - deposits/withdraws revert if actual ‹ min* params.
5. **Re-entrancy** - all mutators use `nonReentrant`; callbacks validated.

## 7. Governance / Upgrade Flow

1. Deploy LM with PoolManager & policyManager; owner sets hook once.
2. Governance (or hook) registers each pool via `storePoolKey`.
3. Phase-1: only governance may deposit/withdraw; later phases can relax modifier.
4. Contract is non-upgradeable; migrations require new LM & token contract.

## 8. Dev & Ops Tips

* Testing: fuzz `_calculateDepositSharesInternal` around edge ratios and zero-liq cases.
* Gas: keep `MIN_LOCKED_SHARES` small; share maths uses packed uint128.
* Observability: index `PoolStateUpdated` for real-time TVL dashboard.
* ETH flows: pools with native ETH require `msg.value` ≥ needed; excess auto-refunded.

## 9. Security Considerations

| Risk | Mitigation |
|------|------------|
| Hook compromise → rogue liquidity ops | One-time address, multisig upgrade path. |
| Share inflation error | Share maths uses `FullMath.mulDiv` & unit tests. |
| Callback spoofing | `unlockCallback` validates `msg.sender == manager`. |
| ETH theft via fallback | No payable fallback; receive-only. |
| Math overflow/underflow | OpenZeppelin Math, SafeCast, FullMath throughout. |

