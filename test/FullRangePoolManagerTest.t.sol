// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title FullRangePoolManagerTest
 * @notice Unit tests covering dynamic-fee pool creation with 90%+ coverage.
 *
 * Phase 2 Requirements:
 *  • Test dynamic-fee check
 *  • Test successful pool creation
 *  • Test revert if not dynamic fee
 *  • Test revert if caller not governance
 */

import "forge-std/Test.sol";
import "../src/FullRangePoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/**
 * @dev Mock V4 Pool Manager for testing
 */
contract MockV4Manager {
    // We'll store ephemeral data to confirm calls
    bool public initializeCalled;
    PoolKey public lastPoolKey;
    uint160 public lastSqrtPriceX96;
    uint24 public lastFee; // Store fee separately for testing

    // Mock initialize function
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) 
        external 
        returns (int24) 
    {
        initializeCalled = true;
        lastPoolKey = key;
        lastSqrtPriceX96 = sqrtPriceX96;
        lastFee = key.fee; // Store fee separately
        return 0; // dummy tick
    }
    
    // Mock setLPFee function
    function setLPFee(PoolId, uint24) external {}
}

/**
 * @notice Main test contract for FullRangePoolManager
 */
contract FullRangePoolManagerTest is Test {
    using PoolIdLibrary for PoolKey;
    
    FullRangePoolManager poolManager;
    MockV4Manager mockManager;

    address gov = address(0x1234);
    address nonGov = address(0x5678);

    function setUp() public {
        // Deploy a mock manager & the FullRangePoolManager with governance=gov
        mockManager = new MockV4Manager();
        poolManager = new FullRangePoolManager(IPoolManager(address(mockManager)), gov);

        // give gov some ETH if needed
        vm.deal(gov, 10 ether);
    }

    function createMockPoolKey(uint24 fee) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0xAA)),
            currency1: Currency.wrap(address(0xBB)),
            fee: fee,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function testInitializeNewPoolSuccess() public {
        // We'll impersonate governance
        vm.startPrank(gov);

        // Build a PoolKey with a dynamic fee 0x800000
        PoolKey memory key = createMockPoolKey(0x800000);
        uint160 sqrtPrice = 12345;
        
        // Call initializeNewPool
        PoolId pid = poolManager.initializeNewPool(key, sqrtPrice);

        // Check the manager call
        assertTrue(mockManager.initializeCalled(), "initialize should be called");
        assertEq(mockManager.lastSqrtPriceX96(), sqrtPrice, "Price mismatch");
        assertEq(mockManager.lastFee(), key.fee, "Fee mismatch");
        
        // Check poolInfo storage
        (bool accruedFees, uint128 totalLiq, int24 spacing) = poolManager.poolInfo(pid);
        assertFalse(accruedFees, "accruedFees should be false");
        assertEq(totalLiq, 0, "initial totalLiquidity should be 0");
        assertEq(spacing, 60, "tickSpacing mismatch");

        vm.stopPrank();
    }

    function testInitializeNewPoolRevertNonGovernance() public {
        // Attempt to call from a non-gov address
        vm.startPrank(nonGov);

        PoolKey memory key = createMockPoolKey(0x800000);
        
        vm.expectRevert("Not authorized");
        poolManager.initializeNewPool(key, 55555);
        
        vm.stopPrank();
    }

    function testInitializeNewPoolNotDynamicFee() public {
        // Must be governance
        vm.startPrank(gov);

        // Use a non-dynamic fee
        PoolKey memory key = createMockPoolKey(3000);
        
        vm.expectRevert("NotDynamicFee");
        poolManager.initializeNewPool(key, 99999);

        vm.stopPrank();
    }

    function testConstructorSetup() public {
        // Verify the constructor properly sets values
        assertEq(address(poolManager.manager()), address(mockManager), "Manager address mismatch");
        assertEq(poolManager.governance(), gov, "Governance address mismatch");
    }
} 