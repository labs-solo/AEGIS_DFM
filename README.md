# VENM: Dynamic Fee Hook for Uniswap V4

VENM is a comprehensive, optimized system for providing and managing full-range (min tick to max tick) liquidity in Uniswap V4. It enables capital-efficient liquidity provision with advanced fee management, CAP event detection, and protocol-owned liquidity (POL) features.

## Overview

VENM reimagines full-range liquidity provision for Uniswap V4's hook-based architecture. The system allows users to deposit tokens into a pool spanning the entire tick range, receiving share tokens that represent proportional ownership of the pooled liquidity. The protocol implements dynamic fee adjustment based on price volatility, automatic fee reinvestment, and sophisticated risk management features.

## Key Features

- **Full-Range Liquidity**: Position tokens spanning from MIN_TICK to MAX_TICK
- **Dynamic Fee Adjustment**: Automated fee adjustments based on market volatility
- **CAP Event Detection**: Identifies Capitalizable Adverse Price (CAP) events for risk management
- **Protocol-Owned Liquidity**: Supports protocol-owned liquidity with dedicated reinvestment
- **Multiple Fee Tiers**: Customizable fee distribution between LPs and protocol
- **Native ETH Support**: Seamless handling of ETH and ERC20 tokens
- **Gas Optimized**: Efficient implementation with minimal bytecode footprint
- **Emergency Controls**: Robust safety mechanisms for risk mitigation

## Architecture

VENM follows a modular architecture with specialized components:

### Core Components

- **Spot.sol**: The main hook contract that implements the dynamic fee and liquidity management strategy
- **FullRangeLiquidityManager.sol**: Manages liquidity positions and handles deposits/withdrawals
- **FullRangeDynamicFeeManager.sol**: Manages dynamic fees and CAP events based on oracle price movements
- **PoolPolicyManager.sol**: Manages pool policies and fee distribution

### Supporting Components

- **TruncGeoOracleMulti.sol**: Price oracle with truncated geometric mean calculations
- **TruncatedOracle.sol**: Library for oracle data storage and manipulation
- **MathUtils.sol**: Mathematical utilities for liquidity calculations
- **FullRangePositions.sol**: ERC6909Claims token implementation for position accounting
- **SettlementUtils.sol**: Utilities for Uniswap V4 settlement operations
- **FullRangeUtils.sol**: Helper functions for the hook contracts

## Dynamic Fee System

VENM implements a two-tiered fee adjustment mechanism:

1. **Base Fee Adjustments**: Gradual fee changes based on long-term market conditions
2. **Surge Fees**: Immediate fee multipliers activated during periods of extreme volatility

### CAP Event Detection

CAP (Capitalizable Adverse Price) events are detected when:

- Price changes exceed a predefined volatility threshold
- Rapid tick movements are observed in a short time period
- Oracle price deviations from exponential moving averages are significant

When a CAP event is detected, the protocol can:
- Activate surge pricing (higher fees)
- Adjust risk parameters across the protocol
- Signal volatility to integrated systems

## Usage

### Depositing Liquidity

```solidity
// Deposit tokens to receive position shares
function deposit(
    PoolId poolId,
    uint256 amount0Desired,
    uint256 amount1Desired,
    uint256 amount0Min,
    uint256 amount1Min,
    address recipient
) external payable returns (uint256 shares, uint256 amount0, uint256 amount1);
```

### Withdrawing Liquidity

```solidity
// Burn position shares to withdraw underlying tokens
function withdraw(
    PoolId poolId,
    uint256 sharesToBurn,
    uint256 amount0Min,
    uint256 amount1Min,
    address recipient
) external returns (uint256 amount0, uint256 amount1);
```

### Creating a New Pool

Pools are created using Uniswap V4's standard pool initialization flow. The VENM hook will be activated during pool creation.

## Getting Started

### Prerequisites

- Foundry (Forge, Anvil, and Cast)
- Access to Uniswap V4 contracts
- Solidity compiler 0.8.26

### Installation

