# Creating Pools with FullRange

This guide explains how to create liquidity pools using the FullRange hook system with Uniswap V4.

## Overview

FullRange pools are created by specifying the FullRange contract as a hook when initializing a Uniswap V4 pool. This allows the hook to intercept pool operations and implement dynamic fee adjustments and other advanced features.

## Prerequisites

- The address of the deployed FullRange contract 
- Access to the Uniswap V4 interface or a way to call the PoolManager.initialize() function
- Authorization to create pools (controlled by the poolCreationPolicy)

## Pool Creation Steps

### Option 1: Using Uniswap V4 Interface

1. Go to the Uniswap V4 pool creation page
2. Enter your token pair (token0 and token1)
3. Set fee to `0x800000` (dynamic fee)
4. Select a supported tick spacing (1, 10, 60, 200, or 2000)
5. Enter hook address: `0x...` (address of FullRange contract)
6. Set initial price and submit the transaction

### Option 2: Using Uniswap SDK

```javascript
import { PoolManager } from '@uniswap/v4-core'

// Create pool key with FullRange hook address
const poolKey = {
  currency0: Currency.from(token0Address),
  currency1: Currency.from(token1Address),
  fee: 0x800000, // Dynamic fee
  tickSpacing: 60, // Choose supported spacing
  hooks: FULL_RANGE_ADDRESS // FullRange contract address
}

// Initialize pool
await poolManager.initialize(poolKey, initialSqrtPriceX96)
```

### Option 3: Using Web3/ethers.js

```javascript
// Get contract instances
const poolManager = new ethers.Contract(POOL_MANAGER_ADDRESS, POOL_MANAGER_ABI, signer);

// Create pool key
const poolKey = {
  currency0: { token: token0Address },
  currency1: { token: token1Address },
  fee: "0x800000", // Dynamic fee
  tickSpacing: 60,
  hooks: FULL_RANGE_ADDRESS
};

// Initialize pool
const tx = await poolManager.initialize(poolKey, initialSqrtPriceX96);
await tx.wait();
```

## Parameter Requirements

- **Hook Address**: Must be the exact FullRange contract address
- **Fee**: Must be `0x800000` to indicate dynamic fee
- **Tick Spacing**: Must be one of the supported values (1, 10, 60, 200, 2000)
- **Authorization**: The transaction sender must be authorized by the pool creation policy

## Validation

You can validate your parameters before attempting to create a pool:

```javascript
// Check if parameters are valid
const [isValid, errorMessage] = await fullRangeContract.validatePoolParameters(
  sender,
  poolKey
);

if (!isValid) {
  console.error(`Cannot create pool: ${errorMessage}`);
}
```

## After Pool Creation

Once a pool is created, you can:

1. Get the Pool ID using `PoolIdLibrary.toId(key)`
2. Deposit liquidity using the `deposit()` function on the FullRange contract
3. Check pool state using available view functions

## Troubleshooting

If pool creation fails, it could be due to:

1. **Invalid hook address**: The hook address must be the exact FullRange contract address
2. **Incorrect fee value**: Must be `0x800000`
3. **Unsupported tick spacing**: Must use one of the supported tick spacing values
4. **Authorization failure**: The sender is not authorized by the pool creation policy
5. **Pool already exists**: A pool with the same tokens, fee, and tick spacing already exists

## Technical Details

When a pool is created with the FullRange hook, the following happens:

1. **Hook validation**: The hook address is validated against the contract
2. **Parameter validation**: Fee, tick spacing, and authorization are checked
3. **Pool registration**: The pool is registered with FullRangePoolManager
4. **Data initialization**: Oracle data and fee data are initialized
5. **Events**: Various events are emitted to track the pool creation 