// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IFullRange, DepositParams, WithdrawParams, CallbackData, ModifyLiquidityParams} from "../../src/interfaces/IFullRange.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/**
 * @title FullRangeMock
 * @notice A mock implementation of IFullRange for testing purposes
 */
contract FullRangeMock is IFullRange {
    using PoolIdLibrary for PoolKey;

    mapping(PoolId => bool) public initializedPools;

    function initializeNewPool(
        PoolKey calldata key,
        uint160 initialSqrtPriceX96
    ) external override returns (PoolId poolId) {
        // Simple mock implementation - generate a real poolId
        poolId = key.toId();
        initializedPools[poolId] = true;
        
        // Unused parameter to avoid compiler warning
        initialSqrtPriceX96;
        
        return poolId;
    }

    function deposit(DepositParams calldata params) 
        external 
        override 
        returns (BalanceDelta delta) 
    {
        require(initializedPools[params.poolId], "Pool not initialized");
        require(params.deadline >= block.timestamp, "Deadline expired");
        require(params.to != address(0), "Invalid recipient");
        require(params.amount0Desired >= params.amount0Min, "Invalid amount0");
        require(params.amount1Desired >= params.amount1Min, "Invalid amount1");
        
        // Return a dummy delta
        return toBalanceDelta(int128(int256(params.amount0Min)), int128(int256(params.amount1Min)));
    }

    function withdraw(WithdrawParams calldata params) 
        external 
        override 
        returns (BalanceDelta delta, uint256 amount0Out, uint256 amount1Out) 
    {
        require(initializedPools[params.poolId], "Pool not initialized");
        require(params.deadline >= block.timestamp, "Deadline expired");
        require(params.sharesBurn > 0, "Invalid shares amount");
        
        // Calculate dummy output amounts
        amount0Out = params.sharesBurn * 2;
        amount1Out = params.sharesBurn * 3;
        
        // Check slippage conditions
        require(amount0Out >= params.amount0Min, "Too much slippage on token0");
        require(amount1Out >= params.amount1Min, "Too much slippage on token1");
        
        // Return a dummy negative delta
        delta = toBalanceDelta(-int128(int256(amount0Out)), -int128(int256(amount1Out)));
        
        return (delta, amount0Out, amount1Out);
    }

    function claimAndReinvestFees() external override {
        // No-op for mock
    }
}

/**
 * @title IFullRangeTest
 * @notice Tests for the IFullRange interface
 */
