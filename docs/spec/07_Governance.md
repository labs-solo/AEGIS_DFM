### 7 Governance Roles & Privilege Mapping (updated)

| Role              | Control Surface                                         | Powers (⭑ = immediate, ⭘ = time-delayed)                                                                                         | Notes                                                                                                      |
| ----------------- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------- |
| **DAO Governor**  | Governor contract                                       | ⭘ Propose/queue any parameter change, contract upgrade, or treasury move                                                       | All successful proposals must enter the Timelock queue before execution.                                    |
| **Timelock**      | `IGovernanceTimelock` (owner of all upgradable modules) | ⭘ Execute queued transactions after **minDelay = 48 h** and before **grace = 14 d**; ⭘ cancel if guardian/DAO revoke queue     | Queue/execute/cancel semantics enforced on-chain. Parameters live in `TimelockConfig` at storage slot 23.  |
| **Pause Guardian**| Single multisig address                                 | ⭑ Toggle any bit in `pauseFlags` bitmap (see Table 7-1) to halt/resume functions; ⭑ cancel a queued Timelock tx in emergencies | No power to upgrade or move funds; Guardian actions are transparent events.                                 |
| **Keeper(s)**     | Permissionless actors                                   | Call `accrueInterest`, `liquidate`, `reinvestFees`, batch helper ops                                                           | Incentivised; can be stopped instantly via the relevant pause bits.                                         |
| **Treasury & POL**| Protocol-owned account                                  | Receives protocol-owned liquidity (POL) & fees; covers bad debt via `coverBadDebt`                                             | Treasury moves _must_ flow through Governor → Timelock.                                                     |

**Operational Flow**

1. **Normal governance** – proposal → Governor vote → Timelock *queue* → 48 h delay → _execute_ → change applied.
2. **Emergency** – Pause Guardian sets `PAUSE_ALL` (bit 0) ⭑; protocol frozen while a fix is prepared.
3. **Fast-track patch** – Governor submits upgrade; Timelock keeps standard delay, but risk is mitigated by the pause flag during the waiting window.
4. **Recovery** – once the fix is executed, Guardian (or Governor) clears `PAUSE_ALL` and normal operation resumes.

> **Where to find the bit-level mapping:** Table 7-1 in the main spec lists every pause bit and the functions it controls; the diagram in Appendix A.2 cross-links each role to the exact calls it can invoke.

### 7.4 Cross-chain Re-entrancy (L2/L3)

Bridged calls from layer-two or layer-three systems could attempt to reenter `VaultManagerCore` during finalization. The vault's `nonReentrant` guard and per-batch interest index checkpoint prevent loops. Governance transactions executed via cross-chain messengers must still pass through the Timelock, so the residual risk is low.
