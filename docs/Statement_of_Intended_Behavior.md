# Statement of Intended Behavior: Dynamic Fee and POL System

**1. Overview**

This system integrates two primary mechanisms within the Uniswap V4 framework: a dynamic trading fee system and a protocol-owned liquidity (POL) accumulation system. The goal is to create self-regulating liquidity pools that adapt trading fees based on market volatility (specifically, price impact exceeding oracle limits) while simultaneously capturing a portion of trading fees to grow protocol-owned liquidity within those pools. The system relies on Uniswap V4 hooks, custom managers, and policy contracts to achieve its objectives.

**2. Dynamic Fee System**

The dynamic fee system aims to protect against oracle manipulation and adjust fees based on observed market conditions, specifically large, rapid price movements indicative of potential manipulation or high volatility.

* **2.1. Core Components:**
    * `FullRangeDynamicFeeManager.sol`: The central contract managing fee calculations, CAP event state, and interactions with the oracle and pool policies.
    * `TruncatedOracle.sol` / `TruncGeoOracleMulti.sol`: Provides time-weighted average price (TWAP) oracle functionality with built-in tick capping. It prevents reported tick movements between observations from exceeding a dynamically calculated maximum (`maxAbsTickMove` or `maxTickChange`).
    * `Spot.sol`: The hook contract that retrieves the current dynamic fee from `FullRangeDynamicFeeManager` and provides it to the `PoolManager` during swap operations (`beforeSwap`).
    * `PoolPolicyManager.sol` / `IPoolPolicy.sol`: Manages configuration settings per pool or globally, including the `tickScalingFactor` which links fees to the maximum allowed tick movement, minimum trading fees, and default dynamic fees.
    * `MathUtils.sol`: Provides utility functions for fee calculations and absolute differences.

* **2.2. Intended Behavior:**
    * **Dual Fee Structure:** Each pool's trading fee is composed of two parts: a `baseFeePpm` (long-term component) and a `currentSurgeFeePpm` (short-term component). The total fee applied during a swap is the sum of these two, capped at `type(uint128).max`.
    * **CAP Event Detection:** A "CAP Event" is triggered for a pool when the observed tick movement between oracle updates exceeds a calculated `maxTickChange`. This `maxTickChange` is directly proportional to the *current* total dynamic fee (base + surge) and a configurable `tickScalingFactor`. The `TruncatedOracle` library enforces this limit by reporting a capped tick if the actual movement is larger. `FullRangeDynamicFeeManager` detects this capping when updating its internal oracle state.
    * **Surge Fee Activation & Decay:**
        * Upon detection of a new CAP event (`tickCapped = true`), the `currentSurgeFeePpm` for the pool is immediately set to a predefined constant (`INITIAL_SURGE_FEE_PPM`).
        * When a subsequent oracle update *does not* result in a capped tick (`tickCapped = false`), the CAP event is marked as ended (`isInCapEvent = false`), and the `capEventEndTime` is recorded.
        * While `isInCapEvent` is true, the full `INITIAL_SURGE_FEE_PPM` is applied (or the previously stored value if non-zero, intended to handle edge cases).
        * Once `isInCapEvent` is false and `capEventEndTime` is set, the applied surge fee decays linearly from `INITIAL_SURGE_FEE_PPM` to zero over a predefined duration (`SURGE_DECAY_PERIOD_SECONDS`).
    * **Base Fee Adjustment:**
        * The `baseFeePpm` is intended to adjust periodically (e.g., hourly) based on the recent frequency or occurrence of CAP events.
        * The intended logic (as described in "MaxTicksPerBlock Feedback Loop Analysis") is:
            * Increase `baseFeePpm` if CAP events are occurring frequently or are currently active.
            * Gradually decrease `baseFeePpm` during periods without CAP events.
        * Adjustments are bounded by a minimum fee (set in `PoolPolicyManager`) and a system-wide maximum base fee.
        * The `updateDynamicFeeIfNeeded` function encapsulates this logic, rate-limited by a timestamp check.
    * **Feedback Loop:** The system creates a negative feedback loop: High price volatility -> CAP events -> Increased surge/base fees -> Increased `maxTickChange` -> Reduced likelihood of future CAP events (for the same volatility) -> Lower fees over time if volatility subsides.
    * **Fee Application:** The `Spot.sol` hook calls `FullRangeDynamicFeeManager.getCurrentDynamicFee` before each swap to get the current total fee (base + decayed surge) and returns it to the `PoolManager` for application to the swap.
    * **Initialization:** Pools require initialization within the `FullRangeDynamicFeeManager` before dynamic fees are calculated; otherwise, a default fee from the policy is used.

**3. Protocol-Owned Liquidity (POL) System**

The POL system aims to automatically collect a portion of the trading fees generated in a pool and reinvest them back into the same pool as liquidity owned by the protocol (represented by the `FullRangeLiquidityManager`).

* **3.1. Core Components:**
    * `FeeReinvestmentManager.sol`: Manages the extraction, queuing, and processing of protocol fees.
    * `FullRangeLiquidityManager.sol`: Manages the protocol's liquidity positions, executes the actual reinvestment by interacting with the `PoolManager`, and holds the LP shares.
    * `PoolPolicyManager.sol` / `IPoolPolicy.sol`: Manages the percentage of fees designated as POL (`polSharePpm`) for each pool or globally.
    * `MathUtils.sol`: Provides utility functions for calculating fee shares and optimal reinvestment amounts based on reserves.
    * `TokenSafetyWrapper.sol`: Used for safe ERC20 approve/revoke operations during reinvestment.
    * `Spot.sol` (implicitly): Generates the fees that are partially captured.
    * `SettlementUtils.sol` / `CurrencySettlerExtension.sol`: Used to handle the settlement of token transfers resulting from liquidity modifications.

