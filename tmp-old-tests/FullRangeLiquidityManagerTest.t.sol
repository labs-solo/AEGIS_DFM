// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/*
 * This test file has been moved to old-tests and commented out.
 * It is kept for reference but is no longer used in the project.
 * The new testing approach uses LocalUniswapV4TestBase.t.sol for local deployments.
 */

/*

/**
 * @title FullRangeLiquidityManagerTest
 * @notice Unit tests for deposit/withdraw logic in Phase 3,
 *         achieving 90%+ coverage. Updated for ERC6909Claims position tokens.
 */

import "forge-std/Test.sol";
import "../src/FullRangeLiquidityManager.sol";
import {FullRangePoolManager} from "../src/FullRangePoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {DepositParams, WithdrawParams, ModifyLiquidityParams} from "../src/interfaces/IFullRange.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Errors} from "../src/errors/Errors.sol";
import {FullRangePositions} from "../src/token/FullRangePositions.sol";
import {PoolTokenIdUtils} from "../src/utils/PoolTokenIdUtils.sol";

contract MockToken is Test {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public immutable decimals;
    
    constructor(uint8 _decimals) {
        decimals = _decimals;
    }
    
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] < amount) return false;
        if (balanceOf[from] < amount) return false;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockPoolManagerImpl is Test {
    mapping(bytes32 => PoolKey) public poolKeys;
    
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external pure returns (int24) {
        return 0;
    }
    
    function modifyLiquidity(
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hook
    ) external returns (BalanceDelta delta) {
        // Mock implementation - just return zero delta
        return BalanceDelta.wrap(0);
    }
    
    function take(Currency currency, address to, uint256 amount) external {
        // Mock implementation - mint tokens to represent taking from the pool
        MockToken(Currency.unwrap(currency)).mint(to, amount);
    }
    
    function settle(Currency currency) external {
        // Mock implementation - do nothing
    }
    
    // New function to handle callbacks from the LiquidityManager
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // Just return a zero balance delta
        return abi.encode(BalanceDelta.wrap(0));
    }
}

