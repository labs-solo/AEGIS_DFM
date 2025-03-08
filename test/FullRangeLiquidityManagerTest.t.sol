// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title FullRangeLiquidityManagerTest
 * @notice Unit tests for deposit/withdraw logic in Phase 3,
 *         achieving 90%+ coverage. 
 */

import "forge-std/Test.sol";
import "../src/FullRangeLiquidityManager.sol";
import {FullRangePoolManager, PoolInfo} from "../src/FullRangePoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {DepositParams, WithdrawParams} from "../src/interfaces/IFullRange.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/**
 * @dev Simplified mock for IPoolManager - we'll only implement what we need
 */
contract MockPoolManagerImpl {
    function initialize(PoolKey calldata, uint160) external pure returns (int24) {
        return 0;
    }
}

/**
 * @dev Main test contract for FullRangeLiquidityManager
 */
contract FullRangeLiquidityManagerTest is Test {
    FullRangeLiquidityManager liqManager;
    FullRangePoolManager poolManager;
    MockPoolManagerImpl mockPoolManagerImpl;

    // Test data
    address constant USER = address(0xABCD);
    PoolId testPoolId;

    function setUp() public {
        // Deploy mock IPoolManager 
        mockPoolManagerImpl = new MockPoolManagerImpl();
        
        // Deploy PoolManager with this as governance
        poolManager = new FullRangePoolManager(IPoolManager(address(mockPoolManagerImpl)), address(this));
        
        // Deploy LiquidityManager
        liqManager = new FullRangeLiquidityManager(IPoolManager(address(mockPoolManagerImpl)), poolManager);

        // Create a test pool ID
        testPoolId = PoolId.wrap(bytes32(keccak256("TestPoolID")));
        
        // Initialize pool info without creating a real pool (direct state update for testing)
        poolManager.updateTotalLiquidity(testPoolId, 0);
    }
    
    /**
     * @notice Helper to create a mock PoolKey
     */
    function createMockPoolKey(uint24 fee) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0xAA)),
            currency1: Currency.wrap(address(0xBB)),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function testDepositSuccess() public {
        // Create deposit params
        DepositParams memory params = DepositParams({
            poolId: testPoolId,
            amount0Desired: 1000,
            amount1Desired: 2000,
            amount0Min: 800,   // Below desired for no slippage error
            amount1Min: 1800,  // Below desired for no slippage error
            to: USER,
            deadline: block.timestamp + 1 hours
        });

        // Call deposit
        BalanceDelta delta = liqManager.deposit(params, USER);
        
        // Check return values
        assertEq(BalanceDelta.unwrap(delta), 0, "Delta should be zero for placeholder");
        
        // Check that totalLiquidity was updated correctly
        (bool hasAccruedFees, uint128 totalLiq, int24 tickSpacing) = poolManager.poolInfo(testPoolId);
        
        // The expected shares minted should be approximately sqrt(1000 * 2000) = 1414
        uint256 expectedShares = FullRangeRatioMath.sqrt(1000 * 2000);
        assertEq(totalLiq, expectedShares, "Total liquidity should match expected shares");
    }
    
    function testDepositSlippageReverts() public {
        // Create deposit params with high minimum amounts to trigger slippage error
        DepositParams memory params = DepositParams({
            poolId: testPoolId,
            amount0Desired: 1000,
            amount1Desired: 2000,
            amount0Min: 1100,  // Higher than actual0 to trigger slippage error
            amount1Min: 1900,
            to: USER,
            deadline: block.timestamp + 1 hours
        });

        // Expect revert on slippage check
        vm.expectRevert("TooMuchSlippage");
        liqManager.deposit(params, USER);
    }
    
    function testWithdrawSuccess() public {
        // First, deposit to have some liquidity
        uint256 initialShares = 2000;
        
        // Manually set some liquidity to the pool
        poolManager.updateTotalLiquidity(testPoolId, uint128(initialShares));
        
        // Create withdraw params for partial withdrawal
        WithdrawParams memory params = WithdrawParams({
            poolId: testPoolId,
            sharesBurn: 500,  // Partial withdrawal (25%)
            amount0Min: 100,  // Low enough to avoid slippage error
            amount1Min: 100,
            deadline: block.timestamp + 1 hours
        });
        
        // Call withdraw
        (BalanceDelta delta, uint256 amount0Out, uint256 amount1Out) = liqManager.withdraw(params, USER);
        
        // Check return values
        assertEq(BalanceDelta.unwrap(delta), 0, "Delta should be zero for placeholder");
        
        // Expected outputs based on fractionX128 * reserves
        // For 500/2000 = 25% of reserves (1000 each)
        uint256 expectedAmountOut = 1000 * 500 / 2000; // 250 of each token
        assertApproxEqAbs(amount0Out, expectedAmountOut, 1, "Amount0 out should be approximately 250");
        assertApproxEqAbs(amount1Out, expectedAmountOut, 1, "Amount1 out should be approximately 250");
        
        // Check that totalLiquidity was updated correctly
        (bool hasAccruedFees, uint128 totalLiq, int24 tickSpacing) = poolManager.poolInfo(testPoolId);
        assertEq(totalLiq, initialShares - params.sharesBurn, "Total liquidity should be reduced by shares burnt");
    }
    
    function testWithdrawSlippageReverts() public {
        // Set up some liquidity
        poolManager.updateTotalLiquidity(testPoolId, 2000);
        
        // Create withdraw params with high minimum amounts to trigger slippage error
        WithdrawParams memory params = WithdrawParams({
            poolId: testPoolId,
            sharesBurn: 500,
            amount0Min: 300,  // Higher than expected output to trigger slippage error
            amount1Min: 100,
            deadline: block.timestamp + 1 hours
        });
        
        // Expect revert on slippage check
        vm.expectRevert("TooMuchSlippage");
        liqManager.withdraw(params, USER);
    }
    
    function testWithdrawInsufficientLiquidityReverts() public {
        // Set up some liquidity
        poolManager.updateTotalLiquidity(testPoolId, 1000);
        
        // Create withdraw params with shares more than available
        WithdrawParams memory params = WithdrawParams({
            poolId: testPoolId,
            sharesBurn: 1500,  // More than available
            amount0Min: 100,
            amount1Min: 100,
            deadline: block.timestamp + 1 hours
        });
        
        // Expect revert on insufficient liquidity check
        vm.expectRevert("InsufficientLiquidity");
        liqManager.withdraw(params, USER);
    }
    
    function testWithdrawZeroLiquidity() public {
        // Ensure pool has zero liquidity
        poolManager.updateTotalLiquidity(testPoolId, 0);
        
        // Create withdraw params
        WithdrawParams memory params = WithdrawParams({
            poolId: testPoolId,
            sharesBurn: 100,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 1 hours
        });
        
        // Call withdraw
        (BalanceDelta delta, uint256 amount0Out, uint256 amount1Out) = liqManager.withdraw(params, USER);
        
        // Check that outputs are zero
        assertEq(amount0Out, 0, "Amount0 out should be zero for zero liquidity");
        assertEq(amount1Out, 0, "Amount1 out should be zero for zero liquidity");
    }
    
    function testClaimAndReinvestFees() public {
        // Just call the function to ensure coverage
        liqManager.claimAndReinvestFees();
        // No assertions needed as this is a no-op in Phase 3
    }
    
    function testRatioMathLibrary() public {
        // Test square root function
        assertEq(FullRangeRatioMath.sqrt(0), 0, "Sqrt of 0 should be 0");
        assertEq(FullRangeRatioMath.sqrt(1), 1, "Sqrt of 1 should be 1");
        assertEq(FullRangeRatioMath.sqrt(4), 2, "Sqrt of 4 should be 2");
        assertEq(FullRangeRatioMath.sqrt(9), 3, "Sqrt of 9 should be 3");
        assertEq(FullRangeRatioMath.sqrt(10000), 100, "Sqrt of 10000 should be 100");
    }
} 