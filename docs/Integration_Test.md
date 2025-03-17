<think>I need to divide the testing process for FullRange into 7 phases of approximately equal complexity. Let me think through what would be a logical progression of tests that build upon each other while maintaining similar complexity in each phase.

Here's a general approach for breaking down the comprehensive E2E testing:

1. **Setup & Environment Configuration**: Fork setup, deploying core contracts
2. **Pool Creation & Basic Validation**: Initialize dynamic fee pools
3. **Liquidity Management**: Test deposits and withdrawals
4. **Basic Swap Testing**: Perform swaps and validate hooks are called
5. **Oracle Update Testing**: Test oracle throttling and updates
6. **Dynamic Fee Testing**: Test fee adjustments and cap events
7. **Complex Scenario Testing**: Combine multiple operations to test the system under realistic conditions

Let me detail each phase with the specific files needed, test steps, and expected outcomes.</think># FullRange End-to-End Testing Plan: 7 Phases

Below is a comprehensive plan to test the FullRange hook system with Uniswap V4 in a real network simulation using Anvil. I've divided the testing into 7 phases of approximately equal complexity.

## Phase 1: Environment Setup & Network Forking ✅ COMPLETED

**Objective**: Create the testing framework and fork a real network environment.

**Status**: Completed successfully on Unichain Sepolia testnet.

**Accomplishments**:
- Created test environment with proper fork settings for Unichain Sepolia
- Set up 5 test accounts (alice, bob, charlie, deployer, governance) with ETH
- Deployed mock tokens (TokenA, TokenB, WETH) for testing
- Distributed tokens to all test accounts
- Implemented validation functions for balances and state
- Verified Uniswap V4 contracts on Unichain Sepolia:
  - PoolManager: 0x00B036B58a818B1BC34d502D3fE730Db729e62AC
  - PositionManager: 0xf969Aee60879C54bAAed9F3eD26147Db216Fd664
  - Universal Router: 0xf70536B3bcC1bD1a972dc186A2cf84cC6da6Be5D
  - StateView: 0xc199F1072a74D4e905ABa1A84d9a45E2546B6222
  - Quoter: 0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472

**Implementation Files**:
- test/FullRangeE2ETest.t.sol - Base setup and Phase 1 tests
- script/run_with_alchemy.sh - Test execution script

## Phase 2: FullRange Contract Suite Deployment ✅ COMPLETED

**Objective**: Deploy all FullRange components on the forked network.

**Status**: Completed successfully on Unichain Sepolia testnet.

**Accomplishments**:
- Implemented contract deployment workflow with proper constructor parameters
- Deployed component contracts:
  - FullRangePoolManager: Interface with Uniswap V4 PoolManager
  - FullRangeLiquidityManager: Manages liquidity positions
  - FullRangeOracleManager: Manages price oracle updates
  - FullRangeDynamicFeeManager: Controls dynamic fee adjustments
- Used HookMiner to find the right salt and deploy the hook with proper permissions
- Set up governance ownership structure with permissions
- Verified cross-contract references are correctly established
- Implemented verification functions to ensure proper deployment

**Implementation Files**:
- test/FullRangeE2ETest.t.sol - Includes _deployFullRangeContractSuite and testPhase2_ContractDeployment
- Added hook permission flags and dynamic fee constants

**Deployment Workflow**:
1. Deploy component contracts
2. Mine hook address with required permissions using HookMiner
3. Deploy the main FullRange hook with mined address
4. Set up permissions between contracts
5. Transfer governance to the proper address
6. Verify deployment with functional tests

## Phase 3: Pool Creation with Dynamic Fees 🔄 IN PROGRESS

**Objective**: Test the creation of Uniswap V4 pools with dynamic fees.

**Files to Review:**
- `src/interfaces/IFullRange.sol` - For interface definitions
- `src/FullRangePoolManager.sol` - For pool creation logic
- `test/FullRangePoolManagerTest.t.sol` - For existing unit tests

**Implementation Steps:**
1. Create a pool with dynamic fee (0x800000)
2. Validate pool creation events are emitted
3. Verify pool is registered in PoolManager
4. Test reverting conditions (non-dynamic fee, unauthorized caller)
5. Validate initial state of the pool (tickSpacing, liquidity, etc.)

