``` mermaid
sequenceDiagram
    autonumber
    participant U as User
    participant Spot as Spot (Hook)
    participant PM as PoolManager
    participant Oracle as TruncGeoOracleMulti
    participant Policy as PoolPolicyManager
    participant DynFee as FullRangeDynamicFeeManager
    participant LM as FullRangeLiquidityManager
    participant POS as FullRangePositions

    rect rgb(240,240,255)
      Note over U,PM: ──  Pool Initialization ──
      U->>PM: initialize(poolKey, sqrtPriceX96)
      PM-->>U: emit Initialize(...)
      PM->>Spot: afterInitialize(...)
      activate Spot
        Spot->>Oracle: enableOracleForPool(key, MAX_ABS_TICK_MOVE)
        Oracle-->>Spot: (ok)
        Spot->>Policy: handlePoolInitialization(...)
        Policy-->>Spot: (ok)
        Spot->>LM: storePoolKey(poolId, key)
        LM-->>Spot: (ok)
      deactivate Spot
      Spot->>DynFee: initializeFeeData(poolId)
      DynFee-->>Spot: (set baseFee=3000)
      Spot->>DynFee: initializeOracleData(poolId, initialTick)
      DynFee-->>Spot: (record tick=initialTick)
    end

    rect rgb(240,255,240)
      Note over U,LM: ──  Add Liquidity (deposit) ──
      U->>Spot: deposit(params)
      activate Spot
        Spot->>LM: deposit(params…)
        activate LM
          LM→>POS: mint(positionToken)
          POS-->>LM: (ok)
          LM→>PM: unlock(callbackData(DEPOSIT))
          activate PM
            PM→>LM: modifyLiquidity(...)
            LM–>PM: settle via CurrencySettlerExtension
          deactivate PM
        LM-->>Spot: (shares minted)
      deactivate LM
        Spot–>U: return (shares, amounts)
      deactivate Spot
    end

    rect rgb(255,240,240)
      Note over U,PM: ──  Swap & Dynamic Fee ──
      U->>PM: unlock(callbackData(SWAP))  or directly swap(...)
      PM->>Spot: beforeSwap(...)
      activate Spot
        Spot->>DynFee: getCurrentDynamicFee(poolId)
        DynFee–>Spot: (feePpm, may internally update cap/decay)
      deactivate Spot
      PM-->>U: do swap
      PM->>Spot: afterSwap(...)
      activate Spot
        Spot->>Oracle: updateObservation(key)
        Oracle–>Spot: (ok)
        Spot->>LM: _updateOracleTick(key) (fallback)
        Spot->>Spot: _processSwapFees…
      deactivate Spot
    end
```
