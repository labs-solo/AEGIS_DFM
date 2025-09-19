# AEGIS Dynamic Fee Mechanism (DFM) for Uniswap V4

> **Smart, self-tuning swap fees & protocol-owned liquidity on-chain.**

`aeGIS-dfm` is an opinionated toolkit that plugs directly into Uniswap V4 pools, replacing the static fee tier with a two-component dynamic fee and automatically compounding a slice of trading fees into protocol-owned liquidity (POL).

Why you might care:

* **Higher Fees.** Sudden price shocks trigger an immediate _surge_ fee, enabling LPs to capitalize on volatility.
* **Capital Efficiency.** In calm markets the _base_ fee self-tunes downward to stay competitive.
* **Liquidity Depth.** A configurable share of fees is recycled into a full-range Uniswap position, deepening the book over time.
* **100 % On-chain & Deterministic.** No external price feeds – all maths derive solely from pool ticks + block‐time.

---

## 📖 Documentation Quick-Links

| Audience | Read First | Purpose |
|----------|-----------|---------|
| **Auditors / Formal Reviewers** | [`docs/AEGIS_Statement_of_Intended_Behavior.md`](docs/AEGIS_Statement_of_Intended_Behavior.md) | Canonical description of expected run-time behavior ☑️ |
| **Protocol Engineers** | One-pagers in [`docs/one_pagers/`](docs/one_pagers) | Storage layout, invariants & gas notes for each contract |
| **Contributors / Devs** | This README | Setup & dev-loop |

---

## 🏗️ Project Layout (High-Level)

```text
src/
├─ Spot.sol                       # central Uniswap V4 hook (fee router)
├─ DynamicFeeManager.sol          # base + surge fee engine
├─ TruncGeoOracleMulti.sol        # adaptive tick-cap oracle
├─ PoolPolicyManager.sol          # registry of risk parameters
└─ FullRangeLiquidityManager.sol  # protocol-owned-liquidity vault
script/                 # build / test / deploy helpers
foundry.toml             # compiler + remappings
package.json + pnpm-lock.yaml
```

---

## 🚀 Getting Started

### Quick-Start

```bash
pnpm install --workspace-root
forge build
npx hardhat test
```

### 1. Install Tooling

| Tool | Purpose | Version |
|------|---------|---------|
| [pnpm](https://pnpm.io) | JS + Solidity dependency manager | ≥ 8.x |
| [Foundry](https://github.com/foundry-rs/foundry) | Build / test Solidity | `forge --version` ≥ 0.2.0 |
| `node` | required by pnpm | ≥ 18 |

```bash
# macOS ex.
brew install pnpm
curl -L https://foundry.paradigm.xyz | bash && foundryup
```

### 2. Clone & Install

```bash
git clone https://github.com/labs-solo/AEGIS_DFM.git
cd AEGIS_DFM
pnpm install --workspace-root                      # fetches ALL deps incl. Uniswap v4 core
```

`pnpm install` populates `node_modules`; `forge` picks them up via `remappings.txt`. No submodules, no manual `lib/` juggling.

### 3. Compile Contracts

```bash
forge b
```

### 4. Run Tests

```bash
pnpm t:i
```

### 5. Format / Clean

```bash
pnpm run format   # prettier solidity
pnpm run clean    # nuke cache/ & out/
```

---

## Deployment

```bash
forge script script/Deploy.s.sol --rpc-url <chain-alias> --sender <deployer-address> --account <deployer-account-name> --broadcast
```

```bash
# verify the Spot contract

forge verify-contract <Spot-address> Spot \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address,address)" <constructor-args>) \
  --verifier etherscan \
  --verifier-url https://api.uniscan.xyz/api \
  --verifier-api-key <api-key> \
  --watch
```

---

## 🤝 Contributing

PRs welcome!  Bug reports, test-cases, and gas-optimization suggestions are especially appreciated.  Please read the Statement of Intended Behavior first to ensure changes uphold published invariants.

---

## 📜 License

Business Source License 1.1 – see `LICENSE` for details.

## Acknowledgments

- Uniswap V4 Core Team
- OpenZeppelin
- Solmate
