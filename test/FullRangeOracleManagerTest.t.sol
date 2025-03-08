// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title FullRangeOracleManagerTest
 * @notice Unit tests for the oracle throttling logic introduced in Phase 5.
 *         Achieves 90%+ coverage by testing:
 *           - block threshold
 *           - tick difference threshold
 *           - successful oracle update
 *           - no update if thresholds not met
 */

import "forge-std/Test.sol";
import "../src/FullRangeOracleManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC6909Claims} from "v4-core/src/interfaces/external/IERC6909Claims.sol";
import {IProtocolFees} from "v4-core/src/interfaces/IProtocolFees.sol";
import {IExtsload} from "v4-core/src/interfaces/IExtsload.sol";
import {IExttload} from "v4-core/src/interfaces/IExttload.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

// Minimal mocks

contract MockTruncGeoOracleMulti is ITruncGeoOracleMulti {
    // State variables - internal with external accessors/setters
    bool internal _called;
    uint24 internal _lastKeyFee;
    int24 internal _lastKeyTickSpacing;
    address internal _lastKeyCurrency0;
    address internal _lastKeyCurrency1;

    // Accessors
    function called() external view returns (bool) {
        return _called;
    }
    
    function setCalled(bool value) external {
        _called = value;
    }
    
    function lastKeyFee() external view returns (uint24) {
        return _lastKeyFee;
    }
    
    function lastKeyTickSpacing() external view returns (int24) {
        return _lastKeyTickSpacing;
    }
    
    function lastKeyCurrency0() external view returns (address) {
        return _lastKeyCurrency0;
    }
    
    function lastKeyCurrency1() external view returns (address) {
        return _lastKeyCurrency1;
    }

    function updateObservation(PoolKey calldata key) external {
        _called = true;
        // Store key components for later assertions
        _lastKeyFee = key.fee;
        _lastKeyTickSpacing = key.tickSpacing;
        _lastKeyCurrency0 = Currency.unwrap(key.currency0);
        _lastKeyCurrency1 = Currency.unwrap(key.currency1);
    }
}

