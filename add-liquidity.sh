#!/bin/bash
set -e  # Exit on any error

# Script to add liquidity to the deployed FullRange pool

echo "====================================================="
echo "Adding liquidity to deployed pool at block number ${FORK_BLOCK_NUMBER:-13900000}"
echo "====================================================="

# Check if DEPLOYED_ADDRESS_FILE is provided
if [ -z "$DEPLOYED_ADDRESS_FILE" ]; then
  echo "Please set DEPLOYED_ADDRESS_FILE environment variable pointing to a file with deployed contract addresses."
  echo "For example: export DEPLOYED_ADDRESS_FILE=./deployed-addresses.txt"
  exit 1
fi

# Check for RPC URL
if [ -z "$UNICHAIN_MAINNET_RPC_URL" ]; then
  echo "Error: UNICHAIN_MAINNET_RPC_URL environment variable is not set"
  echo "Please set it with your Unichain Mainnet RPC URL, for example:"
  echo "export UNICHAIN_MAINNET_RPC_URL=https://rpc.unichain.io"
  exit 1
fi

# Check for private key
if [ -z "$PRIVATE_KEY" ]; then
  echo "Error: PRIVATE_KEY environment variable is not set"
  exit 1
fi

# Use block 13900000 as the default fork point
FORK_BLOCK_NUMBER=${FORK_BLOCK_NUMBER:-"13900000"}

# Read deployed addresses
if [ ! -f "$DEPLOYED_ADDRESS_FILE" ]; then
  echo "Deployed address file not found: $DEPLOYED_ADDRESS_FILE"
  exit 1
fi

# Extract addresses from the file
LP_ROUTER=$(grep "LiquidityRouter" "$DEPLOYED_ADDRESS_FILE" | sed 's/.*: \(0x[a-fA-F0-9]*\).*/\1/')
HOOK_ADDRESS=$(grep "FullRange Hook" "$DEPLOYED_ADDRESS_FILE" | sed 's/.*: \(0x[a-fA-F0-9]*\).*/\1/')
POOL_MANAGER=$(grep "Unichain PoolManager" "$DEPLOYED_ADDRESS_FILE" | sed 's/.*: \(0x[a-fA-F0-9]*\).*/\1/')

if [ -z "$LP_ROUTER" ] || [ -z "$HOOK_ADDRESS" ] || [ -z "$POOL_MANAGER" ]; then
  echo "Could not find all required contract addresses in $DEPLOYED_ADDRESS_FILE"
  echo "LP Router: $LP_ROUTER"
  echo "Hook Address: $HOOK_ADDRESS"
  echo "Pool Manager: $POOL_MANAGER"
  exit 1
fi

echo "Using LP Router address: $LP_ROUTER"
echo "Using FullRange Hook address: $HOOK_ADDRESS"
echo "Using Pool Manager address: $POOL_MANAGER"

# Check if port 8545 is already in use
if command -v nc &> /dev/null && nc -z localhost 8545 2>/dev/null; then
  echo "Error: Port 8545 is already in use. Another Anvil instance may be running."
  exit 1
fi

# Verify if the block is available
echo "Verifying block ${FORK_BLOCK_NUMBER} is available on the RPC..."
BLOCK_CHECK=$(curl -s -X POST -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"0x$(printf '%x' ${FORK_BLOCK_NUMBER})\", false],\"id\":1}" ${UNICHAIN_MAINNET_RPC_URL})
if [[ $BLOCK_CHECK == *"error"* ]]; then
  echo "Error: Block ${FORK_BLOCK_NUMBER} is not available on the RPC. Response: ${BLOCK_CHECK}"
  exit 1
fi

echo "All pre-flight checks passed. Starting Anvil with fork..."

# Start anvil with improved configuration
anvil --fork-url $UNICHAIN_MAINNET_RPC_URL --fork-block-number $FORK_BLOCK_NUMBER --accounts 10 --balance 1000 &
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

# Define token addresses
WETH="0x4200000000000000000000000000000000000006"
USDC="0x078D782b760474a361dDA0AF3839290b0EF57AD6"

