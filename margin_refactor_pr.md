
# PR: Margin System Refactor & Multi-Pool Architecture

This Pull Request introduces a significant refactor of the Margin system, moving towards a more robust, modular, and multi-pool compatible architecture. The core change involves separating the V4 hook interaction logic (`Margin.sol`) from the core state management and business logic (`MarginManager.sol`). This separation enhances clarity, testability, and future extensibility.

Additionally, the testing infrastructure has been overhauled with `MarginTestBase.sol` providing a shared setup for multi-pool testing scenarios, significantly improving test efficiency and coverage.

## Summary of Key Changes & Decisions

*   **Separation of Concerns:**
    *   `Margin.sol` now acts primarily as the Uniswap V4 hook facade, handling hook callbacks and delegating core logic.
    *   `MarginManager.sol` is introduced as the central state and logic contract, managing vaults, interest accrual, solvency checks (placeholder), and governance parameters for all margin pools associated with its paired `Margin.sol` hook.
    *   This separation makes the system easier to understand, maintain, and upgrade.
*   **Multi-Pool Architecture:**
    *   A single `MarginManager` and `FullRangeLiquidityManager` instance now manage state and operations for *multiple* Uniswap V4 pools associated with the deployed `Margin.sol` hook. Pool-specific data is keyed by `PoolId`.
    *   This is a fundamental shift from a one-hook-per-pool model, enabling greater capital efficiency and simplified management.
*   **Refactored Testing Framework:**
    *   `MarginTestBase.sol` provides a reusable base contract that deploys shared infrastructure (PoolManager, Margin, MM, LM, Oracle, Rate Model) once.
    *   Individual test contracts inherit from `MarginTestBase` and initialize specific pools as needed, drastically reducing setup time and complexity for multi-pool tests.
*   **Interface Driven:**
    *   New interfaces (`IMarginManager`, `IMarginData`) define the interactions between `Margin` and `MarginManager`, promoting loose coupling.
    *   Existing interfaces (`IFullRangeLiquidityManager`, `ISpot`, etc.) have been updated to reflect the multi-pool context and new patterns.
*   **Deployment Script Update:**
    *   `DeployLocalUniswapV4.s.sol` is updated to deploy the new `MarginManager` alongside `Margin` (previously `Spot`) using the CREATE2 prediction pattern for linking them during deployment. It now also deploys test tokens and initializes a default pool.
*   **Gas Optimizations:**
    *   `MarginManager.executeBatch` implements memory caching of state reads (vault, pool reserves, interest parameters) to reduce SLOAD operations within a batch, optimizing gas usage for complex multi-action transactions.

## Conceptual Architecture

```
+---------------------+       +---------------------+       +------------------------+
|      User / Bot     | ----> |     Margin.sol      | ----> |     MarginManager.sol  |
| (executeBatch call) |       | (V4 Hook Facade)    |       | (Core Logic & State)   |
+---------------------+       +---------------------+       +------------------------+
                                     |         ^                     |         ^
                                     |         |                     |         | interacts with
                                     v         | interacts with      v         |
+---------------------+       +---------------------+       +------------------------+
|  PoolManager.sol    | <---->|       (Pools)       | <---->| FullRangeLiquidityManager |
| (Uniswap V4 Core)   |       +---------------------+       | (Multi-Pool LM)        |
+---------------------+                                     +------------------------+
                                     |                                |
                                     | interacts with                 | interacts with
                                     v                                v
                          +---------------------+          +--------------------------+
                          | TruncGeoOracleMulti |          | LinearInterestRateModel  |
                          | (Price Oracle)      |          | (Interest Rate Logic)    |
                          +---------------------+          +--------------------------+
                                     ^
                                     | interacts with
                                     v
                          +---------------------+
                          | PoolPolicyManager   |
                          | (Governance/Config) |
                          +---------------------+

```

