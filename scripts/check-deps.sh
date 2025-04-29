#!/usr/bin/env bash

# Check if node_modules/@uniswap/v4-core exists
if [ ! -d "node_modules/@uniswap/v4-core" ]; then
    echo "Error: Dependencies not found. Please run 'pnpm install' first."
    exit 1
fi

# If we get here, dependencies are present
exit 0 