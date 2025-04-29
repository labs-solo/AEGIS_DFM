#!/bin/bash

# Check for required environment variables
if [ -z "$ALCHEMY_API_KEY" ]; then
    echo "Error: ALCHEMY_API_KEY environment variable is not set"
    exit 1
fi

# Run forge script with Alchemy RPC URL
forge script script/DeployUnichainV4.s.sol:DeployUnichainV4 \
    --rpc-url "https://eth-sepolia.g.alchemy.com/v2/${ALCHEMY_API_KEY}" \
    --broadcast \
    --verify \
    -vvvv 