# SoloHook: Deposit Function Specification

## Overview

The deposit function enables users to add liquidity to Uniswap V4 pools using the FullRange hook system. It supports both ERC20 tokens and native ETH, with automatic fee updates and reinvestment features.

## Function Signature

```solidity
function deposit(DepositParams calldata params)
    external
    override
    payable
    nonReentrant
    ensure(params.deadline)
    returns (BalanceDelta delta)
```

## Contract Flow

### 1. FullRange.sol

Entry point that coordinates the deposit process:

- Verifies transaction deadline isn't expired
- Prevents reentrancy attacks
- Updates dynamic fees if necessary
- Processes accumulated fee reinvestment
- Retrieves pool configuration data
- Delegates ETH handling and liquidity management to specialized contracts
- Returns balance delta to the caller

### 2. FullRangePoolManager.sol

Manages pool-related data and operations:

- Stores mappings between pool IDs and pool keys
- Provides `getPoolKey(poolId)` function to retrieve pool configuration
- Maintains registry of all FullRange-managed pools
- Tracks total liquidity amounts per pool

### 3. FullRangeDynamicFeeManager.sol

Handles fee calculations and updates:

- Determines appropriate fee based on market conditions
- Calculates surge fees during capital allocation preference events
- Uses historical data to optimize fee settings
- Works with oracle data to detect volatility events

### 4. FullRangeOracleManager.sol

Monitors and processes oracle data:

- Detects capital allocation preference (CAP) events
- Tracks historical tick data
- Provides price movement indicators for fee adjustments

### 5. FeeReinvestmentManager.sol

Manages protocol-owned liquidity:

- Claims accumulated trading fees from pools
- Converts fee tokens to additional liquidity
- Reinvests fees back into the pool when beneficial
- Optimizes gas usage through threshold-based execution

### 6. FullRangeLiquidityManager.sol

Core liquidity operations manager:

- Handles token transfers (both ERC20 and ETH)
- Validates deposit parameters and amounts
- Calculates fair share allocation for depositors
- Interacts with Uniswap V4 PoolManager for liquidity addition
- Updates reserve tracking for proper share calculations
- Mints position tokens representing liquidity ownership

#### Key Functions:

##### handleDepositWithEth
- Validates ETH amounts for ETH-based pools
- Transfers ERC20 tokens from users to the contract
- Refunds excess ETH if more was sent than needed
- Delegates to depositWithPositions for core liquidity operations

##### depositWithPositions
- Calculates appropriate token amounts and shares
- Enforces slippage protection
- Approves tokens to the PoolManager
- Adds liquidity to the Uniswap V4 pool
- Updates internal reserve tracking
- Mints ERC6909 position tokens to the user

### 7. FullRangePositions.sol

ERC6909 token contract for position management:

- Mints position tokens representing liquidity share
- Allows for trading, transferring and burning of positions
- Associates positions with specific pool IDs using token IDs

### 8. Uniswap V4 PoolManager

Core Uniswap protocol contract that:

- Manages actual token reserves in the pool
- Executes liquidity addition operations
- Calculates balance deltas during operations
- Handles token settlement during the process

## Execution Branches

1. **Initial Fee Setup vs. Fee Update**
   - First interaction with a pool initializes default fee (0.3%)
   - Subsequent interactions may update fees based on time interval and market conditions

2. **Fee Reinvestment Modes**
   - ALWAYS: Reinvest fees with every deposit
   - THRESHOLD_CHECK: Reinvest only when gas-efficient
   - NEVER: Skip fee reinvestment

3. **ETH vs. ERC20 Deposits**
   - ETH deposits: Validate msg.value, handle refunds
   - ERC20-only deposits: Require zero msg.value, standard transfers

4. **Initial vs. Subsequent Deposits**
   - First deposit: Uses sqrt product formula for share calculation
   - Later deposits: Proportional allocation based on reserves

## Token Flow

1. User provides tokens (ETH and/or ERC20) in the deposit transaction
2. FullRange delegates to LiquidityManager for token handling
3. LiquidityManager transfers ERC20 tokens and validates ETH amounts
4. Tokens are approved to the Uniswap PoolManager
5. PoolManager adjusts internal accounting for added liquidity
6. Position tokens are minted to the user representing their share

## State Updates

1. Dynamic fee parameters when conditions warrant
2. Pool reserves in LiquidityManager's tracking
3. Total liquidity amount in PoolManager
4. User's position token balance

## Error Handling

The deposit function includes comprehensive error handling for:

- ETH validation mismatches
- Token transfer failures
- Slippage protection violations
- Deadline expirations
- Reentrancy attacks
- Zero amount checks

## Gas Optimization

Several optimization techniques are employed:

