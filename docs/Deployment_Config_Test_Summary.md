# Deployment & Configuration Test Summary (`DeploymentAndConfig.t.sol`)

## Goal

This document summarizes the integration tests performed by `test/integration/DeploymentAndConfig.t.sol`. The primary goal of this test suite is to verify that the core contracts of the dynamic fee hook system are deployed correctly and that their initial configuration parameters and inter-contract linkages match the expected values set during the deployment process simulated within `test/integration/ForkSetup.t.sol`.

These tests correspond to **Section A** of the `docs/Integration_Testing_Plan.md`.

---

## Tested Behaviors

The following specific aspects of the deployment and configuration were verified:

1. **Contract Existence (`test_VerifyContractAddresses`)**:
    * Checked that the addresses obtained for all core contracts (`PoolManager`, `PoolPolicyManager`, `FullRangeLiquidityManager`, `FullRangeDynamicFeeManager`, `Spot` (hook), `TruncGeoOracleMulti`, `WETH`, `USDC`) after the simulated deployment are non-zero.

2. **`PoolManager` Linkages (`test_VerifyPoolManagerLinkages`)**:
    * Confirmed that the `FullRangeLiquidityManager`, `FullRangeDynamicFeeManager`, and `Spot` hook instances hold the correct address pointer back to the `PoolManager`.
    * *(Note: Oracle linkage to PoolManager was not directly tested here, as the Oracle implementation might not expose a direct `poolManager()` getter).*

3. **`PoolPolicyManager` Linkages (`test_VerifyPolicyManagerLinkages`)**:
    * Confirmed that the `FullRangeDynamicFeeManager` and `Spot` hook instances hold the correct address pointer back to the deployed `PoolPolicyManager`.

4. **`FullRangeLiquidityManager` Linkages (`test_VerifyLiquidityManagerLinkages`)**:
    * Confirmed that the `Spot` hook instance holds the correct address pointer back to the `FullRangeLiquidityManager`.
    * Confirmed that the `FullRangeLiquidityManager` has authorized the deployed `Spot` hook address for callbacks.

5. **`FullRangeDynamicFeeManager` Linkages (`test_VerifyDynamicFeeManagerLinkages`)**:
    * Confirmed that the `Spot` hook instance holds the correct address pointer back to the `FullRangeDynamicFeeManager`.
    * Confirmed that the `FullRangeDynamicFeeManager` holds the correct address pointer back to the `Spot` hook (`fullRangeAddress()`).
    * *(Note: Linkage to the Oracle within DynamicFeeManager was not directly tested via a getter, as it's likely accessed internally).*

6. **Oracle Linkage (`test_VerifyOracleLinkage`)**:
    * This test serves as a placeholder, acknowledging that the direct `oracle()` getter might not exist on `FullRangeDynamicFeeManager`. Verification of correct Oracle *usage* happens in later, behavior-driven tests.

7. **Initial Pool Setup (`test_VerifyInitialPoolSetup`)**:
    * Confirmed that the target WETH/USDC pool (identified by `poolId` derived from `poolKey` in `ForkSetup`) exists and is initialized within the `PoolManager` by checking `StateLibrary.getSlot0`. A non-zero `sqrtPriceX96` indicates initialization.
    * Verified that the `poolKey` used corresponds to the correct WETH and USDC token addresses by unwrapping `poolKey.currency0` and `poolKey.currency1`.
    * *(Note: It implicitly verifies the hook association by confirming the pool exists for the `poolId` derived using the `poolKey` which contains the hook address. It does not directly query the PoolManager for the hook associated with the `poolId`).*

8. **Initial Policy Settings (`test_VerifyInitialPolicySettings`)**:
    * Verified that key parameters read directly from the deployed `PoolPolicyManager` match the expected constant values defined in the test file (which should mirror the values used during deployment in `ForkSetup.sol`). This included:
        * Protocol Owned Liquidity (POL) Share (`getPoolPOLShare`)
        * Minimum Trading Fee (`getMinimumTradingFee`)
        * Tick Scaling Factor (`getTickScalingFactor`)
        * Default Dynamic Fee (`getDefaultDynamicFee`)
    * *(Note: Several other policy settings mentioned in the original plan (Max Base Fee, Max Tick Change, Base Fee Bounds, Increase/Decrease factors, Min Reinvestment Interval) were **not** verified in this test because corresponding getter functions were not found on the `PoolPolicyManager` contract. Their correct configuration relies on the deployment script logic and will be tested implicitly by behavioral tests in subsequent test suites).*

---

## What Was Proven (Given Passing Tests)

* **Deployment Success:** All core contracts (`PolicyManager`, `LiquidityManager`, `DynamicFeeManager`, `Oracle`, `Spot` hook) were successfully deployed to non-zero addresses within the simulated environment.
* **Basic Linkages:** The fundamental pointers (`manager()`, `policy()`, `liquidityManager()`, `dynamicFeeManager()`, `poolManager()`, `fullRangeAddress()`) between the core contracts are correctly set as expected immediately after deployment.
* **Hook Authorization:** The `FullRangeLiquidityManager` correctly recognizes and authorizes the deployed `Spot` hook.
* **Pool Initialization:** The target WETH/USDC pool exists in the `PoolManager` and is initialized with the expected tokens and hook association (implied via `poolId`).
* **Core Policy Parameter Application:** Specific, checkable parameters within the `PoolPolicyManager` (POL Share, Min Fee, Tick Scaling, Default Dynamic Fee) were successfully set to the values provided during deployment.

---

## What Was NOT Proven (Limitations of this Test Suite)

* **Correctness of Deployment *Values*:** These tests only verify that the deployed parameters *match* the expected constants. They do *not* prove that the constants themselves represent the *desired business logic* or optimal configuration.
* **Dynamic Contract *Behavior*:** This suite focuses purely on the static state immediately after deployment. It does **not** test:
  * Actual dynamic fee calculations.
  * CAP event detection or handling.
  * Surge fee activation or decay.
  * Base fee adjustments over time.
  * POL collection, queuing, or reinvestment logic.
  * Oracle price updates or usage correctness.
* **Functionality of Linked Contracts:** While linkages are checked, the internal logic and full functionality of the linked contracts (e.g., `Oracle`, `PoolManager`'s core swap logic) are not tested here.
* **Deployment Script Logic:** The tests verify the *result* of the deployment simulation in `ForkSetup.sol`, not the correctness or robustness of the deployment script (`DeployUnichainV4.s.sol` or `DirectDeploy.s.sol`) itself.
* **Unverified Policy Parameters:** As noted in A8, several policy parameters lacked direct getters and were not explicitly verified. Their correctness is assumed based on the deployment simulation and will be tested implicitly by later behavioral tests.
* **Security Vulnerabilities:** This suite does not perform security-focused testing like reentrancy checks, access control exploits, or economic manipulation vectors.
* **Edge Cases:** Initialization edge cases (e.g., deploying without initializing, using unsupported tick spacings beyond the basic check) are not covered here.
* **CREATE2 Predictability Robustness:** While the hook address was deployed using CREATE2, this suite doesn't stress-test the predictability under different conditions or potential front-running scenarios related to CREATE2 deployment.
* **Gas Costs:** Deployment gas costs are not measured or asserted.

**In essence, this test suite provides confidence that the system components are present and connected correctly after deployment, setting the stage for subsequent integration tests that focus on verifying the intended dynamic behavior.** 