# Current deployer address - derived from private key
DEPLOYER_ADDRESS=$(cast wallet address --private-key $PRIVATE_KEY)
echo "Using deployer address: $DEPLOYER_ADDRESS"

# Set up impersonation and fund account with tokens
echo "Setting up token funding for testing..."

# Impersonate a whale account for WETH
WETH_WHALE="0x0000000000000000000000000000000000000000" # You'll need to find a real WETH whale
if [[ "$WETH_WHALE" != "0x0000000000000000000000000000000000000000" ]]; then
  echo "Impersonating WETH whale and transferring tokens..."
  # Enable impersonation
  curl -s -X POST -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"method\":\"anvil_impersonateAccount\",\"params\":[\"$WETH_WHALE\"],\"id\":1}" http://localhost:8545 > /dev/null
  
  # Transfer WETH to our test account
  cast send --rpc-url http://localhost:8545 --from $WETH_WHALE $WETH "transfer(address,uint256)" $DEPLOYER_ADDRESS 10000000000000000000 > /dev/null || true
  
  # Disable impersonation
  curl -s -X POST -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"method\":\"anvil_stopImpersonatingAccount\",\"params\":[\"$WETH_WHALE\"],\"id\":1}" http://localhost:8545 > /dev/null
fi

# Use anvil_setBalance as a fallback when we don't have a whale
echo "Using anvil_setBalance to ensure the test account has ETH..."
curl -s -X POST -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"method\":\"anvil_setBalance\",\"params\":[\"$DEPLOYER_ADDRESS\", \"0x21E19E0C9BAB2400000\"],\"id\":1}" http://localhost:8545 > /dev/null

# Create a script to add liquidity using forge script
cat > script/AddLiquidity.s.sol << EOL
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import "forge-std/Script.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Spot} from "../src/Spot.sol";

contract AddLiquidity is Script {
    using CurrencyLibrary for Currency;
    
    // Same constants as in DeployUnichainV4.s.sol
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    address constant WETH = 0x4200000000000000000000000000000000000006; // WETH9 on Unichain
    address constant USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6; // Circle USDC on Unichain
    
    function run() external {
        // Use the addresses extracted from the deployment output
        address lpRouterAddress = $LP_ROUTER;
        address hookAddress = $HOOK_ADDRESS;
        address poolManagerAddress = $POOL_MANAGER;
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);
        
        // Create pool key
        address token0;
        address token1;
        if (uint160(WETH) < uint160(USDC)) {
            token0 = WETH;
            token1 = USDC;
        } else {
            token0 = USDC;
            token1 = WETH;
        }
        
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });
        
        // Add liquidity parameters (full range)
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -887272,  // Min tick
            tickUpper: 887272,   // Max tick
            liquidityDelta: 1000000000000000000, // 1 ETH worth of liquidity
            salt: bytes32(0)
        });
        
        PoolModifyLiquidityTest lpRouter = PoolModifyLiquidityTest(lpRouterAddress);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Mint WETH if needed for test wallets
        IWETH9(WETH).deposit{value: 2 ether}();
        
        // Approve tokens to the LP Router
        IERC20(WETH).approve(lpRouterAddress, type(uint256).max);
        if (token1 != address(0)) {
            IERC20(token1).approve(lpRouterAddress, type(uint256).max);
        }
        
        console.log("Starting balance WETH:", IERC20(WETH).balanceOf(deployerAddress));
        
        // Add liquidity
        lpRouter.modifyLiquidity(key, params, "");
        
        console.log("Successfully added liquidity to the pool");
        vm.stopBroadcast();
    }
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
EOL

# Compile and run the script
echo "Building project..."
forge build --use solc:0.8.27 || { echo "Build failed"; exit 1; }

echo "Running add liquidity script..."
forge script script/AddLiquidity.s.sol:AddLiquidity --rpc-url http://localhost:8545 --private-key $PRIVATE_KEY --broadcast -vvv || { echo "Add liquidity failed"; exit 1; }

echo "Liquidity added successfully!" 