contract IFullRangeTest is Test {
    FullRangeMock fullRangeMock;
    
    // Test constants
    address constant ALICE = address(0x1);
    uint256 constant DEADLINE_OFFSET = 1 hours;
    
    function setUp() public {
        fullRangeMock = new FullRangeMock();
        vm.warp(1000); // Set block timestamp
    }
    
    /**
     * @notice Helper to create a mock PoolKey
     */
    function createMockPoolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x2)),
            currency1: Currency.wrap(address(0x3)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }
    
    /**
     * @notice Helper function to compare PoolId values
     */
    function assertEqPoolId(PoolId a, PoolId b, string memory errorMessage) internal {
        assertEq(PoolId.unwrap(a), PoolId.unwrap(b), errorMessage);
    }
    
    /**
     * @notice Test initializing a new pool
     */
    function testInitializeNewPool() public {
        PoolKey memory key = createMockPoolKey();
        uint160 initialSqrtPriceX96 = 1 << 96; // 1.0 as Q96

        PoolId poolId = fullRangeMock.initializeNewPool(key, initialSqrtPriceX96);
        
        // Verify the pool was initialized
        assertTrue(fullRangeMock.initializedPools(poolId), "Pool should be initialized");
        
        // Verify the poolId matches what we'd expect
        assertEqPoolId(poolId, key.toId(), "PoolId should match the expected value");
    }
    
    /**
     * @notice Test depositing liquidity
     */
    function testDeposit() public {
        // First initialize a pool
        PoolKey memory key = createMockPoolKey();
        PoolId poolId = fullRangeMock.initializeNewPool(key, 1 << 96);
        
        // Create deposit parameters
        DepositParams memory params = DepositParams({
            poolId: poolId,
            amount0Desired: 1000,
            amount1Desired: 2000,
            amount0Min: 900,
            amount1Min: 1800,
            to: ALICE,
            deadline: block.timestamp + DEADLINE_OFFSET
        });
        
        // Perform deposit
        BalanceDelta delta = fullRangeMock.deposit(params);
        
        // Verify returned delta
        assertEq(delta.amount0(), int128(int256(params.amount0Min)), "Delta amount0 incorrect");
        assertEq(delta.amount1(), int128(int256(params.amount1Min)), "Delta amount1 incorrect");
    }
    
    /**
     * @notice Test depositing liquidity with deadline validation
     */
    function testDepositDeadlineRevert() public {
        // First initialize a pool
        PoolKey memory key = createMockPoolKey();
        PoolId poolId = fullRangeMock.initializeNewPool(key, 1 << 96);
        
        // Create deposit parameters with expired deadline
        DepositParams memory params = DepositParams({
            poolId: poolId,
            amount0Desired: 1000,
            amount1Desired: 2000,
            amount0Min: 900,
            amount1Min: 1800,
            to: ALICE,
            deadline: block.timestamp - 1 // Expired
        });
        
        // Expect revert
        vm.expectRevert("Deadline expired");
        fullRangeMock.deposit(params);
    }
    
    /**
     * @notice Test withdrawing liquidity
     */
    function testWithdraw() public {
        // First initialize a pool
        PoolKey memory key = createMockPoolKey();
        PoolId poolId = fullRangeMock.initializeNewPool(key, 1 << 96);
        
        // Create withdraw parameters
        WithdrawParams memory params = WithdrawParams({
            poolId: poolId,
            sharesBurn: 100,
            amount0Min: 150, // Less than 100 * 2 = 200
            amount1Min: 250, // Less than 100 * 3 = 300
            deadline: block.timestamp + DEADLINE_OFFSET
        });
        
        // Perform withdrawal
        (BalanceDelta delta, uint256 amount0Out, uint256 amount1Out) = fullRangeMock.withdraw(params);
        
        // Verify returned amounts
        assertEq(amount0Out, 200, "Amount0 out incorrect");
        assertEq(amount1Out, 300, "Amount1 out incorrect");
        
        // Verify delta is negative
        assertEq(delta.amount0(), -int128(int256(amount0Out)), "Delta amount0 should be negative");
        assertEq(delta.amount1(), -int128(int256(amount1Out)), "Delta amount1 should be negative");
    }
    
    /**
     * @notice Test withdrawing with slippage failure
     */
    function testWithdrawSlippageRevert() public {
        // First initialize a pool
        PoolKey memory key = createMockPoolKey();
        PoolId poolId = fullRangeMock.initializeNewPool(key, 1 << 96);
        
        // Create withdraw parameters with high minimum amounts
        WithdrawParams memory params = WithdrawParams({
            poolId: poolId,
            sharesBurn: 100,
            amount0Min: 201, // More than 100 * 2 = 200
            amount1Min: 250, // Less than 100 * 3 = 300
            deadline: block.timestamp + DEADLINE_OFFSET
        });
        
        // Expect revert
        vm.expectRevert("Too much slippage on token0");
        fullRangeMock.withdraw(params);
    }
    
    /**
     * @notice Test claiming and reinvesting fees (simple call coverage)
     */
    function testClaimAndReinvestFees() public {
        // This just ensures coverage of the function call
        fullRangeMock.claimAndReinvestFees();
        // No assertions needed as it's a no-op in the mock
    }
    
    /**
     * @notice Test struct CallbackData coverage
     */
    function testCallbackDataStruct() public pure {
        // Create a CallbackData struct to ensure coverage
        ModifyLiquidityParams memory modParams = ModifyLiquidityParams({
            tickLower: -100,
            tickUpper: 100,
            liquidityDelta: 1000,
            salt: keccak256("FullRangeHook")
        });
        
        CallbackData memory callbackData = CallbackData({
            sender: ALICE,
            key: createMockPoolKey(),
            params: modParams,
            isHookOp: true
        });
        
        // Use the struct to avoid compiler warnings
        assert(callbackData.isHookOp);
        assert(callbackData.sender == ALICE);
        assert(callbackData.params.liquidityDelta == 1000);
    }
} 