1. Clone the repository:
```bash
git clone https://github.com/venm-project/venm.git
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

Run the test suite using Forge:
```bash
forge test --use solc:0.8.26
```

For advanced testing with gas reporting:
```bash
forge test --gas-report -vvv --use solc:0.8.26
```

Use Anvil for local development:
```bash
anvil
```

### Deployment

1. Deploy the core contracts:
```bash
forge script script/DirectDeploy.s.sol --rpc-url [your-rpc-url] --broadcast --verify --use solc:0.8.26
```

2. Initialize the system:
```bash
forge script script/Initialize.s.sol:InitializeScript --rpc-url [your-rpc-url] --broadcast --use solc:0.8.26
```

## Fee Structure

The protocol distributes fees between two primary components:

1. **LP Share**: Fees directed to liquidity providers
2. **Protocol-Owned Liquidity (POL) Share**: Fees collected for protocol operations and reinvestment

The default distribution is:
- LP Share: 90% (900,000 PPM)
- POL Share: 10% (100,000 PPM)

This distribution ensures that liquidity providers receive the majority of the trading fees while still allowing the protocol to accumulate its own liquidity position over time. The POL share is reinvested back into the pool, helping to grow protocol-owned liquidity and create a sustainable source of revenue.

These values can be adjusted through governance for individual pools or globally across the protocol.

## Native ETH Handling

The protocol supports native ETH through two mechanisms:

1. Direct handling of ETH via Uniswap V4's Currency type system
2. Support for WETH in pools that require wrapped ETH

The system features built-in ETH safety mechanisms to prevent loss of funds during transfers.

## Oracle Implementation

The protocol implements a geometric mean oracle with the following features:

- Truncated price movement to prevent manipulation
- Historical observation storage for accurate pricing data
- Customizable thresholds for CAP event detection
- Tick movement capping based on fee levels

## Security Features

- **Emergency Mode**: Allows forced withdrawals during critical situations
- **Access Controls**: Segregated permission system for various operations
- **Rate Limiting**: Prevents excessive operations during volatile periods
- **Slippage Protection**: Customizable slippage parameters for user operations
- **Oracle Guards**: Price movement caps to prevent manipulation

## Protocol-Owned Liquidity (POL)

The protocol maintains its own liquidity position in each pool to:

1. Generate sustainable protocol revenue
2. Improve pool stability and depth
3. Establish minimum liquidity thresholds

POL is managed through dedicated reinvestment mechanisms with governance controls.

## Unichain Mainnet Deployment

This section provides instructions for deploying the VENM Dynamic Fee Hook to Unichain Mainnet.

### Setting Up Unichain Network

1. Add Unichain Mainnet to your wallet:
   - Network Name: Unichain Mainnet
   - RPC URL: https://mainnet.unichain.org
   - Chain ID: 130
   - Currency Symbol: UNI
   - Block Explorer: https://mainnet-explorer.unichain.org

2. Configure Environment Variables:
   - Copy `.env.example` to `.env`:
     ```bash
     cp .env.example .env
     ```
   - Edit `.env` with your configuration:
     ```
     UNICHAIN_MAINNET_RPC_URL=https://mainnet.unichain.org
     FORK_BLOCK_NUMBER=13932475  # Use a recent block number
     PRIVATE_KEY=your_private_key_here  # Add your private key (without 0x prefix)
     ```

### Deployment Scripts

The deployment process uses Foundry scripts to deploy and configure all components:

1. **DirectDeploy Script**: Deploys all core components with proper hook permissions
   ```bash
   # Simulate the deployment (dry-run)
   forge script script/DirectDeploy.s.sol --rpc-url $(grep UNICHAIN_MAINNET_RPC_URL .env | cut -d= -f2) -vvv
   
   # Broadcast the transactions to the network
   forge script script/DirectDeploy.s.sol --rpc-url $(grep UNICHAIN_MAINNET_RPC_URL .env | cut -d= -f2) --broadcast
   ```

2. The DirectDeploy script:
   - Deploys TruncGeoOracleMulti
   - Deploys PoolPolicyManager with optimized fee parameters
   - Deploys FullRangeLiquidityManager
   - Mines a suitable address for the Spot hook with specific permissions:
     - afterInitialize
     - beforeSwap
     - afterSwapReturnDelta
     - afterRemoveLiquidityReturnDelta
   - Deploys the Spot hook
   - Deploys and configures FullRangeDynamicFeeManager
   - Grants necessary permissions between components

### Troubleshooting

- **HookMiner Salt Issue**: If the script fails with "HookMiner: could not find salt", you may need to increase the MAX_LOOP constant in src/utils/HookMiner.sol (default is 200,000)
- **Contract Size Issues**: If contracts exceed size limits, verify optimization settings in foundry.toml
- **Connection Issues**: Ensure your RPC URL is correct and the network is accessible
- **Permission Errors**: Verify that your account has sufficient funds for deployment

### Post-Deployment Verification

After successful deployment, verify your contracts on the Unichain explorer:

```bash
forge verify-contract --chain 130 \
  --constructor-args $(cast abi-encode "constructor(address)" "<pool_manager_address>") \
  <deployed_address> src/TruncGeoOracleMulti.sol:TruncGeoOracleMulti \
  --etherscan-api-key <your_api_key>
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the Business Source License 1.1 - see the LICENSE file for details.

## Acknowledgments

- Uniswap V4 Core Team for the foundational architecture
- OpenZeppelin for security patterns and implementations
- Solmate for efficient implementation references

