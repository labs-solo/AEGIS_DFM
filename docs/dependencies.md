# Dependency Management

This project utilizes `pnpm` workspaces to manage all dependencies, including both JavaScript development tools and Solidity libraries required for compilation and testing with Foundry.

## Approach

- **Single Source of Truth:** The root `package.json` file defines all external dependencies.
- **PNPM Installation:** The command `pnpm install -w` fetches all dependencies listed in `package.json`. 
- **Solidity Dependencies:** Solidity libraries (like Uniswap V4, OpenZeppelin, Forge Std, etc.) are typically included directly from their Git repositories, specified as URLs in `package.json`. `pnpm` handles cloning these repositories into the `node_modules` directory.
- **No Submodules or `lib/`:** We do not use Git submodules or manually place libraries in the `lib/` directory. All external code resides within `node_modules`.
- **Foundry Remappings:** The `remappings.txt` file provides Foundry with paths pointing into the `node_modules` directory, allowing the Solidity compiler (`solc`) to locate the necessary imports.

## Core Dependencies (`devDependencies` in `package.json`)

Here are the primary dependencies managed by `pnpm`:

- **`@openzeppelin/contracts`**: Standard and secure smart contract implementations.
  ```json
  "@openzeppelin/contracts": "^5.0.2"
  ```
- **`forge-std`**: Foundry Standard Library for testing and utilities.
  ```json
  "forge-std": "latest" 
  ``` 
- **`solmate`**: Gas-optimized Solidity building blocks.
  ```json
  "solmate": "6.8.0"
  ```
- **`v4-core`**: Uniswap V4 Core contracts.
  ```json
  "v4-core": "git+https://github.com/Uniswap/v4-core.git#main"
  ```
- **`v4-periphery`**: Uniswap V4 Periphery contracts.
  ```json
  "v4-periphery": "git+https://github.com/Uniswap/v4-periphery.git#main"
  ```
- **`permit2`**: Uniswap's Permit2 contract for signature-based approvals.
  ```json
  "permit2": "git+https://github.com/Uniswap/permit2.git#main"
  ```
- **`prettier`**: Code formatter (primarily for JS/TS/JSON, etc.).
  ```json
  "prettier": "^3.3.3"
  ```

*Note: Git dependencies pointing to `#main` will fetch the latest commit from the main branch at the time of installation. Specific commit hashes or tags can be used for more deterministic builds.*

## Version Requirements

- Node.js (which includes npm, needed to install pnpm): Check `.nvmrc` or project requirements.
- pnpm: Latest stable version recommended.
- `forge-std`: See `package.json` for the specific version range.
- `solmate`: See `package.json` for the specific version.

## Caveats and Known Issues

- Ensure `pnpm` is installed globally (`npm install -g pnpm`) or available in your environment.
- If you encounter build issues, try removing `node_modules` and `pnpm-lock.yaml` and running `pnpm install` again.
- The `lib/v4-core` directory is currently a placeholder. If actual `v4-core` code is needed, it should be populated accordingly, potentially as a separate package within the workspace or fetched from its source. 