*   **User Interaction:** Users interact primarily with `Margin.sol`'s `executeBatch` function.
*   **Hook Logic:** `Margin.sol` receives V4 hook callbacks (e.g., `beforeSwap`, `afterAddLiquidity`) from `PoolManager.sol`.
*   **Delegation:** `Margin.sol` delegates core margin logic (deposits, borrows, solvency checks) to `MarginManager.sol`.
*   **State Management:** `MarginManager.sol` holds the canonical state for user vaults, debt, and interest across all associated pools.
*   **Liquidity Management:** Both `Margin.sol` (indirectly via MM) and `MarginManager.sol` interact with the *single* `FullRangeLiquidityManager` instance to manage LP positions in the underlying V4 pools.
*   **Supporting Contracts:** `PoolPolicyManager`, `TruncGeoOracleMulti`, and `LinearInterestRateModel` provide configuration, price data, and interest rate logic, respectively, interacting primarily with `MarginManager` or related components.

## Detailed Changes by File

**Core Contracts:**

*   **`src/Margin.sol`:**
    *   Inherits from `Spot.sol` now, retaining base hook functionality and policy management.
    *   **Removed** significant state related to vaults, interest, and debt.
    *   Added immutable `marginManager` address, linked at construction.
    *   `executeBatch` function added as the primary user entry point, replacing individual functions like `depositCollateral`, `borrow`, `repay`. It handles token transfers *in* and delegates the core logic to `MarginManager.executeBatch`.
    *   Removed internal logic for deposit/borrow/repay; these are now handled within `MarginManager`.
    *   Hook implementations (`_afterInitialize`, `beforeModifyLiquidity`, `beforeSwap`, etc.) now primarily focus on calling `MarginManager` for state updates (like interest accrual) or delegating relevant checks.
    *   Governance functions (`setSolvencyThresholdLiquidation`, `setLiquidationFee`, `setInterestRateModel`) now delegate calls to `MarginManager`.
    *   `_safeTransferETH` added to handle ETH payouts, with fallback to `pendingETHPayments`. `claimETH` allows users to retrieve failed payments.
    *   `getHookPermissions` updated to reflect the hooks used by Margin (adds `beforeModifyLiquidity`).
    *   Interface functions like `getVault`, `getInterestRatePerSecond` now delegate to `MarginManager`.
*   **`src/MarginManager.sol`:** (New Contract)
    *   Holds all core margin state: `_vaults`, `rentedLiquidity`, `interestMultiplier`, `lastInterestAccrualTime`, `accumulatedFees`.
    *   Stores immutable addresses for `marginContract`, `poolManager`, `liquidityManager`, `governance`.
    *   Holds configurable parameters: `interestRateModel`, `solvencyThresholdLiquidation`, `liquidationFee`.
    *   `executeBatch`: Orchestrates the execution of margin actions, performs interest accrual *before* actions, processes each action internally, performs a final solvency check *after* all actions, and commits the updated vault state. Implements gas optimization via memory caching.
    *   `_processSingleAction`: Internal router function calling specific handlers (`_handleDepositCollateral`, `_handleWithdrawCollateral`, `_handleBorrow`, `_handleRepay`).
    *   Action Handlers (`_handle...`): Contain the specific logic for updating vault state, interacting with `FullRangeLiquidityManager` (for borrow/repay), and handling token transfers *out* via `Margin.sol` or direct ERC20 transfers.
    *   Interest Accrual (`_updateInterestForPool`, `_accrueInterestForUser`): Calculates interest based on utilization (via `IInterestRateModel`) and updates the global `interestMultiplier` and `accumulatedFees`.
    *   Solvency Check (`_isSolvent`, `_calculateCollateralValueInShares`): Provides logic to check vault solvency based on collateral value vs. debt value (uses current interest multiplier).
    *   Governance Setters: Allow the `governance` address to update configurable parameters.
*   **`src/Spot.sol`:**
    *   Minor updates to use `bytes32` for `poolId` internally in mappings (`poolData`, `poolKeys`) for consistency and potential gas savings, while external functions still accept `PoolId`.
    *   `_afterInitialize` now stores the `PoolKey` in `poolKeys` mapping.
    *   Removed direct LM registration from `_afterInitialize` (assumption: LM handles pools implicitly).
    *   Updated imports and variable types (`IFullRangeLiquidityManager`).
