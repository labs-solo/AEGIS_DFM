// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/*
 * This test file has been moved to old-tests and commented out.
 * It is kept for reference but is no longer used in the project.
 * The new testing approach uses LocalUniswapV4TestBase.t.sol for local deployments.
 */

/*

/**
 * @title FullRangePoolManagerTest
 * @notice Unit tests covering dynamic-fee pool creation with 90%+ coverage.
 *
 * Requirements:
 *  • Test pool registration via hook callbacks
 *  • Test dynamic-fee check
 *  • Test successful pool creation
 *  • Test revert if not dynamic fee
 *  • Test revert if caller not authorized
 */

import "forge-std/Test.sol";
import "../src/FullRangePoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {FullRange} from "../src/FullRange.sol";
import "./utils/PoolCreationHelper.sol";

/**
 * @dev Mock V4 Pool Manager for testing
 */
contract MockV4Manager {
    // We'll store ephemeral data to confirm calls
    bool public initializeCalled;
    PoolKey public lastPoolKey;
    uint160 public lastSqrtPriceX96;
    uint24 public lastFee; // Store fee separately for testing
    address public lastSender;

    // Mock initialize function
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) 
        external 
        returns (int24) 
    {
        initializeCalled = true;
        lastPoolKey = key;
        lastSqrtPriceX96 = sqrtPriceX96;
        lastFee = key.fee; // Store fee separately
        lastSender = msg.sender;
        
        // Simulate hook callbacks
        if (address(key.hooks) != address(0)) {
            // Call beforeInitialize
            IHooks(address(key.hooks)).beforeInitialize(msg.sender, key, sqrtPriceX96);
            // Call afterInitialize with a dummy tick
            IHooks(address(key.hooks)).afterInitialize(msg.sender, key, sqrtPriceX96, 0);
        }
        
        return 0; // dummy tick
    }
    
    // Mock setLPFee function
    function setLPFee(PoolId, uint24) external {}
}

// Mock policies for testing
contract MockPoolCreationPolicy {
    function canCreatePool(address, PoolKey calldata) external pure returns (bool) {
        return true;
    }
}

contract MockVTierPolicy {
    function isValidVtier(uint24, int24) external pure returns (bool) {
        return true;
    }
}

contract MockTickScalingPolicy {
    function isTickSpacingSupported(int24) external pure returns (bool) {
        return true;
    }
}

contract MockFeePolicy {
    function getFeeUpdateInterval() external pure returns (uint256) {
        return 86400;
    }
}

/**
 * @notice Main test contract for FullRangePoolManager
 */
