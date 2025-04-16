# Test Specification: `DeploymentAndConfig.t.sol`

## 1. Filename

`test/integration/DeploymentAndConfig.t.sol`

## 2. Inheritance

The test contract `DeploymentAndConfigTest` should inherit from `test/integration/ForkSetup.t.sol`.

## 3. Purpose

This test suite verifies that the Unichain V4 contracts are deployed correctly via the chosen deployment script (`DeployUnichainV4.s.sol` or `DirectDeploy.s.sol`) on a forked environment. It ensures that all core contracts are deployed to valid addresses and that their internal references (linkages) to each other are correctly configured as per the deployment logic. It also verifies critical initial settings in the `PoolManager` and `PoolPolicyManager`. This suite corresponds to Section A of the `Integration_Testing_Plan.md`.

## 4. Dependencies & Setup (Provided by `ForkSetup.t.sol`)

* Foundry test environment (`forge test --fork-url $UNICHAIN_RPC_URL`).
* Execution of the deployment script, populating contract instance variables within `ForkSetup.t.sol` (e.g., `poolManager`, `policyManager`, `liquidityManager`, `dynamicFeeManager`, `spotHook`, `oracle`, `weth`, `usdc`, `poolId`).
* Any necessary initial funding or approvals performed in the `setUp()` function of `ForkSetup.t.sol`.

## 5. Expected Values Source

Expected configuration values should be handled using one of these approaches:
* Define constants in `ForkSetup.t.sol` that match the values used in deployment scripts
* Read values directly from deployment artifacts if available
* Extract values from the deployment script source code as constants
* For certain values, consider adding a helper in `ForkSetup.t.sol` that retrieves the expected values from contract storage (useful for values that might be computed during deployment)

## 6. Test Cases

### A. Deployment & Configuration Verification (Integration Plan Section A)

#### Test 1: `test_VerifyContractAddresses`

* **Purpose:** Ensure all core contracts were deployed successfully and have non-zero addresses.
* **Verification:**
  * `assertNotEq(address(poolManager), address(0))`
  * `assertNotEq(address(policyManager), address(0))`
  * `assertNotEq(address(liquidityManager), address(0))`
  * `assertNotEq(address(dynamicFeeManager), address(0))`
  * `assertNotEq(address(spotHook), address(0))`
  * `assertNotEq(address(oracle), address(0))`
  * `assertNotEq(address(weth), address(0))` // Assuming WETH address is loaded/known
  * `assertNotEq(address(usdc), address(0))` // Assuming USDC address is loaded/known

#### Test 2: `test_VerifyPoolManagerLinkages`

* **Purpose:** Confirm contracts that need to reference the `PoolManager` have the correct address set.
* **Verification:**
  * `assertEq(liquidityManager.poolManager(), address(poolManager))`
  * `assertEq(dynamicFeeManager.poolManager(), address(poolManager))`
  * `assertEq(spotHook.poolManager(), address(poolManager))`
  * `assertEq(oracle.poolManager(), address(poolManager))` // Assuming Oracle has `poolManager()` getter per plan

#### Test 3: `test_VerifyPolicyManagerLinkages`

* **Purpose:** Confirm contracts that need to reference the `PoolPolicyManager` have the correct address set.
* **Verification:**
  * `assertEq(dynamicFeeManager.policyManager(), address(policyManager))`
  * `assertEq(spotHook.policyManager(), address(policyManager))`

#### Test 4: `test_VerifyLiquidityManagerLinkages`

* **Purpose:** Confirm linkage between `SpotHook` and `LiquidityManager`, including hook authorization.
* **Verification:**
  * `assertEq(spotHook.liquidityManager(), address(liquidityManager))`
  * `assertTrue(liquidityManager.isHookAuthorized(address(spotHook)))`

#### Test 5: `test_VerifyDynamicFeeManagerLinkages`

* **Purpose:** Confirm linkage between `SpotHook`, `DynamicFeeManager`, and `Oracle`.
* **Verification:**
  * `assertEq(spotHook.dynamicFeeManager(), address(dynamicFeeManager))`
  * `assertEq(dynamicFeeManager.spotHook(), address(spotHook))`
  * `assertEq(dynamicFeeManager.oracle(), address(oracle))`

