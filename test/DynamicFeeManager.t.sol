// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPoolPolicy} from "../src/interfaces/IPoolPolicy.sol";
import {DynamicFeeManager} from "../src/DynamicFeeManager.sol";
import {TruncGeoOracleMulti} from "../src/TruncGeoOracleMulti.sol";
import {MockPoolManager} from "mocks/MockPoolManager.sol";
import {MockPolicyManager} from "mocks/MockPolicyManager.sol";
import {DummyFullRangeHook} from "utils/DummyFullRangeHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// @notice Event emitted when initialize() is called on an already-initialized pool
/// @dev Duplicated from DynamicFeeManager.
///      If the signature there changes, update this copy too.
event AlreadyInitialized(PoolId indexed id);

/// Minimal stub – we do not inherit IPoolPolicy; we only supply the
/// function(s) touched by the unit-test at runtime.
/// @dev WARNING: This stub only implements getDefaultDynamicFee(). If future DynamicFeeManager
/// versions start using other IPoolPolicy methods, tests will revert. Add the needed methods then.
contract StubPolicy {
    function getDefaultDynamicFee() external pure returns (uint256) {
        return 3_000; // 0.30 % – well below 2**96-1
    }
    /* everything else can be left un-implemented for this unit-test */
}

contract DynamicFeeManagerTest is Test {
    using PoolIdLibrary for PoolId;

    TruncGeoOracleMulti oracle;
    DynamicFeeManager dfm;
    MockPoolManager poolManager;
    MockPolicyManager policyManager;
    PoolKey poolKey;
    PoolId poolId;

    struct CapTestCase {
        uint24 cap;
        uint256 expectPpm;
        string note;
    }

    function setUp() public {
        // We don't need a real policy contract for this unit-test; a
        // zero-address placeholder is fine and avoids referencing an
        // undeclared identifier.
        // IPoolManager _dummyPM = IPoolManager(address(1));
        // IPoolPolicy  _policy  = IPoolPolicy(address(0));

        // Stand-in objects – we never touch them again, so avoid "unused" warnings
        IPoolPolicy  _policy = IPoolPolicy(address(0));

        // (The dummy PoolManager literal below was producing 6133. Remove it.)

        poolManager = new MockPoolManager();

        // Deploy DFM with corrected argument order: (policy, manager, owner)
        policyManager = new MockPolicyManager(); // Deploy MockPolicyManager FIRST

        // configure mock policy for this pool (same values as above)
        MockPolicyManager.Params memory pp;
        pp.minBaseFee      = 100;
        pp.maxBaseFee      = 10_000;
        pp.stepPpm         = 50_000;
        pp.freqScaling     = 1e18;
        pp.budgetPpm       = 100_000;
        pp.decayWindow     = 86_400;
        pp.updateInterval  = 600;
        pp.defaultMaxTicks = 50;

        // NB: poolKey/poolId are created later, so we temporarily create a dummy id

        // Deploy Dummy Hook first
        DummyFullRangeHook fullRange = new DummyFullRangeHook(address(0));
        // Deploy Oracle with hook address
        oracle = new TruncGeoOracleMulti(
            IPoolManager(address(poolManager)),
            policyManager,                 // policy contract
            address(fullRange),      // authorised hook
            address(this)            // owner / governance
        );
        // Set oracle address on hook (if needed by tests)
        // fullRange.setOracle(address(oracle));

        // Deploy DFM
        // ctor is (IPoolPolicy policyMgr, address oracle, address hook)
        dfm = new DynamicFeeManager(address(this), policyManager, address(oracle), address(fullRange)); // Use address(this) as owner, deployed oracle and hook

        // ... (rest of setup like poolKey, poolId, enableOracle)
        address token0 = address(0xA11CE);
        address token1 = address(0xB0B);
        poolKey = PoolKey({ // Define poolKey
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(fullRange))
        });
        poolId = poolKey.toId();

        // Update policy params for the real poolId
        policyManager.setParams(poolId, pp);

        // Enable oracle for the pool
        vm.prank(address(fullRange));
        oracle.enableOracleForPool(poolKey);

        // Governor override removed – rely on the default MTB set during enableOracleForPool

        // Oracle auto-tune guard = 1 day; jump once so first tune is allowed
        vm.warp(block.timestamp + 1 days + 1);

        // Initialize DFM for the pool
        (, int24 initialTick,,) = poolManager.getSlot0(poolId);
        vm.prank(address(this)); // Assuming deployer/governance can initialize
        dfm.initialize(poolId, initialTick);
    }

    /// @dev helper that updates the oracle's cap through its own setter
    function _setCap(PoolId /* pid */, uint24 /* cap */) internal {  // 5667 x2
        // no-op in tests
    }

    function testInitializeIdempotent() public {
        // Test idempotency with default oracle cap

        // First initialization should succeed
        dfm.initialize(poolId, 0); // Use poolId from setUp
        uint256 initialBaseFee = dfm.baseFeeFromCap(poolId); // Use poolId from setUp

        // Second initialization should not revert and should emit event with correct args
        vm.expectEmit(true, true, false, true);
        emit AlreadyInitialized(poolId); // Use poolId from setUp
        dfm.initialize(poolId, 0); // Use poolId from setUp

        // Third initialization should behave the same way
        vm.expectEmit(true, true, false, true);
        emit AlreadyInitialized(poolId); // Use poolId from setUp
        dfm.initialize(poolId, 0); // Use poolId from setUp

        // Verify state remained unchanged throughout
        uint256 finalBaseFee = dfm.baseFeeFromCap(poolId); // Use poolId from setUp
        assertEq(finalBaseFee, initialBaseFee, "Base fee should remain unchanged after multiple inits");
        assertTrue(finalBaseFee > 0, "Base fee should remain set after multiple inits");
    }
}

// Legacy step-based tests removed as they no longer apply to the new fee model
// which derives fees directly from oracle caps (1 tick = 100 ppm = 0.01%)