**Success Criteria:**
- Successful creation of pool with dynamic fee
- Proper events emitted
- Pool ID correctly generated and stored
- Failed pool creation with invalid parameters

## Phase 4: Liquidity Management

**Objective**: Test depositing and withdrawing liquidity.

**Files to Review:**
- `src/FullRangeLiquidityManager.sol` - For liquidity operations
- `test/FullRangeLiquidityManagerTest.t.sol` - For existing unit tests

**Implementation Steps:**
1. Test deposit functionality with various parameters
2. Validate proper token transfers during deposit
3. Test partial and full withdrawals
4. Verify fee collection and reinvestment
5. Test slippage protection
6. Validate deadline enforcement

**Success Criteria:**
- Successful deposits with correct token transfers
- Successful withdrawals with correct token transfers
- Proper handling of slippage requirements
- Deadline enforcement working correctly
- Fee reinvestment functioning

## Phase 5: Swap Testing and Hook Callbacks

**Objective**: Test swap functionality and verify hook callbacks are triggered.

**Files to Review:**
- `test/custom-accounting/ExampleHook.t.sol` - For swap testing examples
- `src/base/ExtendedBaseHook.sol` - For hook implementation
- `lib/v4-core/test/utils/Deployers.sol` - For swap helper functions

**Implementation Steps:**
1. Create event listeners to track hook callback executions
2. Perform various swaps (zeroForOne, oneForZero, exactInput, exactOutput)
3. Validate token transfers are correct
4. Verify hook callbacks are triggered (beforeSwap, afterSwap)
5. Test swap parameters (slippage, amounts, etc.)

**Success Criteria:**
- Successful swaps with correct token transfers
- Hook callbacks triggered correctly
- State updates performed after callbacks
- Slippage protection working correctly
- Events emitted as expected

## Phase 6: Oracle Updates and Dynamic Fee Testing

**Objective**: Test oracle updates and dynamic fee adjustments.

**Files to Review:**
- `src/FullRangeOracleManager.sol` - For oracle updates
- `src/FullRangeDynamicFeeManager.sol` - For dynamic fee logic
- `test/FullRangeOracleManagerTest.t.sol` - For existing oracle tests
- `test/FullRangeDynamicFeeManagerTest.t.sol` - For existing fee tests

**Implementation Steps:**
1. Test oracle updates after various operations
2. Verify oracle throttling works correctly
3. Simulate price volatility through consecutive swaps
4. Test dynamic fee adjustments based on volatility
5. Simulate cap events and verify fee surge multipliers
6. Test fee bounds enforcement

**Success Criteria:**
- Oracle updates performed correctly with throttling
- Dynamic fees adjusted based on volatility
- Cap events properly detected
- Surge multipliers applied correctly
- Fee bounds respected
- Proper events emitted during fee adjustments

## Phase 7: End-to-End Flow and Stress Testing

**Objective**: Perform comprehensive testing combining all components.

**Files to Review:**
- All previously reviewed files
- `test/FullRangeIntegrationTest.t.sol` - For existing integration tests

**Implementation Steps:**
1. Create a complete E2E scenario with:
   - Pool creation
   - Initial liquidity deposits
   - Multiple swaps to trigger volatility
   - Oracle updates
   - Dynamic fee adjustments
   - Withdrawals
   - Fee reinvestment
2. Test with both small and large amounts
3. Test with rapid, repeated operations
4. Validate state consistency after multiple operations
5. Test interaction with other contracts/users in the ecosystem

**Success Criteria:**
- Full lifecycle operations working correctly
- System stability under stress conditions
- Proper state management across multiple operations
- Gas optimization validation
- All events emitted correctly
- All expected state changes occurring correctly

## Running the Tests with Anvil

For each phase, add a deployment script that can be used to:
1. Start Anvil with appropriate fork parameters:
   ```
   anvil --fork-url $MAINNET_RPC_URL --fork-block-number 19000000
   ```

2. Run the test for each phase:
   ```
   forge test --match-path test/FullRangeE2ETest.t.sol --match-test "testPhase{N}" --fork-url http://localhost:8545
   ```

3. Monitor for expected outputs, events, and state changes

This phased approach allows you to build up complexity gradually, ensuring each component works correctly before moving to the next phase. Each phase builds on the previous one, ultimately culminating in a comprehensive end-to-end test that validates the entire system's functionality.
