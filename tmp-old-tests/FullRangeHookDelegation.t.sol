// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/*
 * This test file has been moved to old-tests and commented out.
 * It is kept for reference but is no longer used in the project.
 * The new testing approach uses LocalUniswapV4TestBase.t.sol for local deployments.
 */

/*

import "forge-std/Test.sol";
import {Spot} from "../src/Spot.sol";
import {DefaultHookHandler} from "../src/DefaultHookHandler.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/**
 * @title SpotHookDelegation Test
 * @notice Tests the hook delegation pattern implementation in Spot
 */
contract FullRangeHookDelegationTest is Test {
    address mockPoolManager;
    address mockHookHandler;
    Spot mockFullRange;

    // Mock all the constructor dependencies
    function setUp() public {
        mockPoolManager = makeAddr("poolManager");
        mockHookHandler = makeAddr("defaultHookHandler");
        
        vm.mockCall(
            mockPoolManager,
            abi.encodeWithSelector(IPoolManager.unlock.selector),
            abi.encode(bytes(""))
        );
        
        // Create mock versions of all dependencies for lightweight testing
        vm.mockCall(
            mockHookHandler,
            abi.encodeWithSelector(DefaultHookHandler.handleBeforeAddLiquidity.selector),
            abi.encode(IHooks.beforeAddLiquidity.selector)
        );
        
        vm.mockCall(
            mockHookHandler,
            abi.encodeWithSelector(DefaultHookHandler.handleAfterAddLiquidity.selector),
            abi.encode(IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA)
        );
    }
    
    function testHookDelegation() public {
        // Test that the Spot contract correctly delegates to DefaultHookHandler
        // when hooks are called. This would be a more complex integration test
        // with actual contract deployment. In this case, we're just testing the concept.
        
        // Deploy DefaultHookHandler first (not using mocks for the actual test)
        DefaultHookHandler defaultHookHandler = new DefaultHookHandler();
        
        // Verify default hook outputs match expected values
        bytes4 beforeAddLiquiditySelector = defaultHookHandler.handleBeforeAddLiquidity();
        assertEq(beforeAddLiquiditySelector, IHooks.beforeAddLiquidity.selector);
        
        (bytes4 afterAddLiquiditySelector, BalanceDelta delta) = defaultHookHandler.handleAfterAddLiquidity();
        assertEq(afterAddLiquiditySelector, IHooks.afterAddLiquidity.selector);
        assertEq(BalanceDelta.unwrap(delta), BalanceDelta.unwrap(BalanceDeltaLibrary.ZERO_DELTA));
        
        (bytes4 beforeSwapSelector, BeforeSwapDelta bsDelta, uint24 fee) = defaultHookHandler.handleBeforeSwap();
        assertEq(beforeSwapSelector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(bsDelta), BeforeSwapDelta.unwrap(BeforeSwapDeltaLibrary.ZERO_DELTA));
        assertEq(fee, 0);
    }
} 
*/
