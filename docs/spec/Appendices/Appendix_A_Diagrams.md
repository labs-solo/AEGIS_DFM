# Appendix A – Diagram Assets

## A.1 Module Graph (`diagrams/module_graph.mmd`)

```mermaid
graph TD
    subgraph User
        U(User)
    end
    subgraph Entry
        BE[BatchEngine]
    end
    subgraph Core
        VMC[VaultManagerCore]
    end
    subgraph UniswapV4
        P[Pool Kernel]
        SH[SpotHook]
    end
    subgraph Services
        DFM[DynamicFeeManager]
        ORA[Oracle]
    end
    subgraph Collateral
        PM[PositionManager]
    end
    subgraph Risk
        LQ[LiquidationEngine]
    end
    subgraph Gov
        GOV[Governor+Timelock]
        POL[PolicyManager]
    end
    subgraph Treasury
        TSWY[Treasury]
    end

    U --> BE --> VMC
    VMC --> P
    P --> SH
    SH --> DFM
    DFM -.re‑bate.-> P
    SH --> TSWY
    VMC --> ORA
    DFM --> ORA
    VMC --> PM
    LQ --> VMC
    GOV --> POL --> VMC
    GOV --> VMC
    VMC --> TSWY
```

### A.2 Roles & Governance Graph (`diagrams/roles_graph.mmd`)

```mermaid
graph LR
    GOV[Governor] --> TIM[Timelock]
    TIM --> POL[PolicyManager]
    TIM --> VMC[VaultManagerCore]
    POL --> VMC
    GOV --> SH[SpotHook]
    GOV --> PM[PositionManager]
    GOV --> TSWY[Treasury]
    POL --> DFM[DynamicFeeManager]
    VMC --> LQ[LiquidationEngine]
```

\### A.2 Roles & Permissions Graph (updated)

```mermaid
graph LR
    GOV[Governor (DAO)] -->|queues tx| TIM[Timelock]
    TIM -->|executes after delay| VMC[VaultManager Core]
    TIM --> POLM[PoolPolicyManager]
    TIM --> LENS[VaultMetricsLens]
    GOV --> TSWY[Treasury]
    GOV --> SH[Spot Hook]
    GOV --> PM[PositionManager]
    PG[Pause Guardian] --|toggle pauseFlags| VMC
    PG --|cancel queue| TIM
```

\### A.3 Upgrade Sequence (normal + emergency pause)

```mermaid
sequenceDiagram
    autonumber
    participant GOV as DAO Governor
    participant TIM as Timelock
    participant PG  as Pause Guardian
    participant VMC as VaultManagerCore

    GOV->>TIM: queueChange(new impl)
    Note right of TIM: delay ≥ 48 h
    alt critical bug
        PG->>VMC: set PAUSE_ALL
    end
    TIM->>VMC: executeChange()
    VMC-->>VMC: proxy → new logic
    opt PAUSE_ALL set
        PG->>VMC: clear PAUSE_ALL
    end
```