*   **`src/FullRangeLiquidityManager.sol`:**
    *   Major refactor to support multi-pool operations. Mappings (`_poolKeys`, `poolTotalShares`, `lockedLiquidity`, etc.) are now keyed by `PoolId`.
    *   Removed `userPositions` mapping; user share balances are now solely tracked by the `FullRangePositions` ERC1155 contract. `getAccountPosition` reads directly from the token contract.
    *   Renamed `fullRangeAddress` to `authorizedHookAddress` for clarity, restricted `storePoolKey` to this address.
    *   `registerPool` removed, replaced by `storePoolKey`.
    *   `deposit` and `withdraw` logic updated significantly:
        *   Use `PoolId` parameter to operate on the correct pool's state.
        *   Calculate shares based on pool reserves and desired amounts (`_calculateDepositShares`).
        *   Use `PoolTokenIdUtils.toTokenId(poolId)` to mint/burn the correct ERC1155 token ID.
        *   Handle ETH transfers correctly based on pool key.
        *   Interact with `PoolManager` via `unlock` using `CallbackData`.
    *   `borrowImpl` added: Internal function called by `MarginManager` to remove liquidity *without* burning LP tokens, representing a borrow.
    *   `reinvestProtocolFees` updated for multi-pool context, uses `unlock`.
    *   `handlePoolDelta`: Now correctly handles token settlement *after* `unlockCallback` returns, pulling/pushing tokens from/to `PoolManager`.
    *   Removed internal caching (`PositionCache`) and direct `extsload` reads for reserves; relies on `getPositionData` and `getPoolReserves`.
    *   `getPoolReserves`: Recalculated based on `getPositionData` and `SqrtPriceMath` for accuracy.
*   **`src/FullRangeDynamicFeeManager.sol`:**
    *   Updated to use `PoolId` in mappings and function arguments.
    *   `getOracleData` now calls `ISpot(fullRangeAddress).getOracleData(poolId)`.
*   **`src/LinearInterestRateModel.sol`:** No significant changes apparent in diff.
*   **`src/PoolPolicyManager.sol`:** Updated imports.
*   **`src/FeeReinvestmentManager.sol`:** Updated imports and error handling (`Errors.PoolNotInitialized`).

**Interfaces:**

*   **`src/interfaces/IMargin.sol`:**
    *   Updated `Vault` struct definition removed (now uses `IMarginData.Vault`).
    *   Functions updated to use `IMarginData.Vault`.
    *   Added `PRECISION` constant view function.
    *   Added `getInterestRateModel` view function.
    *   Removed individual action events (Deposit, Withdraw, Borrow, Repay); higher-level events might be emitted by `MarginManager` or `Margin`.
*   **`src/interfaces/IMarginData.sol`:** (New Interface)
    *   Defines shared enums (`ActionType`) and structs (`SwapRequest`, `BatchAction`, `Vault`).
    *   Includes `MarginDataLibrary` with constants like `FLAG_USE_VAULT_BALANCE_FOR_REPAY`.
*   **`src/interfaces/IMarginManager.sol`:** (New Interface)
    *   Defines the external interface for `MarginManager.sol`.
    *   Includes view functions for accessing state (`vaults`, `rentedLiquidity`, etc.) and parameters.
    *   Defines the core `executeBatch`, `accruePoolInterest`, `initializePoolInterest` functions.
    *   Defines governance functions.
    *   Defines events emitted by `MarginManager`.
*   **`src/interfaces/IFullRangeLiquidityManager.sol`:**
    *   Functions updated to accept `PoolId`.
    *   Removed `addUserShares`, `removeUserShares`, `processWithdrawShares`.
    *   Added `storePoolKey` function.
    *   `getAccountPosition` updated.
    *   `reinvestProtocolFees` signature updated.
*   **`src/interfaces/IFullRangePositions.sol`:** (New Interface)
    *   Defines a minimal ERC1155 interface with `mint` and `burn` for the position token contract.
*   **`src/interfaces/ISpot.sol`:** Minor changes to comments/docs, `DepositParams`/`WithdrawParams` use `PoolId`.
*   **`src/interfaces/ISpotHooks.sol`:** Updated imports.

**Libraries & Utils:**

*   **`src/libraries/MathUtils.sol`:** `calculateProportionalShares` logic updated (now returns 0 if a reserve is 0). `computeWithdrawAmounts` simplified.
*   **`src/libraries/SolvencyUtils.sol`:** Updated to use `IMarginData.Vault`.
*   **`src/errors/Errors.sol`:** Added new errors (`CallerNotMarginContract`, `CallerNotPoolManager`, `InvalidAsset`, `InvalidParameter`, `MaxPoolUtilizationExceeded`, etc.). Updated existing pool errors to use `bytes32 poolId`.
*   **`src/oracle/TruncGeoOracleMulti.sol`:** Added `isOracleEnabled` and `getLatestObservation` helper functions.

