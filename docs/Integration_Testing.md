# FullRange Integration Testing Guide

This document explains how to run the full end-to-end (E2E) integration tests for the FullRange project using Sepolia testnet fork.

## Prerequisites

1. Foundry installed (forge, anvil)
2. A Sepolia RPC URL (from Infura, Alchemy, or other providers)
3. Environment setup: export `SEPOLIA_RPC_URL=<your-sepolia-rpc-url>`

## Uniswap V4 on Sepolia

Our integration tests use the official Uniswap V4 contracts deployed on Sepolia testnet:

| Contract | Address |
|----------|---------|
| PoolManager | 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 |
| Universal Router | 0x3a9d48ab9751398bbfa63ad67599bb04e4bdf98b |
| PositionManager | 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4 |
| StateView | 0xe1dd9c3fa50edb962e442f60dfbc432e24537e4c |
| Quoter | 0x61b3f2011a92d183c7dbadbda940a7555ccf9227 |

For the complete list, see the [official Uniswap V4 deployments documentation](https://docs.uniswap.org/contracts/v4/deployments).

## Testing Phases

The integration testing is divided into 7 phases as outlined in `Integration_Test.md`. Each phase builds upon the previous one to ensure comprehensive testing of the FullRange system.

### Phase 1: Environment Setup & Network Forking

This phase validates that the testing environment is correctly set up with a Sepolia fork, test accounts, and mock tokens. It also verifies that the Uniswap V4 contracts are accessible on the forked network.

To run Phase 1 test:

```bash
# Set your Sepolia RPC URL
export SEPOLIA_RPC_URL=<your-sepolia-rpc-url>

# Run the test using the script
./script/run_sepolia_test.sh

# Alternatively, run the test directly with forge
forge test --match-path test/FullRangeE2ETest.t.sol --match-test "testPhase1" -vvv

# For demonstration purposes only (does not require an RPC URL)
./script/run_phase1_test.sh
```

Expected output:
- Successful forking of Sepolia testnet
- Test accounts funded with ETH
- Mock tokens deployed and distributed to test accounts
- Verification of account balances
- Simple token transfer test
- Block advancement test
- Verification of Uniswap V4 contracts on Sepolia

### Phase 2: FullRange Contract Suite Deployment

This phase will test the deployment of all FullRange components on the forked network (coming soon).

### Phase 3: Pool Creation with Dynamic Fees

This phase will test the creation of Uniswap V4 pools with dynamic fees (coming soon).

### Phase 4: Liquidity Management

This phase will test depositing and withdrawing liquidity (coming soon).

### Phase 5: Swap Testing and Hook Callbacks

This phase will test swap functionality and verify hook callbacks are triggered (coming soon).

### Phase 6: Oracle Updates and Dynamic Fee Testing

This phase will test oracle updates and dynamic fee adjustments (coming soon).

### Phase 7: End-to-End Flow and Stress Testing

This phase will perform comprehensive testing combining all components (coming soon).

## Running the Full Test Suite

When all phases are implemented, you can run the entire test suite with:

```bash
export SEPOLIA_RPC_URL=<your-sepolia-rpc-url>
forge test --match-path test/FullRangeE2ETest.t.sol -vvv
```

## Troubleshooting

If you encounter issues with the tests:

1. Ensure your Sepolia RPC URL is valid and active
2. Check that you have sufficient rate limits on your RPC provider
3. For specific test failures, increase verbosity with `-vvvv` for detailed logs
4. Make sure your Foundry installation is up to date

## Updating the Tests

As the FullRange project evolves, the integration tests should be updated to reflect the latest functionality and edge cases. 