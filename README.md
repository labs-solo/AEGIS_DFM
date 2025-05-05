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
contracts/
├─ hooks/Spot.sol                 # central Uniswap V4 hook (fee router)
├─ fee/DynamicFeeManager.sol      # base + surge fee engine
├─ oracle/TruncGeoOracleMulti.sol # adaptive tick-cap oracle
├─ policy/PoolPolicyManager.sol   # registry of risk parameters
└─ pol/FullRangeLiquidityManager.sol # protocol-owned-liquidity vault
scripts/                 # build / test / deploy helpers
foundry.toml             # compiler + remappings
package.json + pnpm-lock.yaml
```

---

## 🚀 Getting Started

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
git clone https://github.com/labs-solo/venm.git    # repo still named venm for now
cd venm
pnpm install --workspace-root                      # fetches ALL deps incl. Uniswap v4 core
```

`pnpm install` populates `node_modules`; `forge` picks them up via `remappings.txt`. No submodules, no manual `lib/` juggling.

### 3. Compile Contracts

```bash
pnpm run build    # wrapper around forge build
```

### 4. Run Tests

```bash
# fast unit + fuzz suite
pnpm run test

# with gas report
forge test --gas-report -vvv
```

### 5. Format / Clean

```bash
pnpm run format   # prettier solidity
pnpm run clean    # nuke cache/ & out/
```

---

## 🔄  Local Fork Demo (Optional)

Spin up a persistent Anvil fork and deploy the full stack:

```bash
cp .env.example .env         # fill in RPC + key
./persistent-fork.sh         # keeps the fork alive in background
./deploy-to-unichain.sh      # or tailor with forge script ...
```

After deployment run `./add-liquidity.sh` then `forge script script/C2DValidation.s.sol` to verify the system invariants on-chain.

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
