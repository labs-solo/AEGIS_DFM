// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title FullRangeE2ETest
 * @notice End-to-End integration tests for FullRange on Unichain Sepolia testnet
 * This file implements all 7 phases of testing as described in Integration_Test.md
 * Phase 1: Environment Setup & Network Forking
 */

import "forge-std/Test.sol";
import "forge-std/console.sol";

// Project imports
import "../src/FullRange.sol";
import "../src/FullRangePoolManager.sol";
import "../src/FullRangeLiquidityManager.sol";
import "../src/FullRangeOracleManager.sol";
import "../src/FullRangeDynamicFeeManager.sol";
import "../src/FullRangeUtils.sol";
import "../src/interfaces/IFullRange.sol";

// Uniswap V4 imports
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";

// For hook address mining
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

// Token mocks
import "../test/utils/MockERC20.sol";

/**
 * @notice FullRangeE2ETestBase - Base contract for all E2E tests
 * Handles common setup and provides helper functions for all phases
 */
contract FullRangeE2ETestBase is Test {
    using PoolIdLibrary for PoolKey;

    // Test accounts
    address payable public alice = payable(address(0x1));
    address payable public bob = payable(address(0x2));
    address payable public charlie = payable(address(0x3));
    address payable public deployer = payable(address(0x4));
    address payable public governance = payable(address(0x5));

    // Initial balance for test accounts
    uint256 constant INITIAL_BALANCE = 100 ether;
    uint256 constant INITIAL_TOKEN_BALANCE = 1000 * 10**18;

    // Token instances
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public weth; // For later phases

    // Unichain Sepolia fork ID
    uint256 public forkId;
    uint256 public forkBlock;

    // Unichain Sepolia chain ID
    uint256 public constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

    // Uniswap V4 Unichain Sepolia Deployment Addresses - with correct checksums
    address public constant UNICHAIN_SEPOLIA_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address public constant UNICHAIN_SEPOLIA_UNIVERSAL_ROUTER = 0xf70536B3bcC1bD1a972dc186A2cf84cC6da6Be5D;
    address public constant UNICHAIN_SEPOLIA_POSITION_MANAGER = 0xf969Aee60879C54bAAed9F3eD26147Db216Fd664;
    address public constant UNICHAIN_SEPOLIA_STATE_VIEW = 0xc199F1072a74D4e905ABa1A84d9a45E2546B6222;
    address public constant UNICHAIN_SEPOLIA_QUOTER = 0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472;
    address public constant UNICHAIN_SEPOLIA_POOL_SWAP_TEST = 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4;
    address public constant UNICHAIN_SEPOLIA_POOL_MODIFY_LIQUIDITY_TEST = 0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB;
    
    // Environment status flags
    bool public environmentInitialized = false;

    // Deployment addresses for later phases
    address public poolManagerAddress;
    address public fullRangeAddress;

    function setUp() public virtual {
        // Step 1: Fork Unichain Sepolia testnet
        forkId = vm.createFork(vm.envString("UNICHAIN_SEPOLIA_RPC_URL"));
        vm.selectFork(forkId);
        forkBlock = block.number;
        
        console.log("Forked Unichain Sepolia at block:", forkBlock);
        assertEq(block.chainid, UNICHAIN_SEPOLIA_CHAIN_ID, "Not on Unichain Sepolia testnet");

        // Step 2: Set up test accounts with ETH
        _setupTestAccounts();
        
        // Step 3: Deploy mock tokens for testing
        _deployMockTokens();

        // Step 4: Mint tokens to test accounts
        _mintTokensToAccounts();

        // Set environment initialized flag
        environmentInitialized = true;

        // Log setup completion
        console.log("Test environment setup complete at Unichain Sepolia block:", forkBlock);
        console.log("Test accounts funded with ETH and tokens");
    }

    // Step 2: Set up test accounts with ETH
    function _setupTestAccounts() internal {
        vm.deal(alice, INITIAL_BALANCE);
        vm.deal(bob, INITIAL_BALANCE);
        vm.deal(charlie, INITIAL_BALANCE);
        vm.deal(deployer, INITIAL_BALANCE);
        vm.deal(governance, INITIAL_BALANCE);
        
        console.log("Test accounts funded with ETH");
    }

    // Step 3: Deploy mock tokens for testing
    function _deployMockTokens() internal {
        vm.startPrank(deployer);
        
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        
        vm.stopPrank();
        
        console.log("Mock tokens deployed:");
        console.log("TokenA:", address(tokenA));
        console.log("TokenB:", address(tokenB));
        console.log("WETH:", address(weth));
    }

    // Step 4: Mint tokens to test accounts
    function _mintTokensToAccounts() internal {
        vm.startPrank(deployer);
        
        // Mint tokens to Alice
        tokenA.mint(alice, INITIAL_TOKEN_BALANCE);
        tokenB.mint(alice, INITIAL_TOKEN_BALANCE);
        weth.mint(alice, INITIAL_TOKEN_BALANCE);
        
        // Mint tokens to Bob
        tokenA.mint(bob, INITIAL_TOKEN_BALANCE);
        tokenB.mint(bob, INITIAL_TOKEN_BALANCE);
        weth.mint(bob, INITIAL_TOKEN_BALANCE);
        
        // Mint tokens to Charlie
        tokenA.mint(charlie, INITIAL_TOKEN_BALANCE);
        tokenB.mint(charlie, INITIAL_TOKEN_BALANCE);
        weth.mint(charlie, INITIAL_TOKEN_BALANCE);
        
        // Mint tokens to Governance
        tokenA.mint(governance, INITIAL_TOKEN_BALANCE);
        tokenB.mint(governance, INITIAL_TOKEN_BALANCE);
        weth.mint(governance, INITIAL_TOKEN_BALANCE);
        
        vm.stopPrank();
        
        console.log("Tokens minted to test accounts");
    }

    // Helper function to validate account token balances
    function _validateAccountBalances() internal view {
        // Validate Alice's balances
        assertEq(alice.balance, INITIAL_BALANCE, "Alice ETH balance incorrect");
        assertEq(tokenA.balanceOf(alice), INITIAL_TOKEN_BALANCE, "Alice TokenA balance incorrect");
        assertEq(tokenB.balanceOf(alice), INITIAL_TOKEN_BALANCE, "Alice TokenB balance incorrect");
        assertEq(weth.balanceOf(alice), INITIAL_TOKEN_BALANCE, "Alice WETH balance incorrect");
        
        // Validate Bob's balances
        assertEq(bob.balance, INITIAL_BALANCE, "Bob ETH balance incorrect");
        assertEq(tokenA.balanceOf(bob), INITIAL_TOKEN_BALANCE, "Bob TokenA balance incorrect");
        assertEq(tokenB.balanceOf(bob), INITIAL_TOKEN_BALANCE, "Bob TokenB balance incorrect");
        assertEq(weth.balanceOf(bob), INITIAL_TOKEN_BALANCE, "Bob WETH balance incorrect");
        
        // Validate Charlie's balances
        assertEq(charlie.balance, INITIAL_BALANCE, "Charlie ETH balance incorrect");
        assertEq(tokenA.balanceOf(charlie), INITIAL_TOKEN_BALANCE, "Charlie TokenA balance incorrect");
        assertEq(tokenB.balanceOf(charlie), INITIAL_TOKEN_BALANCE, "Charlie TokenB balance incorrect");
        assertEq(weth.balanceOf(charlie), INITIAL_TOKEN_BALANCE, "Charlie WETH balance incorrect");
    }

    // Helper function to advance blocks (useful for later phases)
    function _advanceBlocks(uint256 _blocks) internal {
        for (uint256 i = 0; i < _blocks; i++) {
            vm.roll(block.number + 1);
        }
    }

    // Helper function to simulate price volatility (useful for later phases)
    function _simulateVolatility() internal {
        // Will be implemented in later phases
    }
}

