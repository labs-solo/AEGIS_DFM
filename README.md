# v4-template
### **A template for writing Uniswap v4 Hooks 🦄**

[`Use this Template`](https://github.com/uniswapfoundation/v4-template/generate)

1. The example hook [Counter.sol](src/Counter.sol) demonstrates the `beforeSwap()` and `afterSwap()` hooks
2. The test template [Counter.t.sol](test/Counter.t.sol) preconfigures the v4 pool manager, test tokens, and test liquidity.
3. The [ExtendedBaseHook.sol](src/base/ExtendedBaseHook.sol) provides a complete implementation of all hook functions with proper access control and validation.

<details>
<summary>Updating to v4-template:latest</summary>

This template is actively maintained -- you can update the v4 dependencies, scripts, and helpers: 
```bash
git remote add template https://github.com/uniswapfoundation/v4-template
git fetch template
git merge template/main <BRANCH> --allow-unrelated-histories
```

</details>

---

### Check Forge Installation
*Ensure that you have correctly installed Foundry (Forge) Stable. You can update Foundry by running:*

```
foundryup
```

> *v4-template* appears to be _incompatible_ with Foundry Nightly. See [foundry announcements](https://book.getfoundry.sh/announcements) to revert back to the stable build



## Set up

*requires [foundry](https://book.getfoundry.sh)*

```
forge install
forge test
```

### Local Development (Anvil)

Other than writing unit tests (recommended!), you can only deploy & test hooks on [anvil](https://book.getfoundry.sh/anvil/)

```bash
# start anvil, a local EVM chain
anvil

# in a new terminal
forge script script/Anvil.s.sol \
    --rpc-url http://localhost:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    --broadcast
```

See [script/](script/) for hook deployment, pool creation, liquidity provision, and swapping.

---

## Lessons Learned: ExtendedBaseHook and Uniswap v4 Integration

When working with Uniswap v4 hooks, especially when extending the `ExtendedBaseHook` base contract, the following lessons and best practices should be considered:

### 1. State Mutability

- **Always use `view` instead of `pure`** for functions that interact with state, even indirectly
- Common issues:
  - `getHookPermissions()` should be `view` not `pure` 
  - `validateHookAddress()` should be `internal view` not `internal pure`
  - These issues often appear as state mutability errors during compilation

### 2. Hook Address Validation

- **Always override `validateHookAddress()`** in derived hook contracts
- Use `HookMiner.find()` to generate proper hook addresses
- Implement with:
  ```solidity
  function validateHookAddress(ExtendedBaseHook _this) internal view override {
      Hooks.validateHookPermissions(_this, getHookPermissions());
  }
  ```
- Ensure deployed hook addresses match the permission flags

### 3. PoolManager Interaction Pattern

- **Use the unlock pattern** for all state-modifying operations:
  ```solidity
  // CORRECT way to modify liquidity:
  poolManager.unlock(abi.encode(key, params));
  
  // INCORRECT - will revert with ManagerLocked():
  poolManager.modifyLiquidity(key, params, "");
  ```
  
- **Implement `IUnlockCallback` interface** for contracts that call `unlock()`
  ```solidity
  contract MyContract is IUnlockCallback {
      function unlockCallback(bytes calldata data) external returns (bytes memory) {
          // Decode data and perform operations
          // ...
      }
  }
  ```

### 4. Balance Settlement

- **Always settle balances** after operations that modify state:
  ```solidity
  // After modifyLiquidity, handle the returned delta
  (BalanceDelta delta, ) = poolManager.modifyLiquidity(key, params, "");
  
  // Handle negative amounts (paying the pool)
  if (amount0 < 0) {
      uint256 absAmount0 = uint256(uint128(-amount0));
      CurrencySettler.settle(key.currency0, poolManager, address(this), absAmount0, false);
  }
  
  // Handle positive amounts (receiving from pool)
  if (amount0 > 0) {
      uint256 absAmount0 = uint256(uint128(amount0));
      CurrencySettler.take(key.currency0, poolManager, address(this), absAmount0, false);
  }
  ```

- **Be careful with type conversions** when converting `int128` to `uint256`:
  - Convert through `uint128` first to avoid overflow/underflow
  - Use the absolute value (negate negative values) before conversion

### 5. Token Preparation

- **Mint tokens** to your contract before interactions
- **Approve the PoolManager** to spend tokens
- Ensure sufficient token balance for all operations
  ```solidity
  // Before interacting with PoolManager
  token0.mint(address(this), 1000000);
  token1.mint(address(this), 1000000);
  token0.approve(address(poolManager), type(uint256).max);
  token1.approve(address(poolManager), type(uint256).max);
  ```

### 6. Common Errors

- `ManagerLocked()`: Not using the unlock pattern
- `CurrencyNotSettled()`: Not properly settling balances after operations
- Arithmetic underflow/overflow: Incorrect handling of signed integers
- Invalid hook address: Mismatched permissions or incorrect address mining

See full implementation examples in [ExtendedBaseHook.t.sol](test/base/ExtendedBaseHook.t.sol).

---

<details>
<summary><h2>Troubleshooting</h2></summary>



### *Permission Denied*

When installing dependencies with `forge install`, Github may throw a `Permission Denied` error

Typically caused by missing Github SSH keys, and can be resolved by following the steps [here](https://docs.github.com/en/github/authenticating-to-github/connecting-to-github-with-ssh) 

Or [adding the keys to your ssh-agent](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent#adding-your-ssh-key-to-the-ssh-agent), if you have already uploaded SSH keys

### Hook deployment failures

Hook deployment failures are caused by incorrect flags or incorrect salt mining

1. Verify the flags are in agreement:
    * `getHookCalls()` returns the correct flags
    * `flags` provided to `HookMiner.find(...)`
2. Verify salt mining is correct:
    * In **forge test**: the *deployer* for: `new Hook{salt: salt}(...)` and `HookMiner.find(deployer, ...)` are the same. This will be `address(this)`. If using `vm.prank`, the deployer will be the pranking address
    * In **forge script**: the deployer must be the CREATE2 Proxy: `0x4e59b44847b379578588920cA78FbF26c0B4956C`
        * If anvil does not have the CREATE2 deployer, your foundry may be out of date. You can update it with `foundryup`

</details>

---

Additional resources:

[Uniswap v4 docs](https://docs.uniswap.org/contracts/v4/overview)

[v4-periphery](https://github.com/uniswap/v4-periphery) contains advanced hook implementations that serve as a great reference

[v4-core](https://github.com/uniswap/v4-core)

[v4-by-example](https://v4-by-example.org)

## Compiler Version Requirements

**IMPORTANT**: This project must be compiled with Solidity 0.8.26 to ensure the CREATE2 bytecode for hooks matches the expected values.

The bytecode generated by different compiler versions for the same source code can vary, which affects the addresses derived during hook deployment. Hook addresses must contain specific permission bits to be valid in Uniswap V4.

To enforce the correct compiler version when working with this codebase:

1. Always use the commands provided in `run-tests.sh` and `run-deploy.sh` which include the necessary compiler version flags.
2. Run the following command to build with the correct compiler version:
   ```
   forge build --use solc:0.8.26
   ```
3. Run tests with:
   ```
   forge test --use solc:0.8.26
   ```

## Development Setup

This project uses Foundry for development, testing and deployment.

1. Install Foundry:
   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```

2. Install dependencies:
   ```bash
   forge install
   ```
   
3. Build the project:
   ```bash
   ./run-build.sh  # This will use the correct Solidity version
   ```

4. Run tests:
   ```bash
   ./run-tests.sh  # This will use the correct Solidity version
   ```

## License

This project is licensed under the BUSL-1.1 License.

