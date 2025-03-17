#!/bin/bash
# Script to run FullRange integration tests with Sepolia fork

# Check if SEPOLIA_RPC_URL is set
if [ -z "$SEPOLIA_RPC_URL" ]; then
  echo "Error: SEPOLIA_RPC_URL environment variable is not set"
  echo "Please set it with your Sepolia RPC URL, for example:"
  echo "export SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_API_KEY"
  exit 1
fi

echo "Starting Anvil with Sepolia fork..."
# Start Anvil in the background with Sepolia fork
anvil --fork-url $SEPOLIA_RPC_URL &
ANVIL_PID=$!

# Wait for Anvil to start
sleep 3

echo "Running Phase 1 test..."
forge test --match-path test/FullRangeE2ETest.t.sol --match-test "testPhase1" --fork-url http://localhost:8545 -vvv

# Kill Anvil process
kill $ANVIL_PID

echo "Test completed, Anvil process terminated." 