/**
 * @notice FullRangeE2ETest - Implementation of all test phases
 */
contract FullRangeE2ETest is FullRangeE2ETestBase {
    /**
     * @notice Phase 1 Test: Environment Setup & Network Forking
     * This test validates that our Unichain Sepolia fork is working correctly
     * and that we have properly set up our test environment.
     */
    function testPhase1_EnvironmentSetup() public {
        // 1. Validate Unichain Sepolia network configuration
        assertEq(block.chainid, UNICHAIN_SEPOLIA_CHAIN_ID, "Not on Unichain Sepolia testnet");
        assertTrue(forkBlock > 0, "Fork block should be greater than 0");
        
        // 2. Validate environment initialization flag
        assertTrue(environmentInitialized, "Environment initialization failed");
        
        // 3. Validate test accounts have ETH
        assertGe(alice.balance, INITIAL_BALANCE, "Alice has insufficient ETH");
        assertGe(bob.balance, INITIAL_BALANCE, "Bob has insufficient ETH");
        assertGe(charlie.balance, INITIAL_BALANCE, "Charlie has insufficient ETH");
        assertGe(deployer.balance, INITIAL_BALANCE, "Deployer has insufficient ETH");
        assertGe(governance.balance, INITIAL_BALANCE, "Governance has insufficient ETH");
        
        // 4. Validate ERC20 token balances
        _validateAccountBalances();
        
        // 5. Test token transfers
        vm.startPrank(alice);
        tokenA.transfer(bob, 10 * 10**18);
        vm.stopPrank();
        
        assertEq(tokenA.balanceOf(alice), INITIAL_TOKEN_BALANCE - 10 * 10**18, "Alice TokenA balance after transfer incorrect");
        assertEq(tokenA.balanceOf(bob), INITIAL_TOKEN_BALANCE + 10 * 10**18, "Bob TokenA balance after transfer incorrect");
        
        // 6. Test state changes through block advancement
        uint256 initialBlock = block.number;
        _advanceBlocks(5);
        assertEq(block.number, initialBlock + 5, "Block advancement failed");
        
        // 7. Verify Uniswap V4 contracts on Unichain Sepolia
        assertTrue(address(UNICHAIN_SEPOLIA_POOL_MANAGER).code.length > 0, "PoolManager contract not found");
        assertTrue(address(UNICHAIN_SEPOLIA_UNIVERSAL_ROUTER).code.length > 0, "UniversalRouter contract not found");
        assertTrue(address(UNICHAIN_SEPOLIA_POSITION_MANAGER).code.length > 0, "PositionManager contract not found");
        
        console.log("Uniswap V4 contracts verified on Unichain Sepolia:");
        console.log("- PoolManager:", UNICHAIN_SEPOLIA_POOL_MANAGER);
        console.log("- PositionManager:", UNICHAIN_SEPOLIA_POSITION_MANAGER);
        console.log("- Universal Router:", UNICHAIN_SEPOLIA_UNIVERSAL_ROUTER);
        
        // Log success
        console.log("Phase 1 test passed: Environment successfully set up on Unichain Sepolia fork");
        console.log("Current block number:", block.number);
    }

    /**
     * @notice Phase 2 Test: FullRange Contract Suite Deployment
     * This test will be implemented in the next stage
     */
    function testPhase2_ContractDeployment() public {
        // TODO: Implement in next stage
        // Will deploy FullRange contract suite on Unichain Sepolia
    }

    /**
     * @notice Phase 3 Test: Pool Creation with Dynamic Fees
     * This test will be implemented in a future stage
     */
    function testPhase3_PoolCreation() public {
        // TODO: Implement in future stages
    }

    /**
     * @notice Phase 4 Test: Liquidity Management
     * This test will be implemented in a future stage
     */
    function testPhase4_LiquidityManagement() public {
        // TODO: Implement in future stages
    }

    /**
     * @notice Phase 5 Test: Swap Testing and Hook Callbacks
     * This test will be implemented in a future stage
     */
    function testPhase5_SwapAndHooks() public {
        // TODO: Implement in future stages
    }

    /**
     * @notice Phase 6 Test: Oracle Updates and Dynamic Fee Testing
     * This test will be implemented in a future stage
     */
    function testPhase6_OracleAndFees() public {
        // TODO: Implement in future stages
    }

    /**
     * @notice Phase 7 Test: End-to-End Flow and Stress Testing
     * This test will be implemented in a future stage
     */
    function testPhase7_EndToEndFlow() public {
        // TODO: Implement in future stages
    }
} 