#!/bin/bash

# Script for running local tests using Anvil and Forge
# This script:
# 1. Starts a local Anvil instance
# 2. Deploys the local Uniswap V4 environment
# 3. Runs the local tests

# Color codes for output formatting
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting local test environment...${NC}"

# Check if Anvil is already running
if lsof -i:8545 > /dev/null; then
    echo -e "${RED}Port 8545 is already in use. Please stop any running Anvil instances.${NC}"
    exit 1
fi

# Start Anvil in the background
echo -e "${GREEN}Starting Anvil...${NC}"
anvil --silent > /dev/null 2>&1 &
ANVIL_PID=$!

# Wait for Anvil to start
sleep 2

# Make sure Anvil started properly
if ! lsof -i:8545 > /dev/null; then
    echo -e "${RED}Failed to start Anvil.${NC}"
    exit 1
fi

echo -e "${GREEN}Anvil started on port 8545.${NC}"

# Clean up on script exit or interruption
cleanup() {
    echo -e "${YELLOW}Stopping Anvil...${NC}"
    kill $ANVIL_PID > /dev/null 2>&1
    echo -e "${GREEN}Done!${NC}"
    exit 0
}

trap cleanup EXIT INT TERM

# Deploy the local Uniswap V4 environment
echo -e "${YELLOW}Deploying local Uniswap V4 environment...${NC}"
forge script script/DeployLocalUniswapV4.s.sol --rpc-url http://localhost:8545 --broadcast

# Run the local tests
echo -e "${YELLOW}Running local tests...${NC}"
forge test --match-contract FullRangeLocalTest --rpc-url http://localhost:8545 -vvv

# You can add more specific test commands here if needed
# For example:
# forge test --match-test test_deposit --rpc-url http://localhost:8545 -vvv 