#!/bin/bash
set -e  # Exit on any error

# Script to deploy FullRange system to local Unichain Mainnet fork

echo "====================================================="
echo "Deploying to Unichain fork at block number ${FORK_BLOCK_NUMBER:-13900000}"
echo "====================================================="

# Check required environment variables
if [ -z "$UNICHAIN_MAINNET_RPC_URL" ]; then
  echo "Error: UNICHAIN_MAINNET_RPC_URL environment variable is not set"
  echo "Please set it with your Unichain Mainnet RPC URL, for example:"
  echo "export UNICHAIN_MAINNET_RPC_URL=https://rpc.unichain.io"
  exit 1
fi

if [ -z "$PRIVATE_KEY" ]; then
  echo "Error: PRIVATE_KEY environment variable is not set"
  echo "Please set it with your private key, for example:"
  echo "export PRIVATE_KEY=0x123abc..."
  exit 1
fi

# Use block 13900000 as the default fork point
FORK_BLOCK_NUMBER=${FORK_BLOCK_NUMBER:-"13900000"}

# Check if port 8545 is already in use
if command -v nc &> /dev/null && nc -z localhost 8545 2>/dev/null; then
  echo "Error: Port 8545 is already in use. Another Anvil instance may be running."
  exit 1
fi

# Verify if the block is available
echo "Verifying block ${FORK_BLOCK_NUMBER} is available on the RPC..."
BLOCK_CHECK=$(curl -s -X POST -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"0x$(printf '%x' ${FORK_BLOCK_NUMBER})\", false],\"id\":1}" ${UNICHAIN_MAINNET_RPC_URL})
if [[ $BLOCK_CHECK == *"error"* ]]; then
  echo "Error: Block ${FORK_BLOCK_NUMBER} is not available on the RPC. Trying to get latest block..."
  LATEST_BLOCK_HEX=$(curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' ${UNICHAIN_MAINNET_RPC_URL} | grep -o '"result":"0x[^"]*' | sed 's/"result":"//g')
  if [[ $LATEST_BLOCK_HEX != "" ]]; then
    LATEST_BLOCK=$((16#${LATEST_BLOCK_HEX:2}))
    echo "Latest block is ${LATEST_BLOCK}. Using this instead."
    FORK_BLOCK_NUMBER=$LATEST_BLOCK
  else
    echo "Failed to get latest block number. Exiting."
    exit 1
  fi
fi

# Verify the PoolManager contract exists
echo "Verifying PoolManager contract exists at block ${FORK_BLOCK_NUMBER}..."
POOL_MANAGER="0x1F98400000000000000000000000000000000004"
CODE_CHECK=$(curl -s -X POST -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"${POOL_MANAGER}\", \"0x$(printf '%x' ${FORK_BLOCK_NUMBER})\"],\"id\":1}" ${UNICHAIN_MAINNET_RPC_URL})
if [[ $CODE_CHECK == *"0x"* ]] && [[ ${#CODE_CHECK} -lt 20 ]]; then
  echo "Error: PoolManager contract does not exist at block ${FORK_BLOCK_NUMBER}. Response: ${CODE_CHECK}"
  exit 1
fi

echo "All pre-flight checks passed. Starting Anvil with fork..."

# Start Anvil with improved configuration
echo "Starting Anvil with fork from block ${FORK_BLOCK_NUMBER}..."
anvil --fork-url $UNICHAIN_MAINNET_RPC_URL --fork-block-number $FORK_BLOCK_NUMBER --accounts 10 --balance 1000 --no-mining --hardfork cancun --tracing &
ANVIL_PID=$!

# Trap to make sure Anvil is killed when the script exits
trap "echo 'Cleaning up...'; kill $ANVIL_PID 2>/dev/null || true" EXIT INT TERM

# Wait for Anvil to start
echo "Waiting for Anvil to initialize (this may take a while for a large block number)..."
sleep 10

# Verify Anvil is running correctly
echo "Verifying Anvil is running..."
ANVIL_CHECK=$(curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://localhost:8545) || { echo "Anvil failed to start properly"; exit 1; }
echo "Anvil is running. Forked at block: $ANVIL_CHECK"

# Clean previous build artifacts
echo "Cleaning previous build artifacts..."
forge clean || { echo "Failed to clean build artifacts"; exit 1; }

# Build the project
echo "Building project with Solidity 0.8.27..."
forge build --use solc:0.8.27 || { echo "Build failed"; exit 1; }

# Deploy to local fork and save the output
echo "Deploying to local Unichain fork..."
DEPLOYMENT_OUTPUT_FILE="deployment-output.txt"
forge script script/DeployUnichainV4.s.sol:DeployUnichainV4 --rpc-url http://localhost:8545 --private-key $PRIVATE_KEY --broadcast -vvv | tee $DEPLOYMENT_OUTPUT_FILE || { echo "Deployment failed"; exit 1; }

# Extract and save deployed addresses to a simplified file for easier use
ADDRESSES_OUTPUT_FILE="deployed-addresses.txt"
echo "Saving deployment addresses to $ADDRESSES_OUTPUT_FILE..."
grep -A8 "=== Deployment Complete ===" $DEPLOYMENT_OUTPUT_FILE > $ADDRESSES_OUTPUT_FILE || { echo "Failed to extract addresses"; exit 1; }

echo "Deployment addresses saved to $ADDRESSES_OUTPUT_FILE. Use this file with add-liquidity.sh by running:"
echo "export DEPLOYED_ADDRESS_FILE=$ADDRESSES_OUTPUT_FILE"
echo "export FORK_BLOCK_NUMBER=$FORK_BLOCK_NUMBER"

echo "Deployment completed successfully!" 