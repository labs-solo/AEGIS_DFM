#!/bin/bash
set -e  # Exit on any error

# Script to set up a persistent Anvil fork of Unichain

UNICHAIN_RPC_URL=${UNICHAIN_MAINNET_RPC_URL:-"https://mainnet.unichain.org"}
ANVIL_PORT=8545
ANVIL_HOST=127.0.0.1
ANVIL_PID_FILE=/tmp/anvil-fork.pid
BLOCK_INFO_FILE=/tmp/anvil-block-info.txt

# Function to check if an Anvil instance is already running
check_anvil_running() {
  if [ -f "$ANVIL_PID_FILE" ]; then
    PID=$(cat $ANVIL_PID_FILE)
    if ps -p $PID > /dev/null; then
      echo "Anvil instance is already running with PID $PID"
      return 0
    else
      echo "PID file exists but process is not running. Cleaning up."
      rm -f $ANVIL_PID_FILE
      return 1
    fi
  fi
  return 1
}

# Function to get the latest block number
get_latest_block() {
  echo "Getting latest block from $UNICHAIN_RPC_URL..."
  BLOCK_HEX=$(curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    $UNICHAIN_RPC_URL | grep -o '"result":"0x[^"]*' | sed 's/"result":"//g')
  
  if [[ $BLOCK_HEX != "" ]]; then
    BLOCK_NUMBER=$((16#${BLOCK_HEX:2}))
    echo "Latest block is $BLOCK_NUMBER ($BLOCK_HEX)"
    return 0
  else
    echo "Failed to get latest block number. Exiting."
    exit 1
  fi
}

# Function to start Anvil with the fork
start_anvil() {
  echo "Starting Anvil with fork from block $BLOCK_NUMBER..."
  
  # Record block info to file for future reference
  echo "BLOCK_NUMBER=$BLOCK_NUMBER" > $BLOCK_INFO_FILE
  echo "BLOCK_HEX=$BLOCK_HEX" >> $BLOCK_INFO_FILE
  echo "FORK_URL=$UNICHAIN_RPC_URL" >> $BLOCK_INFO_FILE
  
  # Start Anvil with improved configuration
  anvil --fork-url $UNICHAIN_RPC_URL \
        --fork-block-number $BLOCK_NUMBER \
        --host $ANVIL_HOST \
        --port $ANVIL_PORT \
        --accounts 10 \
        --balance 1000 \
        --hardfork cancun \
        --tracing &
  
  ANVIL_PID=$!
  echo $ANVIL_PID > $ANVIL_PID_FILE
  
  echo "Anvil started with PID $ANVIL_PID at block $BLOCK_NUMBER"
  echo "Waiting for Anvil to initialize..."
  sleep 5
  
  # Verify Anvil is running correctly
  ANVIL_CHECK=$(curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    http://$ANVIL_HOST:$ANVIL_PORT)
  
  if [[ $ANVIL_CHECK == *"$BLOCK_HEX"* ]]; then
    echo "Anvil is running successfully at block $BLOCK_NUMBER"
    echo "Anvil RPC endpoint: http://$ANVIL_HOST:$ANVIL_PORT"
    echo "To deploy to this fork, use:"
    echo "forge script script/DeployUnichainV4.s.sol:DeployUnichainV4 --rpc-url http://$ANVIL_HOST:$ANVIL_PORT --private-key \$PRIVATE_KEY --broadcast -vvv"
    return 0
  else
    echo "Anvil failed to start properly. Response: $ANVIL_CHECK"
    kill $ANVIL_PID
    rm -f $ANVIL_PID_FILE
    exit 1
  fi
}

# Function to stop Anvil
stop_anvil() {
  if [ -f "$ANVIL_PID_FILE" ]; then
    PID=$(cat $ANVIL_PID_FILE)
    echo "Stopping Anvil with PID $PID..."
    kill $PID
    rm -f $ANVIL_PID_FILE
    echo "Anvil stopped"
  else
    echo "No Anvil instance found"
  fi
}

# Main script logic
if [ "$1" == "stop" ]; then
  stop_anvil
  exit 0
fi

if check_anvil_running; then
  echo "Using existing Anvil instance"
  if [ -f "$BLOCK_INFO_FILE" ]; then
    source $BLOCK_INFO_FILE
    echo "Fork is running at block $BLOCK_NUMBER ($BLOCK_HEX)"
    echo "Anvil RPC endpoint: http://$ANVIL_HOST:$ANVIL_PORT"
    echo "To deploy to this fork, use:"
    echo "forge script script/DeployUnichainV4.s.sol:DeployUnichainV4 --rpc-url http://$ANVIL_HOST:$ANVIL_PORT --private-key \$PRIVATE_KEY --broadcast -vvv"
  else
    echo "Block info file not found. Anvil is running but block info is unknown."
  fi
else
  # Get latest block and start Anvil
  get_latest_block
  start_anvil
fi

# Instructions for stopping the fork
echo ""
echo "To stop the fork, run: ./persistent-fork.sh stop" 