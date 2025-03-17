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
    bool public contractsDeployed = false;
    bool public poolsCreated = false;
    bool public liquidityAdded = false;

    // Deployment addresses for later phases
    address public poolManagerAddress;
    address public fullRangeAddress;
    
    // FullRange contract instances
    FullRange public fullRange;
    FullRangePoolManager public poolManagerContract;
    FullRangeLiquidityManager public liquidityManager;
    FullRangeOracleManager public oracleManager;
    FullRangeDynamicFeeManager public dynamicFeeManager;
    
    // Pool IDs for created pools
    PoolId public tokenATokenBPoolId;
    PoolId public tokenAWETHPoolId;
    
    // Reference the standard Hooks flags from Uniswap v4-core library
    // Rather than local definitions that don't match Uniswap's implementation
    
    // Dynamic fee constants
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    uint24 internal constant MIN_DYNAMIC_FEE = 100; // 0.01%
    uint24 internal constant MAX_DYNAMIC_FEE = 100000; // 10%
    uint24 internal constant BASE_FEE = 3000; // 0.3%
    uint24 internal constant SURGE_MULTIPLIER = 10; // 10x fee multiplier during high volatility

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
        uint256 startBlock = block.number;
        vm.roll(startBlock + _blocks);
        console.log("Advanced blocks from %d to %d", startBlock, block.number);
    }

    // Helper function to simulate price volatility (useful for later phases)
    function _simulateVolatility() internal {
        // Will be implemented in later phases
    }

    /**
     * @notice Phase 2 - Deploy the FullRange contract suite
     * @dev This function deploys all required contracts and sets up permissions
     * @return hookAddress The address of the deployed FullRange hook
     */
    function _deployFullRangeContractSuite() internal returns (address hookAddress) {
        console.log("Starting FullRange contract suite deployment");
        
        // Deploy contracts as the deployer
        vm.startPrank(deployer);
        
        // 1. First deploy the component contracts
        console.log("Deploying component contracts...");
        
        // Deploy pool manager with the Uniswap V4 Pool Manager reference and governance
        poolManagerContract = new FullRangePoolManager(
            IPoolManager(UNICHAIN_SEPOLIA_POOL_MANAGER),
            governance
        );
        console.log("FullRangePoolManager deployed at:", address(poolManagerContract));
        
        // Deploy liquidity manager with the Uniswap V4 Pool Manager and our pool manager
        liquidityManager = new FullRangeLiquidityManager(
            IPoolManager(UNICHAIN_SEPOLIA_POOL_MANAGER),
            poolManagerContract
        );
        console.log("FullRangeLiquidityManager deployed at:", address(liquidityManager));
        
        // Deploy oracle manager
        oracleManager = new FullRangeOracleManager(
            IPoolManager(UNICHAIN_SEPOLIA_POOL_MANAGER),
            address(0) // placeholder for TruncGeoOracleMulti 
        );
        console.log("FullRangeOracleManager deployed at:", address(oracleManager));
        
        // Deploy dynamic fee manager (min fee, max fee, surge multiplier)
        dynamicFeeManager = new FullRangeDynamicFeeManager(
            MIN_DYNAMIC_FEE,
            MAX_DYNAMIC_FEE,
            SURGE_MULTIPLIER
        );
        console.log("FullRangeDynamicFeeManager deployed at:", address(dynamicFeeManager));
        
        // 2. Calculate the FullRange hook address with required permissions
        console.log("Mining hook address with required permissions...");
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | 
            Hooks.AFTER_INITIALIZE_FLAG | 
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | 
            Hooks.AFTER_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_DONATE_FLAG |
            Hooks.AFTER_DONATE_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG |
            Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        
        // Get salt and hook address from HookMiner
        (address hookAddr, bytes32 salt) = HookMiner.find(
            deployer,
            flags,
            type(FullRange).creationCode,
            abi.encode(
                IPoolManager(UNICHAIN_SEPOLIA_POOL_MANAGER),
                poolManagerContract,
                liquidityManager,
                oracleManager,
                dynamicFeeManager,
                governance
            )
        );
        
        console.log("Hook address mined:", hookAddr);
        console.log("Salt used:", uint256(salt));
        
        // 3. Deploy the FullRange hook with the mined address
        console.log("Deploying FullRange hook...");
        fullRange = new FullRange{salt: salt}(
            IPoolManager(UNICHAIN_SEPOLIA_POOL_MANAGER),
            poolManagerContract,
            liquidityManager,
            oracleManager,
            dynamicFeeManager,
            governance
        );
        
        hookAddress = address(fullRange);
        fullRangeAddress = hookAddress;
        
        console.log("FullRange hook deployed at:", hookAddress);
        
        // 4. Set up permissions between contracts
        console.log("Setting up permissions between contracts...");
        
        // Transfer ownership of dynamicFeeManager to governance
        dynamicFeeManager.transferOwnership(governance);
        
        vm.stopPrank();
        
        // Switch to governance for setting the FullRange address in pool manager
        vm.startPrank(governance);
        
        // Set FullRange hook address in pool manager
        console.log("Setting FullRange address in PoolManager as governance...");
        poolManagerContract.setFullRangeAddress(hookAddress);
        
        // Test a privileged operation as governance
        uint256 testMinFee = 0;
        uint256 testMaxFee = 10000;
        dynamicFeeManager.setFeeBounds(testMinFee, testMaxFee);
        
        // Verify the max fee was set
        assertEq(dynamicFeeManager.maxFeePpm(), testMaxFee, "Max fee not set correctly");
        assertEq(dynamicFeeManager.minFeePpm(), testMinFee, "Min fee not set correctly");
        
        vm.stopPrank();
        
        console.log("FullRange contract suite deployment complete");
        return hookAddress;
    }
    
    /**
     * @notice Verifies that the contract deployment was successful
     * @param hookAddress The address of the deployed FullRange hook
     */
    function _verifyContractDeployment(address hookAddress) internal view {
        // 1. Verify the hook address
        assertTrue(hookAddress != address(0), "Hook address is zero");
        assertTrue(hookAddress.code.length > 0, "No code at hook address");
        
        // 2. Verify permissions are set correctly
        assertEq(address(fullRange.poolManager()), UNICHAIN_SEPOLIA_POOL_MANAGER, "Incorrect pool manager address");
        assertEq(address(fullRange.fullRangePoolManager()), address(poolManagerContract), "Incorrect pool manager contract");
        assertEq(address(fullRange.liquidityManager()), address(liquidityManager), "Incorrect liquidity manager");
        assertEq(address(fullRange.oracleManager()), address(oracleManager), "Incorrect oracle manager");
        assertEq(address(fullRange.dynamicFeeManager()), address(dynamicFeeManager), "Incorrect fee manager");
        assertEq(fullRange.governance(), governance, "Incorrect governance");
        
        // 3. Verify cross-contract references
        assertEq(poolManagerContract.fullRangeAddress(), hookAddress, "Incorrect hook address in pool manager");
        
        // 4. Verify governance ownership
        assertEq(dynamicFeeManager.owner(), governance, "Incorrect dynamic fee manager owner");
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
     * This test validates the deployment of the FullRange contract suite on the forked network
     */
    function testPhase2_ContractDeployment() public {
        // First run Phase 1 setup
        testPhase1_EnvironmentSetup();
        
        console.log("==== Starting Phase 2: FullRange Contract Suite Deployment ====");
        
        // 1. Deploy the FullRange contract suite
        address hookAddress = _deployFullRangeContractSuite();
        
        // 2. Verify the deployment was successful
        _verifyContractDeployment(hookAddress);
        
        // 3. Test basic functionality
        vm.startPrank(governance);
        
        // Test dynamic fee manager
        uint24 newMaxFee = 200000; // 20%
        uint24 newMinFee = 100;    // 0.01%
        dynamicFeeManager.setFeeBounds(newMinFee, newMaxFee);
        assertEq(dynamicFeeManager.maxFeePpm(), newMaxFee, "Max fee not updated");
        assertEq(dynamicFeeManager.minFeePpm(), newMinFee, "Min fee not updated");
        
        // Test pool manager functionality
        PoolKey memory dummyKey = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        
        // Just verify we can call a function without error
        bytes32 dummyId = keccak256(abi.encode(dummyKey));
        PoolId poolId = PoolId.wrap(dummyId);
        
        vm.stopPrank();
        
        // Log success
        console.log("Phase 2 test passed: FullRange contract suite deployed successfully");
        console.log("Hook address:", hookAddress);
        console.log("==== Phase 2 Complete ====");
    }

    /**
     * @notice Phase 3 Test: Pool Creation with Dynamic Fees
     * This test validates creating pools with dynamic fees through FullRange
     */
    function testPhase3_PoolCreation() public {
        // First run Phase 2 to deploy our contracts
        testPhase2_ContractDeployment();
        
        console.log("==== Starting Phase 3: Pool Creation with Dynamic Fees ====");
        console.log("Current FullRange address:", fullRangeAddress);
        console.log("Creating pool with dynamic fees...");
        
        // We'll create pools as governance, since it has the proper permissions
        vm.startPrank(governance);
        
        // 1. Create first pool with TokenA and TokenB - use DYNAMIC_FEE_FLAG (0x800000)
        // Define pool key
        PoolKey memory poolKeyAB = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(fullRangeAddress) // Our FullRange contract is the hook
        });
        
        // Initial sqrt price (approx 1:1 price)
        uint160 initialSqrtPriceX96 = 79228162514264337593543950336; // 1:1 ratio
        
        // Initialize the pool
        console.log("Initializing TokenA/TokenB pool with dynamic fee...");
        PoolId poolIdAB = poolManagerContract.initializeNewPool(poolKeyAB, initialSqrtPriceX96);
        
        // Store the pool ID for later phases
        tokenATokenBPoolId = poolIdAB;
        
        console.log("Pool TokenA/TokenB created successfully");
        console.logBytes32(bytes32(poolIdAB)); // Direct cast to bytes32
        
        // Verify pool was created correctly
        (bool hasAccruedFees, uint128 totalLiquidity, int24 tickSpacing) = poolManagerContract.poolInfo(poolIdAB);
        
        console.log("Pool state - hasAccruedFees:", hasAccruedFees);
        console.log("Pool state - totalLiquidity:", totalLiquidity);
        console.log("Pool state - tickSpacing:", tickSpacing);
        
        // Assertions for first pool
        assertFalse(hasAccruedFees, "Pool should not have accrued fees initially");
        assertEq(totalLiquidity, 0, "Initial liquidity should be zero");
        assertEq(tickSpacing, 60, "Tick spacing should match the requested value");
        
        // 2. Create a second pool with TokenA and WETH
        PoolKey memory poolKeyAWETH = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(weth)),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(fullRangeAddress)
        });
        
        console.log("Initializing TokenA/WETH pool with dynamic fee...");
        PoolId poolIdAWETH = poolManagerContract.initializeNewPool(poolKeyAWETH, initialSqrtPriceX96);
        
        // Store the pool ID for later phases
        tokenAWETHPoolId = poolIdAWETH;
        
        console.log("Pool TokenA/WETH created successfully");
        console.logBytes32(bytes32(poolIdAWETH)); // Direct cast to bytes32
        
        // Verify second pool was created correctly
        (hasAccruedFees, totalLiquidity, tickSpacing) = poolManagerContract.poolInfo(poolIdAWETH);
        
        // Assertions for second pool
        assertFalse(hasAccruedFees, "WETH pool should not have accrued fees initially");
        assertEq(totalLiquidity, 0, "WETH pool initial liquidity should be zero");
        assertEq(tickSpacing, 60, "WETH pool tick spacing should match the requested value");
        
        // Test revert: Create a pool with non-dynamic fee
        PoolKey memory nonDynamicKey = PoolKey({
            currency0: Currency.wrap(address(tokenB)),
            currency1: Currency.wrap(address(weth)),
            fee: 3000, // Standard 0.3% fee
            tickSpacing: 60,
            hooks: IHooks(fullRangeAddress)
        });
        
        console.log("Testing revert: Attempting to create pool with non-dynamic fee...");
        vm.expectRevert(bytes("NotDynamicFee"));
        poolManagerContract.initializeNewPool(nonDynamicKey, initialSqrtPriceX96);
        console.log("Correctly reverted on non-dynamic fee");
        
        // End governance prank
        vm.stopPrank();
        
        // 5. Test revert: Non-governance caller attempt
        vm.startPrank(alice);
        
        console.log("Testing revert: Attempting to create pool as non-governance user...");
        vm.expectRevert(bytes("Only authorized accounts can call this function"));
        poolManagerContract.initializeNewPool(poolKeyAB, initialSqrtPriceX96);
        console.log("Correctly reverted on unauthorized caller");
        
        vm.stopPrank();
        
        // Store that pools were created
        poolsCreated = true;
        
        // Log success
        console.log("Phase 3 test passed: Successfully created pools with dynamic fees");
        console.log("TokenA/TokenB pool ID (bytes32):");
        console.logBytes32(bytes32(tokenATokenBPoolId));
        console.log("TokenA/WETH pool ID (bytes32):");
        console.logBytes32(bytes32(tokenAWETHPoolId));
        console.log("==== Phase 3 Complete ====");
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