* **3.2. Intended Behavior:**
    * **Fee Extraction:** During liquidity operations where fees are settled (e.g., swaps via hooks, withdrawals), the `FeeReinvestmentManager.handleFeeExtraction` function (called via hooks or other integrated components) calculates the protocol's share of the accrued fees based on the `polSharePpm` obtained from `PoolPolicyManager`.
    * **Fee Queuing:** Instead of immediate reinvestment, the calculated protocol fee amounts (for both token0 and token1) are added to `pendingFee0` and `pendingFee1` state variables specific to that pool within `FeeReinvestmentManager`. This batches fees for gas efficiency.
    * **Processing Trigger:** Queued fees for a pool can be processed by calling `FeeReinvestmentManager.processQueuedFees`. This call is permissionless but implicitly rate-limited by a `minimumCollectionInterval` (e.g., 6 hours) check within the triggering logic (e.g., during withdrawals or via keeper calls, though the exact trigger mechanism for the interval isn't fully detailed in the provided `processQueuedFees` snippet itself, it's mentioned elsewhere). Fees are also intended to be processed during liquidity withdrawal operations via `_processRemoveLiquidityFees` calling `collectFees`.
    * **Optimal Reinvestment Calculation:**
        * When `processQueuedFees` is executed, it retrieves the `pendingFee0` and `pendingFee1`, adds any `leftoverToken0` and `leftoverToken1` from previous failed or partial reinvestments, resulting in `total0` and `total1`.
        * It fetches the current pool reserves (`reserve0`, `reserve1`).
        * `MathUtils.calculateReinvestableFees` is used to determine the maximum `optimal0` and `optimal1` amounts from `total0` and `total1` that can be reinvested while maintaining the current `reserve0`/`reserve1` ratio.
    * **Leftover Handling:** Any amounts of `total0` or `total1` that exceed the `optimal0` and `optimal1` (due to ratio constraints) are calculated as `newLeftover0` and `newLeftover1` and stored back in the `PoolFeeState` to be included in the next processing cycle.
    * **Reinvestment Execution:**
        * `FeeReinvestmentManager` approves the `FullRangeLiquidityManager` for `optimal0` and `optimal1`.
        * It calls `FullRangeLiquidityManager.reinvestFees` with the pool ID and optimal amounts.
        * `FullRangeLiquidityManager` calculates the corresponding number of LP shares (`shares`) based on the provided amounts and current pool reserves/total shares. It aims to mint shares proportional to the lesser of the ratios (amount0/reserve0 vs amount1/reserve1) to maintain the pool ratio.
        * `FullRangeLiquidityManager` uses the Uniswap V4 `unlock` mechanism, passing callback data. The `unlockCallback` function decodes this data, constructs `ModifyLiquidityParams` (for the full range, using `minUsableTick` and `maxUsableTick`), and calls `manager.modifyLiquidity` on the V4 PoolManager. The `liquidityDelta` is negative because the *manager* is receiving LP shares/minting liquidity from the perspective of the pool.
        * Token transfers (from `FeeReinvestmentManager`'s holdings of collected fees to the pool) and LP share minting (to `FullRangeLiquidityManager`) are handled by the `PoolManager` and settlement contracts.
    * **Safety Mechanisms:**
        * Reentrancy guards are present on `processQueuedFees`.
        * Pending fees are reset *before* processing attempts to prevent double-spending in reentrancy scenarios.
        * Approvals are revoked if the `liquidityManager.reinvestFees` call fails.
        * Global and per-pool pausing mechanisms (`setReinvestmentPaused`, `setPoolReinvestmentPaused`) controlled by governance are intended to halt reinvestment activity.
        * Minimum processing interval logic exists (though enforcement point details vary).

**4. Shared Components & Interactions**

* Both systems operate on pools identified by `PoolId` derived from `PoolKey`.
* Both systems rely on `PoolPolicyManager` for configuration parameters (fees, POL share, scaling factors).
* Both systems interact with the core `PoolManager` (dynamic fees via `beforeSwap` hook return value, POL via `modifyLiquidity` during reinvestment).
* `MathUtils` provides calculation support for both.
* `BalanceDelta` is used for tracking fee amounts.
* `Spot.sol` hook is involved in both fee generation (implicit for POL) and dynamic fee application.

**5. Key Assumptions & Invariants**

* **V4 Integration:** The system assumes correct integration with the Uniswap V4 `PoolManager`, hook system, and settlement layer.
* **Oracle Reliability:** The dynamic fee system relies on the `TruncGeoOracleMulti` providing reasonably accurate and timely TWAPs. The capping mechanism mitigates sudden spikes *between* observations but still relies on the underlying oracle data.
* **Policy Configuration:** Assumes `PoolPolicyManager` is correctly configured with valid parameters (non-zero tick scaling factor, sensible fee limits, POL shares).
* **Token Availability:** POL reinvestment assumes the `FeeReinvestmentManager` contract actually holds sufficient balances of the collected fee tokens when `processQueuedFees` is called.
* **Ratio Maintenance:** POL reinvestment aims to maintain the pool's reserve ratio but uses the *current* ratio at the time of calculation. Large swaps between calculation and execution could alter the optimal ratio. The leftover mechanism mitigates token waste.
* **Full Range:** The POL system, specifically `FullRangeLiquidityManager`, operates by adding liquidity across the entire possible tick range (`minUsableTick` to `maxUsableTick`).

---
