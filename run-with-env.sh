#!/bin/bash
set -e  # Exit on any error

# Script to load .env variables and run a command

# Load environment from .env file
if [ -f .env ]; then
  echo "✅ Loading environment variables from .env file"
  set -a  # Mark all variables for export
  source .env
  set +a  # Stop marking for export
else
  echo "❌ Error: .env file not found. Please create one with required variables."
  echo "Required variables: UNICHAIN_MAINNET_RPC_URL, PRIVATE_KEY, FORK_BLOCK_NUMBER (optional)"
  exit 1
fi

# Verify required environment variables
if [ -z "$UNICHAIN_MAINNET_RPC_URL" ]; then
  echo "❌ Error: UNICHAIN_MAINNET_RPC_URL is not set in .env file"
  exit 1
fi

if [ -z "$PRIVATE_KEY" ]; then
  echo "❌ Error: PRIVATE_KEY is not set in .env file"
  exit 1
fi

# Set default fork block if not specified
if [ -z "$FORK_BLOCK_NUMBER" ]; then
  echo "ℹ️ FORK_BLOCK_NUMBER not specified, defaulting to 13900000"
  export FORK_BLOCK_NUMBER=13900000
fi

# Show current configuration
echo "╔════════════════════════════════════════════════╗"
echo "║ Environment Configuration:                     ║"
echo "╠════════════════════════════════════════════════╣"
echo "║ RPC URL: $(echo $UNICHAIN_MAINNET_RPC_URL | cut -c 1-40)... ║"
echo "║ Private Key: ***********$(echo $PRIVATE_KEY | cut -c 40-66) ║"
echo "║ Fork Block: $FORK_BLOCK_NUMBER                          ║"
echo "╚════════════════════════════════════════════════╝"

# Check if a command was provided
if [ $# -eq 0 ]; then
  echo "❌ Error: No command specified."
  echo "Usage: ./run-with-env.sh <command> [args...]"
  echo "Examples:"
  echo "  ./run-with-env.sh ./deploy-to-unichain.sh"
  echo "  ./run-with-env.sh ./add-liquidity.sh"
  exit 1
fi

# Execute the specified command with all arguments
echo "🚀 Running command: $@"
"$@"

# Return the exit code of the command
exit $? 