#### Test 6: `test_VerifyOracleLinkage`

* **Purpose:** Specifically confirm `DynamicFeeManager` references the correct `Oracle`. (Redundant with A5 but explicitly listed in the plan).
* **Verification:**
  * `assertEq(dynamicFeeManager.oracle(), address(oracle))`

#### Test 7: `test_VerifyInitialPoolSetup`

* **Purpose:** Confirm the primary test pool (WETH/USDC) exists, is initialized, and uses the deployed `SpotHook`.
* **Prerequisites:** `poolId` for WETH/USDC pool correctly generated/stored in `ForkSetup.t.sol`.
* **Token Ordering Note:** Since token ordering isn't guaranteed (depends on token addresses), the test should handle both possibilities:
  * Either verify token ordering using the `PoolIdLibrary` or similar utility
  * Or check that the pool contains both WETH and USDC in some order
* **Verification:**
  * `(address hookAddress, , bool initialized) = poolManager.getPool(poolId)`
  * `assertEq(hookAddress, address(spotHook), "Pool hook mismatch")`
  * `assertTrue(initialized, "Pool not initialized")`
  * Check token ordering: `assertTrue(poolId.currency0 == weth && poolId.currency1 == usdc || poolId.currency0 == usdc && poolId.currency1 == weth)`

#### Test 8: `test_VerifyInitialPolicySettings`

* **Purpose:** Verify all key configurable parameters in the `PoolPolicyManager` match the expected values from the deployment script.
* **Prerequisites:** Expected values should be defined as constants or variables, potentially within `ForkSetup.t.sol` or directly in the test, matching the deployment script's configuration.
* **Comprehensive Check:** Ensure to verify ALL critical parameters configured during deployment, including but not limited to:
* **Verification (Example Settings - adjust based on actual `PolicyManager` interface):**
  * `assertEq(policyManager.getPolSharePpm(poolId), EXPECTED_POL_SHARE_PPM, "POL Share mismatch")`
  * `assertEq(policyManager.getMinimumTradingFee(poolId), EXPECTED_MIN_FEE_PPM, "Min Fee mismatch")`
  * `assertEq(policyManager.getTickScalingFactor(poolId), EXPECTED_TICK_SCALING, "Tick Scaling mismatch")`
  * `assertEq(policyManager.getMaxBaseFeePpm(poolId), EXPECTED_MAX_BASE_FEE_PPM, "Max Base Fee mismatch")`
  * `assertEq(policyManager.getDefaultDynamicFee(poolId), EXPECTED_DEFAULT_DYNAMIC_FEE, "Default Dynamic Fee mismatch")`
  * `assertEq(policyManager.getMaxTickChange(poolId), EXPECTED_MAX_TICK_CHANGE, "Max Tick Change mismatch")`
  * `assertEq(policyManager.getBaseFeeLowerBound(poolId), EXPECTED_BASE_FEE_LOWER_BOUND, "Base Fee Lower Bound mismatch")`
  * `assertEq(policyManager.getBaseFeePpmIncreaseOnCap(poolId), EXPECTED_BASE_FEE_INCREASE, "Base Fee Increase mismatch")`
  * `assertEq(policyManager.getBaseFeePpmDecrease(poolId), EXPECTED_BASE_FEE_DECREASE, "Base Fee Decrease mismatch")`
  * `assertEq(policyManager.getMinReinvestmentInterval(poolId), EXPECTED_MIN_REINVEST_INTERVAL, "Min Reinvestment Interval mismatch")`
  * // Add any other policy settings defined in the deployment script
  
## 7. Additional Notes

* Make sure to comment failed assertions with descriptive error messages
* For complex verifications, consider using helper functions within the test contract
* Token ordering in the `poolId` should be handled appropriately based on address sorting
* If the deployment script configures any hooks or callbacks for the pool, consider adding tests to verify these configurations 