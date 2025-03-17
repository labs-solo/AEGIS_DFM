# FullRange Integration Testing Guide

This document explains how to run the full end-to-end (E2E) integration tests for the FullRange project using Unichain Sepolia testnet fork.

## Prerequisites

1. Foundry installed (forge, anvil)
2. A Unichain Sepolia RPC URL (from Alchemy)
3. Environment setup: export `UNICHAIN_SEPOLIA_RPC_URL=<your-unichain-sepolia-rpc-url>`

## Uniswap V4 on Unichain Sepolia

Our integration tests use the official Uniswap V4 contracts deployed on Unichain Sepolia testnet:

| Contract | Address |
|----------|---------|
| PoolManager | 0x00b036b58a818b1bc34d502d3fe730db729e62ac |
| Universal Router | 0xf70536b3bcc1bd1a972dc186a2cf84cc6da6be5d |
| PositionManager | 0xf969aee60879c54baaed9f3ed26147db216fd664 |
| StateView | 0xc199f1072a74d4e905aba1a84d9a45e2546b6222 |
| Quoter | 0x56dcd40a3f2d466f48e7f48bdbe5cc9b92ae4472 |

For the complete list, see the [official Uniswap V4 deployments documentation](https://docs.uniswap.org/contracts/v4/deployments).

## Testing Phases

The integration testing is divided into 7 phases as outlined in `Integration_Test.md`. Each phase builds upon the previous one to ensure comprehensive testing of the FullRange system.

### Phase 1: Environment Setup & Network Forking

This phase validates that the testing environment is correctly set up with a Unichain Sepolia fork, test accounts, and mock tokens. It also verifies that the Uniswap V4 contracts are accessible on the forked network.

To run Phase 1 test:

```bash
# Set your Unichain Sepolia RPC URL
export UNICHAIN_SEPOLIA_RPC_URL=<your-unichain-sepolia-rpc-url>

# Run the test using the script
./script/run_sepolia_test.sh

# Alternatively, run the test directly with forge
forge test --match-path test/FullRangeE2ETest.t.sol --match-test "testPhase1" --fork-url http://localhost:8545 -vvv

# For demonstration purposes only (does not require an RPC URL)
./script/run_phase1_test.sh
```

Expected output:
- Successful forking of Unichain Sepolia testnet
- Test accounts funded with ETH
- Mock tokens deployed and distributed to test accounts
- Verification of account balances
- Simple token transfer test
- Block advancement test
- Verification of Uniswap V4 contracts on Unichain Sepolia

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
export UNICHAIN_SEPOLIA_RPC_URL=<your-unichain-sepolia-rpc-url>
forge test --match-path test/FullRangeE2ETest.t.sol -vvv
```

## Troubleshooting

If you encounter issues with the tests:

1. Ensure your Unichain Sepolia RPC URL is valid and active
2. Check that you have sufficient rate limits on your RPC provider
3. For specific test failures, increase verbosity with `-vvvv` for detailed logs
4. Make sure your Foundry installation is up to date

## Updating the Tests

As the FullRange project evolves, the integration tests should be updated to reflect the latest functionality and edge cases. 