contract FullRangeLiquidityManagerTest is Test {
    FullRangeLiquidityManager liqManager;
    FullRangePoolManager poolManager;
    MockPoolManagerImpl mockPoolManagerImpl;
    MockToken token0;
    MockToken token1;
    address constant USER = address(0xABCD);
    PoolId testPoolId;

    function setUp() public {
        mockPoolManagerImpl = new MockPoolManagerImpl();
        
        // Create mock tokens
        token0 = new MockToken(18);
        token1 = new MockToken(18);
        
        // Set up test accounts
        vm.startPrank(USER);
        token0.mint(USER, 100000);
        token1.mint(USER, 100000);
        token0.approve(address(this), type(uint256).max);
        token1.approve(address(this), type(uint256).max);
        vm.stopPrank();
        
        poolManager = new FullRangePoolManager(IPoolManager(address(mockPoolManagerImpl)), address(this));
        liqManager = new FullRangeLiquidityManager(IPoolManager(address(mockPoolManagerImpl)), poolManager);
        
        // Set up a test pool
        testPoolId = PoolId.wrap(bytes32(keccak256("TestPoolID")));
        
        // Store the pool key for the test pool ID
        PoolKey memory poolKey = createMockPoolKey(0x800000);
        bytes32 poolIdBytes = PoolId.unwrap(testPoolId);
        
        // Mock the pool key lookup
        vm.mockCall(
            address(poolManager),
            abi.encodeWithSelector(poolManager.getPoolKey.selector, testPoolId),
            abi.encode(poolKey)
        );
        
        poolManager.updateTotalLiquidity(testPoolId, 0);
    }
    
    function createMockPoolKey(uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    // Updated tests that use the LiquidityManager's new depositWithPositions function
    function testDepositWithPositionsSuccess() public {
        // Fund user before deposit
        token0.mint(USER, 10000);
        token1.mint(USER, 10000);
        
        // Approve tokens to the liquidity manager
        vm.startPrank(USER);
        token0.approve(address(liqManager), 10000);
        token1.approve(address(liqManager), 10000);
        vm.stopPrank();
        
        // Create deposit params
        DepositParams memory params = DepositParams({
            poolId: testPoolId,
            amount0Desired: 1000,
            amount1Desired: 2000,
            amount0Min: 800,
            amount1Min: 1800,
            to: USER,
            deadline: block.timestamp + 1 hours
        });
        
        // Perform deposit
        vm.startPrank(USER);
        (BalanceDelta delta, uint256 sharesMinted) = liqManager.depositWithPositions(params, USER);
        vm.stopPrank();
        
        // Verify results
        assertEq(BalanceDelta.unwrap(delta), 0, "Delta should be zero for mock implementation");
        
        (bool hasAccruedFees, uint128 totalLiq, int24 tickSpacing) = poolManager.poolInfo(testPoolId);
        uint256 expectedShares = FullRangeRatioMath.sqrt(1000 * 2000);
        
        assertEq(totalLiq, expectedShares, "Total liquidity should match expected shares");
        assertEq(sharesMinted, expectedShares, "Shares minted should match expected");
        
        // Verify position tokens were minted
        uint256 tokenId = PoolTokenIdUtils.toTokenId(testPoolId);
        uint256 userPositionBalance = liqManager.positions().balanceOf(USER, tokenId);
        assertEq(userPositionBalance, expectedShares, "User should have received position tokens");
    }
    
    function testWithdrawWithPositionsSuccess() public {
        // First set up a position by depositing
        testDepositWithPositionsSuccess();
        
        // Get user's position balance
        uint256 userShares = liqManager.userShares(testPoolId, USER);
        uint256 sharesToBurn = userShares / 2; // Withdraw 50%
        
        // Create withdraw params
        WithdrawParams memory params = WithdrawParams({
            poolId: testPoolId,
            sharesBurn: sharesToBurn,
            amount0Min: 100,
            amount1Min: 100,
            deadline: block.timestamp + 1 hours
        });
        
        // Perform withdraw
        vm.startPrank(USER);
        (BalanceDelta delta, uint256 amount0Out, uint256 amount1Out) = liqManager.withdrawWithPositions(params, USER);
        vm.stopPrank();
        
        // Verify results
        assertEq(BalanceDelta.unwrap(delta), 0, "Delta should be zero for mock implementation");
        
        // Verify position tokens were burned
        uint256 tokenId = PoolTokenIdUtils.toTokenId(testPoolId);
        uint256 userPositionBalanceAfter = liqManager.positions().balanceOf(USER, tokenId);
        assertEq(userPositionBalanceAfter, userShares - sharesToBurn, "Position tokens should have been burned");
    }
    
    function testPositionTransfer() public {
        // First set up a position by depositing
        testDepositWithPositionsSuccess();
        
        // Get user's position balance
        uint256 userShares = liqManager.userShares(testPoolId, USER);
        
        // Set up a recipient
        address recipient = address(0xBEEF);
        uint256 amountToTransfer = userShares / 2;
        
        // Transfer position tokens
        vm.startPrank(USER);
        uint256 tokenId = PoolTokenIdUtils.toTokenId(testPoolId);
        liqManager.positions().transferFrom(USER, recipient, tokenId, amountToTransfer);
        vm.stopPrank();
        
        // Verify balances
        uint256 userBalanceAfter = liqManager.positions().balanceOf(USER, tokenId);
        uint256 recipientBalance = liqManager.positions().balanceOf(recipient, tokenId);
        
        assertEq(userBalanceAfter, userShares - amountToTransfer, "User position balance should have decreased");
        assertEq(recipientBalance, amountToTransfer, "Recipient should have received position tokens");
    }
    
    function testUnlockCallback() public {
        // Create test data
        FullRangeLiquidityManager.CallbackDataInternal memory callbackData = 
            FullRangeLiquidityManager.CallbackDataInternal({
                callbackType: 1, // Deposit
                sender: USER,
                poolId: testPoolId,
                amount0: 1000,
                amount1: 2000,
                shares: 1414 // sqrt(1000 * 2000)
            });
        
        bytes memory encodedData = abi.encode(callbackData);
        
        // Mock successful token transfer (needed for the callback)
        vm.mockCall(
            address(token0),
            abi.encodeWithSelector(token0.transferFrom.selector, USER, address(liqManager), 1000),
            abi.encode(true)
        );
        
        vm.mockCall(
            address(token1),
            abi.encodeWithSelector(token1.transferFrom.selector, USER, address(liqManager), 2000),
            abi.encode(true)
        );
        
        // Test callback - should revert if not called by pool manager
        vm.expectRevert(abi.encodeWithSelector(Errors.HookNotCalledByPoolManager.selector, address(this)));
        liqManager.unlockCallback(encodedData);
        
        // Test with correct caller
        vm.prank(address(mockPoolManagerImpl));
        bytes memory returnData = liqManager.unlockCallback(encodedData);
        
        // Verify return value contains balance delta
        BalanceDelta delta = abi.decode(returnData, (BalanceDelta));
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();
        
        assertEq(delta0, int128(int256(1000)), "Delta0 should match input amount");
        assertEq(delta1, int128(int256(2000)), "Delta1 should match input amount");
    }
    
    function testReinvestFees() public {
        // First set up a position
        testDepositWithPositionsSuccess();
        
        // Mock token balances to simulate collected fees
        token0.mint(address(liqManager), 100);
        token1.mint(address(liqManager), 200);
        
        // Mock the pool manager call permission
        vm.mockCall(
            address(poolManager),
            abi.encodeWithSelector(poolManager.getPoolKey.selector, testPoolId),
            abi.encode(createMockPoolKey(0x800000))
        );
        
        // Call reinvestFees - should revert if not called by pool manager
        vm.expectRevert(abi.encodeWithSelector(Errors.AccessNotAuthorized.selector, address(this)));
        liqManager.reinvestFees(testPoolId);
        
        // Call with proper permissions
        vm.prank(address(poolManager));
        liqManager.reinvestFees(testPoolId);
        
        // Verify reserves were updated (can't easily verify the emission of FeesReinvested event in this test)
        bytes32 poolIdBytes = PoolId.unwrap(testPoolId);
        assertEq(liqManager.token0Reserves(poolIdBytes), 1000 + 100, "Token0 reserves should include fees");
        assertEq(liqManager.token1Reserves(poolIdBytes), 2000 + 200, "Token1 reserves should include fees");
    }
    
    // Keep the original tests for backward compatibility
    function testDepositSuccess() public {
        // Fund user before deposit
        token0.mint(USER, 10000);
        token1.mint(USER, 10000);
        
        // Approve tokens to the liquidity manager
        vm.startPrank(USER);
        token0.approve(address(liqManager), 10000);
        token1.approve(address(liqManager), 10000);
        vm.stopPrank();
        
        // Create deposit params
        DepositParams memory params = DepositParams({
            poolId: testPoolId,
            amount0Desired: 1000,
            amount1Desired: 2000,
            amount0Min: 800,
            amount1Min: 1800,
            to: USER,
            deadline: block.timestamp + 1 hours
        });
        
        // Perform deposit
        vm.startPrank(USER);
        BalanceDelta delta = liqManager.deposit(params, USER);
        vm.stopPrank();
        
        // Verify results
        assertEq(BalanceDelta.unwrap(delta), 0, "Delta should be zero for mock implementation");
        (bool hasAccruedFees, uint128 totalLiq, ) = poolManager.poolInfo(testPoolId);
        uint256 expectedShares = FullRangeRatioMath.sqrt(1000 * 2000);
        assertEq(totalLiq, expectedShares, "Total liquidity should match expected shares");
    }
    
    function testUserShares() public {
        // Set up initial position
        testDepositWithPositionsSuccess();
        
        // Check shares
        uint256 userShares = liqManager.userShares(testPoolId, USER);
        uint256 expectedShares = FullRangeRatioMath.sqrt(1000 * 2000);
        
        assertEq(userShares, expectedShares, "User shares should match expected amount");
        
        // Test non-existent position
        PoolId nonExistentPool = PoolId.wrap(bytes32(keccak256("NonExistentPool")));
        uint256 noShares = liqManager.userShares(nonExistentPool, USER);
        assertEq(noShares, 0, "Non-existent position should have zero shares");
    }
} 
*/
