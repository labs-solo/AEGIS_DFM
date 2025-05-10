# AEGIS Dynamic Fee Simulator

This directory contains the Python-based simulation environment for testing and validating the AEGIS Dynamic Fee Model. The simulator deploys a local Uniswap V4 environment with the AEGIS fee model and allows running various market scenarios.

## Prerequisites

- Python 3.13 or higher
- [Foundry](https://book.getfoundry.sh/getting-started/installation) for local Anvil node
- Node.js and npm (for contract compilation)

## Setup

1. Create and activate a Python virtual environment:

   ```bash
   # Create virtual environment
   python3 -m venv venv
   
   # Activate it (Unix/macOS)
   source venv/bin/activate
   
   # Activate it (Windows)
   .\venv\Scripts\activate
   ```

2. Install Python dependencies:

   ```bash
   pip install -r requirements.txt
   ```

3. Build the smart contracts (from repository root):

   ```bash
   forge build
   ```

4. Verify Foundry installation:

   ```bash
   forge --version
   anvil --version
   ```

## Configuration

The simulator behavior can be customized through `simConfig.yaml`. Key parameters include:

```yaml
pair:
  token0: TKNA
  token1: TKNB
initialPrice: 1.0
initialLiquidity:
  token0: 1000000000000000000000  # 1e21 wei
  token1: 1000000000000000000000
feeParams:
  defaultBaseFeePpm: 3000
  minBaseFeePpm: 100
  maxBaseFeePpm: 50000
```

## Running the Simulator

1. Make sure your virtual environment is activated:

   ```bash
   source venv/bin/activate  # Unix/macOS
   # or
   .\venv\Scripts\activate   # Windows
   ```

2. Run the basic simulation (from repository root):

   ```bash
   python -m simulation.orchestrator
   ```

   Note: The simulator will automatically start a local Anvil node if one is not running. If you get a "port in use" error, ensure no other Anvil instance is running.

3. Run specific test scenarios:

   ```bash
   # Test base fee decay in calm market
   python -m pytest tests/test_base_fee_down.py -v
   
   # Test base fee increase under volatility
   python -m pytest tests/test_base_fee_up.py -v
   ```

## Understanding the Output

The simulator provides detailed logging of:

- Contract deployment addresses
- Pool initialization parameters
- Fee state changes (base fee and surge fee)
- CAP events (volatility-induced price caps)

Example output:

``` text
Connected to Anvil – chainId: 900
Loaded simConfig.yaml
PoolManager: 0x...
token0, token1: 0x..., 0x...
Initial liquidity added.
BaseFee=3000ppm, SurgeFee=0ppm, TotalFee=3000ppm
```

## Architecture

Key components:

- `orchestrator.py`: Main deployment and simulation logic
- `metrics.py`: Fee state tracking and event detection
- `simConfig.yaml`: Simulation parameters
- `specifications/`: Detailed documentation of simulation phases

## Troubleshooting

1. If Anvil connection fails:
   - Check if another Anvil instance is already running (`lsof -i :8545` on Unix/macOS)
   - Kill any existing Anvil processes and try again
   - Verify Foundry installation with `forge --version`

2. If contract deployment fails:
   - Ensure contracts are built (`forge build`)
   - Check virtual environment is activated
   - Verify all Python dependencies are installed
   - Check the gas limit in the deployment transaction

3. If fee updates aren't occurring:
   - Verify timeStep configuration
   - Check blockchain time advancement in test scenarios
   - Review DynamicFeeManager contract logs

## Contributing

When adding new test scenarios:

1. Create a new test file under `tests/`
2. Use the `setup_simulation()` helper from orchestrator.py
3. Leverage the `FeeTracker` class for consistent fee state monitoring
4. Document expected behavior and assertions