// Mock implementation that correctly works with StateLibrary.getSlot0
contract MockPoolManagerForOracle is IPoolManager {
    int24 public mockTick;
    uint160 public mockSqrtPriceX96;
    bool public shouldUpdateOracle = true; // Add this flag to control oracle updates in tests
    
    function setMockTick(int24 _tick) external {
        mockTick = _tick;
    }
    
    function setMockSqrtPriceX96(uint160 _price) external {
        mockSqrtPriceX96 = _price;
    }
    
    function setShouldUpdateOracle(bool _shouldUpdate) external {
        shouldUpdateOracle = _shouldUpdate;
    }
    
    // This function is specifically designed to work with StateLibrary.getSlot0
    function extsload(bytes32 slot) external view returns (bytes32) {
        // Pack values into bytes32 to simulate storage layout
        bytes32 result;
        assembly {
            // Format: [lpFee (24 bits)][protocolFee (24 bits)][tick (24 bits)][sqrtPriceX96 (160 bits)]
            let tickValue := sload(mockTick.slot)
            let sqrtPrice := sload(mockSqrtPriceX96.slot)
            
            // First pack the sqrtPriceX96 in the lowest 160 bits
            result := and(sqrtPrice, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            
            // Then add the tick (with sign extension) in the next 24 bits
            // Note: For a signed value like tick, we need to ensure sign extension
            result := or(result, shl(160, and(tickValue, 0xFFFFFF)))
        }
        return result;
    }
    
    // Direct implementation for tests
    function getSlot0(PoolId) external view returns (uint160, int24, uint24, uint24) {
        return (mockSqrtPriceX96, mockTick, 0, 0);
    }
    
    // Empty implementations to satisfy the interface
    function extsload(bytes32, uint256) external pure returns (bytes32[] memory) { return new bytes32[](0); }
    function extsload(bytes32[] calldata) external pure returns (bytes32[] memory) { return new bytes32[](0); }
    function exttload(bytes32) external pure returns (bytes32) { return bytes32(0); }
    function exttload(bytes32[] calldata) external pure returns (bytes32[] memory) { return new bytes32[](0); }
    
    // Other required interface methods with minimal implementations
    function initialize(PoolKey calldata, uint160) external pure returns (int24) { return 0; }
    function modifyLiquidity(PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (BalanceDelta, BalanceDelta) { return (BalanceDelta.wrap(0), BalanceDelta.wrap(0)); }
    function swap(PoolKey calldata, SwapParams calldata, bytes calldata) external pure returns (BalanceDelta) { return BalanceDelta.wrap(0); }
    function donate(PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (BalanceDelta) { return BalanceDelta.wrap(0); }
    function take(Currency, address, uint256) external pure {}
    function settle() external payable returns (uint256) { return 0; }
    function settleFor(address) external payable returns (uint256) { return 0; }
    function mint(address, uint256, uint256) external pure {}
    function burn(address, uint256, uint256) external pure {}
    function sync(Currency) external pure {}
    function clear(Currency, uint256) external pure {}
    function updateDynamicLPFee(PoolKey calldata, uint24) external pure {}
    function unlock(bytes calldata) external pure returns (bytes memory) { return bytes(""); }
    function allowance(address, address, uint256) external pure returns (uint256) { return 0; }
    function approve(address, uint256, uint256) external pure returns (bool) { return false; }
    function balanceOf(address, uint256) external pure returns (uint256) { return 0; }
    function isOperator(address, address) external pure returns (bool) { return false; }
    function setOperator(address, bool) external pure returns (bool) { return false; }
    function transfer(address, uint256, uint256) external pure returns (bool) { return false; }
    function transferFrom(address, address, uint256, uint256) external pure returns (bool) { return false; }
    function collectProtocolFees(address, Currency, uint256) external pure returns (uint256) { return 0; }
    function protocolFeeController() external pure returns (address) { return address(0); }
    function protocolFeesAccrued(Currency) external pure returns (uint256) { return 0; }
    function setProtocolFee(PoolKey memory, uint24) external pure {}
    function setProtocolFeeController(address) external pure {}
}

contract FullRangeOracleManagerTest is Test {
    FullRangeOracleManager oracleManager;
    MockTruncGeoOracleMulti mockOracle;
    MockPoolManagerForOracle mockPM;

    PoolKey testKey;
    PoolId testPid;
    
    // Event signature for testing
    event OracleUpdated(bytes32 indexed poolIdHash, int24 oldTick, int24 newTick);

    function setUp() public {
        mockOracle = new MockTruncGeoOracleMulti();
        mockPM = new MockPoolManagerForOracle();
        oracleManager = new FullRangeOracleManager(mockPM, address(mockOracle));

        // Set mock values
        mockPM.setMockTick(100);
        mockPM.setMockSqrtPriceX96(123456);

        // build a PoolKey
        testKey = PoolKey({
            currency0: Currency.wrap(makeAddr("currency0")),
            currency1: Currency.wrap(makeAddr("currency1")),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        testPid = PoolIdLibrary.toId(testKey);
    }

    function testUpdateOracleSuccess() public {
        // For first update, it should always update regardless of thresholds
        // Expect the event to be emitted
        vm.expectEmit(true, true, true, true);
        emit OracleUpdated(PoolId.unwrap(testPid), 0, 100);
        
        oracleManager.updateOracleWithThrottle(testKey);

        // check that the external oracle was called
        assertTrue(mockOracle.called(), "oracle's updateObservation should be called");
        assertEq(mockOracle.lastKeyFee(), 0x800000, "pool key fee mismatch");

        // check lastOracleTick, lastOracleUpdateBlock
        bytes32 pidHash = PoolId.unwrap(testPid);
        assertEq(oracleManager.lastOracleTick(pidHash), 100, "should store new tick");
        assertEq(oracleManager.lastOracleUpdateBlock(pidHash), block.number, "should store this block");
    }

    function testSkipUpdateIfBlockThresholdNotMetAndTickDiffSmall() public {
        // First update to establish baseline
        oracleManager.updateOracleWithThrottle(testKey);
        
        // Reset the called flag
        mockOracle.setCalled(false);
        
        // Try second update in same block - should be skipped due to block threshold
        oracleManager.updateOracleWithThrottle(testKey);
        
        // The oracle should not have been called
        assertFalse(mockOracle.called(), "oracle should not be called when block threshold not met");
    }

    function testUpdateIfBlockThresholdMet() public {
        // First update
        oracleManager.updateOracleWithThrottle(testKey);
        
        // Roll to next block
        vm.roll(block.number + 2); // Move 2 blocks forward (> blockUpdateThreshold of 1)
        
        // Reset the called flag
        mockOracle.setCalled(false);
        
        // Second update - should happen due to block threshold being met
        oracleManager.updateOracleWithThrottle(testKey);
        
        // The oracle should have been called
        assertTrue(mockOracle.called(), "oracle should be called when block threshold met");
    }

    function testUpdateIfTickDiffThresholdMet() public {
        // First update
        oracleManager.updateOracleWithThrottle(testKey);
        
        // Same block, but large tick change
        mockPM.setMockTick(105); // diff of 5 > tickDiffThreshold of 1
        
        // Reset the called flag
        mockOracle.setCalled(false);
        
        // Second update - should happen due to tick difference threshold being met
        oracleManager.updateOracleWithThrottle(testKey);
        
        // The oracle should have been called
        assertTrue(mockOracle.called(), "oracle should be called when tick diff threshold met");
    }

    function testChangeBlockUpdateThreshold() public {
        // Default is 1
        assertEq(oracleManager.blockUpdateThreshold(), 1, "default block threshold should be 1");
        
        // Update it
        oracleManager.setBlockUpdateThreshold(5);
        
        // Check it was updated
        assertEq(oracleManager.blockUpdateThreshold(), 5, "block threshold should be updated to 5");
    }

    function testChangeTickDiffThreshold() public {
        // Default is 1
        assertEq(oracleManager.tickDiffThreshold(), 1, "default tick diff threshold should be 1");
        
        // Update it
        oracleManager.setTickDiffThreshold(10);
        
        // Check it was updated
        assertEq(oracleManager.tickDiffThreshold(), 10, "tick diff threshold should be updated to 10");
    }
    
    function testComplexScenario() public {
        // First update
        oracleManager.updateOracleWithThrottle(testKey);
        
        // Set higher thresholds
        oracleManager.setBlockUpdateThreshold(3);
        oracleManager.setTickDiffThreshold(5);
        
        // Move forward 2 blocks (< new threshold of 3)
        vm.roll(block.number + 2);
        
        // Change tick a little (< new threshold of 5)
        mockPM.setMockTick(102); // diff of 2
        
        // Reset the called flag
        mockOracle.setCalled(false);
        
        // Should not update (neither threshold met)
        oracleManager.updateOracleWithThrottle(testKey);
        assertFalse(mockOracle.called(), "oracle should not be called when neither threshold met");
        
        // Now exceed tick threshold
        mockPM.setMockTick(110); // diff of 10 > threshold of 5
        
        // Should update (tick threshold met)
        oracleManager.updateOracleWithThrottle(testKey);
        assertTrue(mockOracle.called(), "oracle should be called when tick threshold met");
        
        // Reset the called flag
        mockOracle.setCalled(false);
        
        // Now exceed block threshold
        vm.roll(block.number + 4); // > threshold of 3
        
        // Reset tick to avoid tick threshold
        mockPM.setMockTick(111); // diff of 1 < threshold of 5
        
        // Should update (block threshold met)
        oracleManager.updateOracleWithThrottle(testKey);
        assertTrue(mockOracle.called(), "oracle should be called when block threshold met");
    }

    function testAbsDiffFunction() public {
        // First set up a known state for clarity
        mockPM.setMockTick(100);
        mockPM.setMockSqrtPriceX96(5000);
        
        // Set thresholds that are easy to test
        oracleManager.setBlockUpdateThreshold(2); // Don't update unless 2+ blocks have passed
        oracleManager.setTickDiffThreshold(20);   // Don't update unless tick diff >= 20
        
        // First update to establish baseline
        oracleManager.updateOracleWithThrottle(testKey);
        
        // Verify initial state
        bytes32 pidHash = PoolId.unwrap(testPid);
        int24 storedTick = oracleManager.lastOracleTick(pidHash);
        assertEq(storedTick, 100, "Initial tick should be 100");
        assertEq(oracleManager.lastOracleUpdateBlock(pidHash), block.number, "Initial block should be recorded");
        
        // First test: Block threshold not met, tick diff < threshold
        // Same block, small tick change
        mockOracle.setCalled(false);
        mockPM.setMockTick(110); // Diff of 10, threshold is 20
        
        // Should NOT update (block same, tick diff too small)
        oracleManager.updateOracleWithThrottle(testKey);
        
        // Oracle should NOT have been called
        assertFalse(mockOracle.called(), "Oracle should not be called when both thresholds not met");
        
        // Second test: Block threshold met, tick diff irrelevant
        vm.roll(block.number + 3); // Move 3 blocks forward (> blockUpdateThreshold of 2)
        mockOracle.setCalled(false);
        
        // Should update (block threshold met)
        oracleManager.updateOracleWithThrottle(testKey);
        
        // Oracle should have been called due to block threshold
        assertTrue(mockOracle.called(), "Oracle should be called when block threshold met");
        
        // Verify update occurred
        assertEq(oracleManager.lastOracleTick(pidHash), 110, "Tick should be updated to 110");
        assertEq(oracleManager.lastOracleUpdateBlock(pidHash), block.number, "Block number should be updated");
        
        // Third test: Block threshold not met, but tick diff > threshold
        vm.roll(block.number + 1); // Just one block (< blockUpdateThreshold of 2)
        mockOracle.setCalled(false);
        mockPM.setMockTick(135); // Diff of 25 from current 110 (> tickDiffThreshold of 20)
        
        // Should update (tick diff threshold met)
        oracleManager.updateOracleWithThrottle(testKey);
        
        // Oracle should have been called due to tick threshold
        assertTrue(mockOracle.called(), "Oracle should be called when tick diff threshold met");
    }
} 