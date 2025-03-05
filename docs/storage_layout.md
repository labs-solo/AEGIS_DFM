# Detailed Storage Layout (Updated)

This document provides a **comprehensive overview** of the storage layout for the **refactored** Solidity contracts.  
Our architecture has evolved into:

- **`ExtendedBaseHook.sol`** (unchanged)
- **`FullRange.sol`** (formerly `BaseCustomAccounting.sol`)
- **`Pods.sol`** (formerly `BaseCustomCurve.sol`)

Other file names and contract names remain the same, and the internal code referencing these contracts has been updated accordingly. The logic now also covers the additions for **POL maintenance**, **reentrancy protection** via **solmate**, **tiered swap logic** in `Pods.sol`, and **on-curve vs. off-curve** functionalities.

---

## Storage Layout

Below is the list of **persistent storage variables** declared directly in each contract.  
Struct definitions, custom errors, modifiers, and constants without storage footprint (e.g., `constant`) are **not** listed unless they reserve storage.

### 1. `ExtendedBaseHook.sol`

**Contract**: `ExtendedBaseHook`

- **`IPoolManager public immutable poolManager`**  
  &nbsp;&nbsp;• Holds the address of the `PoolManager` contract.  
  &nbsp;&nbsp;• This is set once in the constructor and cannot be changed thereafter.  

No other state variables are declared in `ExtendedBaseHook`.

---

### 2. `FullRange.sol`

**Contract**: `FullRange` (formerly `BaseCustomAccounting.sol`)

- **`mapping(PoolId => PoolInfo) public poolInfo`**  
  &nbsp;&nbsp;• Maps each pool’s `PoolId` to a `PoolInfo` struct containing:  
  &nbsp;&nbsp;&nbsp;&nbsp;• `bool isInitialized`  
  &nbsp;&nbsp;&nbsp;&nbsp;• `uint128 totalLiquidity`  
  &nbsp;&nbsp;• Additional fields can be added as needed.

No other state variables are declared in `FullRange`.

**Inherited from `ExtendedBaseHook`**:  

- `IPoolManager public immutable poolManager` (no override).

**Inherited from `ReentrancyGuard` (Solmate)**:  

- Internal reentrancy variables (for the nonReentrant modifier) do not appear as named storage fields in the same way as typical Solidity variables, but they do consume storage slots to track reentrancy state.  

---

### 3. `Pods.sol`

**Contract**: `Pods` (formerly `BaseCustomCurve.sol`)

- **`address public immutable token0`**  
  &nbsp;&nbsp;• The deposit token for PodA.  
  &nbsp;&nbsp;• Set in the constructor.

- **`address public immutable token1`**  
  &nbsp;&nbsp;• The deposit token for PodB.  
  &nbsp;&nbsp;• Set in the constructor.

- **`PodInfo public podA`**  
  &nbsp;&nbsp;• Tracks the off-curve liquidity share data for PodA.  
  &nbsp;&nbsp;• Contains `uint256 totalShares` plus potential future fields.

- **`PodInfo public podB`**  
  &nbsp;&nbsp;• Tracks the off-curve liquidity share data for PodB.  
  &nbsp;&nbsp;• Contains `uint256 totalShares` plus potential future fields.

- **`mapping(address => uint256) public userPodAShares`**  
  &nbsp;&nbsp;• Tracks user-specific share balances for PodA.

- **`mapping(address => uint256) public userPodBShares`**  
  &nbsp;&nbsp;• Tracks user-specific share balances for PodB.

No other state variables are declared in `Pods`.

**Inherited from `FullRange`:**  

- `mapping(PoolId => PoolInfo) public poolInfo`  
- The reentrancy guard from `ReentrancyGuard`.

---

### 4. `PoolManager.sol`

**Contract**: `PoolManager`

- **`int24 private constant MAX_TICK_SPACING`**  
  &nbsp;&nbsp;• A constant loaded from `TickMath.MAX_TICK_SPACING`.  
  &nbsp;&nbsp;• Consumes no runtime storage (since `constant` values do not occupy storage).

- **`int24 private constant MIN_TICK_SPACING`**  
  &nbsp;&nbsp;• A constant loaded from `TickMath.MIN_TICK_SPACING`.  
  &nbsp;&nbsp;• Consumes no runtime storage (since `constant` values do not occupy storage).

- **`mapping(PoolId => Pool.State) internal _pools`**  
  &nbsp;&nbsp;• Primary storage mapping that keeps track of pool states (`Pool.State`) by their unique `PoolId`.  

Note that `PoolManager` also inherits from several other contracts (e.g. `ProtocolFees`, `NoDelegateCall`, `ERC6909Claims`, `Extsload`, `Exttload`), which may declare additional storage. For `PoolManager`, `_pools` is the main explicitly declared mutable storage.

---

## Mermaid Diagram

Below is a **Mermaid diagram** that illustrates the relevant storage variables and inheritance relationships, including the major changes from **on-curve** (`FullRange`) to **off-curve** (`Pods`) expansions, as well as the `ExtendedBaseHook` base:

```mermaid
flowchart LR
    subgraph ExtendedBaseHook
        EBH["poolManager (immutable)"]
    end

    subgraph ReentrancyGuard [ReentrancyGuard (solmate)]
        RGstate("(internal state slots for nonReentrant)")
    end

    EBH --> FR[FullRange]
    RGstate --> FR

    FR --> PD[Pods]

    subgraph FullRange
        FRinfo["poolInfo (mapping(PoolId => PoolInfo))\n\nPoolInfo:\n - bool isInitialized\n - uint128 totalLiquidity"]
    end

    subgraph Pods
        PD0["token0 (immutable)\ntoken1 (immutable)"]
        PD1["podA (PodInfo)\npodB (PodInfo)\nPodInfo:\n - uint256 totalShares"]
        PD2["userPodAShares (mapping)\nuserPodBShares (mapping)"]
    end

    subgraph PoolManager
        PM1["MAX_TICK_SPACING (constant)\nMIN_TICK_SPACING (constant)\n\n_pools (mapping<PoolId => Pool.State>)"]
    end
```
