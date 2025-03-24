#!/bin/bash

# Script to build the project with the correct compiler version
echo "Building project with Solidity 0.8.26..."

# Clean previous build artifacts
forge clean

# Build with the pinned compiler version
forge build --use solc:0.8.26

# Check build status
if [ $? -eq 0 ]; then
    echo "Build successful!"
else
    echo "Build failed!"
    exit 1
fi 