contract FullRangePoolManagerTest is Test {
    using PoolIdLibrary for PoolKey;
    
    FullRangePoolManager poolManager;
    MockV4Manager mockManager;
    FullRange mockFullRange;

    address gov = address(0x1234);
    address nonGov = address(0x5678);

    function setUp() public {
        // Deploy a mock manager & the FullRangePoolManager with governance=gov
        mockManager = new MockV4Manager();
        poolManager = new FullRangePoolManager(IPoolManager(address(mockManager)), gov);
        
        // Create mock policies
        MockPoolCreationPolicy mockPoolCreationPolicy = new MockPoolCreationPolicy();
        MockVTierPolicy mockVTierPolicy = new MockVTierPolicy();
        MockTickScalingPolicy mockTickScalingPolicy = new MockTickScalingPolicy();
        MockFeePolicy mockFeePolicy = new MockFeePolicy();
        
        // Deploy mock FullRange (we only need it for hook callbacks)
        mockFullRange = new FullRange(
            IPoolManager(address(mockManager)),
            poolManager,
            FullRangeLiquidityManager(address(0)), // Not used in this test
            FullRangeOracleManager(address(0)),    // Not used in this test
            FullRangeDynamicFeeManager(address(0)),// Not used in this test
            gov,
            mockPoolCreationPolicy,
            mockVTierPolicy,
            mockFeePolicy,
            mockTickScalingPolicy
        );
        
        // Set the FullRange address in the pool manager
        vm.prank(gov);
        poolManager.setFullRangeAddress(address(mockFullRange));

        // give gov some ETH if needed
        vm.deal(gov, 10 ether);
    }

    function createMockPoolKey(uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0xAA)),
            currency1: Currency.wrap(address(0xBB)),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(mockFullRange))
        });
    }

    function testRegisterPoolSuccess() public {
        // We'll impersonate governance 
        vm.startPrank(gov);

        // Build a PoolKey with a dynamic fee 0x800000
        PoolKey memory key = createMockPoolKey(0x800000);
        uint160 sqrtPrice = 12345;
        PoolId pid = key.toId();
        
        // Call registerPool
        poolManager.registerPool(pid, key, sqrtPrice);

        // Check poolInfo storage
        (bool accruedFees, uint128 totalLiq, int24 spacing) = poolManager.poolInfo(pid);
        assertFalse(accruedFees, "accruedFees should be false");
        assertEq(totalLiq, 0, "initial totalLiquidity should be 0");
        assertEq(spacing, 60, "tickSpacing mismatch");
        
        // Check the pool key was stored correctly
        PoolKey memory storedKey = poolManager.getPoolKey(pid);
        assertEq(Currency.unwrap(storedKey.currency0), Currency.unwrap(key.currency0), "Currency0 mismatch");
        assertEq(Currency.unwrap(storedKey.currency1), Currency.unwrap(key.currency1), "Currency1 mismatch");
        assertEq(storedKey.fee, key.fee, "Fee mismatch");
        assertEq(storedKey.tickSpacing, key.tickSpacing, "TickSpacing mismatch");

        vm.stopPrank();
    }

    function testRegisterPoolRevertNonAuthorized() public {
        // Attempt to call from a non-authorized address
        vm.startPrank(nonGov);

        PoolKey memory key = createMockPoolKey(0x800000);
        PoolId pid = key.toId();
        
        vm.expectRevert("NotAuthorized");
        poolManager.registerPool(pid, key, 55555);
        
        vm.stopPrank();
    }

    function testRegisterPoolAlreadyExists() public {
        // Must be governance
        vm.startPrank(gov);

        // Register a pool
        PoolKey memory key = createMockPoolKey(0x800000);
        PoolId pid = key.toId();
        poolManager.registerPool(pid, key, 12345);
        
        // Try to register it again
        vm.expectRevert("PoolAlreadyExists");
        poolManager.registerPool(pid, key, 99999);

        vm.stopPrank();
    }

    function testDynamicFeeCheck() public {
        // Test the dynamic fee check
        assertTrue(poolManager.isDynamicFee(0x800000), "0x800000 should be recognized as dynamic fee");
        assertFalse(poolManager.isDynamicFee(3000), "3000 should not be recognized as dynamic fee");
    }

    function testPoolCreationViaHookCallback() public {
        // Test full flow of pool creation via hook callbacks
        
        // Build a PoolKey with a dynamic fee 0x800000
        PoolKey memory key = createMockPoolKey(0x800000);
        uint160 sqrtPrice = 12345;
        
        // Initialize pool via manager (will trigger hook callbacks)
        mockManager.initialize(key, sqrtPrice);
        
        // Check that the pool was registered through callbacks
        PoolId pid = key.toId();
        PoolKey memory storedKey = poolManager.getPoolKey(pid);
        
        assertEq(Currency.unwrap(storedKey.currency0), Currency.unwrap(key.currency0), "Currency0 mismatch");
        assertEq(Currency.unwrap(storedKey.currency1), Currency.unwrap(key.currency1), "Currency1 mismatch");
        assertEq(storedKey.fee, key.fee, "Fee mismatch");
        assertEq(storedKey.tickSpacing, key.tickSpacing, "TickSpacing mismatch");
    }
} 
*/