**Tests:**

*   **`test/MarginTestBase.t.sol`:** (New Base Contract)
    *   Sets up shared infrastructure (PoolManager, Margin+MM via CREATE2, LM, Oracle, RateModel, PolicyManager, Tokens).
    *   Provides helper functions (`createPoolAndRegister`, `addLiquidity`, `addFullRangeLiquidity`, `swap`, `swapExactInput`, `queryCurrentTickAndLiquidity`, batch action creators).
    *   Crucially uses `HookMiner.find` and CREATE2 to deploy `MarginManager` *first* with the predicted `Margin` hook address, then deploys `Margin` using the mined salt, ensuring they are correctly linked.
*   **`test/MarginTest.t.sol`:**
    *   Inherits from `MarginTestBase`.
    *   `setUp` now calls base `setUp` and initializes specific test pools (Pool A, Pool B) using `createPoolAndRegister`.
    *   Tests refactored to use `executeBatch` with appropriate actions instead of direct calls to `depositCollateral`, `borrow`, etc.
    *   Tests adapted for the multi-pool context, often targeting `poolIdA`.
    *   Added isolation tests (`test_ExecuteBatch_Deposit_Isolation`, `test_MM_Interest_Isolation`, etc.) to verify that actions on one pool do not affect the state of another pool.
*   **`test/LPShareCalculation.t.sol`:**
    *   Refactored to inherit from `MarginTestBase`.
    *   Removed redundant contract deployments (PoolManager, LM, Tokens, etc.).
    *   Uses helper functions from the base for pool creation and liquidity addition.
    *   Tests now target `poolIdA` or the `emptyPoolId` created in the refactored `setUp`.
*   **`test/LinearInterestRateModel.t.sol`:**
    *   Refactored to inherit from `MarginTestBase`.
    *   Uses a locally deployed `LinearInterestRateModel` for specific parameter tests but also includes tests using the `interestRateModel` instance deployed in the base `setUp`.
*   **`test/GasBenchmarkTest.t.sol`:**
    *   Completely refactored to inherit from `MarginTestBase`.
    *   Removed comparison pool (`regularPoolKey`).
    *   Focuses on benchmarking `executeBatch` on `poolIdA` with various action combinations (single deposit, multiple deposits, borrow, repay, complex sequences).
    *   Uses `forge-gas-snapshot` for gas measurement.
*   **`test/SimpleV4Test.t.sol`:**
    *   Refactored to inherit from `MarginTestBase`.
    *   Removed redundant contract deployments.
    *   Uses `poolIdA` and `poolKeyA` created in the refactored `setUp`.
    *   Tests adapted to use helpers and interact with the base setup contracts. Includes basic swap and deposit tests, plus isolation tests for emergency state and oracle updates.
*   **`test/SwapGasPlusOracleBenchmark.sol`:**
    *   Refactored to inherit from `MarginTestBase`.
    *   Uses pools and contracts from the base setup.
    *   Focuses on benchmarking swap execution, potentially comparing hooked vs non-hooked pools if `regularPoolKey` is retained/recreated. (Note: Diff shows `poolSwapTest` and related logic removed, might need adjustment if comparison is still desired).
*   **`test/LocalUniswapV4TestBase.t.sol`:** Minor updates to use new setter names (`setAuthorizedHookAddress`, `setDynamicFeeManager`).

**Deployment & Config:**

*   **`script/DeployLocalUniswapV4.s.sol`:**
    *   Updated to deploy `MarginManager` using the CREATE2 pattern before deploying `Margin` (previously `Spot`).
    *   Handles prediction of the hook address and passes it to `MarginManager` constructor.
    *   Deploys test tokens (`MockERC20`) within the script.
    *   Initializes a default pool (using deployed test tokens and the deployed hook) via `poolManager.initialize`.
    *   Links contracts correctly (`setAuthorizedHookAddress`, `setDynamicFeeManager`).
*   **`foundry.toml`:** Updated remapping for `v4-core`. Added `remappings.txt`.
*   **`remappings.txt`:** Added.

**Removed Files:**

*   `lib/openzeppelin-contracts` symlink removed (likely consolidated dependency management).

