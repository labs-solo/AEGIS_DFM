# CI Requirements and Setup

This document outlines the requirements and process for setting up Continuous Integration (CI) for this project.

## CI Requirements

Any CI environment must have the following installed and configured:

1.  **Node.js**: Required for `pnpm`. Check `.nvmrc` or project requirements for the recommended version.
2.  **pnpm**: Used for installing dependencies. Install via `npm install -g pnpm`.
3.  **Foundry**: The core development toolchain (Forge, Anvil, Cast). Follow the official Foundry installation guide.
4.  **Solidity Compiler**: Version `0.8.26` (or as specified in `foundry.toml`). Foundry usually manages this, but ensure the correct version is available.

## Build Process in CI

The standard build process involves:

1.  **Checkout Code**: Get the latest code from the repository.
2.  **Setup Environment**: Install Node.js, pnpm, and Foundry.
3.  **Install Dependencies**:
    ```bash
    pnpm install
    ```
4.  **Build Contracts**:
    ```bash
    pnpm run build
    # or directly:
    # ./scripts/build.sh
    ```

## Test Requirements in CI

Testing should be run after a successful build:

1.  **Run Tests**:
    ```bash
    pnpm run test
    # or directly:
    # ./scripts/test.sh
    ```

2.  **(Optional) Gas Reporting**: If gas usage analysis is part of CI:
    ```bash
    forge test --gas-report
    ```

## Example CI Workflow Step (GitHub Actions)

```yaml
name: Build and Test

on: [push, pull_request]

jobs:
  build_and_test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Node.js
        uses: actions/setup-node@v3
        with:
          node-version: '18' # Or your required version

      - name: Install pnpm
        run: npm install -g pnpm

      - name: Setup Foundry
        uses: foundry-rs/foundry-toolchain@v1
        with:
          version: nightly # Or a specific version

      - name: Install Dependencies
        run: pnpm install

      - name: Build Contracts
        run: pnpm run build

      - name: Run Tests
        run: pnpm run test
``` 