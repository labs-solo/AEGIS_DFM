# Tuesday, April 15th: Integration Testing Tasks

## Goal

Begin implementation and execution of integration tests based on the `Integration_Testing_Plan.md`. Focus on verifying deployment, core dynamic fee logic, and the CAP event lifecycle. Identify, debug, and fix any bugs encountered during testing.

---

## Prerequisites (Both Testers)

* Foundry installed and configured.
* Environment variables set (`PRIVATE_KEY`, `UNICHAIN_RPC_URL` pointing to a suitable fork source).
* Deployment scripts (`DeployUnichainV4.s.sol` or `DirectDeploy.s.sol`) successfully run on the fork, providing necessary contract addresses.
* Test wallet funded with ETH and relevant tokens (WETH, USDC) on the fork (`vm.deal`).
* Base `test/integration/ForkSetup.t.sol` contract available (contains deployment logic and common setup).

---

## Bryan: Deployment, Configuration & Base Fee Logic

1. **Create `test/integration/DeploymentAndConfig.t.sol`:**
    * Structure the file, inheriting from `ForkSetup.t.sol`.
2. **Implement & Verify Section A Tests:**
    * Write the Foundry tests for deployment and configuration verification (A1-A8 from the `Integration_Testing_Plan.md`).
    * Run tests frequently during implementation.
    * **Debug and fix any discrepancies** found between the expected configuration/linkages and the actual deployed state.
    * Ensure all Section A tests pass reliably.
3. **Create `test/integration/DynamicFeeMechanism.t.sol`:**
    * Structure the file, inheriting from `ForkSetup.t.sol`.
4. **Implement & Verify Section B Tests:**
    * Write the Foundry tests for the core dynamic fee calculations and application (B1-B6 from the plan).
    * Execute these tests against the deployed contracts.
    * **Identify, debug, and fix any bugs** within the `DynamicFeeManager` or related hook logic responsible for fee calculation and application covered by these tests.
    * Ensure all Section B tests pass reliably.
5. **Report:** Document any significant bugs fixed or persistent issues encountered.

---

## Taylor: CAP Event Lifecycle

1. **Create `test/integration/CapEventLifecycle.t.sol`:**
    * Structure the file, inheriting from `ForkSetup.t.sol`.
    * Include necessary imports and potentially helper functions (referencing the example in the plan).
2. **Implement & Verify Section C Tests:**
    * Write the Foundry tests for the CAP event lifecycle (C1-C6 from the plan).
    * Run tests, simulating conditions using `vm.warp` etc. as needed.
    * **Identify, debug, and fix any bugs** related to CAP event triggering (`TickChangeCapped`), state management (`isInCapEvent`, `capEventEndTime`), surge fee activation (`INITIAL_SURGE_FEE_PPM`), and decay logic within the `DynamicFeeManager` or associated hooks.
    * Ensure all Section C tests pass reliably.
3. **Report:** Document any significant bugs fixed or persistent issues encountered, particularly around state transitions or decay calculations.

---

## Resources

* **Overall Plan:** `docs/Integration_Testing_Plan.md`
* **Behavior Reference:** `docs/Statement_of_Intended_Behavior.md`
* **Base Test Setup:** `test/integration/ForkSetup.t.sol` (Assumed)
* **Test Files To Create:**
  * `test/integration/DeploymentAndConfig.t.sol`
  * `test/integration/DynamicFeeMechanism.t.sol`
  * `test/integration/CapEventLifecycle.t.sol`
* **Deployment Scripts:** (Located likely in `scripts/`)
  * `DeployUnichainV4.s.sol`
  * `DirectDeploy.s.sol`
* **Core Contracts (Interfaces/Implementations likely in `src/` or `v4-core/src/`)**
  * `PoolManager`
  * `PoolPolicyManager` (or similar name based on deployment)
  * `LiquidityManager`
  * `DynamicFeeManager`
  * `SpotHook` (or specific hook implementation)
  * `Oracle`
* **Foundry Documentation:** [https://book.getfoundry.sh/](https://book.getfoundry.sh/) 