- Delegated logic to specialized contracts
- Cached storage reads for pool information
- Precomputed constants for range boundaries
- Conditional fee reinvestment based on thresholds
- Optimized ETH handling

# SoloHook: Withdraw Function Specification

## Overview

The withdraw function enables users to remove liquidity from Uniswap V4 pools, returning both ERC20 tokens and native ETH as appropriate. It handles position token burning, liquidity removal, and fee reinvestment in a gas-optimized manner.

## Function Signature

```solidity
function withdraw(WithdrawParams calldata params)
    external
    override
    nonReentrant
    returns (BalanceDelta delta, uint256 amount0Out, uint256 amount1Out)
```

## Contract Flow

### 1. FullRange.sol

Entry point that coordinates the withdrawal process:

- Prevents reentrancy attacks with nonReentrant modifier
- Updates dynamic fees if necessary
- Burns position tokens representing user's liquidity share
- Delegates token retrieval and transfers to specialized contracts
- Processes accumulated fee reinvestment after withdrawal
- Returns balance delta and token amounts to the caller

### 2. FullRangePoolManager.sol

Manages pool configuration data:

- Provides pool key information via `getPoolKey(poolId)`
- Maintains registry of pool information
- Updates total liquidity amount after withdrawal
- Stores mappings between pool IDs and pool keys

### 3. FullRangeDynamicFeeManager.sol

Handles fee updates before withdrawal:

- Updates dynamic fees based on time intervals
- Calculates appropriate fees based on market conditions
- Detects and responds to market volatility

### 4. FullRangePositions.sol

ERC6909 token contract that:

- Verifies user has sufficient position tokens
- Burns the appropriate amount of position tokens
- Validates ownership before withdrawal process

### 5. FullRangeLiquidityManager.sol

Core liquidity management contract that:

- Calculates token amounts based on share of total liquidity
- Enforces slippage protection using minAmount parameters
- Interfaces with Uniswap V4 PoolManager for liquidity removal
- Updates internal reserve tracking
- Handles token transfers (both ERC20 and native ETH)

#### Key Functions:

##### withdrawWithPositions
- Validates withdrawal parameters
- Calculates token amounts using ratio mathematics
- Enforces slippage protection
- Removes liquidity from the Uniswap pool
- Updates reserve tracking
- Produces events for withdrawal tracking

##### handleWithdrawWithEth
- Calls withdrawWithPositions for core withdrawal operation
- Determines token types (ETH vs ERC20)
- Handles token transfers back to user
- Manages ETH transfers with appropriate error handling
- Returns final balance delta and token amounts

### 6. FeeReinvestmentManager.sol

Handles post-withdrawal fee processing:

- Potentially claims and reinvests fees based on reinvestment mode
- Optimizes gas usage through threshold-based execution
- Manages protocol-owned liquidity (POL)

### 7. Uniswap V4 PoolManager

Core Uniswap protocol that:

- Processes liquidity removal requests
- Calculates balance deltas for token movements
- Returns tokens to the hook contract for distribution
- Updates pool state after withdrawal

## Execution Branches

1. **Fee Updates**
   - Checks if dynamic fee update is needed based on time interval
   - Updates fee parameters if triggered by market conditions

2. **ETH vs. ERC20 Handling**
   - ETH tokens: Uses special ETH transfer mechanisms
   - ERC20 tokens: Uses standard safeTransfer

3. **Fee Reinvestment**
   - ALWAYS: Reinvests fees after every withdrawal
   - THRESHOLD_CHECK: Reinvests only when gas-efficient
   - NEVER: Skips fee reinvestment entirely

4. **Complete vs. Partial Withdrawals**
   - Complete: User withdraws all their liquidity
   - Partial: User withdraws only a portion, maintaining some position

## Token Flow

1. User initiates withdrawal by specifying amount of shares to burn
2. FullRange burns position tokens directly
3. LiquidityManager calculates token amounts proportionally
4. Uniswap PoolManager releases tokens from the pool
5. Tokens are transferred back to the user (ETH or ERC20)
6. Fee reinvestment may occur with remaining pool fees

## State Updates

1. User's position token balance is reduced
2. Pool reserves in LiquidityManager are decreased
3. Total liquidity in PoolManager is updated
4. Dynamic fee parameters may be updated

## Error Handling

The withdraw function includes comprehensive error handling for:

- Reentrancy attacks prevention
- Zero amount validation (prevents empty withdrawals)
- Insufficient shares validation
- Slippage protection enforcement
- ETH transfer failure handling
- Insufficient liquidity protection

## Gas Optimization

Several optimization techniques are employed:

- Position token burning before liquidity removal
- Delegated logic to specialized contracts
- Single pool key lookup
- Cached storage values
- Batched state updates
- Conditional fee reinvestment
