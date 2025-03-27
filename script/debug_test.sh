#!/bin/bash
# Script to debug integration test setup issues

echo "========== DEBUGGING ENVIRONMENT =========="
echo "Checking Forge installation:"
forge --version

echo ""
echo "Checking Anvil installation:"
anvil --version

echo ""
echo "Checking environment variable:"
if [ -z "$UNICHAIN_SEPOLIA_RPC_URL" ]; then
  echo "ERROR: UNICHAIN_SEPOLIA_RPC_URL is not set"
else
  # Mask the API key for security
  MASKED_URL=$(echo $UNICHAIN_SEPOLIA_RPC_URL | sed 's/v2\/[a-zA-Z0-9]*/v2\/XXXXXXXX/')
  echo "UNICHAIN_SEPOLIA_RPC_URL is set to: $MASKED_URL"
fi

echo ""
echo "Testing network connectivity:"
if [ ! -z "$UNICHAIN_SEPOLIA_RPC_URL" ]; then
  # Send a simple JSON-RPC request to check connection
  RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' $UNICHAIN_SEPOLIA_RPC_URL)
  if [[ $RESPONSE == *"result"* ]]; then
    echo "Successfully connected to RPC endpoint"
    # Extract block number in decimal
    HEX_BLOCK=$(echo $RESPONSE | grep -o '"result":"0x[^"]*' | cut -d'"' -f4)
    if [ ! -z "$HEX_BLOCK" ]; then
      DECIMAL_BLOCK=$((16#${HEX_BLOCK:2}))
      echo "Current block number: $DECIMAL_BLOCK"
    fi
  else
    echo "ERROR: Could not connect to RPC endpoint. Response: $RESPONSE"
  fi
else
  echo "Skipping connectivity test because UNICHAIN_SEPOLIA_RPC_URL is not set"
fi

echo ""
echo "Checking test file:"
if [ -f "test/FullRangeE2ETest.t.sol" ]; then
  echo "Test file exists"
  # Count lines to verify it's not empty
  LINE_COUNT=$(wc -l < test/FullRangeE2ETest.t.sol)
  echo "Line count: $LINE_COUNT"
else
  echo "ERROR: Test file not found"
fi

echo ""
echo "========== SUGGESTED FIXES =========="
echo "1. If UNICHAIN_SEPOLIA_RPC_URL is not set, edit script/run_with_alchemy.sh with your API key"
echo "2. If connectivity fails, check your internet connection and API key validity"
echo "3. For Anvil issues, make sure Foundry is properly installed"
echo "4. For other errors, share the full test output for detailed debugging"
echo ""
echo "To run a full debug test with complete logs:"
echo "./script/run_with_alchemy.sh 2>&1 | tee debug_output.log"
echo "===================================================" 