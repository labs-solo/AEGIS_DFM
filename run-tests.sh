#!/bin/bash

# Clean the build artifacts
forge clean

# Build with the correct Solidity version
echo "Building project with Solidity 0.8.27..."
forge build --use solc:0.8.27

# Run the main test with the correct Solidity version
echo "Running SimpleV4Test with Solidity 0.8.27..."
forge test --match-path test/SimpleV4Test.t.sol --use solc:0.8.27 -vvv

# Run the compiler version check test for reference
echo "Running CompilerVersionCheck with Solidity 0.8.27..."
forge test --match-path test/CompilerVersionCheck.t.sol --use solc:0.8.27 -vvv 