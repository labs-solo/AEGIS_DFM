# File: BatchEngine.mmd      — rev. 2025-07-03

flowchart TD
    classDef success fill:#c8facc,stroke:#2b8,stroke-width:2px,color:#000;
    classDef error   fill:#ffb3b3,stroke:#d33,stroke-width:2px,color:#000;

    %% ── main execution path ───────────────────────────────────────────────
    Start([BatchEngine.entry()]) --> A0[0 - initBatch]
    A0 -->|orders == 0| EndSuccess((Exit – No-op)):::success
    A0 -->|orders &gt; 0| A1[1 - validateBatchParams]

    A1 -->|invalid| ErrInvalid((Revert: BAD_PARAMS)):::error
    A1 -->|ok| A2[2 - preFetchOraclesHook]

    A2 -->|oracle stale| ErrOracle((Revert: ORACLE_STALE)):::error
    A2 -->|fresh| A3[3 - computeDynamicFees]

    A3 --> A4[4 - checkBorrowRateCap]
    A4 -->|rate &gt; cap| ErrRateCap((Revert: BORROW_RATE_CAP)):::error
    A4 -->|within cap| A5[5 - provideSingleTickLiquidity]

    A5 --> A6[6 - applyFeesHook]
    A6 --> A7[7 - executeTrades]
    A7 --> A8[8 - updateVaultStates]

    A8 -->|liquidations?| A9[9 - liquidationCheck]
    A8 -->|none|          A10[10 - commitBalances]

    A9 --> A10
    A10 --> A11[11 - syncOraclesHook]
    A11 --> A12[12 - settleGasRefund]
    A12 --> A13[13 - verifyInvariants]
    A13 --> A14[14 - finalizeBatch]
    A14 --> EndSuccess

    %% ── side-notes for gas & invariants ──────────────────────────────────
    note right of A7
      ActionExecuted emitted
    end

    note right of A5
      ~66 k gas
    end

    note left of A9
      external call → liquidate()
    end

    %% ── style block preserved from original template ─────────────────────
    class EndSuccess success
    class ErrInvalid,ErrOracle,ErrRateCap error
