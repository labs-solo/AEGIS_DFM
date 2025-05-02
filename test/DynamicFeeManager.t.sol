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
        IPoolManager dummyPM = IPoolManager(address(1));

        // deploy very small stub and cast to the interface where needed
        StubPolicy stub = new StubPolicy();
        IPoolPolicy policy = IPoolPolicy(address(stub));

        poolManager = new MockPoolManager();
        policyManager = new MockPolicyManager();

        // Deploy Dummy Hook first
        DummyFullRangeHook fullRange = new DummyFullRangeHook(address(0));
        // Deploy Oracle with hook address
        oracle = new TruncGeoOracleMulti(
            IPoolManager(address(poolManager)),
            address(this), // governance
            policyManager,
            address(fullRange) // hook address
        );
        // Set oracle address on hook (if needed by tests)
        // fullRange.setOracle(address(oracle));

        // Deploy DFM
        dfm = new DynamicFeeManager(policyManager, address(oracle), address(fullRange));

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

        // Enable oracle for the pool
        vm.prank(address(fullRange));
        oracle.enableOracleForPool(poolKey);

        // Initialize DFM for the pool
        (, int24 initialTick,,) = poolManager.getSlot0(poolId);
        vm.prank(address(this)); // Assuming deployer/governance can initialize
        dfm.initialize(poolId, initialTick);

        // enable the pool in the oracle before any cap-setting
        oracle.enablePool(
            poolId,
            oracle.getDefaultMaxTicksPerBlock(),   // use defaults
            oracle.getDefaultDynamicFee()
        );
    }

    /// @dev helper that updates the oracle's cap through its own setter
    function _setCap(PoolId pid, uint24 cap) internal {
        // TruncGeoOracleMulti is deployed with `address(this)` as governance,
        // therefore we can call the governance-only setter directly.
        oracle.setMaxTicksPerBlock(pid, cap); // TruncGeoOracleMulti expects PoolId
    }

    function testCapMapping() external {
        PoolId pid = PoolId.wrap(bytes32(uint256(1)));

        CapTestCase[] memory cases = new CapTestCase[](4);
        cases[0] = CapTestCase(42, 4200, "typical small cap");
        cases[1] = CapTestCase(1000, 100000, "medium cap");
        cases[2] = CapTestCase(16_777_215, 1_677_721_500, "uint24 upper-bound");
        cases[3] = CapTestCase(1, 100, "minimum cap");

        for (uint256 i; i < cases.length; ++i) {
            CapTestCase memory tc = cases[i];
            _setCap(pid, tc.cap);
            assertEq(dfm.baseFeeFromCap(pid), tc.expectPpm, tc.note);
        }
    }

    function testInitializeIdempotent() public {
        PoolId pid = PoolId.wrap(bytes32(uint256(1)));

        // ensure a non-zero cap so the base-fee is > 0
        _setCap(pid, 42);

        // First initialization should succeed
        dfm.initialize(pid, 0);
        uint256 initialBaseFee = dfm.baseFeeFromCap(pid);

        // Second initialization should not revert and should emit event with correct args
        vm.expectEmit(true, true, false, true);
        emit AlreadyInitialized(pid);
        dfm.initialize(pid, 0);

        // Third initialization should behave the same way
        vm.expectEmit(true, true, false, true);
        emit AlreadyInitialized(pid);
        dfm.initialize(pid, 0);

        // Verify state remained unchanged throughout
        uint256 finalBaseFee = dfm.baseFeeFromCap(pid);
        assertEq(finalBaseFee, initialBaseFee, "Base fee should remain unchanged after multiple inits");
        assertTrue(finalBaseFee > 0, "Base fee should remain set after multiple inits");
    }
}

// Legacy step-based tests removed as they no longer apply to the new fee model
// which derives fees directly from oracle caps (1 tick = 100 ppm = 0.01%)
