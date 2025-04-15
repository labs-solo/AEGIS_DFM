# VENM: Dynamic Fee Hook for Uniswap V4

VENM is a comprehensive system for managing dynamic fees and protocol-owned liquidity (POL) in Uniswap V4. It implements a sophisticated dual-component fee structure and automated POL reinvestment mechanism.

## Documentation

For detailed understanding of the system, please refer to our documentation:

- [Statement of Intended Behavior](docs/Statement_of_Intended_Behavior.md) - Complete overview of system components and their interactions
- [Dynamic Fee Requirements](docs/Dynamic_Fee_Requirements.md) - Deep dive into the dynamic fee system implementation
- [Protocol Owned Liquidity](docs/Protocol_Owned_Liquidity.md) - Detailed explanation of the POL system
- [Integration Testing Plan](docs/Integration_Testing_Plan.md) - Comprehensive testing strategy
- [Files Overview](docs/Files.md) - Directory structure and file purposes

## Key Features

### Dynamic Fee System

The system implements a two-component fee structure:
- **Base Fee**: Long-term component that adjusts based on market conditions
- **Surge Fee**: Short-term component activated during high volatility periods

Key capabilities:
- CAP (Capitalizable Adverse Price) event detection
- Automatic fee adjustment based on market conditions
- Linear surge fee decay after volatility events
- Configurable tick scaling for price movement limits

### Protocol-Owned Liquidity (POL)

Automated system for growing protocol-controlled liquidity:
- Configurable share of trading fees designated for POL
- Automatic fee collection and queuing
- Optimal reinvestment calculations based on pool ratios
- Full-range liquidity position management

## Architecture

### Core Components

1. **Fee Management**
   - `FullRangeDynamicFeeManager.sol`: Manages dynamic fee calculations
   - `TruncatedOracle.sol`: Implements tick capping for manipulation protection
   - `Spot.sol`: Hook contract handling fee application during swaps

2. **POL System**
   - `FeeReinvestmentManager.sol`: Handles POL fee extraction and reinvestment
   - `FullRangeLiquidityManager.sol`: Manages protocol liquidity positions
   - `PoolPolicyManager.sol`: Configures POL share and fee parameters

### Supporting Libraries

- `MathUtils.sol`: Mathematical utilities for fee and liquidity calculations
- `SettlementUtils.sol`: Handles Uniswap V4 settlement operations
- `TokenSafetyWrapper.sol`: Safe token operation utilities

## Getting Started

### Prerequisites

- Foundry (Forge, Anvil, and Cast)
- Solidity compiler 0.8.26
- Access to Uniswap V4 contracts

### Installation

1. Clone the repository:
```bash
git clone https://github.com/labs-solo/venm.git
cd venm
```

2. Install dependencies:
```bash
forge install
```

3. Compile contracts:
```bash
forge build --use solc:0.8.26
```

### Testing

Run the test suite:
```bash
forge test --use solc:0.8.26
```

For gas reporting:
```bash
forge test --gas-report -vvv --use solc:0.8.26
```

### Deployment

#### Local Unichain Fork Development

1. Configure environment:
   ```bash
   # Copy example environment file
   cp .env.example .env
   
   # Edit .env with your settings:
   # UNICHAIN_RPC_URL=your_unichain_rpc_url
   # PRIVATE_KEY=your_private_key
   ```

2. Start a persistent fork of Unichain:
   ```bash
   # This will create a persistent fork and keep it running
   ./persistent-fork.sh
   ```

3. Deploy the system:
   ```bash
   # For direct deployment of all components
   ./deploy-to-unichain.sh
   
   # Or for more granular control:
   forge script script/DirectDeploy.s.sol --fork-url http://localhost:8545
   ```

4. Add initial liquidity:
   ```bash
   # This script will add initial liquidity to test the system
   ./add-liquidity.sh
   ```

5. Run validation:
   ```bash
   # Validate the deployment and component interactions
   forge script script/C2DValidation.s.sol --fork-url http://localhost:8545
   ```

#### Available Scripts

- `persistent-fork.sh`: Maintains a persistent fork of Unichain for development
- `deploy-to-unichain.sh`: Deploys all components with proper configuration
- `add-liquidity.sh`: Adds initial liquidity to test pools
- `run-with-env.sh`: Helper for running scripts with environment variables
- `run-tests.sh`: Runs the test suite against the fork

#### Deployment Scripts

The repository includes several deployment-related scripts:

- `DeployUnichainV4.s.sol`: Main deployment script for Unichain
- `DirectDeploy.s.sol`: Alternative deployment approach
- `FixUnichain.s.sol` and `FixUnichainHook.s.sol`: Scripts for fixing potential issues
- `AnalyzeAddress.s.sol`: Analyzes deployed contract addresses
- `C2DValidation.s.sol`: Validates the deployment and component interactions

#### Troubleshooting Local Development

1. **Fork Issues**
   - If the fork becomes stale: `./persistent-fork.sh --reset`
   - For RPC errors: Check your `UNICHAIN_RPC_URL` in `.env`

2. **Deployment Failures**
   - Check `deployed-addresses.txt` for the latest deployment
   - Review `deployment-output.txt` for detailed logs
   - Use `AnalyzeAddress.s.sol` to verify contract states

3. **Validation Errors**
   - Run `C2DValidation.s.sol` for detailed diagnostics
   - Check component interactions and permissions
   - Verify hook addresses and permissions

4. **Common Solutions**
   - Clear the fork: Delete `.anvil/` directory and restart fork
   - Reset deployment: Remove `deployed-addresses.txt` and redeploy
   - Check gas settings in `foundry.toml`

## Security Features

- Reentrancy protection on critical functions
- Rate limiting for fee updates and POL processing
- Configurable minimum intervals between operations
- Emergency pause functionality for both systems
- Safe token approval management

## Fee Structure

The protocol implements a dual-fee structure:

1. **Dynamic Trading Fee**
   - Base component: Long-term market adjustment
   - Surge component: Short-term volatility response
   - Bounded by configurable minimum and maximum values

2. **Fee Distribution**
   - LP Share: Configurable percentage to liquidity providers
   - POL Share: Protocol's portion for reinvestment
   - Governance-adjustable parameters

## Contributing

Contributions are welcome! Please read our documentation first to understand the system architecture.

## License

This project is licensed under the Business Source License 1.1 - see the LICENSE file for details.

## Acknowledgments

- Uniswap V4 Core Team
- OpenZeppelin
- Solmate

